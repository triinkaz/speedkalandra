; ============================================================
; RunService - ciclo de vida de runs (Onda 6, minimal)
; ============================================================
;
; VERSAO POS-DEMOLICAO: gerencia state minimal (runId, startedAt,
; status). Sem splits, sem deaths, sem step, sem campaign.
;
; Coordena com TimerService (mecanica) e RunStateRepository (persistencia).
;
; OPERACOES:
;   NewRun()      : gera runId, zera timer, publica RunStarted
;   FinalizeRun() : Stop timer, marca status=completed, publica RunCompleted
;   CancelRun()   : Stop timer, marca status=cancelled, publica RunCancelled
;   ResetRun()    : Reset timer, zera state, publica RunReset
;   Hydrate(s)    : restaura state do disco (inclui auto-resume do timer)
;
; HYDRATE / CRASH RECOVERY:
;   Hydrate restaura state do RunState (memoria) E retoma o TimerService
;   no estado correspondente:
;     status=running -> timer fica running (GetRunMs continua crescendo)
;     status=paused  -> timer fica paused (GetRunMs constante ate Toggle)
;     outros         -> timer parado
;
; PERSISTENCIA — DOIS CAMINHOS:
;   - _Persist() (4 IniWrites): chamado em transicoes de lifecycle
;     (NewRun/FinalizeRun/CancelRun). Salva todos os campos.
;   - PersistTimer() (1 IniWrite): chamado pelo tick periodico (5s) do
;     composition root. Salva SO o runBaseMs (campo que muda toda hora).
;     Os outros 3 campos so mudam em transicoes — la o _Persist completo
;     ja eh chamado. Otimizacao critica pra evitar lag no thread principal
;     (com Save completo eram 4 IniWrites a cada 5s = lag perceptivel).
;
; EVENTOS PUBLICADOS:
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
; CONSTRUCAO:
;   service := RunService(clock, bus, timerSvc, stateRepo)
;
; NOTA SOBRE NOMES DOS PARAMETROS:
;   AHK v2 faz lookup case-insensitive de variaveis. Se nomeassemos
;   o param `timerService`, ele colidiria com a classe `TimerService`
;   no operando direito de `is`, e a checagem viraria `x is x`.
;   Por isso `timerSvc` — case-insensitive-distinto de TimerService.


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
            throw TypeError("RunService: 'clock' deve implementar NowMs()")
        if !(bus is EventBus)
            throw TypeError("RunService: 'bus' deve ser EventBus")
        if !(timerSvc is TimerService)
            throw TypeError("RunService: 'timerSvc' deve ser TimerService")
        if !(stateRepo is RunStateRepository)
            throw TypeError("RunService: 'stateRepo' deve ser RunStateRepository")

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
            throw TypeError("RunService.Hydrate: 'stateObj' deve ser RunState")
        this._state := stateObj
        this._timer.Hydrate(stateObj.runBaseMs, stateObj.status)

        ; v17.14: se a run hidratada esta ativa (running/paused), publica
        ; Evt.RunStarted pra sincronizar services dependentes. Sem isso:
        ;   - RunStatsRecorder fica com _runId="" — e quando o user
        ;     finaliza, RunHistoryRepository.Save retorna false sem log
        ;     (runId vazio).
        ;   - AutoStartService fica com _runActive=false — pode causar
        ;     auto-start duplicado se a fala do Wounded Man aparecer.
        ;   - ActCheckpointTracker fica com _currentAct=0 (recupera no
        ;     proximo ZoneEntered, mas perde checkpoints da sessao
        ;     anterior — esses ja eram em memoria pura, sem persistencia).
        ;
        ; Flag 'hydrated' permite handlers diferenciar de NewRun real
        ; (ex: nao resetar XP area).
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

    ; v17.14 — quando ha run ativa, NewRun agora chama ResetRun em vez
    ; de CancelRun. CancelRun antes salvava no historico se runMs >= 3min,
    ; o que causava saves indesejados quando o user soh queria reiniciar.
    ; ResetRun descarta sem salvar. Workflow:
    ;   - Quer salvar antes de reiniciar: FinalizeRun (Ctrl+Alt+F) +
    ;     depois NewRun (Ctrl+Alt+N)
    ;   - Quer descartar e reiniciar: NewRun direto (Ctrl+Alt+N)
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
        runId := this._state.runId
        durationMs := this._timer.GetRunMs()

        this._timer.Stop()
        this._state.status    := "completed"
        this._state.runBaseMs := durationMs
        this._Persist()

        this._bus.Publish(Events.RunCompleted, Map(
            "runId",      runId,
            "durationMs", durationMs
        ))
        return true
    }

    CancelRun()
    {
        if !this._state.IsActive()
            return false
        runId := this._state.runId

        this._timer.Stop()
        this._state.status := "cancelled"
        this._Persist()

        this._bus.Publish(Events.RunCancelled, Map("runId", runId))
        return true
    }

    ResetRun()
    {
        runId := this._state.runId
        this._timer.Reset()
        this._state := RunState.Empty()
        this._stateRepo.Clear()

        this._bus.Publish(Events.RunReset, Map("runId", runId))
        return true
    }

    PersistTick() => this.PersistTimer()

    ; ============================================================
    ; PersistTimer - persiste APENAS o runBaseMs (1 IniWrite)
    ;
    ; Chamado pelo timer periodico do composition root (a cada 5s).
    ; Usa SaveRunBaseMs em vez de Save completo pra evitar 3 IniWrites
    ; desnecessarios — os outros campos (runId, startedAt, status) so
    ; mudam em transicoes (NewRun/Finalize/Cancel) onde _Persist
    ; completo eh chamado.
    ;
    ; Otimizacao critica: antes era 4 IniWrites a cada 5s causando lag
    ; perceptivel no thread principal (pause detection demorava 6s).
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
        ; v17.15 (Bug #3): yyyyMMdd_HHmmss + 3 digitos de ms pra evitar
        ; collision quando duas runs comecam no mesmo segundo (ResetRun
        ; rapido + NewRun, ou auto-start no mesmo tick que o user pressa N).
        ; Sem isso, RunHistoryRepository.Save sobrescrevia o INI da primeira
        ; run silenciosamente e PersonalBestRepository registrava BestRunId
        ; errado.
        ;
        ; Formato: "20260515_103045_873" (sempre 19 chars).
        ; ListRunIds nao filtra por regex — usa SplitPath, entao formato
        ; novo funciona transparentemente.
        ms := Mod(A_TickCount, 1000)
        return FormatTime(A_Now, "yyyyMMdd_HHmmss") . "_" . Format("{:03d}", ms)
    }
}
