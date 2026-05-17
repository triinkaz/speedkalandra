; ============================================================
; TimerService - single-scope timer mechanics (Wave 6)
; ============================================================
;
; POST-DEMOLITION VERSION: single-scope (runMs only). No act, no
; segment, no carry. Pure mechanics: start/pause/resume/stop/reset.
;
; STATES:
;   STOPPED   !_active                (boot, after Stop, after Reset)
;   RUNNING    _active && !_paused
;   PAUSED     _active && _paused
;
; CALCULATION:
;   In RUNNING: runMs = _baseMs + (clock.NowMs() - _startTick)
;   In PAUSED: runMs = _baseMs    (current segment already committed)
;
; PUBLISHED EVENTS (via bus):
;   Evt.TimerStarted  -> {runMs}     (Start from STOPPED)
;   Evt.TimerPaused   -> {runMs}     (Pause from RUNNING)
;   Evt.TimerResumed  -> {runMs}     (Resume from PAUSED)
;   Evt.TimerStopped  -> {runMs}     (Stop from any state != STOPPED)
;   Evt.TimerReset    -> {scope: "all"}  (Reset)
;
; CONSTRUCTION:
;   timer := TimerService(clock, bus)
;
; HYDRATE (boot with persisted state):
;   timer.Hydrate(runBaseMs)                  ; STOPPED (default)
;   timer.Hydrate(runBaseMs, "running")       ; RUNNING (mid-run auto-resume)
;   timer.Hydrate(runBaseMs, "paused")        ; PAUSED (user resumes manually)
;
;   In "running": _active=true, _paused=false, _startTick=NowMs. Since
;   _baseMs already has the accumulated time, GetRunMs continues from
;   where it left off + new delta. Does NOT publish TimerStarted (this
;   is restoration, not a new start — subscribers should not react as
;   if it were a new run).


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

    ; ============================================================
    ; Queries
    ; ============================================================
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

    ; ============================================================
    ; Hydrate - restores state from disk
    ;
    ; statusHint controls which state the timer is in after hydrate:
    ;   "stopped" (default): timer STOPPED. _baseMs preserved but
    ;     GetRunMs returns constant. User must Start/Toggle to resume.
    ;   "running": timer RUNNING. GetRunMs continues from _baseMs + delta.
    ;     Used in crash recovery when state.IsRunning() on disk.
    ;   "paused":  timer PAUSED. GetRunMs returns _baseMs. User does
    ;     a Toggle to Resume.
    ;
    ; Hydration is SILENT (does not publish TimerStarted/Resumed/Paused).
    ; It's restoration, not a real transition — other services must
    ; query IsRunning/IsPaused directly to know post-boot state.
    ; ============================================================
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

    ; ============================================================
    ; Start - starts from STOPPED
    ;
    ; In RUNNING/PAUSED: no-op (use Resume to resume from pause).
    ; ============================================================
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

    ; ============================================================
    ; Pause - commits the current segment to _baseMs
    ; ============================================================
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

    ; ============================================================
    ; Resume - exits PAUSED
    ; ============================================================
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

    ; ============================================================
    ; Stop - ends the round (preserves _baseMs)
    ; ============================================================
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

    ; ============================================================
    ; Reset - clears full state
    ; ============================================================
    Reset()
    {
        this._active    := false
        this._paused    := false
        this._startTick := 0
        this._baseMs    := 0
        this._bus.Publish(Events.TimerReset, Map("scope", "all"))
        return true
    }

    ; ============================================================
    ; AddPenaltyMs - adds extra time to the timer (v0.1.3)
    ;
    ; Used by the composition root when Evt.DeathDetected fires and
    ; cfg.deathPenaltyEnabled = true: the penalty goes straight into
    ; the runMs, visible in the widget in real time (previously it
    ; only appeared in the post-finalize plot).
    ;
    ; Behavior:
    ;   - If STOPPED or run inactive: caller must check first (this
    ;     method does not filter — it adds to _baseMs unconditionally).
    ;   - If RUNNING: commits the current delta first (so the penalty
    ;     is "stitched" at the exact time point) and then adds the
    ;     penalty to _baseMs. _startTick is reset to NowMs so GetRunMs
    ;     keeps counting from the new baseline.
    ;   - If PAUSED: adds directly to _baseMs. _startTick stays at 0.
    ;
    ; Negatives / non-number: coerce to 0 (no-op).
    ;
    ; Does NOT publish an event. The penalty is reflected automatically
    ; in GetRunMs() on the next read — widgets refresh on the next
    ; Tick and show the new value without needing a dedicated event.
    ; ============================================================
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

    ; ============================================================
    ; Toggle - hotkey-friendly StartPause
    ;   STOPPED -> Start
    ;   RUNNING -> Pause
    ;   PAUSED -> Resume
    ; ============================================================
    Toggle()
    {
        if !this._active
            return this.Start()
        if this._paused
            return this.Resume()
        return this.Pause()
    }

    ; ============================================================
    ; _CommitDelta - converts (NowMs - startTick) into baseMs
    ; ============================================================
    _CommitDelta()
    {
        if (this._startTick = 0)
            return
        delta := Max(0, this._clock.NowMs() - this._startTick)
        this._baseMs    += delta
        this._startTick := this._clock.NowMs()
    }
}
