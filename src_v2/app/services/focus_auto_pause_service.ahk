; ============================================================
; FocusAutoPauseService — automatic pause on focus loss (event-driven)
; ============================================================
;
; Automatically pauses the timer when PoE2 loses focus (alt-tab to
; the wiki, browser, discord, etc.) and resumes when it gains focus
; back.
;
; ARCHITECTURE (v0.1.1 — hybrid log+polling):
;   PRIMARY: Service consumes Evt.WindowFocusChanged published by
;   LogMonitorService when it parses "[WINDOW] Lost focus" /
;   "[WINDOW] Gained focus" in PoE2's Client.txt. Instant response
;   when the log works.
;
;   BACKUP (v0.1.1 fix Bug Lechtansi): also subscribes to Evt.Tick
;   and polls WinActive every ~300ms. Current PoE2 EA does NOT
;   reliably emit "Gained focus" in the log — without the polling,
;   the timer stayed paused indefinitely when the user came back
;   to the game.
;
;   Both paths call the SAME handler (_OnWindowFocusChanged) which
;   is idempotent (Pause when paused = no-op, Resume when running =
;   no-op). The log fires fast, polling catches up within ~300ms.
;
; SUBSTRING MATCH BUG (resolved via ahk_exe):
;   The previous version used polling with WinActive("Path of Exile 2").
;   In AHK v2, the default TitleMatchMode is substring — windows with
;   "Path of Exile 2" in the title (browser with wiki, Discord
;   #path-of-exile-2) caused false positives. Solution now:
;   WinActive("ahk_exe XXX.exe") is exact match by executable name.
;
; Behavior:
;   - If settings.autoPauseOnFocus = false: noop (handler does nothing)
;   - Lost focus + timer RUNNING: pause + pausedByFocus flag
;   - Gained focus + pausedByFocus: resume + clears flag
;   - If the user pauses/resumes manually between the two, the
;     pausedByFocus flag is preserved/respected (does not re-resume
;     what the user manually paused)
;
; Construction:
;   service := FocusAutoPauseService(bus, timerService, appSettings)
;   service.Start()    ; subscribe to Evt.WindowFocusChanged + Tick
;   service.Stop()     ; unsubscribe both
;
; For tests:
;   service := FocusAutoPauseService(bus, timer, settings)
;   service.Start()
;   bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
;   ; ... check timer.IsPaused() etc.


class FocusAutoPauseService
{
    _bus      := ""
    _timer    := ""    ; TimerService
    _settings := ""    ; AppSettings

    _enabled        := false
    _pausedByFocus  := false
    _lastGameActive := true   ; v0.1.1: cache to detect transitions via polling

    _handlerFocusChanged := ""
    _handlerTick         := ""   ; v0.1.1: backup polling via Tick

    __New(bus, timerSvc, cfg)
    {
        if !(bus is EventBus)
            throw TypeError("FocusAutoPauseService: 'bus' must be EventBus")
        if !(timerSvc is TimerService)
            throw TypeError("FocusAutoPauseService: 'timerSvc' must be TimerService")
        if !(cfg is AppSettings)
            throw TypeError("FocusAutoPauseService: 'cfg' must be AppSettings")

        this._bus      := bus
        this._timer    := timerSvc
        this._settings := cfg

        this._handlerFocusChanged := (data) => this._OnWindowFocusChanged(data)
        this._handlerTick         := (data) => this._OnTick(data)
    }

    ; ============================================================
    ; Lifecycle
    ; ============================================================

    Start()
    {
        if this._enabled
            return
        this._enabled := true
        this._pausedByFocus := false
        ; Initial snapshot of the focus state for polling to detect transitions.
        this._lastGameActive := this._IsGameActive()
        this._bus.Subscribe(Events.WindowFocusChanged, this._handlerFocusChanged)
        this._bus.Subscribe(Events.Tick, this._handlerTick)
    }

    Stop()
    {
        if !this._enabled
            return
        this._enabled := false
        this._pausedByFocus := false
        try this._bus.Unsubscribe(Events.WindowFocusChanged, this._handlerFocusChanged)
        try this._bus.Unsubscribe(Events.Tick, this._handlerTick)
    }

    IsEnabled()         => this._enabled
    WasPausedByFocus()  => this._pausedByFocus

    ; ============================================================
    ; Evt.Tick handler (v0.1.1) — polling backup
    ;
    ; PoE2 EA does not reliably emit "Gained focus" in Client.txt.
    ; Polls WinActive on every Tick (~300ms) and, when it detects a
    ; state change, simulates the corresponding focus event by calling
    ; the same _OnWindowFocusChanged that the log-based path uses.
    ;
    ; Idempotency guaranteed: timer.Pause() when paused = no-op, same
    ; for Resume() when running. Even if the log fires first (fast
    ; path), the subsequent tick that detects the same transition is
    ; harmless.
    ; ============================================================
    _OnTick(data)
    {
        if !this._enabled
            return
        if !this._settings.autoPauseOnFocus
        {
            this._lastGameActive := this._IsGameActive()   ; keep snapshot
            this._pausedByFocus := false
            return
        }

        isActive := this._IsGameActive()
        if (isActive = this._lastGameActive)
            return   ; no change, no-op
        this._lastGameActive := isActive

        ; Fires the same handler that the log-based path uses.
        this._OnWindowFocusChanged(Map("state", isActive ? "gained" : "lost"))
    }

    ; ============================================================
    ; _IsGameActive (v0.1.1)
    ;
    ; Detects whether the PoE2 window is currently focused. Strict
    ; match by ahk_exe to avoid false positives from substring match
    ; (browsers/Discord with "Path of Exile 2" in the title).
    ;
    ; Covers known executable names:
    ;   PoE2 EA Steam:    PathOfExile2Steam.exe, PathOfExile_x64Steam.exe
    ;   PoE2 EA Standalone: PathOfExile2_x64.exe, PathOfExile2.exe
    ;   PoE1 names compat: PathOfExile_x64.exe, PathOfExile.exe
    ;
    ; If none match (future version with a different name), returns
    ; false — polling does nothing, but log-based detection keeps
    ; working.
    ; ============================================================
    _IsGameActive()
    {
        return WinActive("ahk_exe PathOfExile2Steam.exe")
            || WinActive("ahk_exe PathOfExile2_x64.exe")
            || WinActive("ahk_exe PathOfExile2.exe")
            || WinActive("ahk_exe PathOfExile_x64Steam.exe")
            || WinActive("ahk_exe PathOfExile_x64.exe")
            || WinActive("ahk_exe PathOfExile.exe")
    }

    ; ============================================================
    ; Evt.WindowFocusChanged handler
    ;
    ; Expected payload: Map("state", "lost" | "gained")
    ;
    ; Idempotent — duplicate handlers or redundant states do not
    ; cause side effects (Pause on an already-paused timer is a no-op).
    ;
    ; Called both by the log-based path (subscribe to
    ; Evt.WindowFocusChanged) and by the polling backup (_OnTick).
    ; ============================================================
    _OnWindowFocusChanged(data)
    {
        if !this._enabled
            return
        if !this._settings.autoPauseOnFocus
        {
            ; Setting disabled — clear the flag so it doesn't stay
            ; dangling if the user re-enables it in the middle.
            this._pausedByFocus := false
            return
        }
        if !IsObject(data)
            return

        state := data.Has("state") ? String(data["state"]) : ""

        if (state = "lost")
        {
            ; Pause only if the timer was RUNNING (not if already stopped/paused).
            if this._timer.IsRunning()
            {
                this._timer.Pause()
                this._pausedByFocus := true
            }
            return
        }

        if (state = "gained")
        {
            ; Resume only if WE paused (not if the user paused
            ; manually during the alt-tab).
            if (this._pausedByFocus && this._timer.IsPaused())
                this._timer.Resume()
            this._pausedByFocus := false
            return
        }

        ; Unknown state — silently ignored.
    }
}
