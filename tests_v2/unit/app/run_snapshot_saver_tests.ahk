; ============================================================
; RunSnapshotSaverTests
; ============================================================
;
; RunSnapshotSaver coordinates several collaborators (runHistory,
; zoneTracker, timer, statsRecorder, plotBuilder, actCheckpoints,
; personalBest). Each integration is exercised in its own suite for
; the underlying service; here the focus is on the saver's
; responsibilities: threshold gating, undo-state lifecycle, and PB
; rebuild semantics.
;
; The dialogs and TrayTips are skipped by passing headless=true.


; Minimal stub: tracks Save/Delete/ListRunIds/Load calls.
class _SaverStubRunHistory
{
    saveCalls   := 0
    deleteCalls := 0
    listCalls   := 0
    loadCalls   := 0
    _lastSaved  := ""
    _deletable  := true     ; toggle for Delete to return false

    Save(buildResult)
    {
        this.saveCalls += 1
        this._lastSaved := buildResult
        return true
    }

    Delete(runId)
    {
        this.deleteCalls += 1
        return this._deletable
    }

    ListRunIds(maxN := -1)
    {
        this.listCalls += 1
        return []
    }

    Load(runId)
    {
        this.loadCalls += 1
        return ""
    }
}


; Minimal stub of TimerService.GetRunMs (the only method the saver uses).
class _SaverStubTimer
{
    _ms := 0

    SetRunMs(ms)
    {
        this._ms := ms
    }

    GetRunMs()
    {
        return this._ms
    }
}


; Minimal stub of ZoneTrackingService -- the saver calls
; GetTotalsForSnapshot, GetFirstEnteredAtMap, GetActiveZone, and
; GetCurrentVisitMs in the OnBeforeFinalize hook. All four are
; backed by mutable fields so tests can construct the exact
; snapshot they want.
class _SaverStubZoneTracker
{
    totalsForSnapshot := ""
    firstEnteredAt    := ""
    activeZone        := ""
    currentVisitMs    := 0

    __New()
    {
        this.totalsForSnapshot := Map()
        this.firstEnteredAt    := Map()
    }

    SetTotals(map)
    {
        this.totalsForSnapshot := map
    }

    GetTotalsForSnapshot() => this.totalsForSnapshot
    GetFirstEnteredAtMap() => this.firstEnteredAt
    GetActiveZone()        => this.activeZone
    GetCurrentVisitMs()    => this.currentVisitMs
}


; Minimal stub of PersonalBestService — RebuildFromHistory is the
; only path exercised from the undo flow.
class _SaverStubPersonalBest
{
    rebuildCalls  := 0
    rebuildResult := false
    updateCalls   := 0
    lastUpdateRunMs          := 0
    lastUpdateRunId          := ""
    lastUpdateZoneTotals     := ""
    lastUpdateActCheckpoints := ""

    __New()
    {
        this.lastUpdateZoneTotals     := Map()
        this.lastUpdateActCheckpoints := Map()
    }

    RebuildFromHistory(runs)
    {
        this.rebuildCalls += 1
        return this.rebuildResult
    }

    ; Mirrors PersonalBestService.UpdateFromRun. Captures args
    ; (defensive copies of the maps) so tests can assert on the
    ; PB-eligible totals the saver passes in, separate from the
    ; factual zoneTotals.
    UpdateFromRun(runMs, runId, zoneTotalsMap, actCheckpointsMap)
    {
        this.updateCalls += 1
        this.lastUpdateRunMs := runMs
        this.lastUpdateRunId := runId
        this.lastUpdateZoneTotals := Map()
        if IsObject(zoneTotalsMap)
            for k, v in zoneTotalsMap
                this.lastUpdateZoneTotals[k] := v
        this.lastUpdateActCheckpoints := Map()
        if IsObject(actCheckpointsMap)
            for k, v in actCheckpointsMap
                this.lastUpdateActCheckpoints[k] := v
        return false
    }
}


