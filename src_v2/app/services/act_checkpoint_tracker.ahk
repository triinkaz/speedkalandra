; ActCheckpointTracker — captures the total run time at each
; act-transition moment. Used by PersonalBestService to maintain a
; per-act PB (so an Act-1-only run and a full-campaign run can be
; compared fairly on Act 1).
;
; A "transition" is the first ZoneEntered whose (actIndex, stage)
; differs from (_currentAct, _currentStage). The (act, stage) being
; LEFT gets a checkpoint with the current runMs; the final
; (act, stage) of the run is registered via CaptureCurrentAsCheckpoint
; (called from RunSnapshotSaver.Save when reason="completed") because
; no further transition happens.
;
; Stage axis (B1 Layer B):
;   PoE2 EA speedrun is "campaign (Acts 1-4) + interlude (Acts 1-4
;   cruel)". Same actIndex (1) is reached twice in a complete run:
;   once for normal Act 1, once for the cruel Act 1 of the interlude.
;   Pre-B1, _checkpoints was keyed by integer actIndex, so cruel
;   Act 1's checkpoint silently overwrote the normal Act 1 checkpoint
;   and PBs collapsed both into a single per-act bucket.
;
;   Post-B1, this tracker maintains TWO parallel views:
;     - _checkpointsByAct       Map<actInt, runMs>    legacy view,
;                                                     last-write-wins
;                                                     (preserves
;                                                     pre-B1 behaviour
;                                                     for callers not
;                                                     yet migrated).
;     - _checkpointsByActStage  Map<"act|stage", ms>  per-(act, stage)
;                                                     view consumed
;                                                     by per-stage PBs
;                                                     and the Interlude
;                                                     filter in the
;                                                     plot dialog.
;
;   GetCheckpoints() returns the legacy view. GetCheckpointsByStage()
;   returns the new view. PersonalBestService will be migrated to the
;   new API in a subsequent commit; until then the legacy view keeps
;   today's (buggy but stable) PB behaviour for cruel.
;
; Subscribes:
;   ZoneEntered → transition detection
;   RunStarted / RunReset / RunCancelled → Reset()


class ActCheckpointTracker
{
    _bus   := ""
    _timer := ""

    _currentAct   := 0
    _currentStage := ""
    _checkpointsByAct      := ""   ; Map<actInt, runMs>            — legacy view
    _checkpointsByActStage := ""   ; Map<"act|stage", runMs>       — B1 Layer B

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
        this._checkpointsByAct      := Map()
        this._checkpointsByActStage := Map()

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

    GetCurrentAct()   => this._currentAct
    GetCurrentStage() => this._currentStage

    ; Legacy view, integer-keyed: Map<actInt, runMs>. Last-write-wins
    ; across stages — if both normal Act 1 and cruel Act 1 are
    ; captured, the most recent one wins. Preserves pre-B1 behaviour
    ; for callers (PersonalBestService today) that haven't migrated
    ; to the stage-aware API.
    GetCheckpoints()
    {
        out := Map()
        for k, v in this._checkpointsByAct
            out[k] := v
        return out
    }

    ; B1 Layer B view, composite-keyed: Map<"act|stage", runMs>.
    ; Examples: "1|normal", "4|interlude". Defensive copy.
    GetCheckpointsByStage()
    {
        out := Map()
        for k, v in this._checkpointsByActStage
            out[k] := v
        return out
    }

    ; Returns the runMs of the most recent CAPTURED (act, stage)
    ; transition, or 0 if no checkpoint has been captured yet in
    ; this run. Used by RunSnapshotSaver (B2 path) to compute the
    ; truncated runDurationMs when a cancel happens mid-act — the
    ; current (active) bucket isn't captured until either a
    ; transition or a final completed-finalize, so its time isn't
    ; considered "complete" by this query. A cancel call site that
    ; reads this BEFORE invoking CaptureCurrentAsCheckpoint sees
    ; the time of the boundary that closed the last fully
    ; completed (act, stage), which is exactly the timestamp the
    ; partial-run save should be truncated at.
    ;
    ; Returns 0 when no transition fired yet — the caller treats
    ; this as "no complete act" and the B2 save path drops the
    ; entire run instead of persisting a zero-length record.
    GetLastCompleteCheckpointMs()
    {
        maxMs := 0
        for _, ms in this._checkpointsByActStage
        {
            if (IsNumber(ms) && ms > maxMs)
                maxMs := Integer(ms)
        }
        return maxMs
    }

    Reset()
    {
        this._currentAct   := 0
        this._currentStage := ""
        this._checkpointsByAct      := Map()
        this._checkpointsByActStage := Map()
    }

    ; Records the current (act, stage)'s checkpoint with the final
    ; runMs. Called by the composition root inside _SaveRunSnapshot
    ; for reason="completed" — the final (act, stage) has no outgoing
    ; transition so it would otherwise be missed.
    CaptureCurrentAsCheckpoint(runMs)
    {
        if (this._currentAct <= 0)
            return
        if !IsNumber(runMs) || runMs <= 0
            return
        ms := Integer(runMs)
        this._checkpointsByAct[this._currentAct] := ms
        compositeKey := ActCheckpointTracker._ComposeKey(this._currentAct, this._currentStage)
        this._checkpointsByActStage[compositeKey] := ms
    }

    ; ---- Handler ----

    _OnZoneEntered(data)
    {
        if !IsObject(data)
            return
        newAct := data.Has("actIndex") ? data["actIndex"] : 0
        if !IsNumber(newAct) || newAct <= 0
            return
        ; stage default "normal" — producer (ZoneTrackingService) sets
        ; it explicitly; this fallback is defensive for legacy or
        ; programmatic emitters that omit the field.
        newStage := (data.Has("stage") && data["stage"] != "") ? data["stage"] : "normal"

        ; A transition records the (act, stage) being left. The
        ; very first ZoneEntered of the run has no predecessor so
        ; nothing is recorded. Transition fires when EITHER act or
        ; stage changes — e.g. Act 4 normal → Act 1 interlude
        ; records the Act 4 normal checkpoint, and Act 1 interlude
        ; → Act 2 interlude records the Act 1 interlude checkpoint.
        isTransition := this._currentAct > 0
            && (newAct != this._currentAct || newStage != this._currentStage)
        if isTransition
        {
            runMs := 0
            try runMs := this._timer.GetRunMs()
            if (runMs > 0)
            {
                ms := Integer(runMs)
                this._checkpointsByAct[this._currentAct] := ms
                compositeKey := ActCheckpointTracker._ComposeKey(this._currentAct, this._currentStage)
                this._checkpointsByActStage[compositeKey] := ms
            }
        }
        this._currentAct   := newAct
        this._currentStage := newStage
    }

    ; ---- Static helpers ----

    ; Composite key format for _checkpointsByActStage. Pipe (`|`)
    ; chosen because it cannot appear in either component: actIndex
    ; is an integer, stage is one of {"normal", "interlude"}.
    static _ComposeKey(act, stage) => Integer(act) . "|" . stage
}
