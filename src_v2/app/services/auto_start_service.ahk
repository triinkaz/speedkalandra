; ============================================================
; AutoStartService - inicia run automaticamente via regex de log
; ============================================================
;
; Subscribe Evt.LogLineRead e testa cada linha contra cfg.autoStartRegex.
; Match -> publica Cmd.NewRunRequested (que RunService consome).
;
; CASO DE USO CANONICO:
;   Speedrun POE2 — a fala do Wounded Man ("By the First Ones! You're
;   alive!") aparece no primeiro contato logo no comeco da campanha, antes
;   do Clearfell Encampment. Usar essa fala como gatilho de inicio padroniza
;   o ponto-zero da run para todos os jogadores e dispensa hotkey manual.
;
; FILOSOFIA:
;   - Service simples, sem estado complexo.
;   - Nao dispara se ja existe run ativa (tracking via _runActive flag,
;     atualizada por Evt.RunStarted / RunReset / RunCancelled / RunCompleted).
;   - Regex vazia -> service eh no-op (mas continua subscribed).
;   - Regex invalida -> silencia (proxima edicao do user corrige sem crash).
;
; EVENTOS:
;   Subscribe:  Evt.LogLineRead, Evt.RunStarted, Evt.RunReset,
;               Evt.RunCancelled, Evt.RunCompleted
;   Publica:    Cmd.NewRunRequested  { source: "auto" }
;
; CONSTRUCAO:
;   svc := AutoStartService(bus, cfg)


class AutoStartService
{
    _bus := ""
    _cfg := ""

    _runActive := false

    _handlerLogLine     := ""
    _handlerRunStarted  := ""
    _handlerRunReset    := ""
    _handlerRunCancel   := ""
    _handlerRunComplete := ""

    __New(bus, cfg, runService := "")
    {
        if !(bus is EventBus)
            throw TypeError("AutoStartService: 'bus' deve ser EventBus")
        if !(cfg is AppSettings)
            throw TypeError("AutoStartService: 'cfg' deve ser AppSettings")
        this._bus := bus
        this._cfg := cfg

        ; v17.15 (Bug #4): query runService no boot.
        ;
        ; Sem isso, ao reload com run em andamento, RunService.Hydrate
        ; publicava RunStarted{hydrated:true} ANTES deste service
        ; existir. AutoStartService ficava com _runActive=false apesar
        ; da run ativa, e qualquer linha do log que casasse autoStartRegex
        ; (ex: re-entrada de zona, replay de cinematica) disparava
        ; NewRunRequested -> RunService.ResetRun -> wipe da run.
        if (IsObject(runService) && runService.HasMethod("IsActive"))
            this._runActive := runService.IsActive()

        this._handlerLogLine     := (data) => this._OnLogLine(data)
        this._handlerRunStarted  := (data) => this._OnRunStarted(data)
        this._handlerRunReset    := (data) => this._OnRunEnded(data)
        this._handlerRunCancel   := (data) => this._OnRunEnded(data)
        this._handlerRunComplete := (data) => this._OnRunEnded(data)

        bus.Subscribe(Events.LogLineRead,  this._handlerLogLine)
        bus.Subscribe(Events.RunStarted,   this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,     this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled, this._handlerRunCancel)
        bus.Subscribe(Events.RunCompleted, this._handlerRunComplete)
    }

    Dispose()
    {
        if (this._handlerLogLine != "")
        {
            this._bus.Unsubscribe(Events.LogLineRead, this._handlerLogLine)
            this._handlerLogLine := ""
        }
        if (this._handlerRunStarted != "")
        {
            this._bus.Unsubscribe(Events.RunStarted, this._handlerRunStarted)
            this._handlerRunStarted := ""
        }
        if (this._handlerRunReset != "")
        {
            this._bus.Unsubscribe(Events.RunReset, this._handlerRunReset)
            this._handlerRunReset := ""
        }
        if (this._handlerRunCancel != "")
        {
            this._bus.Unsubscribe(Events.RunCancelled, this._handlerRunCancel)
            this._handlerRunCancel := ""
        }
        if (this._handlerRunComplete != "")
        {
            this._bus.Unsubscribe(Events.RunCompleted, this._handlerRunComplete)
            this._handlerRunComplete := ""
        }
    }

    IsRunActive() => this._runActive

    _OnLogLine(data)
    {
        ; Nao dispara se ja ha run em andamento — usuario pode estar
        ; rodando segunda run da sessao e o LogMonitor pode estar
        ; lendo um trecho de log que contem a fala antiga.
        if this._runActive
            return
        if !IsObject(data) || !data.Has("line")
            return
        line := data["line"]
        if (line = "")
            return
        regex := this._cfg.autoStartRegex
        if (regex = "")
            return

        ; Tolerante a regex invalida — usuario pode estar editando
        ; em settings; nao queremos crashar o tracker por causa disso.
        matched := false
        try
        {
            if RegExMatch(line, regex)
                matched := true
        }
        catch
            matched := false

        if !matched
            return

        ; Marca otimisticamente — o handler de RunStarted vai confirmar.
        ; Se o NewRun falhar silenciosamente (improvavel), o proximo
        ; LogLineRead com a mesma frase nao re-dispara durante esta
        ; "pseudo run". Reset/Cancel liberam o flag.
        this._runActive := true
        this._bus.Publish(Commands.NewRunRequested, Map("source", "auto"))
    }

    _OnRunStarted(data)
    {
        this._runActive := true
    }

    _OnRunEnded(data)
    {
        this._runActive := false
    }
}
