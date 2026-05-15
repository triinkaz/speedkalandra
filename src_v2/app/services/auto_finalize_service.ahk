; ============================================================
; AutoFinalizeService - finalizacao automatica via regex de log (Onda 6)
; ============================================================
;
; Subscribe Evt.LogLineRead e testa cada linha contra cfg.autoFinalizeRegex.
; Match -> publica Cmd.FinalizeRunRequested (que RunService consome).
;
; FILOSOFIA:
;   - Service simples, sem state alem de "ja disparou nesta run?"
;   - Dedup por runId: dispara no maximo 1 vez por run, evita matches
;     repetidos em logs duplicados.
;   - Regex vazia -> service eh no-op (mas continua subscribed).
;   - Resetar regex em runtime (settings change): proximo match vai
;     funcionar imediatamente.
;
; EVENTOS:
;   Subscribe:  Evt.LogLineRead
;   Subscribe:  Evt.RunStarted (reseta flag _hasFiredForCurrentRun)
;   Subscribe:  Evt.RunReset / Cancelled / Completed (reseta flag)
;   Publica:    Cmd.FinalizeRunRequested
;
; CONSTRUCAO:
;   svc := AutoFinalizeService(bus, cfg)

class AutoFinalizeService
{
    _bus := ""
    _cfg := ""

    _hasFiredForCurrentRun := false
    _currentRunId          := ""

    _handlerLogLine    := ""
    _handlerRunStarted := ""
    _handlerRunReset   := ""
    _handlerRunCancel  := ""
    _handlerRunComplete := ""

    __New(bus, cfg)
    {
        if !(bus is EventBus)
            throw TypeError("AutoFinalizeService: 'bus' deve ser EventBus")
        if !(cfg is AppSettings)
            throw TypeError("AutoFinalizeService: 'cfg' deve ser AppSettings")
        this._bus := bus
        this._cfg := cfg

        this._handlerLogLine     := (data) => this._OnLogLine(data)
        this._handlerRunStarted  := (data) => this._OnRunStarted(data)
        this._handlerRunReset    := (data) => this._OnRunEnded(data)
        this._handlerRunCancel   := (data) => this._OnRunEnded(data)
        this._handlerRunComplete := (data) => this._OnRunEnded(data)

        bus.Subscribe(Events.LogLineRead,   this._handlerLogLine)
        bus.Subscribe(Events.RunStarted,    this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,      this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled,  this._handlerRunCancel)
        bus.Subscribe(Events.RunCompleted,  this._handlerRunComplete)
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

    _OnLogLine(data)
    {
        if !IsObject(data) || !data.Has("line")
            return
        line := data["line"]
        if (line = "")
            return
        regex := this._cfg.autoFinalizeRegex
        if (regex = "")
            return
        if this._hasFiredForCurrentRun
            return

        ; Test regex; tolerante a regex invalida
        matched := false
        try
        {
            if RegExMatch(line, regex)
                matched := true
        }
        catch
        {
            ; regex invalida -- silencia (proxima edicao do user corrige)
            matched := false
        }

        if !matched
            return

        this._hasFiredForCurrentRun := true
        this._bus.Publish(Commands.FinalizeRunRequested, Map("source", "auto"))
    }

    _OnRunStarted(data)
    {
        this._hasFiredForCurrentRun := false
        this._currentRunId := IsObject(data) && data.Has("runId") ? data["runId"] : ""
    }

    _OnRunEnded(data)
    {
        this._hasFiredForCurrentRun := false
        this._currentRunId := ""
    }
}
