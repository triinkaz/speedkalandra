; ============================================================
; LoadingDetectionService — measures loading time between zones (Phase 9.2)
; ============================================================
;
; Port of the legacy loading_visual.ahk, in service-based architecture.
;
; FLOW:
;
;   1. ARM (start measurement)
;      Subscribe to Evt.AreaLevelChanged -> ArmFromAreaChange()
;      The log monitor publishes this event upon detecting `Generating
;      level X area Y with seed Z`. This is the loading `start`.
;      Preconditions: setting enabled + timer running + not already armed.
;
;   2. POLL (HUD scan)
;      SetTimer 25ms (configurable) calls Tick() while state=active.
;      Each Tick: scanner samples the PoE2 HUD.
;      - HUD visible -> END (publish Evt.LoadingMeasured, return to idle)
;      - HUD absent -> continues
;      - Time > maxMs -> END with source=timeout
;
;   3. END (publish event)
;      Publish Evt.LoadingMeasured with:
;        Map(
;          "durationMs", n,
;          "actIndex",   n,        ; from the snapshot on arm
;          "stepId",     "..",     ; idem
;          "fromZone",   "..",     ; zone when armed
;          "toZone",     "..",     ; current zone on end (may be the same)
;          "source",     "..",     ; "hud_returned_fast" | "scene_then_hud_return" | "timeout_no_hud_return" | etc
;          "score",      n,        ; scanner score
;          "anchor",     ".."      ; "hud_visible_life0_mana3_bar0" debug
;        )
;      App.ahk subscribes and (a) writes to loading.csv (b) injects into
;      the next split as transitionMs.
;
; SUPPRESSION:
;   SuppressForPanel() cancels the active loading (user opened a panel).
;   Useful to avoid a false positive when HUD disappears due to inventory.
;
; SCENE NOTIFICATION:
;   NotifyScene(mapName) is called by SyncEngine when it detects a new
;   SCENE. Acts as an "end preview" — marks sceneSeenTick but does not
;   end. The end only comes when HUD really returns. Reason: SCENE may
;   arrive before the loading screen disappears.
;
; HEADLESS:
;   In headless, Start() does not call a real SetTimer. Tick() can be
;   called manually in tests. Everything else works.

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

    ; Handler refs (fields to allow Unsubscribe in Stop)
    _handlerAreaLevelChanged := ""
    _handlerZoneChanged      := ""
    ; v17.15 (Bug #31): _handlerPanelKeyPressed removed —
    ; PanelKeyService disconnected in v17.2.

    ; Default constants
    static DEFAULT_POLL_MS := 25
    static DEFAULT_MIN_MS  := 250
    static DEFAULT_MAX_MS  := 90000

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

        ; Keep handler refs so that Stop() can Unsubscribe (inline
        ; fat-arrow closures create new refs on each call;
        ; see Section 17.32 / Section 18.5 of ARCHITECTURE.md).
        this._handlerAreaLevelChanged := (data) => this._OnAreaLevelChanged(data)
        this._handlerZoneChanged      := (data) => this._OnZoneChanged(data)

        ; Subscribe arm (AreaLevelChanged triggers ArmFromAreaChange)
        this._bus.Subscribe(Events.AreaLevelChanged, this._handlerAreaLevelChanged)

        ; Subscribe direct SCENE notification (eliminated the carrier
        ; pigeon in app.ahk: Turn 7).
        this._bus.Subscribe(Events.ZoneChanged, this._handlerZoneChanged)

        ; v17.15 (Bug #31): subscribe to Cmd.PanelKeyPressed removed —
        ; PanelKeyService disconnected in v17.2. SuppressForPanel is
        ; still called internally from _CancelActive.
    }

    ; ============================================================
    ; Lifecycle
    ; ============================================================

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

    ; ============================================================
    ; Dispose — tears down subscriptions. Idempotent.
    ;   Call when the service is no longer used (Stop+Start cycle
    ;   of the same app instance, or destruction in tests).
    ; ============================================================
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
        ; v17.15 (Bug #31): unsubscribe from Cmd.PanelKeyPressed removed.
    }

    IsEnabled()  => this._enabled
    IsActive()   => this._state = "active"
    GetStartTick() => this._startTick
    GetLastScore() => this._lastScore
    GetLastAnchor() => this._lastAnchor

    ; ============================================================
    ; Arm
    ; ============================================================

    ; ArmFromAreaChange — called via subscribe to Evt.AreaLevelChanged.
    ;   Preconditions:
    ;     - setting loadingVisualEnabled = true
    ;     - timer service active (running or paused doesn't matter,
    ;       but must have been started — parity with legacy)
    ;     - state = idle (second Generating during loading does not
    ;       restart)
    ;
    ; Returns true if armed, false otherwise.
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

    ; NotifyScene — SyncEngine can call when it detects SCENE during
    ;   an active loading. Marks sceneSeenTick but does not end. End
    ;   only comes when HUD returns.
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

    ; SuppressForPanel — user opened a panel; cancels the active
    ;   loading and ignores samples for the next 1500ms.
    SuppressForPanel(source := "panel")
    {
        if (this._state = "active")
            this._CancelActive(source)
        this._ignoreUntilTick := this._clock.NowMs() + 1500
    }

    ; ============================================================
    ; Tick — HUD poll
    ; ============================================================

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

    ; ============================================================
    ; End / Cancel
    ; ============================================================

    _End(source)
    {
        if (this._state != "active")
            return false

        durationMs := this._clock.NowMs() - this._startTick
        startAct   := this._startActIndex
        startStep  := this._startStepId
        startZone  := this._startZone

        this._ResetState()

        ; v0.1.2 (Bug #5): BEFORE the filter was `< minMs || > maxMs`.
        ; The `> maxMs` branch caused a silent timeout: when Tick
        ; detects loading > maxMs it calls _End("timeout_no_hud_return"),
        ; and _End discarded the event BY DEFINITION (durationMs > maxMs
        ; was the condition that triggered the timeout). Result: ALL
        ; loadings that exceeded 90s became invisible in the stats —
        ; slow PCs had runs with substantially underestimated loading time.
        ;
        ; Fix: keep only the `< minMs` filter (discards very short HUD
        ; fluctuations, scanner noise). The ceiling is controlled by
        ; Tick that fires `timeout_no_hud_return` when it hits maxMs;
        ; when that path runs, we want to publish the event with the
        ; REAL duration (which will be >= maxMs by construction) so
        ; downstream (LoadingTotalsService, RunStatsRecorder) integrates
        ; the correct time into the run's sum.
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

    ; ============================================================
    ; Bus subscribers
    ; ============================================================

    _OnAreaLevelChanged(data)
    {
        if !IsObject(data)
            return
        areaLevel := data.Has("areaLevel") ? data["areaLevel"] : 0
        areaCode  := data.Has("areaCode")  ? data["areaCode"]  : ""
        this.ArmFromAreaChange(areaLevel, areaCode)
    }

    ; SyncEngine receives ZoneChanged and updates the physical zone;
    ; here we reuse the same event to signal that a SCENE arrived
    ; (proxy for loading end). The real end only comes when HUD returns.
    _OnZoneChanged(data)
    {
        if !IsObject(data) || !data.Has("zoneName")
            return
        zone := data["zoneName"]
        if (zone = "")
            return
        this.NotifyScene(zone)
    }

    ; v17.15 (Bug #31): _OnPanelKeyPressed handler removed. PanelKeyService
    ; was disconnected in v17.2 and there is no publisher for
    ; Cmd.PanelKeyPressed. SuppressForPanel above is still usable
    ; via _CancelActive.

    ; ============================================================
    ; Snapshot helpers
    ; ============================================================

    _SnapshotZone()
    {
        try
            return String(this._zoneProvider.Call())
        catch as ex
        {
            ; v17.15 (Bug #8): a snapshot failure is diagnostic, not
            ; flow-breaking. Returns a safe fallback but records for
            ; debug. The service has no logger, so OutputDebug.
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
            ; v17.15 (Bug #8): same as _SnapshotZone
            OutputDebug("LoadingDetectionService._SnapshotStep failed: " ex.Message)
        }
        return Map("actIndex", 0, "stepId", "")
    }

    ; ============================================================
    ; Settings accessors (small indirection for clamp + defaults)
    ; ============================================================

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

    ; ============================================================
    ; Default window provider (in prod uses PoE2's WinGetPos)
    ; ============================================================

    static _DefaultWindowProvider()
    {
        try
        {
            hwnd := WinExist("Path of Exile 2")
            if !hwnd
                return ""
            try
            {
                if (WinGetMinMax("Path of Exile 2") = -1)
                    return ""    ; minimized, not sampleable
            }
            x := 0, y := 0, w := 0, h := 0
            try WinGetPos(&x, &y, &w, &h, "Path of Exile 2")
            if (w <= 0 || h <= 0)
                return ""
            return Map("x", x, "y", y, "w", w, "h", h)
        }
        return ""
    }
}
