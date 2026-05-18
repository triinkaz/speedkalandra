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


; Minimal stub of ZoneTrackingService — saver only needs the two
; snapshot accessors during Save().
class _SaverStubZoneTracker
{
    GetTotalsForSnapshot()
    {
        return Map()
    }

    GetFirstEnteredAtMap()
    {
        return Map()
    }
}


; Minimal stub of PersonalBestService — RebuildFromHistory is the
; only path exercised from the undo flow.
class _SaverStubPersonalBest
{
    rebuildCalls := 0
    rebuildResult := false

    RebuildFromHistory(runs)
    {
        this.rebuildCalls += 1
        return this.rebuildResult
    }
}


class RunSnapshotSaverTests extends TestCase
{
    runHistory   := ""
    zoneTracker  := ""
    timer        := ""
    personalBest := ""
    log          := ""

    Setup()
    {
        this.runHistory   := _SaverStubRunHistory()
        this.zoneTracker  := _SaverStubZoneTracker()
        this.timer        := _SaverStubTimer()
        this.personalBest := _SaverStubPersonalBest()
        this.log          := NullLogger()
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
