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
;
; B2: SetDetailsForBuild lets tests seed the details array the
; builder returns. The truncation logic in the saver filters
; this list by (act, stage); a stub that always returned []
; couldn't exercise that path.
class _SaverStubPlotBuilder
{
    detailsToReturn := ""

    __New()
    {
        this.detailsToReturn := []
    }

    SetDetailsForBuild(details)
    {
        this.detailsToReturn := details
    }

    Build(snapshot)
    {
        return Map(
            "runId",   snapshot.Has("runId")         ? snapshot["runId"]         : "",
            "firstTs", snapshot.Has("firstTs")       ? snapshot["firstTs"]       : "",
            "totalMs", snapshot.Has("runDurationMs") ? snapshot["runDurationMs"] : 0,
            "totals",  Map(),
            "details", this.detailsToReturn
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
;
; B2 surface: tests of the cancel-with-complete-act path use
; SetCheckpointsByStage to seed the completed (act, stage) buckets
; the saver's truncation step will consult.
class _SaverStubActCheckpoints
{
    captureCalls := 0
    _checkpoints := ""
    _checkpointsByStage := ""

    __New()
    {
        this._checkpoints        := Map()
        this._checkpointsByStage := Map()
    }

    SetCheckpoints(map)
    {
        this._checkpoints := map
    }

    SetCheckpointsByStage(map)
    {
        this._checkpointsByStage := map
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

    GetCheckpointsByStage()
    {
        out := Map()
        for k, v in this._checkpointsByStage
            out[k] := v
        return out
    }

    GetLastCompleteCheckpointMs()
    {
        maxMs := 0
        for _, ms in this._checkpointsByStage
        {
            if (IsNumber(ms) && ms > maxMs)
                maxMs := Integer(ms)
        }
        return maxMs
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
        "save_cancelled_without_complete_act_does_not_call_update_from_run",

        ; --- B2 cancel-path truncation ---
        "cancel_with_no_complete_act_drops_save_publishes_too_short",
        "cancel_with_complete_act_uses_truncated_runMs_for_save",
        "cancel_with_complete_act_filters_details_to_completed_buckets",
        "cancel_with_complete_act_recomputes_totals_from_filtered_details",
        "cancel_with_complete_act_keeps_deaths_via_category_bypass",
        "cancel_with_complete_act_does_not_capture_current_bucket",
        "cancel_with_complete_act_updates_pb_from_filtered_details",
        "cancel_with_complete_act_below_threshold_drops_save",
        "completed_path_still_captures_current_checkpoint",
        "completed_path_uses_real_runMs_in_save",

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

    save_cancelled_without_complete_act_does_not_call_update_from_run()
    {
        ; B2: Cancelled runs WITHOUT a complete (act, stage)
        ; bucket are dropped entirely — the early return on
        ; truncatedRunMs==0 skips both runHistory.Save and the PB
        ; path. The factual zoneTotals on the tracker (60s in
        ; Mud Burrow) don't matter because no act-boundary fired.
        ; This is the Q3.a contract ("DNF sem ato completo não
        ; salva"). For the with-complete-act variant see
        ; cancel_with_complete_act_updates_pb_from_filtered_details.
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))
        this.zoneTracker.activeZone     := "Mud Burrow"
        this.zoneTracker.currentVisitMs := 3000
        ; actCheckpoints is the default empty stub.

        this._MakeFullSaver().Save("cancelled")

        Assert.Equal(0, this.personalBest.updateCalls,
            "Cancel with no complete act doesn't reach UpdateFromRun")
        Assert.Equal(0, this.runHistory.saveCalls,
            "Cancel with no complete act doesn't reach runHistory.Save either")
    }

    ; ============================================================
    ; B2 cancel-path truncation
    ; ============================================================
    ;
    ; Cancel paths post-B2 split into two outcomes based on whether
    ; any (act, stage) was completed before the hotkey fired:
    ;
    ;   No complete act    → drop save, outcome "too_short" with
    ;                        durationMs=0. Banner reads "TOO SHORT
    ;                        · NOT SAVED". Q3.a contract.
    ;
    ;   ≥1 complete act    → save with effective runMs = the most
    ;                        recent captured checkpoint (the
    ;                        boundary that closed the last fully
    ;                        completed act). Details filtered to
    ;                        completed (act, stage) tuples only;
    ;                        totals recomputed from the survivors;
    ;                        totalMs and runDurationMs overridden
    ;                        to the truncated boundary so the
    ;                        sum-of-categories matches the saved
    ;                        runDurationMs. Outcome "dnf". PB path
    ;                        runs (Q-B2.3) against the truncated
    ;                        zone aggregation.
    ;
    ; The active bucket is deliberately NOT captured on cancel,
    ; so the saver's GetCheckpointsByStage view contains only
    ; fully-fledged completed buckets. CaptureCurrentAsCheckpoint
    ; runs only on the completed path (where the final boss kill
    ; has no outgoing transition to flush it otherwise).

    cancel_with_no_complete_act_drops_save_publishes_too_short()
    {
        ; 10 minutes of play (well above the 3-min threshold)
        ; that never crossed an act boundary — user gave up mid
        ; Act 1. Nothing to persist; banner reads TOO SHORT.
        this.timer.SetRunMs(600000)
        ; actCheckpoints is the default empty stub.
        captured := []
        this._MakeFullSaverWithBus(captured).Save("cancelled")

        Assert.Equal(0, this.runHistory.saveCalls,
            "No bucket captured → nothing to save")
        Assert.Equal(1, captured.Length)
        Assert.Equal("too_short", captured[1]["outcome"])
        Assert.Equal(0, captured[1]["durationMs"],
            "Truncated boundary is 0 when no act completed")
    }

    cancel_with_complete_act_uses_truncated_runMs_for_save()
    {
        ; 10-min real timer, Act 1 closed at 5 min. Saved snapshot
        ; reports the run as ending at 5 min — totalMs,
        ; runDurationMs and outcome durationMs all converge on
        ; the truncated boundary.
        this.timer.SetRunMs(600000)
        this.actCheckpoints.SetCheckpointsByStage(Map(
            "1|normal", 300000))
        this.plotBuilder.SetDetailsForBuild([
            Map("category", "mapa", "label", "Mud Burrow",
                "ms", 60000, "note", "Act 1", "stage", "normal")
        ])

        this._MakeFullSaver().Save("cancelled")

        Assert.Equal(1, this.runHistory.saveCalls)
        saved := this.runHistory._lastSaved
        Assert.Equal(300000, saved["runDurationMs"],
            "runDurationMs is the truncated boundary, not the 600000 real time")
        Assert.Equal(300000, saved["totalMs"],
            "totalMs converges on the same boundary so the saved file is self-consistent")
    }

    cancel_with_complete_act_filters_details_to_completed_buckets()
    {
        ; Mixed-act details: Act 1 normal completed; Act 2 normal
        ; is the active (partial) bucket. The cancel save keeps
        ; only the Act 1 normal details (mapa + cidade); the Act
        ; 2 normal map detail is dropped.
        this.timer.SetRunMs(600000)
        this.actCheckpoints.SetCheckpointsByStage(Map(
            "1|normal", 300000))
        this.plotBuilder.SetDetailsForBuild([
            Map("category", "mapa",   "label", "Mud Burrow",
                "ms", 60000, "note", "Act 1", "stage", "normal"),
            Map("category", "cidade", "label", "Clearfell Encampment",
                "ms", 30000, "note", "Act 1", "stage", "normal"),
            Map("category", "mapa",   "label", "Vastiri Outskirts",
                "ms", 90000, "note", "Act 2", "stage", "normal")
        ])

        this._MakeFullSaver().Save("cancelled")

        saved := this.runHistory._lastSaved
        Assert.Equal(2, saved["details"].Length,
            "Only Act 1 normal details survive the filter")
        keptLabels := Map()
        for _, d in saved["details"]
            keptLabels[d["label"]] := true
        Assert.True(keptLabels.Has("Mud Burrow"))
        Assert.True(keptLabels.Has("Clearfell Encampment"))
        Assert.False(keptLabels.Has("Vastiri Outskirts"),
            "Active (Act 2 normal) bucket dropped")
    }

    cancel_with_complete_act_recomputes_totals_from_filtered_details()
    {
        ; Same setup as above. Totals are recomputed from the kept
        ; details — the dropped Act 2 mapa entry's 90000ms doesn't
        ; contribute. totalMs stays at the truncated boundary
        ; (300000), NOT the sum of kept ms (90000) — the two are
        ; intentionally decoupled (sum-of-categories is what the
        ; user sees in the plot KPIs; runDurationMs / totalMs is
        ; the canonical "run length").
        this.timer.SetRunMs(600000)
        this.actCheckpoints.SetCheckpointsByStage(Map(
            "1|normal", 300000))
        this.plotBuilder.SetDetailsForBuild([
            Map("category", "mapa",   "label", "Mud Burrow",
                "ms", 60000, "note", "Act 1", "stage", "normal"),
            Map("category", "cidade", "label", "Clearfell Encampment",
                "ms", 30000, "note", "Act 1", "stage", "normal"),
            Map("category", "mapa",   "label", "Vastiri Outskirts",
                "ms", 90000, "note", "Act 2", "stage", "normal")
        ])

        this._MakeFullSaver().Save("cancelled")

        saved := this.runHistory._lastSaved
        Assert.Equal(60000, saved["totals"]["mapa"],
            "mapa total recomputed without the dropped Act 2 entry")
        Assert.Equal(30000, saved["totals"]["cidade"])
        Assert.False(saved["totals"].Has("loading"),
            "No category gains a row from this filter; new totals only"
            . " carries categories that survived")
    }

    cancel_with_complete_act_keeps_deaths_via_category_bypass()
    {
        ; Deaths carry no stage and the aggregated deathCount can't
        ; be sliced per (act, stage). The truncation filter applies
        ; a category bypass: category="morte" always passes. Honest
        ; because the in-app deathCount reflects all deaths during
        ; the underlying run; consistent with the plot dialog's
        ; Act Filter, which exempts deaths the same way.
        this.timer.SetRunMs(600000)
        this.actCheckpoints.SetCheckpointsByStage(Map(
            "1|normal", 300000))
        this.plotBuilder.SetDetailsForBuild([
            Map("category", "mapa",  "label", "Vastiri Outskirts",
                "ms", 90000, "note", "Act 2", "stage", "normal"),
            Map("category", "morte", "label", "3 deaths",
                "ms", 30000, "note", "", "stage", "")
        ])

        this._MakeFullSaver().Save("cancelled")

        saved := this.runHistory._lastSaved
        Assert.Equal(1, saved["details"].Length,
            "Vastiri dropped (Act 2 partial), death detail kept")
        Assert.Equal("morte", saved["details"][1]["category"])
        Assert.Equal(30000, saved["totals"]["morte"],
            "Death total survives the recompute")
    }

    cancel_with_complete_act_does_not_capture_current_bucket()
    {
        ; The active (partial) bucket must stay uncaptured on the
        ; cancel path — otherwise the truncation filter would see
        ; it in completedActStages and the active act's details
        ; would be wrongly retained.
        this.timer.SetRunMs(600000)
        this.actCheckpoints.SetCheckpointsByStage(Map(
            "1|normal", 300000))

        this._MakeFullSaver().Save("cancelled")

        Assert.Equal(0, this.actCheckpoints.captureCalls,
            "Cancel deliberately skips CaptureCurrentAsCheckpoint")
    }

    cancel_with_complete_act_updates_pb_from_filtered_details()
    {
        ; Q-B2.3: per-act PB updates on cancel-with-complete-act.
        ; The PB-eligible zone totals are AGGREGATED from the
        ; TRUNCATED details (mapa + cidade only) — the partial-act
        ; zone time doesn't leak into per-zone PBs. The runMs
        ; passed to UpdateFromRun is the truncated boundary, not
        ; the real timer value (so global run PB reflects the
        ; "this is how long the saved run was" semantic).
        this.timer.SetRunMs(600000)
        this.actCheckpoints.SetCheckpointsByStage(Map(
            "1|normal", 300000))
        this.plotBuilder.SetDetailsForBuild([
            Map("category", "mapa",   "label", "Mud Burrow",
                "ms", 60000, "note", "Act 1", "stage", "normal"),
            Map("category", "cidade", "label", "Clearfell Encampment",
                "ms", 30000, "note", "Act 1", "stage", "normal"),
            Map("category", "mapa",   "label", "Vastiri Outskirts",
                "ms", 90000, "note", "Act 2", "stage", "normal")   ; dropped
        ])

        this._MakeFullSaver().Save("cancelled")

        Assert.Equal(1, this.personalBest.updateCalls,
            "Cancel-with-complete-act DOES call UpdateFromRun (B2 contract)")
        Assert.Equal(300000, this.personalBest.lastUpdateRunMs,
            "PB sees the truncated runMs, not the real 600000 timer")
        Assert.Equal(60000, this.personalBest.lastUpdateZoneTotals["Mud Burrow"])
        Assert.Equal(30000, this.personalBest.lastUpdateZoneTotals["Clearfell Encampment"])
        Assert.False(this.personalBest.lastUpdateZoneTotals.Has("Vastiri Outskirts"),
            "Active-act zone excluded from PB candidates")
    }

    cancel_with_complete_act_below_threshold_drops_save()
    {
        ; Edge case: Act 1 closed at 60 s — below the 3-min
        ; MIN_SAVE_MS threshold. The threshold is now applied to
        ; the EFFECTIVE runMs (truncated boundary), so this drops
        ; even though the real timer might be well above 3 min.
        this.timer.SetRunMs(600000)
        this.actCheckpoints.SetCheckpointsByStage(Map(
            "1|normal", 60000))
        captured := []
        this._MakeFullSaverWithBus(captured).Save("cancelled")

        Assert.Equal(0, this.runHistory.saveCalls,
            "Truncated boundary below threshold → no save")
        Assert.Equal("too_short", captured[1]["outcome"])
        Assert.Equal(60000, captured[1]["durationMs"],
            "durationMs in too_short event still reports the truncated boundary")
    }

    completed_path_still_captures_current_checkpoint()
    {
        ; Regression: the active-bucket-capture is the ONLY way
        ; the final act lands in the saved checkpoints on a
        ; completed run (no outgoing transition fires after the
        ; boss kill). B2 explicitly gated this on reason="completed";
        ; this test pins that the gate still allows the call.
        this.timer.SetRunMs(300000)
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))

        this._MakeFullSaver().Save("completed")

        Assert.Equal(1, this.actCheckpoints.captureCalls,
            "Completed path still captures the active bucket")
    }

    completed_path_uses_real_runMs_in_save()
    {
        ; Regression: completed runs use the REAL timer value
        ; (not the lastCompleteCheckpointMs) for runDurationMs,
        ; totalMs, and PB.UpdateFromRun. The truncation logic
        ; runs only on the cancel path; completed bypasses it.
        this.timer.SetRunMs(400000)
        ; Even with a stale older checkpoint seeded in the stub,
        ; the completed path ignores it.
        this.actCheckpoints.SetCheckpointsByStage(Map(
            "1|normal", 60000))
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))

        this._MakeFullSaver().Save("completed")

        saved := this.runHistory._lastSaved
        Assert.Equal(400000, saved["totalMs"],
            "Completed runs persist the real timer value, not the truncated boundary")
        Assert.Equal(400000, this.personalBest.lastUpdateRunMs,
            "PB also sees the real timer value on completed")
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
        ; B2: cancel with empty checkpoints publishes too_short
        ; with durationMs=0 (the truncated boundary), NOT the
        ; real timer value. The pre-B2 behaviour was to report
        ; the real timer; this changed when the cancel path
        ; started routing through GetLastCompleteCheckpointMs
        ; first (an empty map returns 0). Banner thus reads
        ; "TOO SHORT · NOT SAVED" without a misleading duration.
        this.timer.SetRunMs(45000)
        this.statsRecorder.runId := "20260518_120000_002"
        captured := []
        this._MakeFullSaverWithBus(captured).Save("cancelled")

        Assert.Equal(1, captured.Length)
        Assert.Equal("too_short", captured[1]["outcome"])
        Assert.Equal(0, captured[1]["durationMs"],
            "truncated boundary is 0 when no act completed")
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
        ; Cancelled + above threshold + at least one complete act =
        ; history yes, PB candidate yes (B2), outcome "dnf". The
        ; durationMs in the event is the truncated boundary
        ; (lastCompleteCheckpointMs), NOT the real timer value —
        ; banner thus reads "DNF · 5:00" for a 10-min real run
        ; whose Act 1 closed at minute 5.
        this.timer.SetRunMs(600000)                                 ; 10 min real
        this.actCheckpoints.SetCheckpointsByStage(Map(
            "1|normal", 300000))                                    ; Act 1 at 5 min
        this.zoneTracker.SetTotals(Map("Mud Burrow", 60000))
        captured := []
        this._MakeFullSaverWithBus(captured).Save("cancelled")

        Assert.Equal(1, captured.Length)
        Assert.Equal("dnf",  captured[1]["outcome"])
        Assert.Equal(300000, captured[1]["durationMs"],
            "durationMs reports the truncated boundary, not real timer")
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
