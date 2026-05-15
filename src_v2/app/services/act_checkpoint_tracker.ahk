; ============================================================
; ActCheckpointTracker (v17.13)
; ============================================================
;
; Rastreia o tempo TOTAL DA RUN no momento que cada ato terminou.
; Termina = primeira ZoneEntered de um ato N+1 (saindo do ato N).
;
; Usado pelo PersonalBestService pra criar PBs por ato MAX ALCANCADO,
; em vez de um PB global da run inteira que era inutil quando o user
; misturava runs curtas (Ato 1 only) com runs longas (campanha cheia).
;
; FLUXO DURANTE A RUN:
;
;   t=0:00      RunStarted -> _currentAct=0, _checkpoints={}
;   t=0:00      ZoneEntered(Clearfell, act=1)
;                 -> _currentAct era 0, agora vira 1 (sem checkpoint)
;   t=28:45     ZoneEntered(Vastiri Outskirts, act=2)
;                 -> _currentAct era 1, agora vira 2
;                 -> CHECKPOINT: _checkpoints[1] = 28:45
;   t=1:05:00   ZoneEntered(Sandswept Marsh, act=3)
;                 -> CHECKPOINT: _checkpoints[2] = 1:05:00
;   t=1:55:00   RunCompleted (Ctrl+Alt+F)
;                 -> Composition root chama CaptureCurrentAsCheckpoint(1:55:00)
;                 -> _checkpoints[3] = 1:55:00
;
; SUBSCRIPTIONS:
;   Evt.ZoneEntered      -> detecta transicao de ato
;   Evt.RunStarted       -> zera state
;   Evt.RunReset         -> zera state
;   Evt.RunCancelled     -> zera state
;
; DEPENDENCIAS:
;   timer : TimerService -> GetRunMs() pra capturar momento da transicao
;
; QUERIES:
;   GetCheckpoints() -> Map<actNum, runMs> dos atos confirmados
;   GetCurrentAct()  -> ato atual (em curso, sem checkpoint salvo)
;
; CONSTRUCAO:
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
            throw TypeError("ActCheckpointTracker: 'bus' deve ser EventBus")
        if !IsObject(timer) || !timer.HasMethod("GetRunMs")
            throw TypeError("ActCheckpointTracker: 'timer' deve ter GetRunMs()")

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
    ; CaptureCurrentAsCheckpoint - registra checkpoint do ato em curso
    ;
    ; Chamado pelo composition root no _SaveRunSnapshot quando reason=
    ; "completed". O ato atual (em que a run foi finalizada) ainda nao
    ; teve uma transicao saindo dele, entao precisa ser registrado
    ; explicitamente com o runMs final.
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

        ; Transicao entre atos: registra checkpoint do anterior.
        ; Primeiro ato da run nao registra (nao houve ato anterior).
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
