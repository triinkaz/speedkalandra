; RunSnapshotSaver — finalizes a run to disk, updates personal bests,
; and exposes the 60-second undo window via the tray menu.
;
; Wired into RunService via `SetOnBeforeFinalize` (reason="completed")
; and `SetOnBeforeCancel`  (reason="cancelled") in the composition
; root. These hooks run in the same call frame as FinalizeRun /
; CancelRun, AFTER the timer/state have been updated and BEFORE the
; lifecycle event (RunCompleted / RunCancelled) is published. That
; means Save sees the run's final in-memory state regardless of
; what bus subscribers are wired — in particular,
; ZoneTrackingService still holds the run's totals and
; RunStatsRecorder still holds the runId. Earlier versions
; subscribed Save to the bus directly and relied on FIFO ordering
; of the composition root's __New to run before the state-clearing
; subscribers; the new design makes that contract explicit. The
; class itself doesn't subscribe to anything — it is only invoked
; through the hooks and the tray menu's `UndoLastSave`.
;
; Public surface:
;   Save(reason)         — "completed" or "cancelled"; threshold-gated
;   UndoLastSave()       — F1 from the tray menu; deletes + rebuilds PBs
;
; Undo flow:
;   1. Save() persists a run                 → _MarkUndoable(runId)
;   2. _MarkUndoable stores the id, adds the tray item, arms a 60 s
;      one-shot SetTimer pointing at _ExpireUndoable.
;   3a. User clicks the tray item            → UndoLastSave()
;       — deletes the file, rebuilds PBs from the surviving runs,
;         clears the timer and tray item.
;   3b. 60 s elapse                          → _ExpireUndoable()
;       — clears the runId and the tray item.


class RunSnapshotSaver
{
    ; Runs shorter than this are NOT persisted, regardless of reason
    ; (avoids test/quick-abort garbage). Applies uniformly to
    ; RunCompleted and RunCancelled.
    static MIN_SAVE_MS := 180000   ; 3 min

    _runHistory     := ""
    _zoneTracker    := ""
    _timer          := ""
    _statsRecorder  := ""
    _plotBuilder    := ""
    _actCheckpoints := ""
    _personalBest   := ""
    _log            := ""
    _headless       := false

    ; runId of the most recent save that can still be undone via the
    ; tray menu. Cleared after 60 s or once undo runs.
    _lastSavedRunId := ""
    _undoTimerFn    := ""

    __New(runHistory, zoneTracker, timer, statsRecorder, plotBuilder,
          actCheckpoints, personalBest, log, headless)
    {
        ; Lenient on individual service references — Save() and the
        ; undo path guard with IsObject() so the class can still be
        ; constructed in narrow test setups that only exercise one
        ; collaborator at a time.
        this._runHistory     := runHistory
        this._zoneTracker    := zoneTracker
        this._timer          := timer
        this._statsRecorder  := statsRecorder
        this._plotBuilder    := plotBuilder
        this._actCheckpoints := actCheckpoints
        this._personalBest   := personalBest
        this._log            := log
        this._headless       := !!headless
    }