; Minimal stub for RunStatsRecorder -- the saver only calls
; GetSnapshot(zoneTotals, runMs, zoneFirstEnteredAt). The returned
; snapshot carries the runId/firstTs the plot builder copies
; through to buildResult.
class _SaverStubStatsRecorder
{
    runId   := "20260518_120000_000"
    firstTs := "2026-05-18 12:00:00"

    ; Mirrors RunStatsRecorder.GetRunId. The saver now reads this
    ; early (before the too_short branch returns) so it can stamp
    ; the outcome event with a runId. Tests that didn't need this
    ; before now do; the stub method was added alongside the new
    ; saver behaviour.
    GetRunId() => this.runId

    GetSnapshot(zoneTotalsMap, runMs, firstEnteredAtMap)
    {
        return Map(
            "runId",              this.runId,
            "firstTs",            this.firstTs,
            "runDurationMs",      runMs,
            "zoneTotals",         IsObject(zoneTotalsMap) ? zoneTotalsMap : Map(),
            "zoneFirstEnteredAt", IsObject(firstEnteredAtMap) ? firstEnteredAtMap : Map(),
            "loadingEvents",      [],
            "deathCount",         0
        )
    }
}


; Minimal stub for RunStatsPlotBuilder. The real builder produces
; totals/details from the snapshot; tests here only need runId /
; totalMs to be set on the buildResult so the saver's downstream
; assertions (interrupted-visit keys, actCheckpoints injection,
; PB update) work end-to-end.
class _SaverStubPlotBuilder
{
    Build(snapshot)
    {
        return Map(
            "runId",   snapshot.Has("runId")         ? snapshot["runId"]         : "",
            "firstTs", snapshot.Has("firstTs")       ? snapshot["firstTs"]       : "",
            "totalMs", snapshot.Has("runDurationMs") ? snapshot["runDurationMs"] : 0,
            "totals",  Map(),
            "details", []
        )
    }
}


; Variant of _SaverStubPersonalBest whose UpdateFromRun returns
; true — used by the outcome_published_saved_carries_pb_changed_flag
; test to drive the pbChanged=true branch end-to-end. Declared at
; top level because AHK v2 forbids `class` inside a function body.
class _SaverPbReturnsTrue extends _SaverStubPersonalBest
{
    UpdateFromRun(runMs, runId, zoneTotalsMap, actCheckpointsMap)
    {
        super.UpdateFromRun(runMs, runId, zoneTotalsMap, actCheckpointsMap)
        return true
    }
}


; Variant of _SaverStubRunHistory whose Save returns false — used
; by outcome_silent_when_run_history_save_returns_false to drive
; the "runHistory didn't land the write" branch without throwing.
; Same top-level-class reason as above.
class _SaverHistoryReturnsFalse extends _SaverStubRunHistory
{
    Save(buildResult)
    {
        this.saveCalls += 1
        this._lastSaved := buildResult
        return false
    }
}


; Variant of _SaverStubRunHistory whose Save THROWS — used to
; exercise the saver's outer catch block: log a WARN, surface a
; TrayTip (skipped in headless), don't propagate, don't publish
; a misleading outcome event. The thrown Error's message is
; arbitrary; the saver only catches and logs it. saveCalls still
; increments so tests can confirm the throwing path was actually
; reached.
class _SaverHistoryThrows extends _SaverStubRunHistory
{
    Save(buildResult)
    {
        this.saveCalls += 1
        this._lastSaved := buildResult
        throw Error("_SaverHistoryThrows: forced save failure")
    }
}


; Minimal stub for ActCheckpointTracker. CaptureCurrentAsCheckpoint
; is a no-op; GetCheckpoints returns whatever the test seeded.
class _SaverStubActCheckpoints
{
    captureCalls := 0
    _checkpoints := ""

    __New()
    {
        this._checkpoints := Map()
    }

