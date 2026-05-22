; RunService — run lifecycle (minimal state: runId, startedAt,
; status). Coordinates TimerService (mechanics) and
; RunStateRepository (persistence).
;
; Operations:
;   NewRun()      generate runId, reset timer, publish RunStarted
;   FinalizeRun() stop timer, status=completed, publish RunCompleted
;   CancelRun()   stop timer, status=cancelled, publish RunCancelled
;   ResetRun()    reset timer, clear state, publish RunReset
;   Hydrate(s)    restore state from disk and resume the timer
;
; Hydrate also re-emits RunStarted{hydrated:true} so that services
; depending on the event (RunStatsRecorder, ZoneTrackingService,
; etc.) re-sync their state on app reload. The composition root
; defers the Hydrate call to the end of __New so every subscriber
; is in place when the event fires.
;
; Persistence has two paths so the every-5s tick doesn't lag the
; main thread: PersistTimer writes a single field (runBaseMs);
; _Persist writes all four and runs only on lifecycle transitions.
;
; Pre-publish hooks (SetOnBeforeFinalize / SetOnBeforeCancel):
;   The composition root wires RunSnapshotSaver.Save through these
;   hooks instead of subscribing it to the bus. Reason: a bus
;   subscriber to RunCompleted/RunCancelled would race against
;   ZoneTrackingService and RunStatsRecorder, which clear their
;   in-memory state on RunCancelled (ZoneTracker also flushes on
;   RunCompleted but keeps _totals for the plot dialog). FIFO
;   ordering of Subscribe calls in __New used to be the implicit
;   guarantee that Save ran first; replacing that with an explicit
;   hook here makes the contract visible in code and removes the
;   reordering risk. The hook runs AFTER the timer/state mutation
;   and BEFORE Publish, so subscribers and the hook see the same
;   final state. A throw inside the hook is caught and warned via
;   the logger — the lifecycle event still fires so widgets and
;   state-clearers downstream of RunCompleted/RunCancelled can
;   react.
;
; AHK v2 gotcha: parameter is `timerSvc`, not `timerService` — AHK
; variable lookup is case-insensitive, and `is TimerService` would
; collide with a `timerService` local.


class RunService
{
    _clock     := ""
    _bus       := ""
    _timer     := ""
    _stateRepo := ""
    _state     := ""    ; RunState
    _log       := ""    ; Logger (NullLogger by default) — used to warn on hook throws.

    ; --- Persistence health (for UI/tray surface) ---
    ; _persistenceDegraded flips to true on any lifecycle-persist
    ; failure. A successful _Persist clears it. UI/tray code can
    ; query IsPersistenceDegraded() to surface that crash recovery
    ; may be stale until the next successful save.
    _persistenceDegraded      := false
    ; _persistenceTrayTipCount counts the TrayTip notifications we
    ; actually fired (i.e. ones that passed the cooldown gate).
    ; Tests use GetPersistenceTrayTipCount() to verify the rate-
    ; limiting works — production code doesn't need to read it.
    _persistenceTrayTipCount  := 0
    ; _lastDegradedTrayTipMs holds the clock.NowMs() of the most
    ; recent TrayTip so we can throttle to one notification per
    ; DEGRADED_TRAYTIP_COOLDOWN_MS window. Initialized to
    ; -DEGRADED_TRAYTIP_COOLDOWN_MS so the first failure ever —
    ; even at clock=0 — passes the cooldown gate. (A plain 0
    ; initializer would gate-block any failure that happens while
    ; clock.NowMs() is still under 60000 ms.)
    _lastDegradedTrayTipMs    := -60000
    static DEGRADED_TRAYTIP_COOLDOWN_MS := 60000   ; 60 s

    ; Pre-publish hooks. "" means unwired. See the class header for
    ; the rationale. Settable post-construction (the snapshot saver
    ; they typically point at is constructed later in the composition
    ; root).
    _onBeforeFinalize := ""
    _onBeforeCancel   := ""

    _handlerNew      := ""
    _handlerFinalize := ""
    _handlerCancel   := ""
    _handlerReset    := ""