    ; Persists a finished/cancelled run to history. The
    ; MIN_SAVE_MS threshold (3 min) applies uniformly to both
    ; reasons — below that, the run is discarded as test/quick-abort
    ; garbage. Completed saves above the threshold are marked
    ; undoable for 60 s via the tray menu.
    Save(reason)
    {
        try
        {
            if !IsObject(this._runHistory)
                return

            zoneTotals := IsObject(this._zoneTracker)
                          ? this._zoneTracker.GetTotalsForSnapshot()
                          : Map()
            ; Per-zone first-entry timestamps drive the chronological
            ; ordering of zones in the plot details.
            zoneFirstEnteredAt := IsObject(this._zoneTracker)
                                  ? this._zoneTracker.GetFirstEnteredAtMap()
                                  : Map()
            runMs := IsObject(this._timer) ? this._timer.GetRunMs() : 0

            ; Uniform threshold for completed and cancelled.
            if (runMs < RunSnapshotSaver.MIN_SAVE_MS)
            {
                if IsObject(this._log)
                {
                    try this._log.Info("Run too short, discarded (< "
                        . RunSnapshotSaver.MIN_SAVE_MS . "ms): "
                        . runMs . " ms (reason=" . reason . ")", "RunSnapshotSaver")
                }
                ; TrayTip only for completed — cancelled is expected
                ; to be silent (user cancelled intentionally)
                if (reason = "completed" && !this._headless)
                {
                    try TrayTip("SpeedKalandra",
                        "Run too short (" Duration.FormatMs(runMs)
                        "), not saved.", "Mute")
                }
                return
            }

            if !IsObject(this._statsRecorder) || !IsObject(this._plotBuilder)
                return

            snapshot := this._statsRecorder.GetSnapshot(zoneTotals, runMs, zoneFirstEnteredAt)
            buildResult := this._plotBuilder.Build(snapshot)

            ; Capture act checkpoints HERE and inject into buildResult
            ; before Save. Lets PersonalBestService.RebuildFromHistory
            ; rebuild per-act PBs after run deletes from the same
            ; persisted checkpoints that UpdateFromRun consumes. Runs
            ; saved before this was added carry no checkpoints; rebuild
            ; silently ignores them.
            actCheckpoints := Map()
            if IsObject(this._actCheckpoints)
            {
                try
                {
                    this._actCheckpoints.CaptureCurrentAsCheckpoint(runMs)
                }
                catch as ex
                {
                    if IsObject(this._log)
                        try this._log.Warn("Failed to capture final act checkpoint: " . ex.Message, "RunSnapshotSaver")
                }
                try
                {
                    actCheckpoints := this._actCheckpoints.GetCheckpoints()
                }
                catch as ex
                {
                    if IsObject(this._log)
                        try this._log.Warn("Failed to read act checkpoints for history (falling back to empty): " . ex.Message, "RunSnapshotSaver")
                }
            }
            buildResult["actCheckpoints"] := actCheckpoints

            saved := this._runHistory.Save(buildResult)
            rid := buildResult.Has("runId") ? buildResult["runId"] : ""
            if (saved && IsObject(this._log))
            {
                this._log.Info("Run saved to history (" . reason . "): " . rid
                    . " (" . runMs . " ms)", "RunSnapshotSaver")
            }

            ; --- Personal bests ---
            ; Completed runs only — cancelled doesn't count toward PB
            ; even if it crosses the threshold.
            pbChanged := false
            if (reason = "completed" && IsObject(this._personalBest))
            {
                try
                {
                    pbChanged := this._personalBest.UpdateFromRun(runMs, rid, zoneTotals, actCheckpoints)
                }
                catch as ex
                {
                    if IsObject(this._log)
                        try this._log.Warn("PB update failed on completed run " . rid . ": " . ex.Message, "RunSnapshotSaver")
                }
                if (pbChanged && IsObject(this._log))
                {
                    nActs := 0
                    for _, _ms in actCheckpoints
                    {
                        if (_ms > 0)
                            nActs += 1
                    }
                    try this._log.Info("PB updated on run " . rid
                        . " (runMs=" . runMs . ", checkpoints=" . nActs . ")", "RunSnapshotSaver")
                }
            }

            ; --- TrayTip + "Undo last save" tray menu item ---
            ; Completed only; cancelled is silent.
            if (saved && reason = "completed" && !this._headless)
            {
                durStr := Duration.FormatMs(runMs)
                msg := pbChanged
                    ? "Saved (" durStr "). PB updated! Tray menu has Undo (60s)."
                    : "Saved (" durStr "). Tray menu has Undo (60s)."
                try TrayTip("SpeedKalandra", msg, "Mute")
                this._MarkUndoable(rid)
            }
        }
        catch as ex
        {
            if IsObject(this._log)
                try this._log.Warn("Failed to save run to history: " ex.Message, "RunSnapshotSaver")
        }
    }