    SetCheckpoints(map)
    {
        this._checkpoints := map
    }

    CaptureCurrentAsCheckpoint(runMs)
    {
        this.captureCalls += 1
    }

    GetCheckpoints()
    {
        out := Map()
        for k, v in this._checkpoints
            out[k] := v
        return out
    }
}


class RunSnapshotSaverTests extends TestCase
{
    runHistory     := ""
    zoneTracker    := ""
    timer          := ""
    statsRecorder  := ""
    plotBuilder    := ""
    actCheckpoints := ""
    personalBest   := ""
    log            := ""

    Setup()
    {
        this.runHistory     := _SaverStubRunHistory()
        this.zoneTracker    := _SaverStubZoneTracker()
        this.timer          := _SaverStubTimer()
        this.statsRecorder  := _SaverStubStatsRecorder()
        this.plotBuilder    := _SaverStubPlotBuilder()
        this.actCheckpoints := _SaverStubActCheckpoints()
        this.personalBest   := _SaverStubPersonalBest()
        this.log            := NullLogger()
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Construction ---
        "constructor_accepts_all_empty_collaborators",
        "min_save_ms_is_three_minutes",

        ; --- Save guard clauses ---
        "save_no_op_when_run_history_missing",
        "save_rejects_runs_below_threshold",
        "save_returns_when_stats_or_plot_builder_missing",

        ; --- Save: PB-eligible totals (zone-PB exclusion) ---
        "save_passes_zone_totals_when_no_active_zone",
        "save_passes_zone_totals_when_visit_ms_zero",
        "save_passes_zone_totals_when_active_zone_not_in_totals",
        "save_discounts_interrupted_visit_from_pb_totals",
        "save_drops_zone_from_pb_when_visit_equals_total",
        "save_drops_zone_from_pb_when_visit_exceeds_total",
        "save_injects_interrupted_keys_in_buildresult",
        "save_cancelled_does_not_call_update_from_run",

        ; --- RunOutcomeReported publishing ---
        "outcome_published_too_short_for_completed_below_threshold",
        "outcome_published_too_short_for_cancelled_below_threshold",
        "outcome_published_saved_for_completed_above_threshold",
        "outcome_published_saved_carries_pb_changed_flag",
        "outcome_published_dnf_for_cancelled_above_threshold",
        "outcome_silent_when_bus_missing",
        "outcome_silent_when_run_history_save_returns_false",

        ; --- Save failure path (regression: the catch used to be
        ; log-only, with the inline comment claiming a TrayTip
        ; was emitted from here; the TrayTip was missing) ---
        "save_does_not_propagate_when_history_save_throws",
        "save_logs_warn_when_history_save_throws",
        "save_publishes_no_outcome_when_history_save_throws",

        ; --- Undo state machine ---
        "undo_no_op_when_no_save_marked",
        "undo_calls_delete_when_run_id_set",
        "undo_rebuilds_pbs_when_delete_succeeds",
        "undo_does_not_rebuild_when_delete_fails",
        "expire_clears_state"
    ]

    ; ============================================================
    ; Construction
    ; ============================================================

    constructor_accepts_all_empty_collaborators()
    {
        ; Lenient construction: all service refs may be "" — guards in
        ; the methods take care of the missing-collaborator paths.
        saver := RunSnapshotSaver("", "", "", "", "", "", "", "", true)
        Assert.IsType(RunSnapshotSaver, saver)
    }

    min_save_ms_is_three_minutes()
    {
        ; Contract test: any change to this constant changes which runs
        ; survive disk persistence. Keep it pinned at 3 min.
        Assert.Equal(180000, RunSnapshotSaver.MIN_SAVE_MS)
    }

    ; ============================================================
    ; Save
    ; ============================================================

