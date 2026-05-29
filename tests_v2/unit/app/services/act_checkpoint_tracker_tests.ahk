; ============================================================
; ActCheckpointTrackerTests
; ============================================================
;
; ActCheckpointTracker is a reactive service with 2 deps:
;   - bus (EventBus)   -> subscribes ZoneEntered + lifecycle
;   - timer (TimerService-like) -> GetRunMs() to capture moment
;
; Core logic (in _OnZoneEntered):
;   - data must have actIndex > 0
;   - If _currentAct > 0 && newAct != _currentAct:
;       _checkpoints[_currentAct] = timer.GetRunMs()  (checkpoint of previous)
;   - _currentAct := newAct (always, even on first)
;
; CaptureCurrentAsCheckpoint:
;   - Called manually by composition root at end of run
;   - Records _checkpoints[_currentAct] := runMs (validated >0)
;
; NOTE: we use `stubTimer` as a local name (case-insensitive
; distinct from the `TimerService` class).


; ------------------------------------------------------------
; Injectable stub for the timer: implements GetRunMs() returning
; a value controlled via SetMs(). Top-level because AHK v2 has
; no nested class.
; ------------------------------------------------------------
class _ActCheckpointStubTimer
{
    _ms := 0
    GetRunMs() => this._ms
    SetMs(ms)
    {
        this._ms := ms
    }
}


class ActCheckpointTrackerTests extends TestCase
{
    bus       := ""
    stubTimer := ""
    svc       := ""

    Setup()
    {
        this.bus       := Fixtures.MakeBus()
        this.stubTimer := _ActCheckpointStubTimer()
        this.svc       := ActCheckpointTracker(this.bus, this.stubTimer)
    }

    Teardown()
    {
        if IsObject(this.svc)
            this.svc.Dispose()
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_timer_missing_get_run_ms",
        "constructor_throws_when_timer_is_string",
        "constructor_subscribes_to_zone_entered",
        "constructor_subscribes_to_lifecycle_events",

        ; --- Defaults ---
        "current_act_zero_initially",
        "checkpoints_empty_initially",
        "current_stage_empty_initially",
        "checkpoints_by_stage_empty_initially",

        ; --- ZoneEntered handler ---
        "first_zone_entered_sets_current_act",
        "first_zone_entered_records_no_checkpoint",
        "same_act_zone_does_not_record_checkpoint",
        "act_transition_records_previous_act_checkpoint",
        "act_transition_uses_timer_run_ms_value",
        "multiple_transitions_accumulate_checkpoints",
        "checkpoint_key_is_previous_act_not_new_one",
        "ignores_zone_entered_without_act_index",
        "ignores_zone_entered_with_zero_act_index",
        "ignores_zone_entered_with_negative_act_index",
        "ignores_zone_entered_with_non_object_data",
        "ignores_transition_when_timer_returns_zero",

        ; --- stage axis (B1 Layer B) ---
        "zone_entered_with_interlude_sets_current_stage",
        "zone_entered_without_stage_defaults_current_stage_to_normal",
        "zone_entered_with_empty_stage_defaults_to_normal",
        "composite_key_format_is_act_pipe_stage",
        "act_transition_records_composite_key_in_by_stage_map",
        "stage_only_transition_records_checkpoint",
        "stage_only_transition_uses_old_stage_in_composite_key",
        "realistic_normal_to_interlude_records_act_4_normal_checkpoint",
        "interlude_transitions_record_interlude_checkpoints",
        "legacy_get_checkpoints_last_write_wins_for_same_act_different_stage",
        "capture_current_as_checkpoint_updates_both_maps",
        "capture_uses_current_stage_in_composite_key",
        "get_checkpoints_by_stage_returns_defensive_copy",
        "reset_clears_current_stage",
        "reset_clears_checkpoints_by_stage",

        ; --- GetLastCompleteCheckpointMs (B2 truncation) ---
        "last_complete_ms_zero_initially",
        "last_complete_ms_returns_max_across_buckets",
        "last_complete_ms_excludes_current_active_bucket",
        "last_complete_ms_zero_after_reset",

        ; --- Reset on lifecycle ---
        "resets_on_run_started",
        "resets_on_run_reset",
        "resets_on_run_cancelled",

        ; --- CaptureCurrentAsCheckpoint ---
        "capture_records_current_act_with_run_ms",
        "capture_no_op_when_current_act_is_zero",
        "capture_no_op_when_run_ms_is_zero",
        "capture_no_op_when_run_ms_is_negative",
        "capture_no_op_when_run_ms_is_non_number",
        "capture_overwrites_existing_checkpoint",

        ; --- GetCheckpoints returns a copy ---
        "get_checkpoints_returns_defensive_copy",
        "mutating_returned_map_does_not_affect_internal",

        ; --- Manual reset ---
        "reset_zeroes_current_act",
        "reset_clears_checkpoints",

        ; --- Dispose ---
        "dispose_unsubscribes_zone_entered",
        "dispose_unsubscribes_run_lifecycle",
        "dispose_is_idempotent"
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        stub := this.stubTimer
        Assert.Throws(TypeError, () => ActCheckpointTracker("not a bus", stub))
    }