    __New(clock, bus, timerSvc, stateRepo, log := "")
    {
        if !IsObject(clock) || !clock.HasMethod("NowMs")
            throw TypeError("RunService: 'clock' must implement NowMs()")
        if !(bus is EventBus)
            throw TypeError("RunService: 'bus' must be EventBus")
        if !(timerSvc is TimerService)
            throw TypeError("RunService: 'timerSvc' must be TimerService")
        if !(stateRepo is RunStateRepository)
            throw TypeError("RunService: 'stateRepo' must be RunStateRepository")

        this._clock     := clock
        this._bus       := bus
        this._timer     := timerSvc
        this._stateRepo := stateRepo
        this._state     := RunState.Empty()
        ; Logger is optional (tests construct without one). Default
        ; to NullLogger so the hook-failure warn path is a safe no-op
        ; in those callers. Production wires the real LogService.
        this._log       := (log = "") ? NullLogger() : log

        this._handlerNew      := (data) => this.NewRun()
        this._handlerFinalize := (data) => this.FinalizeRun()
        this._handlerCancel   := (data) => this.CancelRun()
        this._handlerReset    := (data) => this.ResetRun()

        bus.Subscribe(Commands.NewRunRequested,      this._handlerNew)
        bus.Subscribe(Commands.FinalizeRunRequested, this._handlerFinalize)
        bus.Subscribe(Commands.CancelRunRequested,   this._handlerCancel)
        bus.Subscribe(Commands.ResetRunRequested,    this._handlerReset)
    }

    ; Sets the pre-publish hook for FinalizeRun. Pass "" to clear.
    ; Fail-fast on non-callable so a wiring bug trips here instead of
    ; the next FinalizeRun call.
    SetOnBeforeFinalize(callback)
    {
        if (callback != "" && !(callback is Func) && !HasMethod(callback, "Call"))
            throw TypeError("RunService.SetOnBeforeFinalize: callback must be callable (Func or have Call method)")
        this._onBeforeFinalize := callback
    }

    ; Sets the pre-publish hook for CancelRun. Same contract as the
    ; finalize variant.
    SetOnBeforeCancel(callback)
    {
        if (callback != "" && !(callback is Func) && !HasMethod(callback, "Call"))
            throw TypeError("RunService.SetOnBeforeCancel: callback must be callable (Func or have Call method)")
        this._onBeforeCancel := callback
    }

    Dispose()
    {
        if (this._handlerNew != "")
        {
            this._bus.Unsubscribe(Commands.NewRunRequested, this._handlerNew)
            this._handlerNew := ""
        }
        if (this._handlerFinalize != "")
        {
            this._bus.Unsubscribe(Commands.FinalizeRunRequested, this._handlerFinalize)
            this._handlerFinalize := ""
        }
        if (this._handlerCancel != "")
        {
            this._bus.Unsubscribe(Commands.CancelRunRequested, this._handlerCancel)
            this._handlerCancel := ""
        }
        if (this._handlerReset != "")
        {
            this._bus.Unsubscribe(Commands.ResetRunRequested, this._handlerReset)
            this._handlerReset := ""
        }
    }

    Hydrate(stateObj)
    {
        if !(stateObj is RunState)
            throw TypeError("RunService.Hydrate: 'stateObj' must be RunState")
        this._state := stateObj
        this._timer.Hydrate(stateObj.runBaseMs, stateObj.status)

        ; Re-emit RunStarted with hydrated:true so services that
        ; missed the original event on a previous app instance pick
        ; up the run id and re-arm their state. Without this:
        ;   - RunStatsRecorder stays with _runId="" — finalizing
        ;     produces a snapshot with empty runId that
        ;     RunHistoryRepository silently rejects.
        ;   - AutoStartService stays with _runActive=false — the
        ;     next "Wounded Man" log line would trigger a duplicate
        ;     run start.
        ;   - ActCheckpointTracker recovers _currentAct on the next
        ;     ZoneEntered but the previous session's checkpoints
        ;     are lost (they were never persisted to disk).
        ;
        ; The hydrated flag lets handlers tell this apart from a
        ; fresh NewRun (e.g. _OnRunStartedForXp skips the area reset).
        if stateObj.IsActive()
        {
            this._bus.Publish(Events.RunStarted, Map(
                "runId",     stateObj.runId,
                "startedAt", stateObj.startedAt,
                "profileId", "",
                "hydrated",  true
            ))
        }
    }