    save_no_op_when_run_history_missing()
    {
        saver := RunSnapshotSaver("", this.zoneTracker, this.timer,
            "", "", "", this.personalBest, this.log, true)
        saver.Save("completed")
        ; The stub history isn't injected; nothing to assert on it.
        ; The point is: no exception, function returned cleanly.
        Assert.True(true)
    }

    save_rejects_runs_below_threshold()
    {
        ; 90 s run — well below the 3-min threshold.
        this.timer.SetRunMs(90000)
        saver := RunSnapshotSaver(this.runHistory, this.zoneTracker,
            this.timer, "", "", "", this.personalBest, this.log, true)
        saver.Save("completed")
        Assert.Equal(0, this.runHistory.saveCalls,
            "Save should be skipped for runs shorter than MIN_SAVE_MS")
    }

    save_returns_when_stats_or_plot_builder_missing()
    {
        ; Run long enough to clear the threshold, but statsRecorder
        ; and plotBuilder are missing — second guard fires.
        this.timer.SetRunMs(300000)   ; 5 min
        saver := RunSnapshotSaver(this.runHistory, this.zoneTracker,
            this.timer, "", "", "", this.personalBest, this.log, true)
        saver.Save("completed")
        Assert.Equal(0, this.runHistory.saveCalls,
            "Save should be skipped when stats/plot builder is missing")
    }

    ; ============================================================
    ; Save: PB-eligible totals (zone-PB exclusion)
    ; ============================================================
    ;
    ; The saver runs in the OnBeforeFinalize hook -- after
    ; TimerStopped flushes the active visit into _totals and
    ; _currentVisitMs, but before RunCompleted is published. At
    ; this point the saver discounts the interrupted visit's time
    ; from the factual zoneTotals when computing the PB-eligible
    ; totals it hands to PersonalBestService.UpdateFromRun. The
    ; factual zoneTotals (used for history/plot) stay untouched.
    ; The (interruptedZoneName, interruptedZoneVisitMs) pair is
    ; also injected into the buildResult so RebuildFromHistory
    ; can mirror the discount on Undo / Delete.

    ; Helper: build a fully-wired saver that includes the new
    ; statsRecorder / plotBuilder / actCheckpoints collaborators.
    _MakeFullSaver()
    {
        return RunSnapshotSaver(
            this.runHistory, this.zoneTracker, this.timer,
            this.statsRecorder, this.plotBuilder, this.actCheckpoints,
            this.personalBest, this.log, true
        )
    }

    ; Same as _MakeFullSaver but wires a real EventBus so the
    ; outcome-event publishing path can be observed by subscribers.
    ; The subscriber is a single Array that captures the payloads
    ; in order; tests assert on its contents.
    _MakeFullSaverWithBus(busOut)
    {
        ; busOut is an Array (passed by reference) that will hold
        ; the captured payloads. The closure pushes into it on
        ; every Evt.RunOutcomeReported publish. Two callers need
        ; to mutate the same list (the closure and the test
        ; assertions), which is why the array is owned by the
        ; test method rather than by this helper.
        bus := EventBus(NullLogger())
        bus.Subscribe(Events.RunOutcomeReported, (data) => busOut.Push(data))
        return RunSnapshotSaver(
            this.runHistory, this.zoneTracker, this.timer,
            this.statsRecorder, this.plotBuilder, this.actCheckpoints,
            this.personalBest, this.log, true, bus
        )
    }

