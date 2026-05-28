; RunStatsRecorder — in-memory buffer of run-relevant events
; (loadings, deaths, runId metadata). The composition root combines
; the snapshot from GetSnapshot() with ZoneTrackingService.GetTotals()
; to feed RunStatsPlotBuilder.Build at the end of a run.
;
; Subscribes:
;   LoadingMeasured  → push to _loadingEvents
;   DeathDetected    → _deathCount++
;   RunStarted       → Reset() + capture runId/startedAt
;                     EXCEPT when data["hydrated"] is true (boot
;                     replay of an in-progress run) — see below
;   RunReset         → Reset()
;   RunCancelled     → Reset()
;   RunCompleted     → no-op (next RunStarted resets; data stays
;                    available to the plot builder in between)
;
; PERSISTENCE / HYDRATION:
;   _loadingEvents is persisted by the composition root to
;   <iniBase>_loading_events.txt every 5 s (RunStatePersister.Tick)
;   and on Stop()/OnExit (Flush). On boot Hydrate(events, firstTs,
;   deathCount) restores the array BEFORE runService.Hydrate
;   publishes Evt.RunStarted{hydrated:true}. The hydrated:true
;   branch of _OnRunStarted skips Reset() so the just-restored
;   array survives. Same pattern as LoadingTotalsService and
;   ZoneTrackingService.
;
;   _deathCount follows the same pattern but is a scalar persisted
;   in [RunState] DeathCount=N (like LoadingTotalMs). Without it,
;   the count would reset to 0 every reboot — multi-session
;   finalized runs would under-report total deaths in the dialog.
;
;   Without these, every close/reopen of an in-progress run wiped
;   the array — the live overlay (which reads the scalar in
;   LoadingTotalsService) stayed correct, but the run-history plot
;   dialog (which sums loadingEvents from the snapshot) only saw
;   events from the FINAL session before finalize, showing
;   absurdly low Loading KPI on multi-session runs.

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
        this._handlerRunCompleted    := (data) => 0    ; keep data for the plot builder

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

    ; ---- Queries ----
    GetRunId()         => this._runId
    GetFirstTs()       => this._firstTs
    GetLoadingEvents() => this._CopyArrayOfMaps(this._loadingEvents)
    GetDeathCount()    => this._deathCount

    ; Builds the snapshot consumed by RunStatsPlotBuilder. zoneTotalsMap
    ; comes from ZoneTrackingService.GetTotals (or GetTotalsForSnapshot).
    ; zoneFirstEnteredAt is the per-zone first-entry timestamp map
    ; (also from ZoneTrackingService); the plot builder uses it for
    ; chronological ordering of zone details. Empty when not provided
    ; — plot falls back to whatever order the totals iterate in.
    GetSnapshot(zoneTotalsMap := "", runDurationMs := 0, zoneFirstEnteredAt := "")
    {
        return Map(
            "runId",              this._runId,
            "firstTs",            this._firstTs,
            "runDurationMs",      runDurationMs,
            "zoneTotals",         IsObject(zoneTotalsMap) ? zoneTotalsMap : Map(),
            "zoneFirstEnteredAt", IsObject(zoneFirstEnteredAt) ? zoneFirstEnteredAt : Map(),
            "loadingEvents",      this._CopyArrayOfMaps(this._loadingEvents),
            "deathCount",         this._deathCount
        )
    }

    Reset()
    {
        this._runId         := ""
        this._firstTs       := ""
        this._startedAt     := 0
        this._loadingEvents := []
        this._deathCount    := 0
    }

    ; Restores loading events + firstTs + deathCount from disk
    ; (crash recovery). Called by the composition root on boot
    ; AFTER constructing the recorder and BEFORE runService.Hydrate
    ; publishes Evt.RunStarted{hydrated:true}. The hydrated:true
    ; branch of _OnRunStarted skips Reset() so these values survive.
    ;
    ; Defensive: non-Array evtArr is ignored; non-Map entries and
    ; entries with missing/invalid durationMs are silently skipped
    ; (RunStateRepository.LoadLoadingEvents already filters; this is
    ; a second line of defense for direct programmatic callers).
    ;
    ; firstTs is the original "yyyy-MM-dd HH:mm:ss" start timestamp
    ; preserved across sessions. Empty string leaves _firstTs as is.
    ;
    ; deathCount is the integer death count for the run. Negative
    ; values (default -1) leave _deathCount as is, so callers that
    ; don't have a value to set can omit the arg.
    Hydrate(evtArr, firstTs := "", deathCount := -1)
    {
        if (evtArr is Array)
        {
            hydrated := []
            for _, evtMap in evtArr
            {
                if !IsObject(evtMap)
                    continue
                ms := evtMap.Has("durationMs") ? evtMap["durationMs"] : 0
                if !IsNumber(ms)
                    continue
                msInt := Integer(ms + 0)
                if (msInt <= 0)
                    continue
                hydrated.Push(Map(
                    "durationMs", msInt,
                    "ts",         evtMap.Has("ts")       ? evtMap["ts"]       : "",
                    "source",     evtMap.Has("source")   ? evtMap["source"]   : "",
                    "fromZone",   evtMap.Has("fromZone") ? evtMap["fromZone"] : "",
                    "toZone",     evtMap.Has("toZone")   ? evtMap["toZone"]   : ""
                ))
            }
            this._loadingEvents := hydrated
        }
        if (firstTs != "")
            this._firstTs := firstTs
        if (IsNumber(deathCount) && deathCount >= 0)
            this._deathCount := Integer(deathCount + 0)
    }

    ; ---- Handlers ----

    ; RunStarted handler. The hydrated:true variant comes from
    ; RunService.Hydrate at the end of the composition root's __New;
    ; by that point Hydrate(events, firstTs) has already restored
    ; _loadingEvents and _firstTs from disk. Wiping them via Reset()
    ; here would lose every loading event tracked before the
    ; previous shutdown. Same convention as LoadingTotalsService and
    ; ZoneTrackingService._OnRunStarted.
    _OnRunStarted(data)
    {
        isHydrate := IsObject(data) && data.Has("hydrated") && data["hydrated"]
        if !isHydrate
            this.Reset()
        if !IsObject(data)
            return
        if data.Has("runId")
            this._runId := data["runId"]
        if data.Has("startedAt")
            this._startedAt := data["startedAt"]
        if !isHydrate
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

    ; ---- Helpers ----

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
        return FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
    }
}
