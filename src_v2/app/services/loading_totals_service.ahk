; ============================================================
; LoadingTotalsService — acumula tempo total de loading da run (Fase B4.4)
; ============================================================
;
; Service simples e reativo: subscribe Evt.LoadingMeasured pra acumular
; durationMs em _totalMs. Zera em transicoes de run (RunStarted/RunReset/
; RunCancelled/RunCompleted).
;
; Razao de existir: a UI precisa saber quanto tempo de loading o jogador
; passou na run atual pra calcular gameplay% / loading%. O LoadingDetection
; ja mede e publica cada loading individual; este service so agrega.
;
; FILOSOFIA:
;   - State minimal (1 numero).
;   - Reativo via bus, sem lifecycle (sem Start/Stop).
;   - Idempotente: subscribers podem reagir multiplas vezes sem efeito.
;
; PERSISTENCIA:
;   _totalMs eh persistido pelo composition root no campo
;   [RunState].LoadingTotalMs do INI, lado a lado com runBaseMs.
;   Hydrate() restaura no boot. Sem isso, apos um reload o tempo de
;   loading da run atual seria perdido.
;
; Construcao:
;   svc := LoadingTotalsService(bus)
;   svc.GetTotalMs()    ; 0 inicialmente
;
; Uso tipico (composition root):
;   bus.Publish(Events.LoadingMeasured, Map("durationMs", 4500, ...))
;   svc.GetTotalMs()    ; 4500
;   bus.Publish(Events.RunStarted, Map("runId", "..."))
;   svc.GetTotalMs()    ; 0 (zerado)


class LoadingTotalsService
{
    _bus     := ""
    _totalMs := 0

    ; Handler refs (Section 17.32 — fields pra Unsubscribe em Dispose)
    _handlerLoadingMeasured := ""
    _handlerRunStarted      := ""
    _handlerRunReset        := ""
    _handlerRunCancelled    := ""
    _handlerRunCompleted    := ""

    __New(bus)
    {
        if !(bus is EventBus)
            throw TypeError("LoadingTotalsService: 'bus' deve ser EventBus")
        this._bus     := bus
        this._totalMs := 0

        this._handlerLoadingMeasured := (data) => this._OnLoadingMeasured(data)
        this._handlerRunStarted      := (data) => this.Reset()
        this._handlerRunReset        := (data) => this.Reset()
        this._handlerRunCancelled    := (data) => this.Reset()
        this._handlerRunCompleted    := (data) => this.Reset()

        this._bus.Subscribe(Events.LoadingMeasured, this._handlerLoadingMeasured)
        this._bus.Subscribe(Events.RunStarted,      this._handlerRunStarted)
        this._bus.Subscribe(Events.RunReset,        this._handlerRunReset)
        this._bus.Subscribe(Events.RunCancelled,    this._handlerRunCancelled)
        this._bus.Subscribe(Events.RunCompleted,    this._handlerRunCompleted)
    }

    ; ============================================================
    ; Dispose — desfaz subscriptions. Idempotente.
    ; ============================================================
    Dispose()
    {
        if (this._handlerLoadingMeasured != "")
        {
            this._bus.Unsubscribe(Events.LoadingMeasured, this._handlerLoadingMeasured)
            this._handlerLoadingMeasured := ""
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
        if (this._handlerRunCompleted != "")
        {
            this._bus.Unsubscribe(Events.RunCompleted, this._handlerRunCompleted)
            this._handlerRunCompleted := ""
        }
    }

    ; ============================================================
    ; Public API
    ; ============================================================

    GetTotalMs() => this._totalMs

    Reset()
    {
        this._totalMs := 0
    }

    ; ============================================================
    ; Hydrate - restaura tempo acumulado do disco (crash recovery)
    ;
    ; Chamado pelo composition root no boot apos LoadLoadingTotal()
    ; do RunStateRepository. Defensivo contra valores invalidos.
    ; ============================================================
    Hydrate(totalMs)
    {
        if !IsNumber(totalMs)
            totalMs := 0
        n := Integer(totalMs)
        this._totalMs := (n > 0) ? n : 0
    }

    ; ============================================================
    ; Event handlers
    ; ============================================================

    ; Acumula durationMs no total. Defensivo contra dados malformados.
    _OnLoadingMeasured(data)
    {
        if !IsObject(data)
            return
        if !data.Has("durationMs")
            return
        durMs := data["durationMs"]
        if !IsNumber(durMs)
            return
        n := Integer(durMs)
        if (n <= 0)
            return
        this._totalMs += n
    }
}
