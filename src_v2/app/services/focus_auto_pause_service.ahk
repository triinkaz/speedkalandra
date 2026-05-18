; FocusAutoPauseService — automatic pause when PoE2 loses focus,
; auto-resume when it gains focus back. Hybrid path: a primary log
; signal and two polling backups.
;
;   PRIMARY — LogMonitorService publishes Evt.WindowFocusChanged when
;     it parses "[WINDOW] Lost focus" / "[WINDOW] Gained focus" in
;     Client.txt. Instant response when the log behaves.
;
;   BACKUP 1 (focus polling) — subscribes to Evt.Tick and polls
;     WinActive every ~300 ms. Current PoE2 EA does NOT reliably
;     emit "Gained focus"; without polling the timer stayed paused
;     indefinitely when the user came back.
;
;   BACKUP 2 (process polling) — same Tick also checks ProcessExist
;     against every known PoE2 executable. A sudden process death
;     (Alt+F4 / crash / kill task) never publishes "lost focus" —
;     the window simply vanishes and the WinActive polling can race
;     with the closing window. ProcessExist gives an unambiguous
;     boolean, and we force a "lost" event when it flips alive→absent.
;
; All paths converge on _OnWindowFocusChanged. It's idempotent:
; Pause on an already-paused timer and Resume on a running timer
; are both no-ops.
;
; Window identity is checked by ahk_exe (exact match on the process
; name), never by title substring. A substring match would also fire
; for a browser tab named "Path of Exile 2 - Wiki" or a Discord
; channel with the game's name, hijacking the auto-pause.
;
; Known executables (focus AND process polling share the same list):
;   PoE2 Steam:        PathOfExile_x64Steam.exe, PathOfExileSteam.exe
;   PoE2 standalone:   PathOfExile2_x64.exe, PathOfExile2.exe
;   PoE2 hypothetical: PathOfExile2Steam.exe  (defensive)
;   PoE1 / shared:     PathOfExile_x64.exe, PathOfExile.exe
;
; The pausedByFocus flag tracks whether WE paused the timer (vs.
; the user pausing manually mid-alt-tab); only our pauses are
; auto-resumed on focus gained.


class FocusAutoPauseService
{
    ; Every known PoE2 executable. _IsGameActive and
    ; _IsGameProcessAlive both iterate this list. Keep it in sync
    ; with LoadingDetectionService.GAME_EXECUTABLES — a future build
    ; with a new exe must update both, otherwise one service silently
    ; breaks.
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
    _log      := ""    ; LogService (Info method), defaults to NullLogger

    _enabled         := false
    _pausedByFocus   := false
    _lastGameActive  := true     ; Snapshot for focus-transition detection.
    _lastGameAlive   := true     ; Snapshot for process-death detection.

    _handlerFocusChanged := ""
    _handlerTick         := ""

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

    ; ---- Lifecycle ----

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

    ; Evt.Tick polling backup. Two checks per tick:
    ;
    ; (1) Process existence — catches Alt+F4 / crash / kill task.
    ;     When the process dies between ticks, the WinActive check
    ;     can race with the closing window. If process was alive
    ;     last tick and isn't now, force a "lost focus" event so
    ;     the run pauses immediately and is preserved for re-launch.
    ;
    ; (2) Focus transitions — alt-tab between the game and another
    ;     window. Identical to the log-based path's outcome.
    ;
    ; Both call _OnWindowFocusChanged, which is idempotent: even
    ; when both checks fire on the same tick (process died implies
    ; focus lost too), the second invocation is a no-op.
    _OnTick(data)
    {
        if !this._enabled
            return
        if !this._settings.autoPauseOnFocus
        {
            ; Setting disabled — keep snapshots fresh so re-enabling
            ; mid-session doesn't fire a phantom transition.
            this._lastGameActive := this._IsGameActive()
            this._lastGameAlive  := this._IsGameProcessAlive()
            this._pausedByFocus  := false
            return
        }

        ; (1) Did the game process die?
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

            ; Process died → force a lost-focus event. We do NOT
            ; auto-fire "gained" on the alive transition; the user
            ; still needs to focus the game window, which the focus
            ; check below picks up.
            if !isAlive
            {
                ; Process gone, focus is logically gone too — keep
                ; the focus snapshot consistent.
                this._lastGameActive := false
                this._OnWindowFocusChanged(Map("state", "lost"))
                return
            }
        }

        ; (2) Alt-tab / focus stolen by another window.
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

    ; Returns true when one of the known PoE2 executables owns the
    ; foreground window. Exact match on ahk_exe avoids the substring
    ; trap from default TitleMatchMode.
    _IsGameActive()
    {
        for _, exeName in FocusAutoPauseService.GAME_EXECUTABLES
        {
            if WinActive("ahk_exe " . exeName)
                return true
        }
        return false
    }

    ; Returns true when ANY known PoE2 executable is running,
    ; focused or not. ProcessExist returns the PID (truthy) or 0;
    ; we don't need the PID, just the boolean.
    _IsGameProcessAlive()
    {
        for _, exeName in FocusAutoPauseService.GAME_EXECUTABLES
        {
            if ProcessExist(exeName)
                return true
        }
        return false
    }

    ; WindowFocusChanged handler. Payload: Map("state", "lost" | "gained").
    ; Idempotent — Pause on already-paused timer, Resume on running
    ; timer are both no-ops. Called from three paths: the bus
    ; subscription, the focus-polling tick branch, and the
    ; process-polling tick branch ("lost" only).
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
            ; Only Pause if the timer was actually RUNNING (not
            ; already paused or stopped).
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
            ; Only Resume if WE caused the pause. A user-initiated
            ; pause during the alt-tab must NOT be auto-resumed.
            if (this._pausedByFocus && this._timer.IsPaused())
            {
                this._timer.Resume()
                try this._log.Info("Timer resumed (focus gained)", "FocusAutoPause")
            }
            this._pausedByFocus := false
            return
        }

        ; Anything else — silently ignored.
    }
}
