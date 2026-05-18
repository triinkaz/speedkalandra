; LoadingDetectionService — measures loading time between zones by
; watching the PoE2 HUD with the pixel scanner.
;
; Flow:
;   Arm    AreaLevelChanged (the "Generating level X area Y" log
;          line) starts a measurement. Preconditions: setting on,
;          run timer active, not already armed.
;   Poll   SetTimer at ~25ms calls Tick() while state=active. Tick
;          samples the HUD: visible → end; absent → continue;
;          duration > maxMs → end with source=timeout.
;   End    Publishes Evt.LoadingMeasured with from/to zone, duration,
;          source, and scanner score for debug.
;
; NotifyScene(name) is called by SyncEngine on a new SCENE. It only
; marks sceneSeenTick — the end is gated on the HUD actually returning,
; because SCENE often fires before the loading screen disappears.
;
; SuppressForPanel cancels an in-flight measurement (user opened an
; inventory panel) and silences sampling for 1.5s.
;
; Headless: Start() doesn't arm a real SetTimer; Tick() is called
; manually by tests.

class LoadingDetectionService
{
    _bus       := ""
    _clock     := ""
    _scanner   := ""
    _settings  := ""
    _timerSvc  := ""

    ; State
    _state := "idle"     ; "idle" | "active"
    _startTick := 0
    _startActIndex := 0
    _startStepId := ""
    _startZone := ""
    _ignoreUntilTick := 0
    _sceneSeenTick := 0
    _lastScore := 0
    _lastAnchor := ""

    ; Snapshot helpers (callers pass these on arm)
    _zoneProvider := ""    ; () -> string (current zone)
    _stepProvider := ""    ; () -> Map("actIndex", n, "stepId", "..")
    _windowProvider := ""  ; () -> Map("x",n,"y",n,"w",n,"h",n) or ""

    ; Lifecycle
    _enabled := false
    _tickFn := ""
    _headless := false

    ; Handler refs (fields, so Stop can Unsubscribe — inline
    ; fat-arrow closures make a new ref each call).
    _handlerAreaLevelChanged := ""
    _handlerZoneChanged      := ""

    static DEFAULT_POLL_MS := 25
    static DEFAULT_MIN_MS  := 250
    static DEFAULT_MAX_MS  := 90000

    ; Known PoE2 executables. _DefaultWindowProvider locates the
    ; game window by ahk_exe (exact match) rather than by title
    ; substring, which would match Chrome on the wiki or Discord
    ; channels named after the game. Keep this list in sync with
    ; FocusAutoPauseService.GAME_EXECUTABLES — a future build that
    ; ships a new exe must update both at once or one service
    ; silently breaks.
    static GAME_EXECUTABLES := [
        "PathOfExile2Steam.exe",
        "PathOfExile2_x64.exe",
        "PathOfExile2.exe",
        "PathOfExile_x64Steam.exe",
        "PathOfExileSteam.exe",
        "PathOfExile_x64.exe",
        "PathOfExile.exe"
    ]

    __New(bus, clock, scanner, cfg, timerSvc, zoneProvider, stepProvider, windowProvider := "", headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("LoadingDetectionService: 'bus' must be EventBus")
        if !IsObject(clock) || !clock.HasMethod("NowMs")
            throw TypeError("LoadingDetectionService: 'clock' must have NowMs()")
        if !(scanner is HudPixelScanner)
            throw TypeError("LoadingDetectionService: 'scanner' must be HudPixelScanner")
        if !(cfg is AppSettings)
            throw TypeError("LoadingDetectionService: 'cfg' must be AppSettings")
        if !(timerSvc is TimerService)
            throw TypeError("LoadingDetectionService: 'timerSvc' must be TimerService")
        if !IsObject(zoneProvider)
            throw TypeError("LoadingDetectionService: 'zoneProvider' must be callable")
        if !IsObject(stepProvider)
            throw TypeError("LoadingDetectionService: 'stepProvider' must be callable")

        this._bus            := bus
        this._clock          := clock
        this._scanner        := scanner
        this._settings       := cfg
        this._timerSvc       := timerSvc
        this._zoneProvider   := zoneProvider
        this._stepProvider   := stepProvider
        this._windowProvider := windowProvider != "" ? windowProvider : (() => LoadingDetectionService._DefaultWindowProvider())
        this._headless       := !!headless

        this._tickFn := this.Tick.Bind(this)

        ; Handlers kept as fields so Stop()/Dispose() can Unsubscribe.
        ; Inline fat-arrow expressions return a fresh ref every call,
        ; so subscribing one and unsubscribing another would silently
        ; leak.
        this._handlerAreaLevelChanged := (data) => this._OnAreaLevelChanged(data)
        this._handlerZoneChanged      := (data) => this._OnZoneChanged(data)

        this._bus.Subscribe(Events.AreaLevelChanged, this._handlerAreaLevelChanged)
        ; ZoneChanged doubles as the SCENE notification (no separate
        ; carrier event in the bus).
        this._bus.Subscribe(Events.ZoneChanged, this._handlerZoneChanged)
    }