    constructor_throws_when_timer_missing_get_run_ms()
    {
        b := this.bus
        ; Object without GetRunMs
        emptyObj := { foo: () => 0 }
        Assert.Throws(TypeError, () => ActCheckpointTracker(b, emptyObj))
    }

    constructor_throws_when_timer_is_string()
    {
        b := this.bus
        Assert.Throws(TypeError, () => ActCheckpointTracker(b, "not a timer"))
    }

    constructor_subscribes_to_zone_entered()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.ZoneEntered))
    }

    constructor_subscribes_to_lifecycle_events()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.RunStarted))
        Assert.Equal(1, this.bus.Subscribers(Events.RunReset))
        Assert.Equal(1, this.bus.Subscribers(Events.RunCancelled))
    }

    ; ============================================================
    ; Defaults
    ; ============================================================

    current_act_zero_initially()
    {
        Assert.Equal(0, this.svc.GetCurrentAct())
    }

    checkpoints_empty_initially()
    {
        Assert.Equal(0, this.svc.GetCheckpoints().Count)
    }

    current_stage_empty_initially()
    {
        Assert.Equal("", this.svc.GetCurrentStage())
    }

    checkpoints_by_stage_empty_initially()
    {
        Assert.Equal(0, this.svc.GetCheckpointsByStage().Count)
    }

    ; ============================================================
    ; ZoneEntered handler
    ; ============================================================

    first_zone_entered_sets_current_act()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1, "zoneName", "Clearfell"))
        Assert.Equal(1, this.svc.GetCurrentAct())
    }

    first_zone_entered_records_no_checkpoint()
    {
        ; First zone of the run: no previous act to record
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1, "zoneName", "Clearfell"))
        Assert.Equal(0, this.svc.GetCheckpoints().Count)
    }

    same_act_zone_does_not_record_checkpoint()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1, "zoneName", "Clearfell"))
        this.stubTimer.SetMs(60000)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1, "zoneName", "Mud Burrow"))
        Assert.Equal(0, this.svc.GetCheckpoints().Count,
            "Same act: no transition, no checkpoint")
    }

    act_transition_records_previous_act_checkpoint()
    {
        ; Act 1 -> Act 2 at t=28:45 (1725000ms)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1, "zoneName", "Clearfell"))
        this.stubTimer.SetMs(1725000)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 2, "zoneName", "Vastiri"))

        checkpoints := this.svc.GetCheckpoints()
        Assert.Equal(1, checkpoints.Count)
        Assert.True(checkpoints.Has(1))
    }

    act_transition_uses_timer_run_ms_value()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1, "zoneName", "Clearfell"))
        this.stubTimer.SetMs(1725000)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 2, "zoneName", "Vastiri"))

        Assert.Equal(1725000, this.svc.GetCheckpoints()[1])
    }

    multiple_transitions_accumulate_checkpoints()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1, "zoneName", "Clearfell"))
        this.stubTimer.SetMs(1725000)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 2, "zoneName", "Vastiri"))
        this.stubTimer.SetMs(3900000)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 3, "zoneName", "Sandswept"))

        checkpoints := this.svc.GetCheckpoints()
        Assert.Equal(2, checkpoints.Count)
        Assert.Equal(1725000, checkpoints[1])
        Assert.Equal(3900000, checkpoints[2])
    }

    checkpoint_key_is_previous_act_not_new_one()
    {
        ; Transition 1->2: saves checkpoint AT KEY 1 (act that left), not 2
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1, "zoneName", "Clearfell"))
        this.stubTimer.SetMs(1725000)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 2, "zoneName", "Vastiri"))

        Assert.True(this.svc.GetCheckpoints().Has(1), "Key 1 (previous act)")
        Assert.False(this.svc.GetCheckpoints().Has(2), "Key 2 (new act) has no checkpoint yet")
        Assert.Equal(2, this.svc.GetCurrentAct())
    }

    ignores_zone_entered_without_act_index()
    {
        this.bus.Publish(Events.ZoneEntered, Map("zoneName", "Clearfell"))
        Assert.Equal(0, this.svc.GetCurrentAct(), "actIndex missing: ignore")
    }

    ignores_zone_entered_with_zero_act_index()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 0, "zoneName", "Limbo"))
        Assert.Equal(0, this.svc.GetCurrentAct())
    }

    ignores_zone_entered_with_negative_act_index()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", -1, "zoneName", "Limbo"))
        Assert.Equal(0, this.svc.GetCurrentAct())
    }

    ignores_zone_entered_with_non_object_data()
    {
        this.bus.Publish(Events.ZoneEntered, "string data")
        Assert.Equal(0, this.svc.GetCurrentAct())
    }

    ignores_transition_when_timer_returns_zero()
    {
        ; Edge case: if timer.GetRunMs() returns 0/negative, defensively
        ; we don't record a checkpoint (but current_act still changes)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1, "zoneName", "Clearfell"))
        this.stubTimer.SetMs(0)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 2, "zoneName", "Vastiri"))
        Assert.Equal(0, this.svc.GetCheckpoints().Count,
            "Timer returning 0: defensive, no checkpoint")
        Assert.Equal(2, this.svc.GetCurrentAct(), "current_act still changes")
    }

    ; ============================================================
    ; stage axis (B1 Layer B)
    ; ============================================================
    ;
    ; PoE2 EA speedrun reaches each actIndex (1..4) TWICE in a
    ; full run: once normal, once interlude (cruel). Pre-B1, the
    ; tracker keyed checkpoints by actIndex alone, so cruel Act 1
    ; overwrote normal Act 1. Post-B1 the tracker maintains both a
    ; legacy view (act-only, last-write-wins — preserved for
    ; PersonalBestService until it migrates) and a stage-aware
    ; view keyed by "<act>|<stage>".

    zone_entered_with_interlude_sets_current_stage()
    {
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "zoneName", "Clearfell", "stage", "interlude"))
        Assert.Equal("interlude", this.svc.GetCurrentStage())
    }

    zone_entered_without_stage_defaults_current_stage_to_normal()
    {
        ; Backward-compat: programmatic callers (tests, legacy
        ; subscribers) that omit `stage` get "normal".
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1, "zoneName", "Clearfell"))
        Assert.Equal("normal", this.svc.GetCurrentStage())
    }

    zone_entered_with_empty_stage_defaults_to_normal()
    {
        ; Defensive: explicit empty string treated same as missing.
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "zoneName", "Clearfell", "stage", ""))
        Assert.Equal("normal", this.svc.GetCurrentStage())
    }

    composite_key_format_is_act_pipe_stage()
    {
        ; Format used by GetCheckpointsByStage. Pipe separator,
        ; integer act, lowercase stage. Tests downstream consumers
        ; (PB Service, plot builder) that will parse these.
        Assert.Equal("1|normal",    ActCheckpointTracker._ComposeKey(1, "normal"))
        Assert.Equal("4|interlude", ActCheckpointTracker._ComposeKey(4, "interlude"))
    }

    act_transition_records_composite_key_in_by_stage_map()
    {
        ; Normal-to-normal transition. Legacy map keys by act (1),
        ; new map keys by composite ("1|normal").
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "zoneName", "Clearfell", "stage", "normal"))
        this.stubTimer.SetMs(1725000)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 2, "zoneName", "Vastiri", "stage", "normal"))

        byAct := this.svc.GetCheckpoints()
        Assert.Equal(1, byAct.Count)
        Assert.Equal(1725000, byAct[1])

        byStage := this.svc.GetCheckpointsByStage()
        Assert.Equal(1, byStage.Count)
        Assert.True(byStage.Has("1|normal"))
        Assert.Equal(1725000, byStage["1|normal"])
    }

    stage_only_transition_records_checkpoint()
    {
        ; Synthetic edge case: same actIndex, different stage. The
        ; tracker MUST treat this as a transition. (In practice
        ; PoE2's interlude jumps from Act 4 normal back to Act 1
        ; interlude, but the tracker handles the general case.)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "zoneName", "Clearfell", "stage", "normal"))
        this.stubTimer.SetMs(60000)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "zoneName", "Clearfell", "stage", "interlude"))

        byStage := this.svc.GetCheckpointsByStage()
        Assert.Equal(1, byStage.Count, "Stage-only transition still records")
        Assert.True(byStage.Has("1|normal"))
        Assert.Equal(60000, byStage["1|normal"])
    }

    stage_only_transition_uses_old_stage_in_composite_key()
    {
        ; Key records the (act, stage) being LEFT, not entered.
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "zoneName", "Clearfell", "stage", "normal"))
        this.stubTimer.SetMs(60000)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "zoneName", "Clearfell", "stage", "interlude"))

        byStage := this.svc.GetCheckpointsByStage()
        Assert.True(byStage.Has("1|normal"),    "Key is the LEFT (act, stage)")
        Assert.False(byStage.Has("1|interlude"), "New stage hasn't checkpointed yet")
        Assert.Equal("interlude", this.svc.GetCurrentStage())
    }

    realistic_normal_to_interlude_records_act_4_normal_checkpoint()
    {
        ; Production sequence: Act 4 normal → Act 1 interlude.
        ; Both act AND stage change. Records "4|normal".
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 4, "zoneName", "Ogham Wilderness", "stage", "normal"))
        this.stubTimer.SetMs(7200000)   ; 2h
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "zoneName", "Clearfell", "stage", "interlude"))

        byStage := this.svc.GetCheckpointsByStage()
        Assert.True(byStage.Has("4|normal"))
        Assert.Equal(7200000, byStage["4|normal"])
        Assert.Equal("interlude", this.svc.GetCurrentStage())
        Assert.Equal(1,           this.svc.GetCurrentAct())
    }

    interlude_transitions_record_interlude_checkpoints()
    {
        ; Act 1 interlude → Act 2 interlude. Both same stage.
        ; Records "1|interlude".
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "zoneName", "Clearfell", "stage", "interlude"))
        this.stubTimer.SetMs(8200000)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 2, "zoneName", "Vastiri", "stage", "interlude"))

        byStage := this.svc.GetCheckpointsByStage()
        Assert.True(byStage.Has("1|interlude"))
        Assert.Equal(8200000, byStage["1|interlude"])
    }

    legacy_get_checkpoints_last_write_wins_for_same_act_different_stage()
    {
        ; The legacy map preserves pre-B1 behaviour (the bug)
        ; for callers that haven't migrated. Cruel Act 1's
        ; checkpoint overwrites normal Act 1's checkpoint in the
        ; integer-keyed map. The stage-aware map preserves both.
        ; This test locks in the legacy semantic so the migration
        ; commit (PB Service → stage-aware API) is a clear,
        ; intentional change.
        ;
        ; Sequence: Act 1 normal → Act 2 normal → Act 1 interlude
        ;           → Act 2 interlude → Act 3 interlude
        ; Each arrow is a transition that records the LEFT bucket.
        ; Four transitions → four byStage entries, but only two
        ; distinct actIndex values → byAct collapses to two
        ; (last-write-wins on each act).
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "zoneName", "Clearfell", "stage", "normal"))
        this.stubTimer.SetMs(60000)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 2, "zoneName", "Vastiri", "stage", "normal"))
        this.stubTimer.SetMs(7200000)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "zoneName", "Clearfell", "stage", "interlude"))
        this.stubTimer.SetMs(8300000)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 2, "zoneName", "Vastiri", "stage", "interlude"))
        this.stubTimer.SetMs(9400000)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 3, "zoneName", "Jungle", "stage", "interlude"))

        byAct := this.svc.GetCheckpoints()
        Assert.Equal(2, byAct.Count, "Legacy view collapses by act")
        Assert.Equal(8300000, byAct[1], "Act 1 from cruel transition (LAST WRITE WINS)")
        Assert.Equal(9400000, byAct[2], "Act 2 from cruel transition (LAST WRITE WINS)")

        byStage := this.svc.GetCheckpointsByStage()
        Assert.Equal(4, byStage.Count, "Stage-aware view preserves all four")
        Assert.Equal(60000,   byStage["1|normal"])
        Assert.Equal(7200000, byStage["2|normal"])
        Assert.Equal(8300000, byStage["1|interlude"])
        Assert.Equal(9400000, byStage["2|interlude"])
    }

    capture_current_as_checkpoint_updates_both_maps()
    {
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 4, "zoneName", "Ogham", "stage", "interlude"))
        this.svc.CaptureCurrentAsCheckpoint(9999999)

        Assert.Equal(9999999, this.svc.GetCheckpoints()[4])
        Assert.Equal(9999999, this.svc.GetCheckpointsByStage()["4|interlude"])
    }

    capture_uses_current_stage_in_composite_key()
    {
        ; Final-act capture happens at "completed" from RunSnapshotSaver.
        ; The composite key must use whatever stage was current at
        ; that moment — interlude when finishing the campaign.
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 4, "zoneName", "Ogham", "stage", "interlude"))
        this.svc.CaptureCurrentAsCheckpoint(11000000)

        byStage := this.svc.GetCheckpointsByStage()
        Assert.True(byStage.Has("4|interlude"))
        Assert.False(byStage.Has("4|normal"))
    }

    get_checkpoints_by_stage_returns_defensive_copy()
    {
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "zoneName", "Clearfell", "stage", "normal"))
        this.stubTimer.SetMs(60000)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 2, "zoneName", "Vastiri", "stage", "normal"))

        copy := this.svc.GetCheckpointsByStage()
        copy["1|normal"] := 0
        copy["9|interlude"] := 1

        original := this.svc.GetCheckpointsByStage()
        Assert.Equal(60000, original["1|normal"], "Internal not mutated")
        Assert.False(original.Has("9|interlude"), "Internal not extended")
    }

    reset_clears_current_stage()
    {
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "stage", "interlude"))
        this.svc.Reset()
        Assert.Equal("", this.svc.GetCurrentStage())
    }

    reset_clears_checkpoints_by_stage()
    {
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "stage", "normal"))
        this.stubTimer.SetMs(60000)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 2, "stage", "normal"))
        Assert.Equal(1, this.svc.GetCheckpointsByStage().Count, "sanity")
        this.svc.Reset()
        Assert.Equal(0, this.svc.GetCheckpointsByStage().Count)
    }

    ; ============================================================
    ; GetLastCompleteCheckpointMs (B2 truncation)
    ; ============================================================
    ;
    ; Returns the runMs at the latest *captured* (act, stage)
    ; transition. Used by RunSnapshotSaver on the cancel path to
    ; decide the truncation point of a partial run. Critically:
    ; the current (active) bucket is NOT considered "complete"
    ; until it has actually been captured — either by a transition
    ; out of it, or by CaptureCurrentAsCheckpoint at finalize time.
    ; The cancel path reads this BEFORE doing any explicit capture
    ; so the active partial-act time isn't mistaken for completed.

    last_complete_ms_zero_initially()
    {
        ; Run hasn't started; no zones entered. The cancel path
        ; uses this to short-circuit Save (no complete act = nothing
        ; to persist, fulfils B2's Q3.a).
        Assert.Equal(0, this.svc.GetLastCompleteCheckpointMs())
    }

    last_complete_ms_returns_max_across_buckets()
    {
        ; Normal Act 1 → Act 2 → cruel Act 1 (transitions).
        ; Captured buckets: "1|normal"=60000, "2|normal"=150000.
        ; Latest captured = 150000.
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "stage", "normal"))
        this.stubTimer.SetMs(60000)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 2, "stage", "normal"))
        this.stubTimer.SetMs(150000)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "stage", "interlude"))

        Assert.Equal(150000, this.svc.GetLastCompleteCheckpointMs())
    }

    last_complete_ms_excludes_current_active_bucket()
    {
        ; The active bucket isn't captured until either a transition
        ; or an explicit CaptureCurrentAsCheckpoint. Even after the
        ; timer has advanced well past the last captured value, the
        ; query continues to return the LAST CAPTURED time, not the
        ; live runMs — that's the B2 contract.
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "stage", "normal"))
        this.stubTimer.SetMs(60000)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 2, "stage", "normal"))
        ; Active in Act 2 normal, timer advances past the captured value.
        this.stubTimer.SetMs(300000)

        Assert.Equal(60000, this.svc.GetLastCompleteCheckpointMs(),
            "current active bucket (Act 2 at 300000ms) isn't 'complete' yet")
    }

    last_complete_ms_zero_after_reset()
    {
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 1, "stage", "normal"))
        this.stubTimer.SetMs(60000)
        this.bus.Publish(Events.ZoneEntered, Map(
            "actIndex", 2, "stage", "normal"))
        Assert.Equal(60000, this.svc.GetLastCompleteCheckpointMs(), "sanity")

        this.svc.Reset()

        Assert.Equal(0, this.svc.GetLastCompleteCheckpointMs())
    }

    ; ============================================================
    ; Reset on lifecycle
    ; ============================================================

    resets_on_run_started()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1))
        this.stubTimer.SetMs(1725000)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 2))
        this.bus.Publish(Events.RunStarted, Map("runId", "20260101_000000"))

        Assert.Equal(0, this.svc.GetCurrentAct())
        Assert.Equal(0, this.svc.GetCheckpoints().Count)
    }

    resets_on_run_reset()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1))
        this.stubTimer.SetMs(1725000)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 2))
        this.bus.Publish(Events.RunReset, Map("runId", "20260101_000000"))

        Assert.Equal(0, this.svc.GetCurrentAct())
        Assert.Equal(0, this.svc.GetCheckpoints().Count)
    }

    resets_on_run_cancelled()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1))
        this.stubTimer.SetMs(1725000)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 2))
        this.bus.Publish(Events.RunCancelled, Map("runId", "20260101_000000"))

        Assert.Equal(0, this.svc.GetCurrentAct())
        Assert.Equal(0, this.svc.GetCheckpoints().Count)
    }

    ; ============================================================
    ; CaptureCurrentAsCheckpoint
    ; ============================================================

    capture_records_current_act_with_run_ms()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 3))
        this.svc.CaptureCurrentAsCheckpoint(6900000)
        Assert.Equal(6900000, this.svc.GetCheckpoints()[3])
    }

    capture_no_op_when_current_act_is_zero()
    {
        ; No zone entered yet: current_act=0, no-op
        this.svc.CaptureCurrentAsCheckpoint(1000)
        Assert.Equal(0, this.svc.GetCheckpoints().Count)
    }

    capture_no_op_when_run_ms_is_zero()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1))
        this.svc.CaptureCurrentAsCheckpoint(0)
        Assert.Equal(0, this.svc.GetCheckpoints().Count)
    }

    capture_no_op_when_run_ms_is_negative()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1))
        this.svc.CaptureCurrentAsCheckpoint(-100)
        Assert.Equal(0, this.svc.GetCheckpoints().Count)
    }

    capture_no_op_when_run_ms_is_non_number()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1))
        this.svc.CaptureCurrentAsCheckpoint("not a number")
        Assert.Equal(0, this.svc.GetCheckpoints().Count)
    }

    capture_overwrites_existing_checkpoint()
    {
        ; Rare but valid case: capture called more than once in the same act
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1))
        this.svc.CaptureCurrentAsCheckpoint(1000)
        this.svc.CaptureCurrentAsCheckpoint(2000)
        Assert.Equal(2000, this.svc.GetCheckpoints()[1])
    }

    ; ============================================================
    ; GetCheckpoints returns a copy
    ; ============================================================

    get_checkpoints_returns_defensive_copy()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1))
        this.stubTimer.SetMs(1000)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 2))

        copy1 := this.svc.GetCheckpoints()
        copy2 := this.svc.GetCheckpoints()
        Assert.False(copy1 == copy2, "Distinct maps (different references)")
        Assert.Equal(copy1[1], copy2[1])
    }

    mutating_returned_map_does_not_affect_internal()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1))
        this.stubTimer.SetMs(1000)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 2))

        copy := this.svc.GetCheckpoints()
        copy[99] := 999   ; mutate the return
        copy.Delete(1)

        ; Internal state intact
        original := this.svc.GetCheckpoints()
        Assert.False(original.Has(99))
        Assert.True(original.Has(1))
    }

    ; ============================================================
    ; Manual reset
    ; ============================================================

    reset_zeroes_current_act()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 3))
        this.svc.Reset()
        Assert.Equal(0, this.svc.GetCurrentAct())
    }

    reset_clears_checkpoints()
    {
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 1))
        this.stubTimer.SetMs(1000)
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 2))
        this.svc.Reset()
        Assert.Equal(0, this.svc.GetCheckpoints().Count)
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_zone_entered()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.ZoneEntered))

        ; After Dispose, events don't affect state
        this.bus.Publish(Events.ZoneEntered, Map("actIndex", 5))
        Assert.Equal(0, this.svc.GetCurrentAct())
    }

    dispose_unsubscribes_run_lifecycle()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.RunStarted))
        Assert.Equal(0, this.bus.Subscribers(Events.RunReset))
        Assert.Equal(0, this.bus.Subscribers(Events.RunCancelled))
    }

    dispose_is_idempotent()
    {
        this.svc.Dispose()
        this.svc.Dispose()   ; second Dispose: no-op
        Assert.Equal(0, this.bus.Subscribers(Events.ZoneEntered))
    }
}

TestRegistry.Register(ActCheckpointTrackerTests)