    GetRunId()     => this._state.runId
    GetStatus()    => this._state.status
    GetStartedAt() => this._state.startedAt
    IsActive()     => this._state.IsActive()
    IsRunning()    => this._state.IsRunning()
    IsPaused()     => this._state.IsPaused()
    GetState()     => this._state

    ; True when the most recent lifecycle-transition _Persist
    ; threw and no later _Persist has succeeded since. UI/tray
    ; can surface a "crash recovery may be stale" indicator while
    ; this is true. Cleared automatically by the next successful
    ; _Persist (which also logs an Info entry so a log tail shows
    ; the recovery transition explicitly).
    IsPersistenceDegraded() => this._persistenceDegraded

    ; Test-facing accessor: number of TrayTip notifications fired
    ; due to persistence degradation. Increments only when the
    ; cooldown window has elapsed since the last notification, so
    ; tests can verify the rate-limit by advancing a stub clock
    ; and checking this counter.
    GetPersistenceTrayTipCount() => this._persistenceTrayTipCount

    ; NewRun on an active run discards the current state (ResetRun)
    ; instead of cancelling it. CancelRun would save to history if
    ; runMs >= 3 min, which used to surprise users who just wanted
    ; to restart. Workflow:
    ;   - Save before restart: FinalizeRun (Ctrl+Alt+F), then NewRun.
    ;   - Discard and restart:  NewRun directly (Ctrl+Alt+N).
    NewRun(profileId := "")
    {
        if this._state.IsActive()
            this.ResetRun()

        this._state := RunState.Empty()
        this._state.runId     := this._GenerateRunId()
        this._state.startedAt := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
        this._state.status    := "running"
        this._state.runBaseMs := 0

        this._timer.Reset()
        this._timer.Start()
        this._Persist()

        this._bus.Publish(Events.RunStarted, Map(
            "runId",     this._state.runId,
            "startedAt", this._state.startedAt,
            "profileId", profileId
        ))
        return true
    }

    FinalizeRun()
    {
        if !this._state.IsActive()
            return false
        ; Local `runId` collides with the `RunId` domain class; rename.
        currentRunId := this._state.runId
        durationMs := this._timer.GetRunMs()

        this._timer.Stop()
        this._state.status    := "completed"
        this._state.runBaseMs := durationMs
        this._Persist()

        ; Pre-publish hook — runs while collaborators (zoneTracker,
        ; statsRecorder, etc.) still hold the run's in-memory state.
        ; Wrapped in try so a throw doesn't block the lifecycle event
        ; from firing; the event still needs to reach widgets and
        ; state-clearers downstream. See class header.
        this._InvokeBeforeHook(this._onBeforeFinalize, "OnBeforeFinalize")

        this._bus.Publish(Events.RunCompleted, Map(
            "runId",      currentRunId,
            "durationMs", durationMs
        ))
        return true
    }

    CancelRun()
    {
        if !this._state.IsActive()
            return false
        currentRunId := this._state.runId

        this._timer.Stop()
        this._state.status := "cancelled"
        this._Persist()

        ; Pre-publish hook — same contract as FinalizeRun. Critical
        ; here because ZoneTrackingService / RunStatsRecorder DO clear
        ; state on RunCancelled, so the hook is the only safe point
        ; to capture totals for a saved long-cancelled run.
        this._InvokeBeforeHook(this._onBeforeCancel, "OnBeforeCancel")

        this._bus.Publish(Events.RunCancelled, Map("runId", currentRunId))
        return true
    }

    ResetRun()
    {
        currentRunId := this._state.runId
        this._timer.Reset()
        this._state := RunState.Empty()
        this._stateRepo.Clear()

        this._bus.Publish(Events.RunReset, Map("runId", currentRunId))
        return true
    }

    PersistTick() => this.PersistTimer()

    ; Persists only runBaseMs (1 IniWrite). Called by the composition
    ; root every 5 s; the other three fields only change on lifecycle
    ; transitions, which already invoke _Persist (4 IniWrites). The
    ; split exists because the naive every-tick full Save was lagging
    ; the main thread enough to delay pause detection by ~6 s.
    PersistTimer()
    {
        if !this._state.IsActive()
            return
        this._state.runBaseMs := this._timer.GetRunMs()
        try this._stateRepo.SaveRunBaseMs(this._state.runBaseMs)
    }

