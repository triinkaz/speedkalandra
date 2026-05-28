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
;
; Outcome reporting:
;   Every Save() call ends in exactly one Events.RunOutcomeReported
;   publish: "saved" / "dnf" / "too_short". The bus is optional so
;   narrow test setups that only exercise the persistence side can
;   skip it (IsObject check before each publish). The widget that
;   surfaces this to the user is RunOutcomeBannerWidget; the saver
;   itself doesn't know about UI.


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
    _bus            := ""

    ; runId of the most recent save that can still be undone via the
    ; tray menu. Cleared after 60 s or once undo runs.
    _lastSavedRunId := ""
    _undoTimerFn    := ""

    __New(runHistory, zoneTracker, timer, statsRecorder, plotBuilder,
          actCheckpoints, personalBest, log, headless, bus := "")
    {
        ; Lenient on individual service references — Save() and the
        ; undo path guard with IsObject() so the class can still be
        ; constructed in narrow test setups that only exercise one
        ; collaborator at a time. Same leniency applies to the bus:
        ; the saver publishes RunOutcomeReported when a bus is
        ; available and silently skips otherwise. Production wires
        ; one; persistence-only tests can leave it empty.
        this._runHistory     := runHistory
        this._zoneTracker    := zoneTracker
        this._timer          := timer
        this._statsRecorder  := statsRecorder
        this._plotBuilder    := plotBuilder
        this._actCheckpoints := actCheckpoints
        this._personalBest   := personalBest
        this._log            := log
        this._headless       := !!headless
        this._bus            := bus
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
            ; The zone that was active when the hotkey fired and the
            ; elapsed of that visit -- captured straight after
            ; _OnTimerStopped flushed it but BEFORE RunCompleted is
            ; published. RunSnapshotSaver runs in the
            ; OnBeforeFinalize hook, which is exactly that window.
            ; This visit didn't close via transition, so it isn't
            ; PB-eligible: we discount it from pbZoneTotals below
            ; (factual zoneTotals stay untouched for history/plot).
            ; The pair is also persisted into buildResult so
            ; RebuildFromHistory can apply the same discount on
            ; Undo / Delete. `try expr` silences UnsetItemError
            ; from lightweight test stubs that don't implement the
            ; new methods.
            interruptedZoneName := ""
            interruptedZoneVisitMs := 0
            if IsObject(this._zoneTracker)
            {
                try interruptedZoneName := String(this._zoneTracker.GetActiveZone())
                try interruptedZoneVisitMs := Integer(this._zoneTracker.GetCurrentVisitMs())
            }
            runMs := IsObject(this._timer) ? this._timer.GetRunMs() : 0

            ; Captured early so the too_short branch (which returns
            ; before buildResult exists) can still report a runId in
            ; the outcome event. Falls back to "" if the stats
            ; recorder isn't wired.
            rid := IsObject(this._statsRecorder) ? this._statsRecorder.GetRunId() : ""

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
                this._PublishOutcome("too_short", runMs, rid, false)
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
                    ; B1 Layer B: use the stage-aware checkpoints so
                    ; cruel Act N doesn't overwrite normal Act N in
                    ; the persisted history. The composite-key Map
                    ; flows through buildResult["actCheckpoints"] →
                    ; RunHistoryRepository serialization → PB Service
                    ; UpdateFromRun / RebuildFromHistory. All three
                    ; speak the new shape; legacy integer-keyed
                    ; values are still accepted by every consumer
                    ; for older runs already on disk.
                    actCheckpoints := this._actCheckpoints.GetCheckpointsByStage()
                }
                catch as ex
                {
                    if IsObject(this._log)
                        try this._log.Warn("Failed to read act checkpoints for history (falling back to empty): " . ex.Message, "RunSnapshotSaver")
                }
            }
            buildResult["actCheckpoints"] := actCheckpoints

            ; Persist the interrupted-visit info alongside the
            ; factual totals so RebuildFromHistory (UndoLastSave /
            ; history Delete) can apply the same PB discount as
            ; UpdateFromRun below. Legacy runs lack these keys; the
            ; repository's Load defaults them to "" / 0 (no discount,
            ; matches the bug's original behavior for those runs --
            ; consistent with the data they were saved with).
            buildResult["interruptedZoneName"]    := interruptedZoneName
            buildResult["interruptedZoneVisitMs"] := interruptedZoneVisitMs

            saved := this._runHistory.Save(buildResult)
            rid := buildResult.Has("runId") ? buildResult["runId"] : rid
            if (saved && IsObject(this._log))
            {
                this._log.Info("Run saved to history (" . reason . "): " . rid
                    . " (" . runMs . " ms)", "RunSnapshotSaver")
            }

            ; --- Personal bests ---
            ; Completed runs only -- cancelled doesn't count toward PB
            ; even if it crosses the threshold.
            pbChanged := false
            if (reason = "completed" && IsObject(this._personalBest))
            {
                ; PB-eligible totals: factual zoneTotals minus the
                ; time of the visit that was interrupted by the
                ; hotkey. That visit never closed via transition, so
                ; it isn't PB-eligible. Visits before it in the same
                ; run are unaffected -- a zone visited twice (one
                ; complete + one interrupted) keeps the complete
                ; visit's contribution as a PB candidate.
                ; RebuildFromHistory applies the same discount via
                ; the persisted keys so Undo lands on the same PB.
                pbZoneTotals := Map()
                for zoneKey, zoneMs in zoneTotals
                    pbZoneTotals[zoneKey] := zoneMs
                if (interruptedZoneName != "" && interruptedZoneVisitMs > 0
                    && pbZoneTotals.Has(interruptedZoneName))
                {
                    adjusted := pbZoneTotals[interruptedZoneName] - interruptedZoneVisitMs
                    if (adjusted > 0)
                        pbZoneTotals[interruptedZoneName] := adjusted
                    else
                        pbZoneTotals.Delete(interruptedZoneName)
                }

                try
                {
                    pbChanged := this._personalBest.UpdateFromRun(runMs, rid, pbZoneTotals, actCheckpoints)
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

            ; --- Outcome event ---
            ; Published exactly once per Save() call that crossed the
            ; threshold. Completed runs report "saved" with the real
            ; pbChanged; cancelled runs that crossed the threshold
            ; report "dnf" (history yes, PB no). If runHistory.Save
            ; returned false (rare — the repository normally throws),
            ; we stay silent here: no banner, no false signal of
            ; success. The TrayTip on the save-failure catch already
            ; surfaces the problem.
            if saved
            {
                outcome := (reason = "completed") ? "saved" : "dnf"
                this._PublishOutcome(outcome, runMs, rid, pbChanged)
            }
        }
        catch as ex
        {
            ; Save failed mid-flow (runHistory.Save threw, the
            ; statsRecorder.GetSnapshot blew up on bad state, or
            ; any other unexpected exception). Two things must
            ; happen here:
            ;
            ;   1. Log at WARN so the diagnostics trail is intact.
            ;   2. Surface a TrayTip to the user — the comment in
            ;      the outcome-event branch above promises this,
            ;      and without it the user has no signal that the
            ;      run wasn't actually persisted (the in-game
            ;      timer stopped, the hotkey fired, but the
            ;      history file is silently missing the run).
            ;
            ; TrayTip is gated on !this._headless so tests don't
            ; pop OS-level notifications. Wrapped in try because
            ; some hardened Windows configurations (group policy)
            ; can make TrayTip throw — a failed surface attempt
            ; on top of an already-failed save shouldn't escalate.
            if IsObject(this._log)
                try this._log.Warn("Failed to save run to history: " ex.Message, "RunSnapshotSaver")
            if !this._headless
            {
                try TrayTip("SpeedKalandra",
                    "Run NOT saved to history. Check the log for details.",
                    "Mute Icon!")
            }
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

    ; Publishes Events.RunOutcomeReported when a bus was wired.
    ; Silent no-op otherwise (narrow tests construct the saver
    ; without a bus). Wrapped in try because the bus subscriber
    ; chain shouldn't be able to fail the save — a misbehaving
    ; widget that throws on RunOutcomeReported shouldn't make the
    ; run vanish.
    _PublishOutcome(outcome, durationMs, runId, pbChanged)
    {
        if !IsObject(this._bus)
            return
        try this._bus.Publish(Events.RunOutcomeReported, Map(
            "outcome",    outcome,
            "durationMs", Integer(durationMs),
            "runId",      String(runId),
            "pbChanged",  !!pbChanged
        ))
    }

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
