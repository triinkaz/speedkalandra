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
