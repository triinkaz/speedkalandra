; ============================================================
; FocusAutoPauseService — automatic pause on focus loss (event-driven)
; ============================================================
;
; Automatically pauses the timer when PoE2 loses focus (alt-tab to
; the wiki, browser, discord, etc.) and resumes when it gains focus
; back.
;
; ARCHITECTURE (v0.1.4 — hybrid log+polling, with process death detection):
;
;   PRIMARY (log): consumes Evt.WindowFocusChanged published by
;     LogMonitorService when it parses "[WINDOW] Lost focus" /
;     "[WINDOW] Gained focus" in PoE2's Client.txt. Instant response
;     when the log works.
;
;   BACKUP 1 (focus polling, v0.1.1): subscribes to Evt.Tick and polls
;     WinActive every ~300ms. Current PoE2 EA does NOT reliably emit
;     "Gained focus" — without polling the timer stayed paused
;     indefinitely when the user came back.
;
;   BACKUP 2 (process polling, v0.1.4): on the same Tick, also checks
;     ProcessExist for any known PoE2 executable. When the process
;     died between ticks (Alt+F4 / crash / process kill), the focus
;     never publishes "lost" (window simply vanishes) and the WinActive
;     polling can race with the closing window state. ProcessExist
;     gives an unambiguous boolean: process exists or doesn't.
;
;     If the process was alive and is no longer alive, we force a
;     "lost" focus event regardless of what WinActive reported. The
;     timer pauses immediately — the run is preserved for when the
;     user reopens the game.
;
;   All paths call the SAME handler (_OnWindowFocusChanged) which is
;   idempotent (Pause when paused = no-op, Resume when running = no-op).
;
; SUBSTRING MATCH BUG (resolved via ahk_exe):
;   The previous version polled WinActive("Path of Exile 2"). In
;   AHK v2, default TitleMatchMode is substring — browsers / Discord
;   with "Path of Exile 2" in the title caused false positives. The
;   fix uses WinActive("ahk_exe XXX.exe"), exact match by executable.
;
; KNOWN EXECUTABLES (also used for ProcessExist polling):
;   PoE2 EA Steam:      PathOfExile_x64Steam.exe, PathOfExileSteam.exe
;   PoE2 EA Standalone: PathOfExile2_x64.exe, PathOfExile2.exe
;   PoE2 EA hypothetical (covered defensively): PathOfExile2Steam.exe
;   PoE1 / shared binary: PathOfExile_x64.exe, PathOfExile.exe
;
; Behavior:
;   - If settings.autoPauseOnFocus = false: noop (handler does nothing)
;   - Lost focus / process died + timer RUNNING: pause + pausedByFocus flag
;   - Gained focus + pausedByFocus: resume + clears flag
;   - If user manually paused/resumed between the two, the pausedByFocus
;     flag is preserved/respected (does not re-resume what the user
;     manually paused)
;
; Construction:
;   service := FocusAutoPauseService(bus, timerService, appSettings, logService)
;     logService is OPTIONAL (defaults to NullLogger). Used to log
;     transitions (Info level) for diagnostics.
;
; Lifecycle:
;   service.Start()    ; subscribe to Evt.WindowFocusChanged + Tick
;   service.Stop()     ; unsubscribe both
;
; For tests:
;   service := FocusAutoPauseService(bus, timer, settings)
;   service.Start()
;   bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
;   ; ... assert timer.IsPaused() etc.


class FocusAutoPauseService
{
    ; List of executables considered to be "PoE2 game running".
    ; Used by both _IsGameActive (focus check) and _IsGameProcessAlive
    ; (process existence check). Updated in v0.1.4 to add
    ; PathOfExileSteam.exe (sibling of x64Steam, observed in Steam install).
    static GAME_EXECUTABLES := [
        "PathOfExile2Steam.exe",
        "PathOfExile2_x64.exe",
        "PathOfExile2.exe",
        "PathOfExile_x64Steam.exe",
        "PathOfExileSteam.exe",
        "PathOfExile_x64.exe",
        "PathOfExile.exe"
    ]

    _bus      := ""
    _timer    := ""    ; TimerService
    _settings := ""    ; AppSettings
    _log      := ""    ; LogService (Info method) — optional, defaults to NullLogger

    _enabled         := false
    _pausedByFocus   := false
    _lastGameActive  := true     ; v0.1.1: cache to detect focus transitions via polling
    _lastGameAlive   := true     ; v0.1.4: cache to detect process death between ticks

    _handlerFocusChanged := ""
    _handlerTick         := ""   ; v0.1.1: backup polling via Tick

