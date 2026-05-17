; ============================================================
; AutoFinalizeService - automatic finalization via log regex (Wave 6)
; ============================================================
;
; Subscribes to Evt.LogLineRead and tests each line against
; cfg.autoFinalizeRegex. Match -> publishes Cmd.FinalizeRunRequested
; (which RunService consumes).
;
; PHILOSOPHY:
;   - Simple service, no state beyond "already fired in this run?"
;   - Dedup by runId: fires at most once per run, avoids repeated
;     matches in duplicated logs.
;   - Empty regex -> service is a no-op (but stays subscribed).
;   - Resetting the regex at runtime (settings change): next match
;     will work immediately.
;
; EVENTS:
;   Subscribe:  Evt.LogLineRead
;   Subscribe:  Evt.RunStarted (resets the _hasFiredForCurrentRun flag)
;   Subscribe:  Evt.RunReset / Cancelled / Completed (resets flag)
;   Publishes:  Cmd.FinalizeRunRequested
;
; CONSTRUCTION:
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
            throw TypeError("AutoFinalizeService: 'bus' must be EventBus")
        if !(cfg is AppSettings)
            throw TypeError("AutoFinalizeService: 'cfg' must be AppSettings")
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

        ; Test regex; tolerant of invalid regex
        matched := false
        try
        {
            if RegExMatch(line, regex)
                matched := true
        }
        catch
        {
            ; invalid regex -- silence (user's next edit will fix it)
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
