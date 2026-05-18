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

    _handlerNew      := ""
    _handlerFinalize := ""
    _handlerCancel   := ""
    _handlerReset    := ""

    __New(clock, bus, timerSvc, stateRepo)
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

        this._handlerNew      := (data) => this.NewRun()
        this._handlerFinalize := (data) => this.FinalizeRun()
        this._handlerCancel   := (data) => this.CancelRun()
        this._handlerReset    := (data) => this.ResetRun()

        bus.Subscribe(Commands.NewRunRequested,      this._handlerNew)
        bus.Subscribe(Commands.FinalizeRunRequested, this._handlerFinalize)
        bus.Subscribe(Commands.CancelRunRequested,   this._handlerCancel)
        bus.Subscribe(Commands.ResetRunRequested,    this._handlerReset)
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
        try this._stateRepo.Save(this._state)
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
