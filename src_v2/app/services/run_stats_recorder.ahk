; ============================================================
; RunStatsRecorder - buffer em memoria de eventos da run atual
; ============================================================
;
; Service reativo que escuta os eventos relevantes pra plot final e
; acumula em arrays/contadores. Composition root usa GetSnapshot()
; pra montar o input do RunStatsPlotBuilder.Build(snapshot).
;
; SUBSCRIPTIONS:
;   Evt.LoadingMeasured  -> push loadingEvents
;   Evt.DeathDetected    -> deathCount++
;   Evt.RunStarted       -> Reset() + snapshot _runId/_startedAt
;   Evt.RunReset         -> Reset()
;   Evt.RunCancelled     -> Reset()
;   Evt.RunCompleted     -> snapshot final duration (Reset acontece no proximo RunStarted)
;
; ZONE TOTALS:
;   NAO sao acumulados aqui. ZoneTrackingService.GetTotals() ja faz isso.
;   Composition root combina os dois services no momento de construir
;   o snapshot.
;
; BOSS EVENTS (REMOVIDO em v17.13):
;   Feature de boss tracking foi removida da app (voice lines de classe
;   nao iam pra Client.txt do PoE2). Snapshot ja nao inclui bossEvents.
;
; GetSnapshot(zoneTotalsMap, runDurationMs) -> Map:
;   Map(
;     "runId":         this._runId,
;     "firstTs":       this._firstTs,
;     "runDurationMs": runDurationMs,
;     "zoneTotals":    zoneTotalsMap,
;     "loadingEvents": [...],
;     "deathCount":    int
;   )
;
; CONSTRUCAO:
;   recorder := RunStatsRecorder(bus, clock)


class RunStatsRecorder
{
    _bus   := ""
    _clock := ""

    _runId         := ""
    _firstTs       := ""
    _startedAt     := 0
    _loadingEvents := ""    ; Array<Map>
    _deathCount    := 0

    _handlerLoadingMeasured := ""
    _handlerDeathDetected   := ""
    _handlerRunStarted      := ""
    _handlerRunReset        := ""
    _handlerRunCancelled    := ""
    _handlerRunCompleted    := ""

    __New(bus, clock)
    {
        if !(bus is EventBus)
            throw TypeError("RunStatsRecorder: 'bus' deve ser EventBus")
        if !IsObject(clock) || !clock.HasMethod("NowMs")
            throw TypeError("RunStatsRecorder: 'clock' deve implementar NowMs()")

        this._bus           := bus
        this._clock         := clock
        this._loadingEvents := []

        this._handlerLoadingMeasured := (data) => this._OnLoadingMeasured(data)
        this._handlerDeathDetected   := (data) => this._OnDeathDetected(data)
        this._handlerRunStarted      := (data) => this._OnRunStarted(data)
        this._handlerRunReset        := (data) => this.Reset()
        this._handlerRunCancelled    := (data) => this.Reset()
        this._handlerRunCompleted    := (data) => 0    ; mantem dados pro plot final

        bus.Subscribe(Events.LoadingMeasured, this._handlerLoadingMeasured)
        bus.Subscribe(Events.DeathDetected,   this._handlerDeathDetected)
        bus.Subscribe(Events.RunStarted,      this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,        this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled,    this._handlerRunCancelled)
        bus.Subscribe(Events.RunCompleted,    this._handlerRunCompleted)
    }

    Dispose()
    {
        if (this._handlerLoadingMeasured != "")
        {
            this._bus.Unsubscribe(Events.LoadingMeasured, this._handlerLoadingMeasured)
            this._handlerLoadingMeasured := ""
        }
        if (this._handlerDeathDetected != "")
        {
            this._bus.Unsubscribe(Events.DeathDetected, this._handlerDeathDetected)
            this._handlerDeathDetected := ""
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
    ; Queries
    ; ============================================================
    GetRunId()         => this._runId
    GetFirstTs()       => this._firstTs
    GetLoadingEvents() => this._CopyArrayOfMaps(this._loadingEvents)
    GetDeathCount()    => this._deathCount

    ; GetSnapshot - monta Map snapshot consumido pelo plot builder.
    ; zoneTotalsMap eh fornecido pelo caller (ZoneTrackingService.GetTotals()).
    ; runDurationMs idem (TimerService.GetRunMs()).
    GetSnapshot(zoneTotalsMap := "", runDurationMs := 0)
    {
        return Map(
            "runId",         this._runId,
            "firstTs",       this._firstTs,
            "runDurationMs", runDurationMs,
            "zoneTotals",    IsObject(zoneTotalsMap) ? zoneTotalsMap : Map(),
            "loadingEvents", this._CopyArrayOfMaps(this._loadingEvents),
            "deathCount",    this._deathCount
        )
    }

    ; ============================================================
    ; Reset
    ; ============================================================
    Reset()
    {
        this._runId         := ""
        this._firstTs       := ""
        this._startedAt     := 0
        this._loadingEvents := []
        this._deathCount    := 0
    }

    ; ============================================================
    ; Handlers
    ; ============================================================
    _OnRunStarted(data)
    {
        this.Reset()
        if !IsObject(data)
            return
        if data.Has("runId")
            this._runId := data["runId"]
        if data.Has("startedAt")
            this._startedAt := data["startedAt"]
        this._firstTs := this._NowTimestamp()
    }

    _OnLoadingMeasured(data)
    {
        if !IsObject(data)
            return
        ms := data.Has("durationMs") ? data["durationMs"] : 0
        if (ms <= 0)
            return
        this._loadingEvents.Push(Map(
            "fromZone",   data.Has("fromZone") ? data["fromZone"] : "",
            "toZone",     data.Has("toZone")   ? data["toZone"]   : "",
            "durationMs", ms,
            "source",     data.Has("source")   ? data["source"]   : "",
            "ts",         this._NowTimestamp()
        ))
    }

    _OnDeathDetected(data)
    {
        this._deathCount += 1
    }

    ; ============================================================
    ; Helpers
    ; ============================================================
    _CopyArrayOfMaps(arr)
    {
        out := []
        if !IsObject(arr)
            return out
        for _, item in arr
        {
            if !IsObject(item)
                continue
            copy := Map()
            for k, v in item
                copy[k] := v
            out.Push(copy)
        }
        return out
    }

    _NowTimestamp()
    {
        ; YYYY-MM-DD HH:MM:SS no fuso local
        return FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
    }
}
