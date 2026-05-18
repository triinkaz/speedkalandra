; TimerService — single-scope run timer (runMs only). Pure
; mechanics: start / pause / resume / stop / reset.
;
; States:
;   STOPPED   !_active                (boot / after Stop / after Reset)
;   RUNNING    _active && !_paused
;   PAUSED     _active && _paused
;
; runMs:
;   RUNNING → _baseMs + (clock.NowMs() - _startTick)
;   PAUSED  → _baseMs (the current segment is already committed)
;
; Hydrate(runBaseMs, statusHint) restores state from disk. It does
; NOT publish TimerStarted/Resumed/Paused — those are real transitions
; only. Other services that need to know post-boot state must query
; IsRunning / IsPaused directly.


class TimerService
{
    _clock := ""
    _bus   := ""

    _active    := false
    _paused    := false
    _startTick := 0
    _baseMs    := 0

    __New(clock, bus)
    {
        if !IsObject(clock) || !clock.HasMethod("NowMs")
            throw TypeError("TimerService: 'clock' must implement NowMs()")
        if !(bus is EventBus)
            throw TypeError("TimerService: 'bus' must be EventBus")
        this._clock := clock
        this._bus   := bus
    }

    ; ---- Queries ----
    IsActive()  => this._active
    IsRunning() => this._active && !this._paused
    IsPaused()  => this._active && this._paused

    GetRunMs()
    {
        if (!this._active)
            return this._baseMs
        if this._paused
            return this._baseMs
        return this._baseMs + Max(0, this._clock.NowMs() - this._startTick)
    }

    ; Restores state from disk. statusHint:
    ;   "stopped" (default) — _baseMs preserved, GetRunMs constant;
    ;                        user must Start/Toggle to resume.
    ;   "running" — timer active, GetRunMs continues from _baseMs +
    ;               delta. Used by crash recovery when the persisted
    ;               RunState reports a running run.
    ;   "paused"  — timer active but paused, GetRunMs returns _baseMs;
    ;               user does a Toggle to Resume.
    ;
    ; Hydration is silent (publishes nothing). It restores state, it
    ; doesn't transition — services that need post-boot state must
    ; query IsRunning/IsPaused directly.
    Hydrate(runBaseMs, statusHint := "stopped")
    {
        if !IsNumber(runBaseMs)
            runBaseMs := 0
        this._baseMs := Integer(runBaseMs)
        if (this._baseMs < 0)
            this._baseMs := 0

        hint := StrLower(String(statusHint))
        if (hint = "running")
        {
            this._active    := true
            this._paused    := false
            this._startTick := this._clock.NowMs()
        }
        else if (hint = "paused")
        {
            this._active    := true
            this._paused    := true
            this._startTick := 0
        }
        else
        {
            ; stopped (default)
            this._active    := false
            this._paused    := false
            this._startTick := 0
        }
    }

    ; Starts from STOPPED. RUNNING / PAUSED are no-ops (Resume is
    ; the path out of PAUSED).
    Start()
    {
        if this._active
            return false
        this._active    := true
        this._paused    := false
        this._startTick := this._clock.NowMs()
        this._bus.Publish(Events.TimerStarted, Map("runMs", this.GetRunMs()))
        return true
    }

    ; Commits the current segment to _baseMs and freezes the clock.
    Pause()
    {
        if !this._active
            return false
        if this._paused
            return false
        this._CommitDelta()
        this._paused := true
        this._bus.Publish(Events.TimerPaused, Map("runMs", this.GetRunMs()))
        return true
    }

    ; Leaves PAUSED.
    Resume()
    {
        if !this._active
            return false
        if !this._paused
            return false
        this._paused    := false
        this._startTick := this._clock.NowMs()
        this._bus.Publish(Events.TimerResumed, Map("runMs", this.GetRunMs()))
        return true
    }

    ; Ends the round, preserves _baseMs.
    Stop()
    {
        if !this._active
            return false
        if !this._paused
            this._CommitDelta()
        this._active := false
        this._paused := false
        this._bus.Publish(Events.TimerStopped, Map("runMs", this._baseMs))
        return true
    }

    ; Clears everything (including _baseMs).
    Reset()
    {
        this._active    := false
        this._paused    := false
        this._startTick := 0
        this._baseMs    := 0
        this._bus.Publish(Events.TimerReset, Map("scope", "all"))
        return true
    }

    ; Adds extra time to the timer. Used by the composition root
    ; when a death is detected and cfg.deathPenaltyEnabled is set:
    ; the penalty lands in runMs immediately so the widget shows it
    ; live (previously it was only visible in the post-finalize plot).
    ;
    ; - STOPPED: caller is responsible for checking; this method
    ;   adds to _baseMs unconditionally.
    ; - RUNNING: commits the delta first so the penalty stitches in
    ;   at the right time point, then adds; _startTick resets to NowMs.
    ; - PAUSED: adds directly to _baseMs.
    ; - non-positive: no-op.
    ;
    ; Doesn't publish an event — GetRunMs picks it up automatically
    ; on the next read and widgets refresh on the next Tick.
    AddPenaltyMs(ms)
    {
        if (!IsNumber(ms) || ms <= 0)
            return false
        penalty := Integer(ms)
        if (this._active && !this._paused)
            this._CommitDelta()
        this._baseMs += penalty
        return true
    }

    ; Hotkey-friendly Start/Pause:
    ;   STOPPED → Start
    ;   RUNNING → Pause
    ;   PAUSED  → Resume
    Toggle()
    {
        if !this._active
            return this.Start()
        if this._paused
            return this.Resume()
        return this.Pause()
    }

    ; Converts (NowMs - startTick) into baseMs.
    _CommitDelta()
    {
        if (this._startTick = 0)
            return
        delta := Max(0, this._clock.NowMs() - this._startTick)
        this._baseMs    += delta
        this._startTick := this._clock.NowMs()
    }
}
