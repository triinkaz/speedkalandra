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