    __New(bus, timerSvc, cfg, logService := "")
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
        ; Logger duck-typed (Info method). Falls back to NullLogger when missing,
        ; keeping the call site free of `if IsObject(this._log)` guards.
        this._log := (IsObject(logService) && logService.HasMethod("Info"))
                     ? logService
                     : NullLogger()

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
        ; Initial snapshot of both focus AND process states.
        ; Without the process snapshot, the first tick after Start might
        ; spuriously treat "true -> false" as a transition when in
        ; reality the game was never alive in this session.
        this._lastGameActive := this._IsGameActive()
        this._lastGameAlive  := this._IsGameProcessAlive()
        try this._log.Info(
            "Auto-pause started (game focus=" (this._lastGameActive ? "active" : "inactive")
            . ", process=" (this._lastGameAlive ? "alive" : "absent") ")",
            "FocusAutoPause")
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
    ; Evt.Tick handler (v0.1.1, extended v0.1.4) — polling backup
    ;
    ; v0.1.4 — TWO checks per tick:
    ;
    ;   (1) Process existence: catches Alt+F4 / crash / kill task. When
    ;       the process died between ticks the WinActive polling alone
    ;       may not detect it reliably (race with closing window). If
    ;       process was alive last tick and isn't now, we treat it as
    ;       "lost focus" — the run pauses immediately, preserved for
    ;       when the user reopens the game.
    ;
    ;   (2) Focus transitions: original behavior (alt-tab between game
    ;       and another window). Same handler is called.
    ;
    ; Idempotency guarantee: a Pause on already-paused timer is no-op.
    ; If both detections fire on the same tick (process died = both lost
    ; focus AND not alive), the handler is called once for each, but
    ; the second is a no-op.
    ; ============================================================
    _OnTick(data)
    {
        if !this._enabled
            return
        if !this._settings.autoPauseOnFocus
        {
            ; Setting disabled — keep snapshots fresh so re-enabling
            ; doesn't trigger a phantom transition.
            this._lastGameActive := this._IsGameActive()
            this._lastGameAlive  := this._IsGameProcessAlive()
            this._pausedByFocus  := false
            return
        }

        ; --- (1) Process check (v0.1.4): did the game die? ---
        isAlive := this._IsGameProcessAlive()
        if (isAlive != this._lastGameAlive)
        {
            ; Transition detected. Update snapshot FIRST so we don't
            ; re-enter on every subsequent tick.
            this._lastGameAlive := isAlive
            try this._log.Info(
                "Game process " (isAlive ? "started" : "stopped detected")
                . " (was " (isAlive ? "absent" : "alive") ", now "
                . (isAlive ? "alive" : "absent") ")",
                "FocusAutoPause")

            ; Process died -> force lost focus. The timer will pause.
            ; We don't fire "gained" on process-alive transitions
            ; because the user must focus the game window themselves;
            ; the focus check below handles that case.
            if !isAlive
            {
                ; Sync the focus snapshot too — if process is gone,
                ; focus is logically gone as well.
                this._lastGameActive := false
                this._OnWindowFocusChanged(Map("state", "lost"))
                return   ; nothing else to do this tick
            }
        }

        ; --- (2) Focus check (v0.1.1): alt-tab / focus stolen by other window ---
        isActive := this._IsGameActive()
        if (isActive = this._lastGameActive)
            return   ; no change, no-op
        this._lastGameActive := isActive
        try this._log.Info(
            "Game focus " (isActive ? "gained" : "lost")
            . " (polling)", "FocusAutoPause")

        ; Fires the same handler used by the log-based path.
        this._OnWindowFocusChanged(Map("state", isActive ? "gained" : "lost"))
    }

    ; ============================================================
    ; _IsGameActive (v0.1.1)
    ;
    ; Detects whether the PoE2 window is currently focused. Exact match
    ; by ahk_exe to avoid substring-match false positives (browsers /
    ; Discord with "Path of Exile 2" in the title).
    ;
    ; Returns false if no known executable is focused. Future PoE2
    ; versions with a different name silently fall back to log-based
    ; detection — until the executable list is updated.
    ; ============================================================
    _IsGameActive()
    {
        for _, exeName in FocusAutoPauseService.GAME_EXECUTABLES
        {
            if WinActive("ahk_exe " . exeName)
                return true
        }
        return false
    }

    ; ============================================================
    ; _IsGameProcessAlive (v0.1.4)
    ;
    ; Detects whether ANY known PoE2 executable is currently running,
    ; regardless of focus state. Used by the polling backup to catch
    ; sudden process death (Alt+F4 inside the game / crash / task kill)
    ; that the focus-only check can miss.
    ;
    ; ProcessExist(name) returns the PID (truthy) or 0. We do not store
    ; the PID — just the boolean "any process alive".
    ; ============================================================
    _IsGameProcessAlive()
    {
        for _, exeName in FocusAutoPauseService.GAME_EXECUTABLES
        {
            if ProcessExist(exeName)
                return true
        }
        return false
    }

    ; ============================================================
    ; Evt.WindowFocusChanged handler
    ;
    ; Expected payload: Map("state", "lost" | "gained")
    ;
    ; Idempotent — duplicate handlers or redundant states do not cause
    ; side effects (Pause on already-paused timer = no-op).
    ;
    ; Called by:
    ;   - log-based path (Evt.WindowFocusChanged subscriber)
    ;   - focus polling backup (_OnTick check 2)
    ;   - process polling backup (_OnTick check 1, "lost" only)
    ; ============================================================
    _OnWindowFocusChanged(data)
    {
        if !this._enabled
            return
        if !this._settings.autoPauseOnFocus
        {
            ; Setting disabled — clear the flag so it doesn't stay
            ; dangling if the user re-enables it mid-session.
            this._pausedByFocus := false
            return
        }
        if !IsObject(data)
            return

        state := data.Has("state") ? String(data["state"]) : ""

        if (state = "lost")
        {
            ; Pause only if the timer was RUNNING (not already stopped/paused).
            if this._timer.IsRunning()
            {
                this._timer.Pause()
                this._pausedByFocus := true
                try this._log.Info("Timer paused (focus lost)", "FocusAutoPause")
            }
            return
        }

        if (state = "gained")
        {
            ; Resume only if WE paused (not if the user paused
            ; manually during the alt-tab).
            if (this._pausedByFocus && this._timer.IsPaused())
            {
                this._timer.Resume()
                try this._log.Info("Timer resumed (focus gained)", "FocusAutoPause")
            }
            this._pausedByFocus := false
            return
        }

        ; Unknown state — silently ignored.
    }
}
