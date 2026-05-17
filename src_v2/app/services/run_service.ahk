; ============================================================
; RunService - run lifecycle (Wave 6, minimal)
; ============================================================
;
; POST-DEMOLITION VERSION: manages minimal state (runId, startedAt,
; status). No splits, no deaths, no step, no campaign.
;
; Coordinates with TimerService (mechanics) and RunStateRepository
; (persistence).
;
; OPERATIONS:
;   NewRun()      : generates runId, clears timer, publishes RunStarted
;   FinalizeRun() : Stop timer, marks status=completed, publishes RunCompleted
;   CancelRun()   : Stop timer, marks status=cancelled, publishes RunCancelled
;   ResetRun()    : Reset timer, clears state, publishes RunReset
;   Hydrate(s)    : restores state from disk (includes timer auto-resume)
;
; HYDRATE / CRASH RECOVERY:
;   Hydrate restores the RunState (memory) AND resumes TimerService
;   in the corresponding state:
;     status=running -> timer stays running (GetRunMs keeps growing)
;     status=paused  -> timer stays paused (GetRunMs constant until Toggle)
;     others         -> timer stopped
;
; PERSISTENCE — TWO PATHS:
;   - _Persist() (4 IniWrites): called on lifecycle transitions
;     (NewRun/FinalizeRun/CancelRun). Saves all fields.
;   - PersistTimer() (1 IniWrite): called by the composition root's
;     periodic tick (5s). Saves ONLY runBaseMs (the field that changes
;     every time). The other 3 fields only change on transitions —
;     there the full _Persist is already called. Critical optimization
;     to avoid lag on the main thread (with full Save it was 4 IniWrites
;     every 5s = perceptible lag).
;
; PUBLISHED EVENTS:
;   Evt.RunStarted    {runId, startedAt, profileId}
;   Evt.RunCompleted  {runId, durationMs}
;   Evt.RunCancelled  {runId}
;   Evt.RunReset      {runId}
;
; SUBSCRIPTIONS:
;   Cmd.FinalizeRunRequested -> FinalizeRun()
;   Cmd.NewRunRequested      -> NewRun()
;   Cmd.CancelRunRequested   -> CancelRun()
;   Cmd.ResetRunRequested    -> ResetRun()
;
; CONSTRUCTION:
;   service := RunService(clock, bus, timerSvc, stateRepo)
;
; NOTE ON PARAMETER NAMES:
;   AHK v2 does case-insensitive variable lookup. If we named the
;   param `timerService`, it would collide with the `TimerService`
;   class on the right side of `is`, and the check would become
;   `x is x`. Hence `timerSvc` — case-insensitive-distinct from
;   TimerService.


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

        ; v17.14: if the hydrated run is active (running/paused),
        ; publish Evt.RunStarted to sync dependent services. Without
        ; this:
        ;   - RunStatsRecorder stays with _runId="" — and when the
        ;     user finalizes, RunHistoryRepository.Save returns false
        ;     with no log (empty runId).
        ;   - AutoStartService stays with _runActive=false — may cause
        ;     duplicate auto-start if the Wounded Man line appears.
        ;   - ActCheckpointTracker stays with _currentAct=0 (recovers
        ;     on the next ZoneEntered, but loses checkpoints from the
        ;     previous session — those were already pure-memory, no
        ;     persistence).
        ;
        ; The 'hydrated' flag lets handlers differentiate from a real
        ; NewRun (e.g. don't reset XP area).
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

    ; v17.14 — when there's an active run, NewRun now calls ResetRun
    ; instead of CancelRun. CancelRun used to save to history if
    ; runMs >= 3min, which caused unwanted saves when the user just
    ; wanted to restart. ResetRun discards without saving. Workflow:
    ;   - Want to save before restarting: FinalizeRun (Ctrl+Alt+F) +
    ;     then NewRun (Ctrl+Alt+N)
    ;   - Want to discard and restart: NewRun directly (Ctrl+Alt+N)
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
        ; v0.1.0: local `runId` collides with the `RunId` class (#Warn). Use currentRunId.
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

    ; ============================================================
    ; PersistTimer - persists ONLY runBaseMs (1 IniWrite)
    ;
    ; Called by the composition root's periodic timer (every 5s).
    ; Uses SaveRunBaseMs instead of a full Save to avoid 3 unnecessary
    ; IniWrites — the other fields (runId, startedAt, status) only
    ; change on transitions (NewRun/Finalize/Cancel) where the full
    ; _Persist is called.
    ;
    ; Critical optimization: before it was 4 IniWrites every 5s causing
    ; perceptible lag on the main thread (pause detection took 6s).
    ; ============================================================
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
        ; v17.15 (Bug #3): yyyyMMdd_HHmmss + 3 ms digits to avoid
        ; collision when two runs start in the same second (quick
        ; ResetRun + NewRun, or auto-start on the same tick the user
        ; presses N). Without this, RunHistoryRepository.Save silently
        ; overwrote the first run's INI and PersonalBestRepository
        ; recorded the wrong BestRunId.
        ;
        ; Format: "20260515_103045_873" (always 19 chars).
        ; ListRunIds doesn't filter by regex — uses SplitPath, so the
        ; new format works transparently.
        ms := Mod(A_TickCount, 1000)
        return FormatTime(A_Now, "yyyyMMdd_HHmmss") . "_" . Format("{:03d}", ms)
    }
}