    save_passes_zone_totals_when_no_active_zone()
    {
        ; No active zone at finalize (player was mid-transition or
        ; just hydrated). Nothing to discount: pbZoneTotals equals
        ; the factual zoneTotals.
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000, "Vastiri Outskirts", 30000))
        this.zoneTracker.activeZone     := ""
        this.zoneTracker.currentVisitMs := 0

        this._MakeFullSaver().Save("completed")

        Assert.Equal(1, this.personalBest.updateCalls)
        Assert.Equal(60000, this.personalBest.lastUpdateZoneTotals["Mud Burrow"])
        Assert.Equal(30000, this.personalBest.lastUpdateZoneTotals["Vastiri Outskirts"])
    }

    save_passes_zone_totals_when_visit_ms_zero()
    {
        ; Active zone known but currentVisitMs is 0 -- no discount
        ; (the active zone hasn't accumulated any time yet, e.g.
        ; finalized immediately after a transition).
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))
        this.zoneTracker.activeZone     := "Mud Burrow"
        this.zoneTracker.currentVisitMs := 0

        this._MakeFullSaver().Save("completed")

        Assert.Equal(60000, this.personalBest.lastUpdateZoneTotals["Mud Burrow"])
    }

    save_passes_zone_totals_when_active_zone_not_in_totals()
    {
        ; Defensive: an active zone that somehow isn't in _totals
        ; (the visit was timed out before any flush). No-op without
        ; raising.
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))
        this.zoneTracker.activeZone     := "Vastiri Outskirts"
        this.zoneTracker.currentVisitMs := 3000

        this._MakeFullSaver().Save("completed")

        Assert.Equal(60000, this.personalBest.lastUpdateZoneTotals["Mud Burrow"])
        Assert.False(this.personalBest.lastUpdateZoneTotals.Has("Vastiri Outskirts"))
    }

    save_discounts_interrupted_visit_from_pb_totals()
    {
        ; Permissive scenario: zone X visited 60s (closed via
        ; transition), then revisited 3s before the hotkey. Factual
        ; zoneTotals carries 63000 (sum of both visits); PB-eligible
        ; totals get 60000 -- only the interrupted visit's 3000ms is
        ; subtracted, the complete-visit time is preserved.
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 63000, "Vastiri Outskirts", 30000))
        this.zoneTracker.activeZone     := "Mud Burrow"
        this.zoneTracker.currentVisitMs := 3000

        this._MakeFullSaver().Save("completed")

        Assert.Equal(60000, this.personalBest.lastUpdateZoneTotals["Mud Burrow"],
            "Interrupted visit (3000ms) discounted from PB-eligible total")
        Assert.Equal(30000, this.personalBest.lastUpdateZoneTotals["Vastiri Outskirts"],
            "Other zones untouched")
    }

    save_drops_zone_from_pb_when_visit_equals_total()
    {
        ; Original bug scenario: zone visited only once (interrupted)
        ; -- the visit equals the zone's total. After the discount
        ; the zone falls out of PB-eligible totals entirely.
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000, "Vastiri Outskirts", 3000))
        this.zoneTracker.activeZone     := "Vastiri Outskirts"
        this.zoneTracker.currentVisitMs := 3000

        this._MakeFullSaver().Save("completed")

        Assert.Equal(60000, this.personalBest.lastUpdateZoneTotals["Mud Burrow"])
        Assert.False(this.personalBest.lastUpdateZoneTotals.Has("Vastiri Outskirts"),
            "Interrupted zone with no prior visit is removed from PB-eligible totals")
    }

    save_drops_zone_from_pb_when_visit_exceeds_total()
    {
        ; Defensive: if the visit accumulator somehow exceeds the
        ; total (out-of-band state, e.g. a bug in the tracker), the
        ; saver still drops the zone instead of writing a negative
        ; PB candidate.
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 2000))
        this.zoneTracker.activeZone     := "Mud Burrow"
        this.zoneTracker.currentVisitMs := 3000

        this._MakeFullSaver().Save("completed")

        Assert.False(this.personalBest.lastUpdateZoneTotals.Has("Mud Burrow"),
            "Negative adjusted total falls through to Delete, not a negative PB")
    }

    save_injects_interrupted_keys_in_buildresult()
    {
        ; Even when the discount is a no-op (e.g. zone not in totals),
        ; the keys are present in buildResult so RebuildFromHistory
        ; has a consistent shape to read from. Repository's Load
        ; defaults them to "" / 0 for legacy runs.
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))
        this.zoneTracker.activeZone     := "Mud Burrow"
        this.zoneTracker.currentVisitMs := 4500

        this._MakeFullSaver().Save("completed")

        saved := this.runHistory._lastSaved
        Assert.True(IsObject(saved))
        Assert.Equal("Mud Burrow", saved["interruptedZoneName"])
        Assert.Equal(4500,         saved["interruptedZoneVisitMs"])
    }

    save_cancelled_does_not_call_update_from_run()
    {
        ; Cancelled runs persist to history (over the threshold) but
        ; never touch PBs. The discount logic doesn't run because
        ; UpdateFromRun is gated on reason="completed".
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))
        this.zoneTracker.activeZone     := "Mud Burrow"
        this.zoneTracker.currentVisitMs := 3000

        this._MakeFullSaver().Save("cancelled")

        Assert.Equal(0, this.personalBest.updateCalls,
            "Cancelled save never calls UpdateFromRun")
    }

    ; ============================================================
    ; RunOutcomeReported publishing
    ; ============================================================
    ;
    ; Every Save() call ends in exactly one Evt.RunOutcomeReported
    ; publish that names what actually happened: "too_short",
    ; "saved", or "dnf". The event payload carries the duration the
    ; saver measured (so the banner doesn't have to recompute) and a
    ; pbChanged flag (meaningful only for "saved"; always false
    ; otherwise). The widget renders from this single fact source.
    ;
    ; Tests use a real EventBus so the publish/subscribe wiring is
    ; exercised end-to-end — a publish that didn't fire would be
    ; invisible to a mock-bus assertion that checks call counts.

    outcome_published_too_short_for_completed_below_threshold()
    {
        this.timer.SetRunMs(90000)                 ; below the 3-min cap
        this.statsRecorder.runId := "20260518_120000_001"
        captured := []
        this._MakeFullSaverWithBus(captured).Save("completed")

        Assert.Equal(1, captured.Length, "Exactly one outcome event per Save")
        Assert.Equal("too_short", captured[1]["outcome"])
        Assert.Equal(90000,        captured[1]["durationMs"])
        Assert.Equal("20260518_120000_001", captured[1]["runId"])
        Assert.False(captured[1]["pbChanged"])
    }

    outcome_published_too_short_for_cancelled_below_threshold()
    {
        ; Same too_short outcome regardless of reason — the threshold
        ; gate is reason-agnostic.
        this.timer.SetRunMs(45000)
        this.statsRecorder.runId := "20260518_120000_002"
        captured := []
        this._MakeFullSaverWithBus(captured).Save("cancelled")

        Assert.Equal(1, captured.Length)
        Assert.Equal("too_short", captured[1]["outcome"])
        Assert.Equal(45000,        captured[1]["durationMs"])
    }

    outcome_published_saved_for_completed_above_threshold()
    {
        ; Above threshold, completed reason, no PB shift — outcome
        ; "saved" with pbChanged=false.
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))
        ; _SaverStubPersonalBest.UpdateFromRun returns false.
        captured := []
        this._MakeFullSaverWithBus(captured).Save("completed")

        Assert.Equal(1, captured.Length)
        Assert.Equal("saved", captured[1]["outcome"])
        Assert.Equal(300000, captured[1]["durationMs"])
        Assert.False(captured[1]["pbChanged"])
    }

    outcome_published_saved_carries_pb_changed_flag()
    {
        ; Same as above but the PB stub flips a flag so the saver
        ; sees pbChanged=true. The widget paints a different colour
        ; based on this field, so it has to round-trip cleanly.
        ; _SaverPbReturnsTrue is defined at file scope above.
        this.timer.SetRunMs(450000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))
        this.personalBest := _SaverPbReturnsTrue()
        captured := []
        this._MakeFullSaverWithBus(captured).Save("completed")

        Assert.Equal(1, captured.Length)
        Assert.Equal("saved", captured[1]["outcome"])
        Assert.True(captured[1]["pbChanged"], "pbChanged round-trips from PB service")
    }

    outcome_published_dnf_for_cancelled_above_threshold()
    {
        ; Cancelled + above threshold = history yes, PB no = "dnf".
        ; pbChanged is always false for this outcome since the PB
        ; path is gated on reason="completed" upstream.
        this.timer.SetRunMs(600000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))
        captured := []
        this._MakeFullSaverWithBus(captured).Save("cancelled")

        Assert.Equal(1, captured.Length)
        Assert.Equal("dnf", captured[1]["outcome"])
        Assert.Equal(600000, captured[1]["durationMs"])
        Assert.False(captured[1]["pbChanged"])
    }

    outcome_silent_when_bus_missing()
    {
        ; The bus is optional. Existing test setups that don't pass
        ; one still work — _PublishOutcome short-circuits on the
        ; IsObject guard. This is the test that pins that
        ; back-compat: a saver constructed without a bus must not
        ; throw and must not crash the save path.
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))
        this._MakeFullSaver().Save("completed")
        ; No assertions on captured events — just no throw + Save
        ; ran to completion.
        Assert.Equal(1, this.runHistory.saveCalls)
    }

    outcome_silent_when_run_history_save_returns_false()
    {
        ; If runHistory.Save returns false (rare — the repo normally
        ; throws), the saver does NOT publish a "saved" outcome.
        ; Falsely signalling success when the file didn't land would
        ; mislead the banner; the TrayTip on the catch path already
        ; surfaces the problem. _SaverHistoryReturnsFalse lives at
        ; file scope above.
        this.runHistory := _SaverHistoryReturnsFalse()
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))
        captured := []
        this._MakeFullSaverWithBus(captured).Save("completed")

        Assert.Equal(0, captured.Length,
            "No outcome event when Save reports a non-success")
    }

    ; ============================================================
    ; Save failure path (catch block)
    ; ============================================================
    ;
    ; When runHistory.Save THROWS (vs returns false), the saver's
    ; outer catch is responsible for three things:
    ;
    ;   1. Not propagating the exception — callers of Save() are
    ;      the OnBeforeFinalize hooks in RunService, which expect
    ;      a clean return regardless of persistence success.
    ;   2. Logging at WARN so diagnostics are intact.
    ;   3. Surfacing a TrayTip to the user so they know the run
    ;      didn't actually land on disk. This was the gap caught
    ;      in the senior review: the inline comment in the outcome-
    ;      event branch above promised the TrayTip would fire from
    ;      this catch, but the original code only logged. Without
    ;      the TrayTip the user sees the timer stop, the hotkey
    ;      fire, and assumes the run was saved — silent data loss.
    ;
    ; Tests here use a real EventBus + InMemoryLogger so the
    ; observable surfaces (log + outcome-event absence) can be
    ; asserted directly. TrayTip itself is skipped in headless
    ; mode so it isn't testable here; the contract is that the
    ; code path is REACHABLE, which the log assertion below pins.

    save_does_not_propagate_when_history_save_throws()
    {
        ; The saver runs inside RunService's OnBeforeFinalize hook.
        ; Letting a Save throw would prevent the lifecycle event
        ; from publishing and leave the app in a wedged state
        ; (timer stopped, finalize half-done). The catch must
        ; swallow.
        this.runHistory := _SaverHistoryThrows()
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))

        threw := false
        try this._MakeFullSaver().Save("completed")
        catch
            threw := true

        Assert.False(threw,
            "history.Save throwing must NOT propagate out of saver.Save")
        Assert.Equal(1, this.runHistory.saveCalls,
            "the throwing Save path was actually reached")
    }

    save_logs_warn_when_history_save_throws()
    {
        ; The catch must leave a WARN entry citing the exception
        ; message so post-mortem diagnostics (or the boot-time
        ; severity TrayTip) can surface the failure. Replaces the
        ; default NullLogger with an InMemoryLogger for the
        ; assertion.
        this.runHistory := _SaverHistoryThrows()
        this.log := InMemoryLogger()
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))

        this._MakeFullSaver().Save("completed")

        Assert.True(this.log.HasEntry("WARN", "Failed to save run to history"),
            "the catch must log a WARN summarizing the failure")
        Assert.True(this.log.HasEntry("WARN", "forced save failure"),
            "the WARN must carry the underlying exception's message")
    }

    save_publishes_no_outcome_when_history_save_throws()
    {
        ; Symmetric to outcome_silent_when_run_history_save_returns_false:
        ; an exception from Save means we don't know whether the
        ; file landed or not. Publishing "saved" would be a lie,
        ; publishing "dnf" / "too_short" would be wrong shape.
        ; The saver stays silent on the bus and lets the TrayTip
        ; surface (untestable in headless) be the user-facing signal.
        this.runHistory := _SaverHistoryThrows()
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))
        captured := []

        this._MakeFullSaverWithBus(captured).Save("completed")

        Assert.Equal(0, captured.Length,
            "a thrown save must NOT result in a misleading outcome event")
    }

    ; ============================================================
    ; UndoLastSave
    ; ============================================================

    undo_no_op_when_no_save_marked()
    {
        saver := RunSnapshotSaver(this.runHistory, "", "", "", "", "",
            this.personalBest, this.log, true)
        saver.UndoLastSave()
        Assert.Equal(0, this.runHistory.deleteCalls,
            "Undo with no marked save should not touch runHistory")
        Assert.Equal(0, this.personalBest.rebuildCalls,
            "Undo with no marked save should not rebuild PBs")
    }

    undo_calls_delete_when_run_id_set()
    {
        saver := RunSnapshotSaver(this.runHistory, "", "", "", "", "",
            this.personalBest, this.log, true)
        ; Simulate a previous successful save: poke the field directly,
        ; bypassing the GUI-bound Save() path.
        saver._lastSavedRunId := "20260518_120000_000"
        saver.UndoLastSave()
        Assert.Equal(1, this.runHistory.deleteCalls)
        Assert.Equal("", saver._lastSavedRunId,
            "Undo should clear the runId after running")
    }

    undo_rebuilds_pbs_when_delete_succeeds()
    {
        this.runHistory._deletable := true
        saver := RunSnapshotSaver(this.runHistory, "", "", "", "", "",
            this.personalBest, this.log, true)
        saver._lastSavedRunId := "20260518_120000_000"
        saver.UndoLastSave()
        Assert.Equal(1, this.personalBest.rebuildCalls,
            "PBs must be rebuilt after a successful undo-delete")
    }

    undo_does_not_rebuild_when_delete_fails()
    {
        this.runHistory._deletable := false   ; simulates "file not found"
        saver := RunSnapshotSaver(this.runHistory, "", "", "", "", "",
            this.personalBest, this.log, true)
        saver._lastSavedRunId := "20260518_120000_000"
        saver.UndoLastSave()
        Assert.Equal(1, this.runHistory.deleteCalls)
        Assert.Equal(0, this.personalBest.rebuildCalls,
            "PB rebuild only runs after a successful delete")
    }

    ; ============================================================
    ; _ExpireUndoable
    ; ============================================================

    expire_clears_state()
    {
        saver := RunSnapshotSaver(this.runHistory, "", "", "", "", "",
            this.personalBest, this.log, true)
        saver._lastSavedRunId := "20260518_120000_000"
        saver._undoTimerFn := () => 0   ; non-empty sentinel
        saver._ExpireUndoable()
        Assert.Equal("", saver._lastSavedRunId)
        Assert.Equal("", saver._undoTimerFn)
    }
}

TestRegistry.Register(RunSnapshotSaverTests)