    ; Undo last save — F1 from the tray menu.
    ; The undo path rebuilds PBs (same semantics as the Delete button
    ; in RunHistoryDialog), so a deleted run no longer contributes to
    ; any PB.
    UndoLastSave()
    {
        ; Local `runId` collides case-insensitively with the `RunId`
        ; domain class; rename.
        currentRunId := this._lastSavedRunId
        if (currentRunId = "")
        {
            ; Stale menu item — clean up just in case.
            try SpeedKalandraTrayRemoveUndoItem()
            return
        }

        deleted := false
        try
        {
            if IsObject(this._runHistory)
                deleted := this._runHistory.Delete(currentRunId)
        }
        catch as ex
        {
            deleted := false
            if IsObject(this._log)
                try this._log.Warn("UndoLastSave: Delete threw for " . currentRunId . ": " . ex.Message, "RunSnapshotSaver")
        }

        ; Rebuild PBs from the surviving runs so the deleted run no
        ; longer contributes. Mirrors RunHistoryDialog._OnDeleteSelected.
        pbChanged := false
        if deleted
        {
            try
            {
                pbChanged := this._RebuildPbsFromHistory()
            }
            catch as ex
            {
                if IsObject(this._log)
                    try this._log.Warn("UndoLastSave: PB rebuild failed: " . ex.Message, "RunSnapshotSaver")
            }
        }

        ; Clear internal state
        this._lastSavedRunId := ""
        if (this._undoTimerFn != "")
        {
            try SetTimer(this._undoTimerFn, 0)
            this._undoTimerFn := ""
        }
        try SpeedKalandraTrayRemoveUndoItem()

        if IsObject(this._log)
        {
            try this._log.Info("Undo last save: " . currentRunId
                . (deleted ? " (removed)" : " (file not found)")
                . (pbChanged ? " | PBs rebuilt from history" : ""), "RunSnapshotSaver")
        }
        if !this._headless
        {
            if deleted
            {
                msg := pbChanged
                    ? "Last save removed. PBs were rebuilt from history."
                    : "Last save removed (no PB changes)."
            }
            else
            {
                msg := "Last save not found (already removed?)."
            }
            try TrayTip("SpeedKalandra", msg, "Mute")
        }
    }

    ; ---- Private helpers ----

    _MarkUndoable(runId)
    {
        if (runId = "")
            return
        this._lastSavedRunId := runId

        ; Cancel the old timer if it existed (previous save still undoable)
        if (this._undoTimerFn != "")
        {
            try SetTimer(this._undoTimerFn, 0)
            this._undoTimerFn := ""
        }

        ; Adds tray menu item (global helper in speedkalandra.ahk)
        try SpeedKalandraTrayAddUndoItem()

        ; Arms a one-shot timer to expire after 60 s (negative = run once)
        this._undoTimerFn := () => this._ExpireUndoable()
        try SetTimer(this._undoTimerFn, -60000)
    }

    ; Loads every surviving run from disk (full Load, with details
    ; and actCheckpoints) and replays them through
    ; PersonalBestService.RebuildFromHistory. Returns true if any PB
    ; changed. Mirrors the helper of the same name in
    ; RunHistoryDialog so both delete paths share semantics.
    _RebuildPbsFromHistory()
    {
        if !IsObject(this._personalBest)
            return false
        runs := []
        try
        {
            for _, rid in this._runHistory.ListRunIds()
            {
                br := this._runHistory.Load(rid)
                if IsObject(br)
                    runs.Push(br)
            }
        }
        catch as ex
        {
            if IsObject(this._log)
                try this._log.Warn("Failed to enumerate runs during PB rebuild: " . ex.Message, "RunSnapshotSaver")
        }
        return this._personalBest.RebuildFromHistory(runs)
    }

    _ExpireUndoable()
    {
        this._lastSavedRunId := ""
        this._undoTimerFn := ""
        try SpeedKalandraTrayRemoveUndoItem()
    }
}