    _Persist()
    {
        try
        {
            this._stateRepo.Save(this._state)
        }
        catch as ex
        {
            ; Lifecycle-transition persist (NewRun, FinalizeRun,
            ; CancelRun). A failure here means crash recovery
            ; will see stale data on the next boot. Four things
            ; happen, in order:
            ;
            ;   (a) Log Warn unconditionally. Persistent disk
            ;       issues need a trail in the log file so a bug
            ;       report can find the root cause.
            ;
            ;   (b) Set _persistenceDegraded := true so UI/tray
            ;       can surface that crash recovery is stale.
            ;       The flag stays set until the next successful
            ;       _Persist clears it.
            ;
            ;   (c) Rate-limited TrayTip — fire at most one
            ;       notification per DEGRADED_TRAYTIP_COOLDOWN_MS
            ;       window. Without throttling, a transient lock
            ;       (antivirus scan, OneDrive sync, backup app)
            ;       could burst 3+ notifications across a
            ;       NewRun → FinalizeRun → NewRun sequence in a
            ;       couple of seconds.
            ;
            ;   (d) On the FIRST failure (false→true transition),
            ;       publish PersistenceHealthChanged{degraded:true}
            ;       so a tray-menu / widget subscriber can mark a
            ;       persistent indicator. Repeated failures do NOT
            ;       republish — subscribers track *state*, not
            ;       *attempts*.
            ;
            ; PersistTimer (every-5s tick) stays silent on
            ; purpose: the next tick retries, and warning per
            ; tick would flood the log if the disk is
            ; persistently unavailable.
            try this._log.Warn("Lifecycle persist failed: " . ex.Message
                . " | status=" . this._state.status,
                "RunService")
            wasHealthy := !this._persistenceDegraded
            this._persistenceDegraded := true
            nowMs := this._clock.NowMs()
            if (nowMs - this._lastDegradedTrayTipMs >= RunService.DEGRADED_TRAYTIP_COOLDOWN_MS)
            {
                this._lastDegradedTrayTipMs   := nowMs
                this._persistenceTrayTipCount += 1
                try TrayTip("SpeedKalandra",
                    "Run state save failed — crash recovery may be stale. See log.",
                    "Iconi")
            }
            if wasHealthy
            {
                try this._bus.Publish(Events.PersistenceHealthChanged, Map(
                    "degraded", true))
            }
            return
        }

        ; Success path. If we were degraded, log the recovery so a
        ; tail of speedkalandra.log shows the transition explicitly,
        ; clear the flag, and publish PersistenceHealthChanged so
        ; the tray indicator (or any other subscriber) can clear
        ; its visual marker.
        if this._persistenceDegraded
        {
            this._persistenceDegraded := false
            try this._log.Info(
                "Lifecycle persist recovered after previous failure",
                "RunService")
            try this._bus.Publish(Events.PersistenceHealthChanged, Map(
                "degraded", false))
        }
    }

    ; Invokes a pre-publish hook with try/catch + Warn. Centralized so
    ; FinalizeRun and CancelRun share identical semantics, including
    ; the same context tag in the log. `hookName` shows up in the warn
    ; message so a future bug report can tell which hook misbehaved.
    _InvokeBeforeHook(hook, hookName)
    {
        if (hook = "")
            return
        try
        {
            hook()
        }
        catch as ex
        {
            try this._log.Warn(hookName . " threw: " . ex.Message
                . " | What: " . (ex.HasOwnProp("What") ? ex.What : "?")
                . " | Line: " . (ex.HasOwnProp("Line") ? ex.Line : "?"),
                "RunService")
        }
    }

    _GenerateRunId()
    {
        ; yyyyMMdd_HHmmss + 3 ms digits. Two runs starting in the
        ; same second (quick ResetRun + NewRun, or auto-start on the
        ; same tick the user presses N) would otherwise share a runId
        ; — RunHistoryRepository.Save would silently overwrite the
        ; first INI and PersonalBestRepository would point at the
        ; wrong run. 19-char format.
        ms := Mod(A_TickCount, 1000)
        return FormatTime(A_Now, "yyyyMMdd_HHmmss") . "_" . Format("{:03d}", ms)
    }
}
