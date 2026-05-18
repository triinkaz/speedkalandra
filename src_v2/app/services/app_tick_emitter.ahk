; ============================================================
; AppTickEmitter — periodic Events.Tick pulse
; ============================================================
;
; Responsibility: publish Events.Tick every N milliseconds while
; running. Subscribers (overlay widgets) react by querying services
; and updating their controls.
;
; Why does it exist?
;   Widgets need to update values in real time (run timer, step
;   timer, percentages). Instead of each widget having its own
;   SetTimer, we centralize in a single pulse — they all update
;   in sync, without multiplying timers.
;
; Why no payload?
;   Architecture decision: widgets query services directly via
;   constructor refs. The Tick is only the "refresh now" signal,
;   which keeps the emitter simple and decoupled from which
;   services exist.
;
; Lifecycle:
;   emitter := AppTickEmitter(bus, 300)    ; 300ms default
;   emitter.Start()                          ; starts pulsing
;   emitter.Pulse()                          ; manual pulse (tests)
;   emitter.Stop()                           ; stops the SetTimer
;
; Idempotency:
;   Start() when running = no-op
;   Stop() when stopped = no-op
;   Multiple Start/Stop are safe


class AppTickEmitter
{
    static DEFAULT_INTERVAL_MS := 300

    _bus            := ""
    _intervalMs     := 0
    _running        := false
    _timerCallback  := ""    ; BoundFunc, kept to avoid GC

    __New(bus, intervalMs := AppTickEmitter.DEFAULT_INTERVAL_MS)
    {
        if !(bus is EventBus)
            throw TypeError("AppTickEmitter: 'bus' must be EventBus")
        if (!IsInteger(intervalMs) || intervalMs <= 0)
            throw ValueError("AppTickEmitter: 'intervalMs' must be a positive integer")

        this._bus           := bus
        this._intervalMs    := intervalMs
        ; Bind once. Required because SetTimer needs a stable callable
        ; (same object) for Stop to be able to cancel it.
        this._timerCallback := this._Pulse.Bind(this)
    }

    ; ============================================================
    ; Commands
    ; ============================================================

    ; Starts the periodic pulse. No-op if already running.
    Start()
    {
        if this._running
            return
        this._running := true
        SetTimer(this._timerCallback, this._intervalMs)
    }

    ; Stops the pulse. No-op if already stopped.
    Stop()
    {
        if !this._running
            return
        SetTimer(this._timerCallback, 0)
        this._running := false
    }

    ; Manual pulse (publishes Events.Tick once). Useful in tests to
    ; avoid depending on a real SetTimer, and in prod to force an
    ; immediate refresh after a relevant state change.
    Pulse() => this._Pulse()

    ; ============================================================
    ; Queries
    ; ============================================================

    IsRunning()     => this._running
    GetIntervalMs() => this._intervalMs

    ; ============================================================
    ; Private helpers
    ; ============================================================

    _Pulse()
    {
        this._bus.Publish(Events.Tick)
    }
}
