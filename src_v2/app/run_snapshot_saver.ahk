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
;
; B2 cancel path — partial-act truncation:
;   When reason=="cancelled" the saver truncates the saved snapshot
;   to data from FULLY COMPLETED (act, stage) buckets only. The
;   active (partial) act is dropped: its zone time, loadings, and
;   the bump it would give to runDurationMs all stay out of the
;   persisted run. This means:
;
;     - Cancel with no complete act → nothing saved (outcome
;       too_short with truncatedRunMs=0). Fulfils BACKLOG B2's
;       Q3.a ("DNF sem ato completo não salva").
;     - Cancel with ≥1 complete act → saved as DNF with
;       runDurationMs = GetLastCompleteCheckpointMs(), details
;       filtered to completed (act, stage) tuples, totals
;       recomputed from filtered details. Banner shows the
;       truncated time (Q3.b). The PB path runs too — the last
;       complete act's checkpoint is a valid PB candidate even on
;       cancel (Q-B2.3).
;
;   Critically, the saver does NOT call CaptureCurrentAsCheckpoint
;   on the cancel path — doing so would write the active bucket
;   into _checkpointsByActStage and make it look "complete" to the
;   truncation filter. Only the completed path (reason=="completed")
;   captures the final (act, stage) explicitly, since the campaign
;   ending boss-kill has no outgoing transition to flush it.
;
;   Deaths bypass the truncation (category="morte" doesn't carry
;   stage; deathCount is a single aggregate from the recorder). A
;   cancelled run's saved deathCount reflects all deaths in the
;   underlying run, not just those during completed acts. Honest
;   given we don't have per-death timestamps; consistent with how
;   the plot dialog's act filter already treats deaths.


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

            ; --- B2 cancel-path truncation ---
            ; Cancel with no complete act → don't save anything.
            ; Cancel with ≥1 complete act → effective runMs becomes
            ; the LAST captured (act, stage) checkpoint. The active
            ; bucket isn't captured yet (no transition out of it,
            ; and we deliberately skip CaptureCurrentAsCheckpoint
            ; on cancel below), so the query returns the boundary
            ; that closed the last fully completed act.
            ; Completed path keeps the real runMs unchanged.
            truncatedRunMs := 0
            if (reason = "cancelled" && IsObject(this._actCheckpoints))
            {
                try truncatedRunMs := this._actCheckpoints.GetLastCompleteCheckpointMs()
                if (truncatedRunMs = 0)
                {
                    ; No complete act — user gave up before any
                    ; transition fired. Drop silently with a
                    ; too_short outcome so the banner reports
                    ; "TOO SHORT · NOT SAVED" instead of pretending
                    ; a DNF was persisted.
                    if IsObject(this._log)
                    {
                        try this._log.Info("Cancelled run with no complete "
                            . "act discarded (runMs=" . runMs . " ms, "
                            . "lastCompleteMs=0)", "RunSnapshotSaver")
                    }
                    this._PublishOutcome("too_short", 0, rid, false)
                    return
                }
            }

            ; Effective runMs is what flows into the threshold
            ; check, the saved runDurationMs, and the outcome
            ; event's durationMs. For completed runs it's just the
            ; real timer value; for cancelled runs with a complete
            ; act it's the truncated boundary.
            effectiveRunMs := (reason = "cancelled" && truncatedRunMs > 0)
                ? truncatedRunMs
                : runMs

            ; Uniform threshold for completed and cancelled, now
            ; applied to the EFFECTIVE runMs. A cancel with a 5-min
            ; Act 1 boundary still passes (5 min > 3 min) and is
            ; persisted as DNF. A cancel with a 2-min Act 1
            ; boundary doesn't pass and is dropped — same shape
            ; as the existing too-short defense.
            if (effectiveRunMs < RunSnapshotSaver.MIN_SAVE_MS)
            {
                if IsObject(this._log)
                {
                    try this._log.Info("Run too short, discarded (< "
                        . RunSnapshotSaver.MIN_SAVE_MS . "ms): "
                        . effectiveRunMs . " ms (reason=" . reason . ")", "RunSnapshotSaver")
                }
                ; TrayTip only for completed — cancelled is expected
                ; to be silent (user cancelled intentionally)
                if (reason = "completed" && !this._headless)
                {
                    try TrayTip("SpeedKalandra",
                        "Run too short (" Duration.FormatMs(effectiveRunMs)
                        "), not saved.", "Mute")
                }
                this._PublishOutcome("too_short", effectiveRunMs, rid, false)
                return
            }

            if !IsObject(this._statsRecorder) || !IsObject(this._plotBuilder)
                return

            snapshot := this._statsRecorder.GetSnapshot(zoneTotals, effectiveRunMs, zoneFirstEnteredAt)
            buildResult := this._plotBuilder.Build(snapshot)

            ; Capture act checkpoints HERE and inject into buildResult
            ; before Save. Lets PersonalBestService.RebuildFromHistory
            ; rebuild per-act PBs after run deletes from the same
            ; persisted checkpoints that UpdateFromRun consumes. Runs
            ; saved before this was added carry no checkpoints; rebuild
            ; silently ignores them.
            ;
            ; B2: capture the current bucket ONLY on completed runs.
            ; The cancel path deliberately leaves the active bucket
            ; uncaptured so the truncation step below treats it as
            ; the partial act it is. (Capturing it would promote the
            ; partial act into _checkpointsByActStage, defeating
            ; the whole point of B2.)
            actCheckpoints := Map()
            if IsObject(this._actCheckpoints)
            {
                if (reason = "completed")
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

            ; B2 truncation: on cancel with completed acts, drop
            ; details whose (act, stage) isn't in actCheckpoints,
            ; recompute totals from the survivors, and override
            ; totalMs + runDurationMs to the truncated boundary.
            ; The factual zoneTotals (from ZoneTrackingService) flow
            ; through unchanged — the plot builder already snapshot
            ; -ed them into details, and the filter narrows on the
            ; details list. Deaths bypass via category="morte".
            if (reason = "cancelled" && truncatedRunMs > 0)
            {
                this._TruncateBuildResultToCompletedActStages(
                    buildResult, actCheckpoints, truncatedRunMs)
            }

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
            ; Updates on both completed runs and on cancelled-with-
            ; complete-act runs (B2 Q-B2.3): the last complete act's
            ; checkpoint is a valid PB candidate even when the user
            ; cancelled mid-next-act. The buildResult passed here is
            ; already truncated for the cancel path, so the per-zone
            ; aggregation runs against completed-act zones only.
            pbChanged := false
            pbEligible := (reason = "completed")
                          || (reason = "cancelled" && truncatedRunMs > 0)
            if (pbEligible && IsObject(this._personalBest))
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
                ;
                ; B2 cancel path: rebuild pbZoneTotals from the
                ; TRUNCATED details list (only completed-act zones)
                ; so the partial-act zone time is excluded from PB
                ; candidates. This is symmetric with the completed
                ; path's interrupted-visit discount — both flavors
                ; of "this time doesn't represent a real closed
                ; visit" get filtered out before UpdateFromRun runs.
                pbZoneTotals := Map()
                if (reason = "cancelled" && truncatedRunMs > 0)
                {
                    ; Aggregate per-zone time from the truncated
                    ; details. Category-filter to map+town entries
                    ; (loadings have toZone but their `label` is the
                    ; loading description, not a zone, so they don't
                    ; contribute to per-zone totals). The plot
                    ; builder's _AddZoneDetails uses zoneName as
                    ; label for both mapa and cidade categories.
                    for _, detail in (buildResult.Has("details") && IsObject(buildResult["details"]) ? buildResult["details"] : [])
                    {
                        cat := detail.Has("category") ? detail["category"] : ""
                        if (cat != "mapa" && cat != "cidade")
                            continue
                        label := detail.Has("label") ? detail["label"] : ""
                        ms    := detail.Has("ms") ? detail["ms"] : 0
                        if (label = "" || ms <= 0)
                            continue
                        if !pbZoneTotals.Has(label)
                            pbZoneTotals[label] := 0
                        pbZoneTotals[label] += ms
                    }
                }
                else
                {
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
                }

                try
                {
                    pbChanged := this._personalBest.UpdateFromRun(effectiveRunMs, rid, pbZoneTotals, actCheckpoints)
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
                        . " (runMs=" . effectiveRunMs . ", checkpoints=" . nActs . ")", "RunSnapshotSaver")
                }
            }

            ; --- TrayTip + "Undo last save" tray menu item ---
            ; Completed only; cancelled is silent.
            if (saved && reason = "completed" && !this._headless)
            {
                durStr := Duration.FormatMs(effectiveRunMs)
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
            ; report "dnf" (history yes, PB now yes too on B2 with
            ; complete acts). If runHistory.Save returned false (rare
            ; — the repository normally throws), we stay silent here:
            ; no banner, no false signal of success. The TrayTip on
            ; the save-failure catch already surfaces the problem.
            if saved
            {
                outcome := (reason = "completed") ? "saved" : "dnf"
                this._PublishOutcome(outcome, effectiveRunMs, rid, pbChanged)
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

    ; B2: mutates `buildResult` IN PLACE. Filters `details` to
    ; entries whose (act, stage) pair is present in
    ; `completedActStages`. Recomputes `totals` from the
    ; survivors. Overrides `totalMs` and `runDurationMs` to
    ; `truncatedRunMs` so the saved snapshot reads as a clean
    ; partial-run record (banner duration, plot duration, and
    ; sum-of-categories all converge on the same boundary).
    ;
    ; `completedActStages` is the Map<"act|stage", ms> returned by
    ; ActCheckpointTracker.GetCheckpointsByStage(). On cancel the
    ; current bucket is NOT in that map (the saver skips
    ; CaptureCurrentAsCheckpoint on cancel), so membership checks
    ; correctly reject details from the active partial act.
    ;
    ; Filter rules per detail:
    ;   - category="morte" → always kept. Deaths carry no stage
    ;     and the aggregated deathCount can't be sliced per
    ;     (act, stage) without per-death timestamps we don't have
    ;     today. Same exemption the plot dialog's Act Filter uses.
    ;   - note doesn't parse to an act → dropped. Unattributable
    ;     under exact-match truncation. Pre-B2 saves that survived
    ;     pre-this-feature with weird notes would round-trip
    ;     un-truncated (this method is only invoked on the cancel
    ;     PATH; legacy on-disk runs aren't re-truncated by Load).
    ;   - (parsed-act, stage) not in completedActStages → dropped.
    ;     Stage defaults to "normal" when the detail has no stage
    ;     field (pre-B1 details, loadings emitted before stage
    ;     wiring landed). Matches the behaviour of
    ;     RunStatsPlotBuilder._DetailPassesAct.
    _TruncateBuildResultToCompletedActStages(buildResult, completedActStages, truncatedRunMs)
    {
        if !IsObject(buildResult)
            return
        srcDetails := (buildResult.Has("details") && IsObject(buildResult["details"]))
            ? buildResult["details"]
            : []

        keptDetails := []
        newTotals := Map()
        for _, d in srcDetails
        {
            if !IsObject(d)
                continue
            if !this._DetailIsInCompletedActStages(d, completedActStages)
                continue
            keptDetails.Push(d)
            cat := d.Has("category") ? d["category"] : ""
            ms  := d.Has("ms") ? d["ms"] : 0
            if (cat = "" || ms <= 0)
                continue
            if !newTotals.Has(cat)
                newTotals[cat] := 0
            newTotals[cat] += ms
        }

        buildResult["details"]       := keptDetails
        buildResult["totals"]        := newTotals
        buildResult["totalMs"]       := Integer(truncatedRunMs)
        buildResult["runDurationMs"] := Integer(truncatedRunMs)
        ; maxActReached carries through unchanged on purpose — it
        ; describes the run's highest reached act (a fact about the
        ; underlying play session), not the truncated view's
        ; surviving acts. A run that reached Act 2 but was cancelled
        ; with only Act 1 in completedActStages still has
        ; maxActReached=2 on disk — honest, and consistent with the
        ; plot dialog's FilterByAct behaviour.
    }

    ; Predicate for _TruncateBuildResultToCompletedActStages. Kept
    ; out-of-line to keep the loop body small and so the rules can
    ; be tested as a unit. See the parent method's comment for the
    ; rationale of each branch.
    _DetailIsInCompletedActStages(detail, completedActStages)
    {
        cat := detail.Has("category") ? detail["category"] : ""
        if (cat = "morte")
            return true

        note := detail.Has("note") ? detail["note"] : ""
        if !RegExMatch(note, "(?:Ato|Act)\s+(\d+)", &m)
            return false
        act := Integer(m[1] + 0)
        if (act <= 0)
            return false

        stage := detail.Has("stage") ? String(detail["stage"]) : "normal"
        if (stage != "normal" && stage != "interlude")
            stage := "normal"

        compositeKey := Integer(act) . "|" . stage
        return IsObject(completedActStages) && completedActStages.Has(compositeKey)
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