    ; ---- Lifecycle ----

    Start()
    {
        if this._enabled
            return
        this._enabled := true
        if !this._headless
        {
            try SetTimer(this._tickFn, this._GetPollMs())
        }
    }

    Stop()
    {
        if !this._enabled
            return
        this._enabled := false
        this._CancelActive("service_stop")
        if !this._headless
        {
            try SetTimer(this._tickFn, 0)
        }
    }

    ; Tears down subscriptions. Idempotent.
    Dispose()
    {
        if (this._handlerAreaLevelChanged != "")
        {
            this._bus.Unsubscribe(Events.AreaLevelChanged, this._handlerAreaLevelChanged)
            this._handlerAreaLevelChanged := ""
        }
        if (this._handlerZoneChanged != "")
        {
            this._bus.Unsubscribe(Events.ZoneChanged, this._handlerZoneChanged)
            this._handlerZoneChanged := ""
        }
    }

    IsEnabled()  => this._enabled
    IsActive()   => this._state = "active"
    GetStartTick() => this._startTick
    GetLastScore() => this._lastScore
    GetLastAnchor() => this._lastAnchor

    ; ---- Arm ----

    ; Starts a measurement. Preconditions:
    ;   - cfg.loadingVisualEnabled
    ;   - timer service active (running or paused both fine, must
    ;     have been started)
    ;   - state = idle (a second AreaLevelChanged during an active
    ;     measurement does not restart it)
    ; Returns true on arm, false otherwise.
    ArmFromAreaChange(areaLevel := 0, areaCode := "")
    {
        if !this._settings.loadingVisualEnabled
            return false
        if !this._timerSvc.IsActive()
            return false
        if (this._state = "active")
            return false

        snapshot := this._SnapshotStep()
        zone := this._SnapshotZone()

        this._state           := "active"
        this._startTick       := this._clock.NowMs()
        this._startActIndex   := snapshot["actIndex"]
        this._startStepId     := snapshot["stepId"]
        this._startZone       := zone
        this._ignoreUntilTick := this._startTick + 150
        this._sceneSeenTick   := 0
        this._lastScore       := 70
        this._lastAnchor      := "client_generating:" areaCode
        return true
    }

    ; SyncEngine can call this when it sees SCENE during an active
    ; measurement. Only marks sceneSeenTick — the actual end is gated
    ; on the HUD returning.
    NotifyScene(mapName := "")
    {
        if (this._state != "active")
            return false
        durationMs := this._clock.NowMs() - this._startTick
        if (durationMs < this._GetMinMs())
            return false
        this._sceneSeenTick := this._clock.NowMs()
        this._lastAnchor    := "scene:" mapName
        return true
    }

    ; Cancels an in-flight measurement (user opened an inventory
    ; panel) and silences sampling for 1.5 s.
    SuppressForPanel(source := "panel")
    {
        if (this._state = "active")
            this._CancelActive(source)
        this._ignoreUntilTick := this._clock.NowMs() + 1500
    }

    ; ---- Tick (HUD poll) ----

    Tick()
    {
        if (this._state != "active")
            return

        now := this._clock.NowMs()

        ; Timeout: loading running for more than maxMs
        if ((now - this._startTick) > this._GetMaxMs())
        {
            this._End("timeout_no_hud_return")
            return
        }

        ; Timer stopped: cancel
        if !this._timerSvc.IsActive()
        {
            this._CancelActive("timer_not_running")
            return
        }

        ; PoE2 window not sampleable (no focus, minimized)
        winInfo := this._windowProvider.Call()
        if !IsObject(winInfo)
            return    ; keeps open, waits for HUD to return

        ; Initial post-arm ignore period
        if (this._ignoreUntilTick > 0 && now < this._ignoreUntilTick)
            return

        ; Scan
        result := this._scanner.Scan(winInfo["x"], winInfo["y"], winInfo["w"], winInfo["h"])

        ; Anchor for debug
        anchor := result["visible"]
            ? "hud_visible_life" result["lifeHits"] "_mana" result["manaHits"] "_bar" result["hotbarHits"]
            : "hud_absent_life" result["lifeHits"] "_mana" result["manaHits"] "_bar" result["hotbarHits"]
        this._lastAnchor := anchor
        this._lastScore  := result["visible"] ? 0 : 70

        if !result["visible"]
            return    ; HUD still absent, continue poll

        ; HUD returned → end
        endSource := this._sceneSeenTick > 0 ? "scene_then_hud_return" : "hud_returned_fast"
        this._End(endSource)
    }

    ; ---- End / Cancel ----

