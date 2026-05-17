; ============================================================
; RunStatsRecorder - in-memory buffer of current-run events
; ============================================================
;
; Reactive service that listens to the events relevant to the final
; plot and accumulates them in arrays/counters. The composition root
; uses GetSnapshot() to build the input for RunStatsPlotBuilder.Build(snapshot).
;
; SUBSCRIPTIONS:
;   Evt.LoadingMeasured  -> push loadingEvents
;   Evt.DeathDetected    -> deathCount++
;   Evt.RunStarted       -> Reset() + snapshot _runId/_startedAt
;   Evt.RunReset         -> Reset()
;   Evt.RunCancelled     -> Reset()
;   Evt.RunCompleted     -> snapshot final duration (Reset happens on the next RunStarted)
;
; ZONE TOTALS:
;   NOT accumulated here. ZoneTrackingService.GetTotals() already
;   does that. The composition root combines the two services when
;   building the snapshot.
;
; BOSS EVENTS (REMOVED in v17.13):
;   Boss tracking feature was removed from the app (class voice lines
;   were not going into PoE2's Client.txt). Snapshot no longer
;   includes bossEvents.
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
; CONSTRUCTION:
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
            throw TypeError("RunStatsRecorder: 'bus' must be EventBus")
        if !IsObject(clock) || !clock.HasMethod("NowMs")
            throw TypeError("RunStatsRecorder: 'clock' must implement NowMs()")

        this._bus           := bus
        this._clock         := clock
        this._loadingEvents := []

        this._handlerLoadingMeasured := (data) => this._OnLoadingMeasured(data)
        this._handlerDeathDetected   := (data) => this._OnDeathDetected(data)
        this._handlerRunStarted      := (data) => this._OnRunStarted(data)
        this._handlerRunReset        := (data) => this.Reset()
        this._handlerRunCancelled    := (data) => this.Reset()
        this._handlerRunCompleted    := (data) => 0    ; keeps data for the final plot

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

    ; GetSnapshot - builds the Map snapshot consumed by the plot builder.
    ; zoneTotalsMap is provided by the caller (ZoneTrackingService.GetTotals()).
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
        ; YYYY-MM-DD HH:MM:SS in local time
        return FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
    }
}
