; ============================================================
; LoadingTotalsService — accumulates total run loading time (Phase B4.4)
; ============================================================
;
; Simple, reactive service: subscribes to Evt.LoadingMeasured to
; accumulate durationMs into _totalMs. Clears on run transitions
; (RunStarted/RunReset/RunCancelled/RunCompleted).
;
; Reason to exist: the UI needs to know how much loading time the
; player spent in the current run to compute gameplay% / loading%.
; LoadingDetection already measures and publishes each individual
; loading; this service just aggregates.
;
; PHILOSOPHY:
;   - Minimal state (1 number).
;   - Bus-reactive, no lifecycle (no Start/Stop).
;   - Idempotent: subscribers can react multiple times with no effect.
;
; PERSISTENCE:
;   _totalMs is persisted by the composition root in the
;   [RunState].LoadingTotalMs INI field, side by side with runBaseMs.
;   Hydrate() restores on boot. Without this, after a reload the
;   current run's loading time would be lost.
;
; Construction:
;   svc := LoadingTotalsService(bus)
;   svc.GetTotalMs()    ; 0 initially
;
; Typical use (composition root):
;   bus.Publish(Events.LoadingMeasured, Map("durationMs", 4500, ...))
;   svc.GetTotalMs()    ; 4500
;   bus.Publish(Events.RunStarted, Map("runId", "..."))
;   svc.GetTotalMs()    ; 0 (cleared)


class LoadingTotalsService
{
    _bus     := ""
    _totalMs := 0

    ; Handler refs (Section 17.32 — fields for Unsubscribe in Dispose)
    _handlerLoadingMeasured := ""
    _handlerRunStarted      := ""
    _handlerRunReset        := ""
    _handlerRunCancelled    := ""
    _handlerRunCompleted    := ""

    __New(bus)
    {
        if !(bus is EventBus)
            throw TypeError("LoadingTotalsService: 'bus' must be EventBus")
        this._bus     := bus
        this._totalMs := 0

        this._handlerLoadingMeasured := (data) => this._OnLoadingMeasured(data)
        this._handlerRunStarted      := (data) => this._OnRunStarted(data)
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
    ; Dispose — tears down subscriptions. Idempotent.
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
    ; Hydrate - restores accumulated time from disk (crash recovery)
    ;
    ; Called by the composition root on boot after
    ; RunStateRepository.LoadLoadingTotal(). Defensive against invalid
    ; values.
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

    ; RunStarted handler. The hydrated:true variant comes from
    ; RunService.Hydrate at the end of the composition root's __New;
    ; by the time it fires, _totalMs has already been restored from
    ; disk via Hydrate(loadingMs). Wiping it here would lose every
    ; ms of loading tracked before the previous shutdown. Same
    ; convention used by ZoneTrackingService._OnRunStarted.
    _OnRunStarted(data)
    {
        isHydrate := IsObject(data) && data.Has("hydrated") && data["hydrated"]
        if isHydrate
            return
        this.Reset()
    }

    ; Accumulates durationMs into the total. Defensive against
    ; malformed data.
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