    _End(source)
    {
        if (this._state != "active")
            return false

        durationMs := this._clock.NowMs() - this._startTick
        startAct   := this._startActIndex
        startStep  := this._startStepId
        startZone  := this._startZone

        this._ResetState()

        ; Discard only very short scans (HUD flicker, scanner noise);
        ; never discard the high end. A previous version filtered
        ; `> maxMs` here as well, which made `timeout_no_hud_return`
        ; events drop themselves — every loading over 90 s simply
        ; vanished from the stats, and slow PCs ended up with runs
        ; whose total loading time was substantially undercounted.
        ; Tick already caps the duration via its timeout branch; this
        ; method just has to publish whatever real duration came in.
        if (durationMs < this._GetMinMs())
            return false    ; discard very short scans (HUD flicker)

        toZone := this._SnapshotZone()
        this._bus.Publish(Events.LoadingMeasured, Map(
            "durationMs", durationMs,
            "actIndex",   startAct,
            "stepId",     startStep,
            "fromZone",   startZone,
            "toZone",     toZone,
            "source",     source,
            "score",      this._lastScore,
            "anchor",     this._lastAnchor
        ))
        return true
    }

    _CancelActive(source)
    {
        if (this._state != "active")
            return
        this._ResetState()
        this._ignoreUntilTick := this._clock.NowMs() + 500
    }

    _ResetState()
    {
        this._state         := "idle"
        this._startTick     := 0
        this._sceneSeenTick := 0
    }

    ; ---- Bus subscribers ----

    _OnAreaLevelChanged(data)
    {
        if !IsObject(data)
            return
        areaLevel := data.Has("areaLevel") ? data["areaLevel"] : 0
        areaCode  := data.Has("areaCode")  ? data["areaCode"]  : ""
        this.ArmFromAreaChange(areaLevel, areaCode)
    }

    ; ZoneChanged doubles as the SCENE notification — the real end
    ; still waits for the HUD to return.
    _OnZoneChanged(data)
    {
        if !IsObject(data) || !data.Has("zoneName")
            return
        zone := data["zoneName"]
        if (zone = "")
            return
        this.NotifyScene(zone)
    }

    ; ---- Snapshot helpers ----

    _SnapshotZone()
    {
        try
            return String(this._zoneProvider.Call())
        catch as ex
        {
            ; Snapshot failure is diagnostic, not flow-breaking. The
            ; service has no injected logger, so OutputDebug.
            OutputDebug("LoadingDetectionService._SnapshotZone failed: " ex.Message)
        }
        return ""
    }

    _SnapshotStep()
    {
        try
        {
            r := this._stepProvider.Call()
            if IsObject(r)
                return Map(
                    "actIndex", r.Has("actIndex") ? r["actIndex"] : 0,
                    "stepId",   r.Has("stepId")   ? r["stepId"]   : ""
                )
        }
        catch as ex
        {
            OutputDebug("LoadingDetectionService._SnapshotStep failed: " ex.Message)
        }
        return Map("actIndex", 0, "stepId", "")
    }

    ; ---- Settings accessors (clamp + defaults) ----

    _GetPollMs()
    {
        v := this._settings.loadingVisualPollMs
        return v >= 10 ? Integer(v) : LoadingDetectionService.DEFAULT_POLL_MS
    }

    _GetMinMs()
    {
        v := this._settings.loadingVisualMinMs
        return v >= 0 ? Integer(v) : LoadingDetectionService.DEFAULT_MIN_MS
    }

    _GetMaxMs()
    {
        v := this._settings.loadingVisualMaxMs
        return v > 0 ? Integer(v) : LoadingDetectionService.DEFAULT_MAX_MS
    }

    ; Locates the PoE2 game window by ahk_exe (exact match on the
    ; process name) and locks all follow-up queries to its HWND via
    ; ahk_id. Using a title substring instead would also match
    ; windows like "PoE2 Wiki - Chrome" or a Discord channel named
    ; after the game; the HUD scanner would then read garbage pixels
    ; from the wrong window. Locking by HWND between WinGetMinMax
    ; and WinGetPos also prevents another window from hijacking the
    ; readout in the race window between those two calls.
    static _DefaultWindowProvider()
    {
        try
        {
            hwnd := 0
            for _, exeName in LoadingDetectionService.GAME_EXECUTABLES
            {
                hwnd := WinExist("ahk_exe " . exeName)
                if hwnd
                    break
            }
            if !hwnd
                return ""
            winSpec := "ahk_id " . hwnd
            try
            {
                if (WinGetMinMax(winSpec) = -1)
                    return ""    ; minimized, not sampleable
            }
            x := 0, y := 0, w := 0, h := 0
            try WinGetPos(&x, &y, &w, &h, winSpec)
            if (w <= 0 || h <= 0)
                return ""
            return Map("x", x, "y", y, "w", w, "h", h)
        }
        return ""
    }
}
