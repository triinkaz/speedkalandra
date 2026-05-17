; ============================================================
; ActCheckpointTracker (v17.13)
; ============================================================
;
; Tracks the TOTAL RUN time at the moment each act ends.
; Ends = first ZoneEntered of an act N+1 (leaving act N).
;
; Used by PersonalBestService to create PBs by MAX ACT REACHED,
; instead of a global full-run PB that was useless when the user
; mixed short runs (Act 1 only) with long runs (full campaign).
;
; FLOW DURING THE RUN:
;
;   t=0:00      RunStarted -> _currentAct=0, _checkpoints={}
;   t=0:00      ZoneEntered(Clearfell, act=1)
;                 -> _currentAct was 0, now becomes 1 (no checkpoint)
;   t=28:45     ZoneEntered(Vastiri Outskirts, act=2)
;                 -> _currentAct was 1, now becomes 2
;                 -> CHECKPOINT: _checkpoints[1] = 28:45
;   t=1:05:00   ZoneEntered(Sandswept Marsh, act=3)
;                 -> CHECKPOINT: _checkpoints[2] = 1:05:00
;   t=1:55:00   RunCompleted (Ctrl+Alt+F)
;                 -> Composition root calls CaptureCurrentAsCheckpoint(1:55:00)
;                 -> _checkpoints[3] = 1:55:00
;
; SUBSCRIPTIONS:
;   Evt.ZoneEntered      -> detects act transition
;   Evt.RunStarted       -> clears state
;   Evt.RunReset         -> clears state
;   Evt.RunCancelled     -> clears state
;
; DEPENDENCIES:
;   timer : TimerService -> GetRunMs() to capture the transition moment
;
; QUERIES:
;   GetCheckpoints() -> Map<actNum, runMs> of confirmed acts
;   GetCurrentAct()  -> current act (in progress, no checkpoint saved)
;
; CONSTRUCTION:
;   tracker := ActCheckpointTracker(bus, timer)


class ActCheckpointTracker
{
    _bus   := ""
    _timer := ""

    _currentAct  := 0
    _checkpoints := ""     ; Map<actNum, runMs>

    _handlerZoneEntered  := ""
    _handlerRunStarted   := ""
    _handlerRunReset     := ""
    _handlerRunCancelled := ""

    __New(bus, timer)
    {
        if !(bus is EventBus)
            throw TypeError("ActCheckpointTracker: 'bus' must be EventBus")
        if !IsObject(timer) || !timer.HasMethod("GetRunMs")
            throw TypeError("ActCheckpointTracker: 'timer' must have GetRunMs()")

        this._bus   := bus
        this._timer := timer
        this._checkpoints := Map()

        this._handlerZoneEntered  := (data) => this._OnZoneEntered(data)
        this._handlerRunStarted   := (data) => this.Reset()
        this._handlerRunReset     := (data) => this.Reset()
        this._handlerRunCancelled := (data) => this.Reset()

        bus.Subscribe(Events.ZoneEntered,    this._handlerZoneEntered)
        bus.Subscribe(Events.RunStarted,     this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,       this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled,   this._handlerRunCancelled)
    }

    Dispose()
    {
        if (this._handlerZoneEntered != "")
        {
            this._bus.Unsubscribe(Events.ZoneEntered, this._handlerZoneEntered)
            this._handlerZoneEntered := ""
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
        if (this._handlerRunCancelled != "")
        {
            this._bus.Unsubscribe(Events.RunCancelled, this._handlerRunCancelled)
            this._handlerRunCancelled := ""
        }
    }

    ; ============================================================
    ; Queries
    ; ============================================================

    GetCurrentAct() => this._currentAct

    GetCheckpoints()
    {
        out := Map()
        for k, v in this._checkpoints
            out[k] := v
        return out
    }

    Reset()
    {
        this._currentAct  := 0
        this._checkpoints := Map()
    }

    ; ============================================================
    ; CaptureCurrentAsCheckpoint - records the current act's checkpoint
    ;
    ; Called by the composition root in _SaveRunSnapshot when reason=
    ; "completed". The current act (in which the run was finalized)
    ; has not had a transition leaving it yet, so it must be explicitly
    ; registered with the final runMs.
    ; ============================================================
    CaptureCurrentAsCheckpoint(runMs)
    {
        if (this._currentAct <= 0)
            return
        if !IsNumber(runMs) || runMs <= 0
            return
        this._checkpoints[this._currentAct] := Integer(runMs)
    }

    ; ============================================================
    ; Handler
    ; ============================================================
    _OnZoneEntered(data)
    {
        if !IsObject(data)
            return
        newAct := data.Has("actIndex") ? data["actIndex"] : 0
        if !IsNumber(newAct) || newAct <= 0
            return

        ; Transition between acts: records the previous act's checkpoint.
        ; The first act of the run does not record (there was no previous act).
        if (this._currentAct > 0 && newAct != this._currentAct)
        {
            runMs := 0
            try runMs := this._timer.GetRunMs()
            if (runMs > 0)
                this._checkpoints[this._currentAct] := Integer(runMs)
        }
        this._currentAct := newAct
    }
}
