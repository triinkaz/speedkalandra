; AutoStartService — publishes Cmd.NewRunRequested when a log line
; matches cfg.autoStartRegex. The canonical trigger for PoE2 speedruns
; is the Wounded Man's first line ("By the First Ones! You're alive!"),
; which appears at the start of the campaign and standardizes the
; run zero-point across players without a manual hotkey.
;
; Does not fire while a run is already active. Empty regex makes the
; service a no-op (still subscribed). Invalid regex is silently
; tolerated so the user can edit it without crashing the tracker.


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
            throw TypeError("AutoStartService: 'bus' must be EventBus")
        if !(cfg is AppSettings)
            throw TypeError("AutoStartService: 'cfg' must be AppSettings")
        this._bus := bus
        this._cfg := cfg

        ; The composition root passes runService so this service can
        ; read the hydrated active-run state at construction time.
        ; Without it, after a reload mid-run, RunService.Hydrate would
        ; have already published RunStarted{hydrated:true} before this
        ; service existed, leaving _runActive=false despite the active
        ; run — the next log line matching autoStartRegex would then
        ; reset the run.
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
        ; Don't fire if a run is in progress — the LogMonitor could
        ; be reading a chunk that contains the same trigger line.
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

        ; Tolerant of invalid regex (user editing settings); never
        ; crash the tracker over a malformed pattern.
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

        ; Optimistically mark active. RunStarted will confirm; Reset/
        ; Cancel free the flag if NewRun somehow silently fails.
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
