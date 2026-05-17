; ============================================================
; AutoStartService - automatically starts a run via log regex
; ============================================================
;
; Subscribes to Evt.LogLineRead and tests each line against
; cfg.autoStartRegex. Match -> publishes Cmd.NewRunRequested (which
; RunService consumes).
;
; CANONICAL USE CASE:
;   PoE2 speedrun — the Wounded Man's line ("By the First Ones! You're
;   alive!") appears in the first contact right at the start of the
;   campaign, before Clearfell Encampment. Using that line as the
;   start trigger standardizes the run zero-point for all players
;   and removes the need for a manual hotkey.
;
; PHILOSOPHY:
;   - Simple service, no complex state.
;   - Does not fire if there is already an active run (tracked via
;     the _runActive flag, updated by Evt.RunStarted / RunReset /
;     RunCancelled / RunCompleted).
;   - Empty regex -> service is a no-op (but stays subscribed).
;   - Invalid regex -> silences (next user edit fixes it without crash).
;
; EVENTS:
;   Subscribe:  Evt.LogLineRead, Evt.RunStarted, Evt.RunReset,
;               Evt.RunCancelled, Evt.RunCompleted
;   Publishes:  Cmd.NewRunRequested  { source: "auto" }
;
; CONSTRUCTION:
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
            throw TypeError("AutoStartService: 'bus' must be EventBus")
        if !(cfg is AppSettings)
            throw TypeError("AutoStartService: 'cfg' must be AppSettings")
        this._bus := bus
        this._cfg := cfg

        ; v17.15 (Bug #4): query runService on boot.
        ;
        ; Without this, on reload with a run in progress, RunService.Hydrate
        ; would publish RunStarted{hydrated:true} BEFORE this service
        ; existed. AutoStartService would end up with _runActive=false
        ; despite the active run, and any log line matching autoStartRegex
        ; (e.g. zone re-entry, cinematic replay) would fire
        ; NewRunRequested -> RunService.ResetRun -> wiping the run.
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
        ; Does not fire if there's already a run in progress — the
        ; user may be doing a second session run and the LogMonitor
        ; could be reading a log chunk that contains the old line.
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

        ; Tolerant of invalid regex — user may be editing in settings;
        ; we don't want to crash the tracker over that.
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

        ; Optimistically mark — the RunStarted handler will confirm.
        ; If NewRun silently fails (unlikely), the next LogLineRead
        ; with the same phrase won't re-fire during this "pseudo run".
        ; Reset/Cancel free the flag.
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
