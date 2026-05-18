; ActCheckpointTracker — captures the total run time at each
; act-transition moment. Used by PersonalBestService to maintain a
; per-act PB (so an Act-1-only run and a full-campaign run can be
; compared fairly on Act 1).
;
; A "transition" is the first ZoneEntered whose actIndex differs
; from _currentAct. The act being LEFT gets a checkpoint with the
; current runMs; the final act of the run is registered via
; CaptureCurrentAsCheckpoint (called from RunSnapshotSaver.Save when
; reason="completed") because no further transition happens.
;
; Subscribes:
;   ZoneEntered → transition detection
;   RunStarted / RunReset / RunCancelled → Reset()


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

    ; ---- Queries ----

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

    ; Records the current act's checkpoint with the final runMs.
    ; Called by the composition root inside _SaveRunSnapshot for
    ; reason="completed" — the final act has no outgoing transition
    ; so it would otherwise be missed.
    CaptureCurrentAsCheckpoint(runMs)
    {
        if (this._currentAct <= 0)
            return
        if !IsNumber(runMs) || runMs <= 0
            return
        this._checkpoints[this._currentAct] := Integer(runMs)
    }

    ; ---- Handler ----

    _OnZoneEntered(data)
    {
        if !IsObject(data)
            return
        newAct := data.Has("actIndex") ? data["actIndex"] : 0
        if !IsNumber(newAct) || newAct <= 0
            return

        ; A transition records the act being left. The very first
        ; act of the run has no predecessor so nothing is recorded.
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
