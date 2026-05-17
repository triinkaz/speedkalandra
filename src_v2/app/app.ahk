; ============================================================
; SpeedKalandraApp - composition root (Wave 7, v17.10)
; ============================================================
;
; POST-DEMOLITION VERSION: focused on pure speedrun.
;
; RUN PERSISTENCE (crash recovery + perf):
;   4 pieces are persisted to the INI:
;     1. [RunState].(RunId,StartedAt,Status) — metadata (transitions only)
;     2. [RunState].RunBaseMs                — timer (5s periodic tick)
;     3. [RunState].LoadingTotalMs           — accumulated loading
;     4. [RunZoneTotals]                     — Map<zone, ms>
;
;   CRITICAL OPTIMIZATION (v14.1): _PersistRunData uses a hash cache to
;   skip unnecessary IniWrites. Previously did 25 IniWrites every 5s
;   blocking the thread for 1-2s — caused 6s lag in pause-detection.
;
; RUN HISTORY (v17.6 + v17.10):
;   Every run is saved to data/runs/{runId}.ini by RunHistoryRepository.
;   Save happens on two events:
;     - Evt.RunCompleted (Ctrl+Alt+F) — always saved
;     - Evt.RunCancelled (Ctrl+Alt+N -> CancelRun, or Ctrl+Alt+R) —
;       saved only if runMs >= MIN_CANCELLED_SAVE_MS (3min). Avoids
;       garbage from quick aborts / tests.
;
;   SUBSCRIBE ORDER (v17.10):
;     EventBus calls subscribers in FIFO order. RunStatsRecorder and
;     ZoneTrackingService both clear their internal state on RunCancelled.
;     If we subscribed our save handler in Start() (after them), the
;     snapshot would already come back empty.
;
;     Solution: we subscribe the handlers in __New, RIGHT AFTER creating
;     this.runHistory and BEFORE instantiating zoneTracker and statsRecorder.
;     That way our handler is called FIRST when RunCancelled fires, with
;     state intact.
;
;     The arrow function captures `this` by scope (not by value); when
;     the handler is invoked, this.statsRecorder etc. already exist.
;
; AUTO-MICRO VIA PANEL KEYS (REMOVED in v17.2):
;   PanelKeyService DISCONNECTED. MICRO only activates via Ctrl+F9.
;
; GAME PAUSE DETECTION (REMOVED in v17.5):
;   GamePauseDetectionService DISCONNECTED (false positives).


class SpeedKalandraApp
{
    ; Cancelled runs shorter than this are NOT saved to history
    ; (avoids test/quick-abort garbage). In milliseconds.
    static MIN_CANCELLED_SAVE_MS := 180000   ; 3min

    _cfg          := ""
    _settingsRepo := ""
    log    := ""
    bus    := ""
    clock  := ""

    zonesCatalog := ""

    timer            := ""
    runState         := ""
    runService       := ""
    xpService        := ""
    logMonitor       := ""
    zoneTracker      := ""
    loadingDetection := ""
    loadingTotals    := ""
    personalBest     := ""
    actCheckpoints   := ""   ; v17.13
    statsRecorder    := ""
    plotBuilder      := ""
    autoFinalize     := ""
    autoStart        := ""

    runHistory      := ""    ; RunHistoryRepository — v17.6

    overlayMode     := ""
    overlayApplier  := ""
    focusAutoPause  := ""
    hudScanner      := ""
    hotkeyService   := ""
    overlayInter    := ""
    tickEmitter     := ""
    eventTracer     := ""    ; v0.1.4 — EventTraceLogger (logs every Publish)

    compactWidget := ""
    microWidget   := ""
    steveWidget   := ""    ; v17.14
    widgets       := ""

    settingsDialog     := ""
    plotDialog         := ""
    runHistoryDialog   := ""
    exportDialog       := ""    ; v0.1.0 — export/import feature
    importPreviewDialog := ""   ; v0.1.0 — export/import feature

    runExportService   := ""    ; v0.1.0 — export/import feature
    runImportService   := ""    ; v0.1.0 — export/import feature

    _started   := false
    _persistFn := ""
    _logMonitorTimer  := ""
    _runPersistTimer  := ""
    _headless         := false    ; v17.13 — controls whether confirmation MsgBoxes are shown

    _lastSavedLoadingTotal := -1
    _lastSavedZoneTotalsHash := ""

    ; v17.15 (Bug #9): flag to reset level only on the FIRST entry
    ; into Riverbank in the run. Previously, any re-entry (death
    ; respawn, portal, party invite) silently reset characterLevel to 1.
    _riverbankSeenInRun := false

    ; v17.14 — "Undo last save" (F1): runId of the most recent save
    ; that can still be undone. Cleared after 60s by _undoTimerFn
    ; or when undo is executed.
    _lastSavedRunId := ""
    _undoTimerFn    := ""

    __New(config := "")
    {
        cfgMap := IsObject(config) ? config : Map()

        scriptDir := A_ScriptDir
        iniPath := cfgMap.Has("iniPath") ? cfgMap["iniPath"]
                                          : (scriptDir "\speedkalandra.ini")
        zonesCsvPath := cfgMap.Has("zonesCsvPath") ? cfgMap["zonesCsvPath"]
                                                    : (scriptDir "\data\zones.csv")
        logPath := cfgMap.Has("logPath") ? cfgMap["logPath"]
                                          : (scriptDir "\data\speedkalandra.log")
        runHistoryDir := cfgMap.Has("runHistoryDir") ? cfgMap["runHistoryDir"]
                                                      : (scriptDir "\data\runs")
        pbPath := cfgMap.Has("personalBestPath") ? cfgMap["personalBestPath"]
                                                  : (scriptDir "\data\personal_bests.ini")

        headless := cfgMap.Has("headless") ? !!cfgMap["headless"] : false
        this._headless := headless

        this.log   := LogService(logPath, "INFO", headless ? 1 : 32)
        this.bus   := EventBus(this.log)
        ; v0.1.4: register the event-trace interceptor BEFORE any service
        ; subscribes — guarantees the trace captures every Publish from
        ; the moment the app starts wiring. Start() is called below in
        ; Start(), not here; construction only prepares the object.
        this.eventTracer := EventTraceLogger(this.bus, this.log)
        ; v0.1.1: clock injectable via cfgMap so integration tests can use FakeClock.
        ; Default is RealClock (NowMs = A_TickCount).
        this.clock := cfgMap.Has("clock") ? cfgMap["clock"] : RealClock()

        ini := IniFile(iniPath)
        this._settingsRepo := SettingsRepository(ini)
        this._cfg := this._settingsRepo.Load()

        this.zonesCatalog := ZonesCatalog(zonesCsvPath)
        this.log.Info("Zones catalog loaded: " this.zonesCatalog.Count() " zones", "App")

        ; Run history (v17.6)
        this.runHistory := RunHistoryRepository(runHistoryDir)

        ; Personal bests (v17.13) — loaded from the INI in the service
        ; constructor (via repo.Load). Updated in _SaveRunSnapshot when
        ; reason="completed".
        this.personalBest := PersonalBestService(PersonalBestRepository(pbPath))
        if this.personalBest.HasRunPb()
        {
            try this.log.Info("Run PB loaded: "
                . this.personalBest.GetRunPbMs() . " ms ("
                . this.personalBest.GetRunPbRunId() . ")", "App")
        }

        ; (ActCheckpointTracker is instantiated FURTHER DOWN, after
        ; this.timer is created — it depends on TimerService.GetRunMs.)

        ; ============================================================
        ; v17.10: HISTORY SAVE handlers — subscribed NOW, before the
        ; services that clear state on RunCancelled (statsRecorder and
        ; zoneTracker further down). EventBus FIFO order ensures our
        ; handlers are called first, with the snapshot intact.
        ; ============================================================
        this.bus.Subscribe(Events.RunCompleted,
            (data) => this._SaveRunSnapshot("completed"))
        this.bus.Subscribe(Events.RunCancelled,
            (data) => this._SaveRunSnapshot("cancelled"))

        this.runState   := RunStateRepository(ini)
        this.timer      := TimerService(this.clock, this.bus)
        this.runService := RunService(this.clock, this.bus, this.timer, this.runState)

        ; Act checkpoint tracker (v17.13) — tracks total run time at
        ; each act transition. Feeds per-act PB on finalize. Depends on
        ; this.timer (for GetRunMs), so instantiated HERE right after
        ; the timer.
        this.actCheckpoints := ActCheckpointTracker(this.bus, this.timer)

        hydratedState := this.runState.Load()
        try this.runService.Hydrate(hydratedState)

        ; v0.1.4: pass the LogService so transitions (focus/process) are
        ; surfaced in speedkalandra.log for diagnostics.
        this.focusAutoPause := FocusAutoPauseService(this.bus, this.timer, this._cfg, this.log)

        ; GamePauseDetection DISCONNECTED in v17.5

        this.hotkeyService := HotkeyService(this.bus, headless)
        this.hotkeyService.Hydrate(this._cfg.hotkeys)

        ; PanelKeys DISCONNECTED in v17.2

        this.overlayMode := OverlayModeService(this.bus, this._cfg)
        this.overlayMode.Hydrate()
        this.overlayInter := OverlayInteractionService(this.bus, headless)

        this.xpService := XpService()
        this.xpService.Hydrate(
            this._cfg.characterName,
            this._cfg.characterClass,
            this._cfg.characterLevel,
            this._cfg.currentAreaLevel,
            this._cfg.currentAreaCode
        )

        this.logMonitor := LogMonitorService(this.clock, this.bus, this.log)
        this.logMonitor.Configure(this._cfg.logFile)
        ; v17.15 (Bug #2): hydrates the character name for the
        ; DeathDetected filter. Without this, real-time deaths between
        ; boot and the first CharacterLevelUp would not be counted.
        this.logMonitor.SetCharacterName(this._cfg.characterName)

        ; zoneTracker subscribes to RunCancelled here — AFTER our save handler
        this.zoneTracker := ZoneTrackingService(this.bus, this.clock, this.zonesCatalog)

        try
        {
            zoneTotals := this.runState.LoadZoneTotals()
            this.zoneTracker.Hydrate(zoneTotals)
            if (hydratedState is RunState && hydratedState.IsRunning())
            {
                this.zoneTracker.SetRunActive(true)
                this.log.Info("Zone tracker hydrated: " . zoneTotals.Count . " zones with accumulated time (run in progress)", "App")
            }
            this._lastSavedZoneTotalsHash := this._ComputeTotalsHash(zoneTotals)
        }
        catch as ex
        {
            this.log.Warn("Failed to hydrate zone totals: " . ex.Message
                . " | What: " . (ex.HasOwnProp("What") ? ex.What : "?")
                . " | Line: " . (ex.HasOwnProp("Line") ? ex.Line : "?")
                . " | File: " . (ex.HasOwnProp("File") ? ex.File : "?"), "App")
        }

        this.hudScanner := HudPixelScanner((x, y) => PixelGetColor(x, y, "RGB"))
        zoneProvider := () => this.zoneTracker.GetActiveZone()
        stepProvider := () => Map("actIndex", this._DeduceCurrentAct(), "stepId", "")
        this.loadingDetection := LoadingDetectionService(
            this.bus, this.clock, this.hudScanner, this._cfg, this.timer,
            zoneProvider, stepProvider, "", headless
        )
        this.loadingTotals := LoadingTotalsService(this.bus)

        try
        {
            if (hydratedState is RunState && hydratedState.IsActive())
            {
                loadingMs := this.runState.LoadLoadingTotal()
                this.loadingTotals.Hydrate(loadingMs)
                if (loadingMs > 0)
                    this.log.Info("Loading totals hydrated: " . loadingMs . " ms accumulated", "App")
                this._lastSavedLoadingTotal := loadingMs
            }
        }
        catch as ex
        {
            this.log.Warn("Failed to hydrate loading totals: " . ex.Message
                . " | What: " . (ex.HasOwnProp("What") ? ex.What : "?")
                . " | Line: " . (ex.HasOwnProp("Line") ? ex.Line : "?")
                . " | File: " . (ex.HasOwnProp("File") ? ex.File : "?"), "App")
        }

        ; statsRecorder subscribes to RunCancelled here — AFTER our save handler
        this.statsRecorder := RunStatsRecorder(this.bus, this.clock)
        this.plotBuilder   := RunStatsPlotBuilder(this.zonesCatalog, this._cfg)

        this.autoFinalize := AutoFinalizeService(this.bus, this._cfg)
        ; v17.15 (Bug #4): passes runService so that AutoStart knows
        ; whether there is already a hydrated active run and does not
        ; wipe it with the next log line matching autoStartRegex.
        this.autoStart := AutoStartService(this.bus, this._cfg, this.runService)

        compactPos := this._GetWidgetPos("compactLayout", 10, 1.5)
        microPos   := this._GetWidgetPos("microLayout",   75, 92)
        stevePos   := this._GetWidgetPos("steveLayout",   10, 1.5)   ; v17.14

        this._persistFn := () => this._PersistSettings()

        this.compactWidget := CompactLayoutWidget(
            this.bus, compactPos, this._persistFn,
            this.timer, this.zoneTracker, this.xpService,
            this.zonesCatalog, this.loadingTotals, this._cfg,
            this.personalBest
        )

        this.microWidget := MicroLayoutWidget(
            this.bus, microPos, this._persistFn,
            this.timer, this.xpService
        )

        this.steveWidget := SteveLayoutWidget(
            this.bus, stevePos, this._persistFn,
            this.timer, this.zoneTracker, this.xpService,
            this.zonesCatalog, this.loadingTotals, this.personalBest
        )

        this.widgets := Map()
        this.widgets["compactLayout"] := this.compactWidget
        this.widgets["microLayout"]   := this.microWidget
        this.widgets["steveLayout"]   := this.steveWidget

        this.overlayApplier := OverlayModeApplier(this.bus, this.widgets)
        this.tickEmitter := AppTickEmitter(this.bus, 300)

        this.settingsDialog := SettingsDialog(this.bus, this._settingsRepo, this._cfg, headless)
        this.plotDialog := RunStatsPlotDialog(
            this.bus, this.plotBuilder, this.statsRecorder,
            this.zoneTracker, this.timer, this.runHistory, headless
        )
        this.runHistoryDialog := RunHistoryDialog(this.bus, this.runHistory, this.plotDialog, this.personalBest, headless)

        ; v0.1.0 — Export/import feature
        this.runExportService := RunExportService(this.bus, this.runHistory, this.personalBest)
        this.runImportService := RunImportService(this.bus, this.runHistory, this.personalBest)
        this.exportDialog := ExportOptionsDialog(this.bus, this.runExportService, headless)
        this.importPreviewDialog := ImportPreviewDialog(this.bus, this.runImportService, headless)

        this._WireEventHandlers()
    }

    Start()
    {
        if this._started
            return
        this._started := true

        ; v17.15.2: shows disclaimer on boot if not yet acknowledged.
        ; Modal — blocks the rest of Start() until the user dismisses it.
        this._ShowDisclaimerIfNeeded()

        ; v0.1.3: Client.txt setup on first run. Blocks the boot until
        ; the user configures a valid path (or cancels, which closes
        ; the app).
        this._PromptLogFileSetupIfNeeded()

        ; v17.14 — F4: if there is a hydrated active run, ask the user
        ; what to do before bringing up the widgets/hotkeys. Resolves
        ; the ambiguity of a "dangling run" on boot.
        this._PromptHydratedRun()

        this.bus.Subscribe(Events.CharacterLevelUp,
            (data) => this._OnCharacterLevelUp(data))
        this.bus.Subscribe(Events.AreaLevelChanged,
            (data) => this._OnAreaLevelChanged(data))

        this.bus.Subscribe(Events.ZoneEntered,
            (data) => this._OnZoneEnteredForLevel(data))

        this.bus.Subscribe(Events.RunReset,
            (data) => this._OnRunEndedClearZones(data))
        this.bus.Subscribe(Events.RunCancelled,
            (data) => this._OnRunEndedClearZones(data))

        ; NOTE: the subscribes for RunCompleted/RunCancelled that CALL
        ; _SaveRunSnapshot were already done in __New (before the
        ; services that clear state). Do not re-subscribe here.

        if (this._cfg.logFile != "" && FileExist(this._cfg.logFile))
        {
            this.logMonitor.Start(true)
            this._logMonitorTimer := () => this.logMonitor.Tick()
            try SetTimer(this._logMonitorTimer, 250)
            this.log.Info("Log monitor started: " this._cfg.logFile, "App")
        }
        else if (this._cfg.logFile = "")
        {
            ; v17.15.2: fresh install — empty logFile is expected. INFO
            ; instead of WARN so it does not trigger the "boot with
            ; warnings" TrayTip on the user's first boot.
            this.log.Info("Log file not configured. Configure the Client.txt path in Settings (tray menu) to enable zone detection.", "App")
        }
        else
        {
            ; logFile configured but missing — user got the path wrong.
            ; Keep WARN to notify.
            this.log.Warn("Log file configured but file does not exist: " this._cfg.logFile, "App")
        }

        this.focusAutoPause.Start()
        this.hotkeyService.Start()
        this.overlayInter.Start()

        if this._cfg.loadingVisualEnabled
            this.loadingDetection.Start()

        this.compactWidget.Show()
        this.microWidget.Show()
        this.steveWidget.Show()

        this.overlayApplier.ApplyMode(this.overlayMode.GetMode())

        this.tickEmitter.Start()

        ; v0.1.4: start the event-trace interceptor AFTER all wiring is
        ; done. Volume will be high (every Tick at ~300ms plus all
        ; gameplay events) — LogService size-based rotation (5MB) and
        ; daily rotation handle file growth.
        try this.eventTracer.Start()

        this._runPersistTimer := () => this._PersistRunData()
        try SetTimer(this._runPersistTimer, 5000)

        this.bus.Publish(Events.AppStarted, Map())
        this.log.Info("SpeedKalandra started", "App")

        ; ============================================================
        ; Surface boot warnings/errors (v17.15).
        ;
        ; LogService counts WARN/ERROR regardless of minLevel. If the
        ; boot logged anything, emit a TrayTip so the user knows —
        ; without this, warnings stayed silent in the log file (case
        ; of the "Map has no method Count" bug that ran for 3 days
        ; without anyone noticing).
        ;
        ; Resets counters after surfacing: runtime warnings don't
        ; accumulate in the next boot prompt.
        ; ============================================================
        warnCount := this.log.GetWarnCount()
        errorCount := this.log.GetErrorCount()
        if (!this._headless && (warnCount > 0 || errorCount > 0))
        {
            label := errorCount > 0
                ? "Boot with errors (" warnCount " warn, " errorCount " error)"
                : "Boot with warnings (" warnCount " warn)"
            try TrayTip("SpeedKalandra",
                label . "`nSee data\speedkalandra.log for details.",
                "Iconi")
        }
        try this.log.ResetCounts()
    }

    Stop()
    {
        if !this._started
            return
        this._started := false

        this.bus.Publish(Events.AppStopping, Map())

        if (this._logMonitorTimer != "")
            try SetTimer(this._logMonitorTimer, 0)
        if (this._runPersistTimer != "")
            try SetTimer(this._runPersistTimer, 0)

        try this.tickEmitter.Stop()
        try this.eventTracer.Stop()
        try this.loadingDetection.Stop()
        try this.overlayInter.Stop()
        try this.hotkeyService.Stop()
        try this.focusAutoPause.Stop()
        try this.logMonitor.Stop()

        try this.compactWidget.Hide()
        try this.microWidget.Hide()
        try this.steveWidget.Hide()

        try this._PersistSettings()
        try this._PersistRunDataFull()
        try this.log.Flush()
    }

    ToggleOverlay()
    {
        mode := this.overlayMode.GetMode()
        if (mode = OverlayModes.MICRO)
        {
            if this.microWidget.IsVisible()
                this.microWidget.Hide()
            else
                this.microWidget.Show()
        }
        else if (mode = OverlayModes.STEVE)
        {
            if this.steveWidget.IsVisible()
                this.steveWidget.Hide()
            else
                this.steveWidget.Show()
        }
        else
        {
            if this.compactWidget.IsVisible()
                this.compactWidget.Hide()
            else
                this.compactWidget.Show()
        }
    }

    HandleTimerToggle()
    {
        if this.runService.IsActive()
            this.timer.Toggle()
        else
            this.runService.NewRun()
    }

    _WireEventHandlers()
    {
        this.bus.Subscribe(Commands.ToggleOverlayRequested,
            (data) => this.ToggleOverlay())

        this.bus.Subscribe(Commands.TimerToggleRequested,
            (data) => this.HandleTimerToggle())

        this.bus.Subscribe(Events.RunStarted,
            (data) => this._OnRunStartedForXp(data))

        ; v17.13 — reset PBs via tray menu
        this.bus.Subscribe(Commands.ResetPersonalBestsRequested,
            (data) => this._OnResetPersonalBestsRequested())

        ; v0.1.0 — run export (published by RunHistoryDialog buttons)
        this.bus.Subscribe(Commands.ExportRunsRequested,
            (data) => this._OnExportRunsRequested(data))

        ; v0.1.0 — run import (published by the Import... button in RunHistoryDialog)
        this.bus.Subscribe(Commands.ImportRunsRequested,
            (data) => this._OnImportRunsRequested(data))

        ; v0.1.0 Phase 5 — export/import logging for tracing in
        ; data\speedkalandra.log. Subscriber-only, doesn't change services.
        this.bus.Subscribe(Events.RunsExported,
            (data) => this._LogRunsExported(data))
        this.bus.Subscribe(Events.RunsImported,
            (data) => this._LogRunsImported(data))

        ; v0.1.3: apply death penalty to the timer in real time (it
        ; was only visible post-finalize in the plot before).
        this.bus.Subscribe(Events.DeathDetected,
            (data) => this._OnDeathApplyTimerPenalty(data))

        ; v0.1.4: hot-reload LogMonitor when the Client.txt path
        ; changes via Settings — no full app reload needed.
        this.bus.Subscribe(Events.LogFilePathChanged,
            (data) => this._OnLogFilePathChanged(data))

        ; v0.1.4: hot-rebind hotkeys when the user changes them via
        ; Settings — no full app reload needed.
        this.bus.Subscribe(Events.HotkeysChanged,
            (data) => this._OnHotkeysChanged(data))
    }

    ; ============================================================
    ; _OnDeathApplyTimerPenalty (v0.1.3)
    ;
    ; Handler for Evt.DeathDetected. If cfg.deathPenaltyEnabled and
    ; the run is active, adds cfg.deathPenaltyMs to the timer via
    ; TimerService.AddPenaltyMs. The user sees the pointer jump
    ; forward in the overlay as soon as they die.
    ;
    ; The "Deaths" category in the post-finalize plot continues to
    ; be count*penalty (RunStatsPlotBuilder._AddDeathDetails). The
    ; plot's totalMs already includes that sum because
    ; _AddZoneDetails / _AddLoadingDetails cover real time (no
    ; penalty) and _AddDeathDetails provides the penalty separately
    ; — same sum as the current runMs (which already has the penalty
    ; baked in).
    ; ============================================================
    _OnDeathApplyTimerPenalty(data)
    {
        if !IsObject(this._cfg) || !this._cfg.deathPenaltyEnabled
            return
        if !IsObject(this.timer) || !this.timer.IsActive()
            return
        penaltyMs := this._cfg.deathPenaltyMs
        if (!IsNumber(penaltyMs) || penaltyMs <= 0)
            return
        try this.timer.AddPenaltyMs(penaltyMs)
        if IsObject(this.log)
            try this.log.Info("Death penalty applied to timer: +" . penaltyMs . " ms", "App")
    }

    ; ============================================================
    ; _OnHotkeysChanged (v0.1.4)
    ;
    ; Handler for Evt.HotkeysChanged. Published by SettingsDialog when
    ; the user changes any hotkey binding via Settings. Performs a
    ; full rebind cycle on HotkeyService so the new keys take effect
    ; without a full app reload.
    ;
    ; Steps:
    ;   1. Stop HotkeyService (unregisters every currently bound key)
    ;   2. Hydrate with the new map from data["newHotkeys"]; falls
    ;      back to cfg.hotkeys if data is missing/malformed
    ;   3. Start HotkeyService (registers each non-empty binding)
    ;
    ; Failures inside any step are logged but do not propagate — a
    ; bad rebind should not crash the app. The user can re-open
    ; Settings to retry.
    ;
    ; Note: Hotkeys for actions opening dialogs (Settings, PlotRunStats)
    ; do a modifier cleanup Send before publishing the command (see
    ; FocusChangingActions in HotkeyService). That happens at fire
    ; time, independent of this rebind.
    ; ============================================================
    _OnHotkeysChanged(data)
    {
        if !IsObject(this.hotkeyService)
            return

        ; Prefer the new map from the event payload; fall back to
        ; cfg.hotkeys when the payload is missing/malformed. Either
        ; way the rebind goes through.
        newHotkeys := ""
        if (IsObject(data) && data.Has("newHotkeys") && data["newHotkeys"] is Map)
            newHotkeys := data["newHotkeys"]
        else if (IsObject(this._cfg) && this._cfg.hotkeys is Map)
            newHotkeys := this._cfg.hotkeys
        else
            newHotkeys := Map()

        try this.hotkeyService.Stop()
        try this.hotkeyService.Hydrate(newHotkeys)
        try this.hotkeyService.Start()

        if IsObject(this.log)
        {
            try this.log.Info("Hotkeys rebound: " . newHotkeys.Count
                . " action(s), " . this.hotkeyService.Count() . " registered", "App")
        }
        if !this._headless
            try TrayTip("SpeedKalandra", "Hotkeys updated.", "Mute")
    }

    ; ============================================================
    ; _OnLogFilePathChanged (v0.1.4)
    ;
    ; Handler for Evt.LogFilePathChanged. Published by SettingsDialog
    ; when the user changes the Client.txt path. Restarts LogMonitor
    ; against the new path so the user doesn't have to reload the app
    ; (huge UX win on first install, when the path was empty and the
    ; user just configured it).
    ;
    ; Steps:
    ;   1. Stop the polling SetTimer (so Tick doesn't fire mid-restart)
    ;   2. Stop the LogMonitor (closes the file handle / clears state)
    ;   3. Reconfigure with the new path
    ;   4. If the new path is valid, Start(seedFromTail=true) and
    ;      re-arm the SetTimer
    ;   5. If the new path is empty or invalid, leave it stopped —
    ;      the user will see warn lines in the log but no crash.
    ;
    ; Also re-applies the character name (LogMonitor's Stop clears
    ; nothing of its internal state, but this guarantees the death
    ; filter remains active after the path swap).
    ; ============================================================
    _OnLogFilePathChanged(data)
    {
        if !IsObject(data)
            return
        newPath := data.Has("newPath") ? String(data["newPath"]) : ""
        oldPath := data.Has("oldPath") ? String(data["oldPath"]) : ""

        if IsObject(this.log)
            try this.log.Info("Log file path changed: '" . oldPath . "' -> '" . newPath . "'", "App")

        ; (1) Stop the polling SetTimer first — if a Tick fires between
        ; LogMonitor.Stop and LogMonitor.Start it might try to read a
        ; half-configured state.
        if (this._logMonitorTimer != "")
        {
            try SetTimer(this._logMonitorTimer, 0)
            this._logMonitorTimer := ""
        }

        ; (2) Stop the LogMonitor (idempotent if already stopped).
        if IsObject(this.logMonitor)
            try this.logMonitor.Stop()

        ; (3) Reconfigure with the new path.
        if IsObject(this.logMonitor)
            try this.logMonitor.Configure(newPath)

        ; (4) If the path is valid, restart the tail loop and arm the timer.
        if (newPath != "" && FileExist(newPath))
        {
            try this.logMonitor.Start(true)
            ; Re-apply character name so the DeathDetected filter remains active.
            try this.logMonitor.SetCharacterName(this._cfg.characterName)
            this._logMonitorTimer := () => this.logMonitor.Tick()
            try SetTimer(this._logMonitorTimer, 250)
            if IsObject(this.log)
                try this.log.Info("Log monitor restarted with new path: " . newPath, "App")
            if !this._headless
                try TrayTip("SpeedKalandra", "Log monitor restarted with new path.", "Mute")
        }
        else if (newPath = "")
        {
            if IsObject(this.log)
                try this.log.Info("Log file path cleared; log monitor stopped.", "App")
        }
        else
        {
            if IsObject(this.log)
                try this.log.Warn("New log file path does not exist: " . newPath, "App")
        }
    }

    ; ============================================================
    ; _OnExportRunsRequested (v0.1.0)
    ;
    ; Handler for Commands.ExportRunsRequested. Expects `data` to have
    ; the "runIds" field (Array<string>). Forwards to ExportOptionsDialog
    ; which does the rest (options + path picker + service call).
    ; ============================================================
    _OnExportRunsRequested(data)
    {
        if !IsObject(data)
            return
        runIds := data.Has("runIds") ? data["runIds"] : ""
        if !IsObject(runIds) || !(runIds is Array) || runIds.Length = 0
        {
            try TrayTip("SpeedKalandra", "No runs to export.", "Mute")
            return
        }
        if IsObject(this.exportDialog)
            this.exportDialog.Open(runIds)
    }

    ; ============================================================
    ; _OnImportRunsRequested (v0.1.0)
    ;
    ; Handler for Commands.ImportRunsRequested. Expects `data` to have
    ; the "path" field (string pointing to the .json). Calls Preview
    ; on RunImportService; on success, opens the ImportPreviewDialog.
    ; On failure (invalid file, wrong schema, etc.), shows a MsgBox
    ; with the errors.
    ; ============================================================
    _OnImportRunsRequested(data)
    {
        if !IsObject(data)
            return
        path := data.Has("path") ? String(data["path"]) : ""
        if (Trim(path) = "")
            return

        preview := this.runImportService.Preview(path)

        if !preview["success"]
        {
            msg := "Failed to load import file:"
            for _, e in preview["errors"]
                msg .= "`n  - " e
            try SpeedKalandraMsgBox(msg, "Import failed", "IconX")
            return
        }

        if IsObject(this.importPreviewDialog)
            this.importPreviewDialog.OpenWithPreview(preview)
    }

    ; ============================================================
    ; _LogRunsExported / _LogRunsImported (v0.1.0 Phase 5)
    ;
    ; Subscribers for Evt.RunsExported / Evt.RunsImported. Record to
    ; LogService so that export/import operations appear in
    ; data/speedkalandra.log. Without this, debug is blind — the
    ; services have no injected log (deliberate decision to keep
    ; them simple).
    ; ============================================================
    _LogRunsExported(data)
    {
        if !IsObject(data) || !IsObject(this.log)
            return
        count := data.Has("count") ? data["count"] : 0
        path  := data.Has("path")  ? data["path"]  : "?"
        try this.log.Info("Exported " count " run(s) to: " path, "Export")
    }

    _LogRunsImported(data)
    {
        if !IsObject(data) || !IsObject(this.log)
            return
        imported := data.Has("imported") ? data["imported"] : 0
        renamed  := data.Has("renamed")  ? data["renamed"]  : 0
        skipped  := data.Has("skipped")  ? data["skipped"]  : 0
        path     := data.Has("path")     ? data["path"]     : "?"
        try this.log.Info("Imported runs: " . imported . " new (of which " . renamed
            . " renamed), " . skipped . " skipped, from: " . path, "Import")
    }

    _OnCharacterLevelUp(data)
    {
        if !IsObject(data)
            return
        name      := data.Has("character") ? data["character"] : ""
        ; v0.1.1: `class` collides with the AHK v2 `class` keyword. Use `charClass`.
        charClass := data.Has("class")     ? data["class"]     : ""
        level     := data.Has("level")     ? data["level"]     : 0
        this.xpService.SetCharacter(name, charClass, level)
        if (name != "")
        {
            this._cfg.characterName := name
            ; v17.15 (Bug #2): propagate to the DeathDetected filter
            try this.logMonitor.SetCharacterName(name)
        }
        if (charClass != "")
            this._cfg.characterClass := charClass
        if (level > 0)
            this._cfg.characterLevel := level
    }

    _OnAreaLevelChanged(data)
    {
        if !IsObject(data)
            return
        lvl  := data.Has("areaLevel") ? data["areaLevel"] : 0
        code := data.Has("areaCode")  ? data["areaCode"]  : ""
        this.xpService.SetCurrentArea(lvl, code)
        if (lvl > 0)
            this._cfg.currentAreaLevel := lvl
        if (code != "")
            this._cfg.currentAreaCode := code
    }

    _OnZoneEnteredForLevel(data)
    {
        ; v17.15 (Bug #9): only resets level to 1 on the FIRST entry
        ; into Riverbank in a fresh run.
        ;
        ; Before: InStr(zone, "Riverbank") + unconditional reset.
        ; Problem 1: substring match (any zone with "Riverbank" in
        ;            its name would match — unlikely in PoE2 but
        ;            fragile against name changes).
        ; Problem 2: re-entry (death respawn, portal, party invite)
        ;            reset the cached level, causing wrong XP display
        ;            until the next CharacterLevelUp.
        ;
        ; Now: exact name "The Riverbank" + _riverbankSeenInRun flag.
        ; Flag is cleared on RunStarted (NEW run) and RunEnded (Reset/Cancel).
        if !IsObject(data) || !data.Has("zoneName")
            return
        zone := data["zoneName"]
        if (zone != "The Riverbank")
            return
        if this._riverbankSeenInRun
            return
        this._riverbankSeenInRun := true
        this.xpService.SetCharacter("", "", 1)
        this._cfg.characterLevel := 1
    }

    ; v17.14 — RunStarted handler that does NOT reset XP area when the
    ; run comes from Hydrate (app reload). Hydrate restores persisted
    ; state; resetting XP area would lose accumulated info from the run.
    _OnRunStartedForXp(data)
    {
        isHydrate := IsObject(data) && data.Has("hydrated") && data["hydrated"]
        if isHydrate
            return
        try this.xpService.ResetCurrentArea()
        ; v17.15 (Bug #9): new run, release the level reset on Riverbank
        this._riverbankSeenInRun := false
    }

    _OnRunEndedClearZones(data)
    {
        try this.runState.ClearZoneTotals()
        this._lastSavedLoadingTotal := -1
        this._lastSavedZoneTotalsHash := ""
        ; v17.15 (Bug #9): end of run, release the flag for the next one
        this._riverbankSeenInRun := false
    }

    ; ============================================================
    ; _PromptLogFileSetupIfNeeded (v0.1.3)
    ;
    ; Blocks boot until the user configures a valid Client.txt.
    ;
    ; Preconditions to SHOW the dialog:
    ;   - !this._headless (tests silently skip)
    ;   - cfg.logFile empty  OR  configured file does not exist
    ;
    ; The suggested default is the Steam path (PoE2 installed via Steam).
    ; The standalone version (GGG launcher) has a different path; the
    ; user changes it via Browse.
    ;
    ; Buttons:
    ;   OK — if path is valid (FileExist), saves to the INI and proceeds.
    ;        If path is invalid, shows an error and keeps the dialog open.
    ;   Cancel — ExitApp() (closes the program). User explicitly asked
    ;            that the app NOT run without Client.txt.
    ; ============================================================
    _PromptLogFileSetupIfNeeded()
    {
        if this._headless
            return

        ; Do we already have a valid path? Then no setup is needed.
        if (this._cfg.logFile != "" && FileExist(this._cfg.logFile))
            return

        defaultPath := "C:\Program Files (x86)\Steam\steamapps\common\Path of Exile 2\logs\Client.txt"

        ; Pre-fill: if there was already a configured path but the file
        ; is gone, preserve the old path for the user to correct;
        ; otherwise, use the Steam default.
        initialPath := this._cfg.logFile != "" ? this._cfg.logFile : defaultPath

        choice := { value: "", path: "" }

        g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox +ToolWindow",
            "SpeedKalandra — Setup")
        g.MarginX := 16
        g.MarginY := 14

        g.SetFont("s11 bold", "Segoe UI")
        g.Add("Text", "x16 y14 w560", "Configure PoE2's Client.txt path")

        g.SetFont("s9", "Segoe UI")
        bodyText := ""
            . "SpeedKalandra reads Path of Exile 2's Client.txt log file to detect zone"
            . " changes, level ups, and deaths in real time. The path below is the"
            . " default location when PoE2 is installed via Steam.\n\nIf your installation"
            . " is somewhere else, use Browse to point to your own Client.txt. The app"
            . " will not start without a valid path."
        ; AHK v2 doesn't recognize \n; convert to `n
        bodyText := StrReplace(bodyText, "\n", "`n")
        g.Add("Text", "x16 y44 w560 h60", bodyText)

        g.SetFont("s9 bold", "Segoe UI")
        g.Add("Text", "x16 y110 w120", "Client.txt path:")

        g.SetFont("s9", "Consolas")
        editPath := g.Add("Edit", "x16 y130 w470 h24", initialPath)

        g.SetFont("s9", "Segoe UI")
        btnBrowse := g.Add("Button", "x494 y129 w82 h26", "Browse...")
        browseHandler := (*) => (
            picked := this._SetupBrowseLog(editPath.Value),
            (picked != "" ? (editPath.Value := picked) : 0)
        )
        btnBrowse.OnEvent("Click", browseHandler)

        ; Status line (empty initially, gets red text on error)
        g.SetFont("s9", "Segoe UI")
        statusLbl := g.Add("Text",
            "x16 y162 w560 h20 c" Theme.Color("danger"), "")

        ; Buttons
        btnOk := g.Add("Button", "x376 y196 w100 h30 Default", "OK")
        btnCancel := g.Add("Button", "x484 y196 w92 h30", "Cancel")

        okHandler := (*) => (
            (this._SetupValidatePath(editPath.Value, statusLbl)
                ? (choice.value := "ok",
                   choice.path := Trim(editPath.Value),
                   g.Destroy())
                : 0)
        )
        cancelHandler := (*) => (
            choice.value := "cancel",
            g.Destroy()
        )

        btnOk.OnEvent("Click", okHandler)
        btnCancel.OnEvent("Click", cancelHandler)
        g.OnEvent("Close", cancelHandler)
        g.OnEvent("Escape", cancelHandler)

        g.Show("w592 h240")

        ; Block until user dismisses
        hwnd := g.Hwnd
        while (choice.value = "" && WinExist("ahk_id " hwnd))
            Sleep 50

        if (choice.value = "cancel")
        {
            if IsObject(this.log)
                try this.log.Info("Setup cancelled by user: exiting app", "App")
            try TrayTip("SpeedKalandra",
                "Setup cancelled. The app cannot run without Client.txt.",
                "Iconx")
            ExitApp()
        }

        ; OK: persist the chosen path
        this._cfg.logFile := choice.path
        try this._PersistSettings()
        ; v0.1.4 fix: also reconfigure the LogMonitor with the chosen
        ; path. Without this, _logFilePath stays as "" (set in __New
        ; with the empty cfg.logFile of a fresh install). The Start()
        ; that runs later in app.Start() then calls logMonitor.Start()
        ; which early-returns because the path looks unconfigured.
        ; Result before this fix: user has to reload the app for the
        ; new path to take effect, defeating the auto-reload feature.
        if IsObject(this.logMonitor)
            try this.logMonitor.Configure(choice.path)
        if IsObject(this.log)
            try this.log.Info("Client.txt path configured: " . choice.path, "App")
    }

    ; Setup dialog helper: opens FileSelect and returns the chosen
    ; path (or "" if cancelled). Kept as a separate method for closure
    ; capture of the initial path.
    _SetupBrowseLog(currentValue)
    {
        try
        {
            ; v0.1.1: `file` collides with the builtin `File`. Use `selectedFile`.
            selectedFile := FileSelect(1, currentValue,
                "Select PoE2 Client.txt", "Log files (*.txt)")
            return selectedFile
        }
        return ""
    }

    ; Setup dialog helper: validates that the path exists. On error,
    ; updates the status label with a red message. Returns a bool
    ; indicating whether to proceed.
    _SetupValidatePath(path, statusLbl)
    {
        path := Trim(path)
        if (path = "")
        {
            try statusLbl.Value := "Path cannot be empty."
            return false
        }
        if !FileExist(path)
        {
            try statusLbl.Value := "File not found: " . path
            return false
        }
        return true
    }

    ; ============================================================
    ; _ShowDisclaimerIfNeeded (v17.15.2)
    ;
    ; Modal on boot. Shows a dialog with the disclaimer + a "Don't
    ; show again" checkbox. If the user ticks the checkbox and clicks
    ; "I understand", persists cfg.disclaimerAcknowledged = true and
    ; does not show it again.
    ;
    ; Headless mode: skipped. Already-acknowledged: skipped.
    ;
    ; The text is in English to reach the largest possible audience
    ; (PoE2 is global; Brazilian players usually already know gaming
    ; English). We keep the text in a single place for easy editing.
    ; ============================================================
    _ShowDisclaimerIfNeeded()
    {
        if this._headless
            return
        if this._cfg.disclaimerAcknowledged
            return

        ; Disclaimer text (multi-line continuation section).
        ; Leading whitespace on each line is stripped by AHK up to the
        ; closing `)`.
        bodyText := "
        (
SpeedKalandra is a personal project by a player, not a developer.

I built this because some functionality was missing from the overlays available during my runs, and I wanted something for my own use that other players might also find useful.

Yes, I know other speedrun trackers exist, some maintained by teams. I don't care if there are 10 other people working on this - I'm not trying to compete with them. I'm doing this because it's fun, and because I want a tracker that works the way I want it to.

The code was written with substantial help from AI. I directed what I wanted, reviewed the output, tested in actual runs, and iterated when things broke - but I won't pretend I wrote the architecture from scratch or deeply understand every line. I understand enough to use it, debug obvious problems, and make small adjustments.

What this means for you:

- USE AT YOUR OWN RISK. I tested on my own machine for my own playstyle. Your setup may differ in ways I haven't anticipated.

- BUGS ARE LIKELY. I fix what I personally hit. Edge cases I never encounter may sit broken for a long time.

- DON'T EXPECT FAST SUPPORT. I'm not maintaining this as a product. If you open an issue, I'll read it, but response times will be whenever-I-feel-like-it.

- FORK, MODIFY, RIP PARTS OUT. If you're a real developer and want to clean up something that's clearly wrong, go ahead.

- ANTI-CHEAT / TOS: The tool only reads the PoE2 Client.txt log file and captures pixel colors from the screen for loading detection. It does not inject into the game process, modify game files, or send inputs to the game. To my knowledge this is within typical overlay/tracker territory, but I make no guarantees - use it understanding that ultimately you're responsible for what runs on your machine while playing.

If it helps your runs, great. If it doesn't fit your needs, that's fine too - the goal was to scratch my own itch, not to build the universal speedrun tracker.
        )"

        choice := { dontShow: false, done: false }

        g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox +ToolWindow",
                 "SpeedKalandra - Disclaimer")
        g.MarginX := 16
        g.MarginY := 14

        g.SetFont("s11 bold", "Segoe UI")
        g.Add("Text", "x16 y14 w560", "Before using SpeedKalandra...")

        ; Multi-line Edit read-only with VScroll. Automatic wrap.
        g.SetFont("s9", "Segoe UI")
        edt := g.Add("Edit",
            "x16 y42 w560 h360 +Multi +ReadOnly +VScroll Background0xFFFFFF",
            bodyText)

        ; Checkbox
        g.SetFont("s9", "Segoe UI")
        chkDontShow := g.Add("Checkbox", "x16 y414 w300",
            "Don't show this disclaimer again")

        ; Button
        btnOk := g.Add("Button", "x456 y410 w120 h30 Default", "I understand")

        ; Handlers — closure shares the choice object by reference
        dismissFn := (*) => (
            choice.dontShow := chkDontShow.Value = 1,
            choice.done := true,
            g.Destroy()
        )
        btnOk.OnEvent("Click", dismissFn)
        g.OnEvent("Close",  dismissFn)
        g.OnEvent("Escape", dismissFn)

        ; Center on the screen
        g.Show("w592 h460")

        ; Block until user dismisses (same pattern as _PromptHydratedRun)
        hwnd := g.Hwnd
        while (!choice.done && WinExist("ahk_id " hwnd))
            Sleep 50

        ; If the user ticked the checkbox, persist the ack so it does
        ; not show again
        if (choice.dontShow)
        {
            this._cfg.disclaimerAcknowledged := true
            try this._PersistSettings()
            if IsObject(this.log)
                try this.log.Info("Disclaimer acknowledged by user", "App")
        }
    }

    ; ============================================================
    ; _PromptHydratedRun (v17.14 — F4)
    ;
    ; Called at the start of Start(). If there is a hydrated active
    ; run (from the persisted INI), shows a custom GUI with 3 buttons:
    ;   - Resume: no-op, the app continues with the hydrated run normally
    ;   - Finalize & save: calls FinalizeRun -> _SaveRunSnapshot saves
    ;     via threshold (>=3min) and updates PBs
    ;   - Discard: calls ResetRun -> clears state without saving
    ;
    ; Headless mode: skipped (default = Resume, test behavior).
    ;
    ; GUI blocks until user picks (modal). No timeout — the decision
    ; must be explicit to avoid inconsistent state.
    ; ============================================================
    _PromptHydratedRun()
    {
        if this._headless
            return
        if !IsObject(this.runService) || !this.runService.IsActive()
            return

        ; v17.15 (Bug #5): pause the timer during the user's decision.
        ;
        ; Before: a Sleep 50 loop blocked the main thread without
        ; disabling the timer. A timer hydrated as "running" kept
        ; counting during the decision time (potentially minutes) —
        ; in a speedrun where 1s matters, that's unacceptable.
        ;
        ; Now: explicit pause before the prompt. If the user picks
        ; Resume, the timer is resumed. Discard/Finalize clear the
        ; timer anyway (via ResetRun/FinalizeRun).
        wasRunningBeforePrompt := IsObject(this.timer) && this.timer.IsRunning()
        if wasRunningBeforePrompt
            try this.timer.Pause()

        state := this.runService.GetState()
        runMs := IsObject(this.timer) ? this.timer.GetRunMs() : 0
        durStr := SpeedKalandraApp._FormatMsForMsg(runMs)
        startedAt := state.startedAt != "" ? state.startedAt : "unknown"

        ; Choice via shared closure
        choice := { value: "" }

        g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox +ToolWindow",
            "SpeedKalandra — Active run found")
        g.SetFont("s10")
        g.Add("Text", "x20 y20 w360",
            "An active run was found from a previous session:")
        g.SetFont("s10 bold")
        g.Add("Text", "x20 y50 w360",
            "Started:  " startedAt "`n"
            . "Duration: " durStr)
        g.SetFont("s10")
        g.Add("Text", "x20 y100 w360", "What do you want to do?")

        ; Buttons
        btnResume := g.Add("Button", "x20 y140 w110 h32 Default", "Resume")
        btnResume.OnEvent("Click", (*) => (choice.value := "resume", g.Destroy()))

        btnFinalize := g.Add("Button", "x140 y140 w120 h32", "Finalize && save")
        btnFinalize.OnEvent("Click", (*) => (choice.value := "finalize", g.Destroy()))

        btnDiscard := g.Add("Button", "x270 y140 w110 h32", "Discard")
        btnDiscard.OnEvent("Click", (*) => (choice.value := "discard", g.Destroy()))

        ; Close X = Resume (safe default — does not lose data)
        g.OnEvent("Close", (*) => (choice.value := "resume", g.Destroy()))
        g.OnEvent("Escape", (*) => (choice.value := "resume", g.Destroy()))

        g.Show("w400 h190")

        ; Wait for choice (blocks the thread). g.Destroy() above
        ; triggers the loop exit.
        hwnd := g.Hwnd
        while (choice.value = "" && WinExist("ahk_id " hwnd))
            Sleep 50

        ; Apply the choice
        if (choice.value = "discard")
        {
            try this.runService.ResetRun()
            try this.log.Info("Hydrated run discarded by user (" . durStr . ", started at " . startedAt . ")", "App")
            try TrayTip("SpeedKalandra", "Previous run discarded.", "Mute")
        }
        else if (choice.value = "finalize")
        {
            ; FinalizeRun publishes RunCompleted -> _SaveRunSnapshot("completed")
            ; applies threshold and saves or discards
            try this.runService.FinalizeRun()
            try this.log.Info("Hydrated run finalized by user (" . durStr . ", started at " . startedAt . ")", "App")
        }
        else
        {
            ; "resume" (button or close-X): resume the timer if it was
            ; running before the prompt. If it was paused, keep paused.
            if wasRunningBeforePrompt
                try this.timer.Resume()
        }
    }

    ; ============================================================
    ; _SaveRunSnapshot (v17.14 — no confirmation MsgBox, F1)
    ;
    ; Called on TWO events (subscribed in __New BEFORE the services
    ; that clear state):
    ;   - Evt.RunCompleted  (Ctrl+Alt+F)  -> reason = "completed"
    ;   - Evt.RunCancelled  (direct CancelRun) -> reason = "cancelled"
    ;
    ; The MIN_CANCELLED_SAVE_MS threshold (3min) applies to BOTH reasons:
    ;   - Run < 3min: silently discarded (test garbage)
    ;   - Run >= 3min: saved directly, no MsgBox
    ;
    ; After a successful save of a completed run, marks the save as
    ; "undoable" for 60s via the tray menu "Undo last save". User can
    ; click to remove it from history (PBs are not reverted — to clear
    ; an incorrect PB, use "Reset PBs" in the tray menu).
    ;
    ; Silent failures: we don't want to break the finalize flow because
    ; of an I/O error in history.
    ; ============================================================
    _SaveRunSnapshot(reason)
    {
        try
        {
            if !IsObject(this.runHistory)
                return

            zoneTotals := IsObject(this.zoneTracker)
                          ? this.zoneTracker.GetTotalsForSnapshot()
                          : Map()
            ; v0.1.4: collect per-zone first-entry timestamps for
            ; chronological ordering in the plot details.
            zoneFirstEnteredAt := IsObject(this.zoneTracker)
                                  ? this.zoneTracker.GetFirstEnteredAtMap()
                                  : Map()
            runMs := IsObject(this.timer) ? this.timer.GetRunMs() : 0

            ; Uniform threshold for completed AND cancelled (F1)
            if (runMs < SpeedKalandraApp.MIN_CANCELLED_SAVE_MS)
            {
                if IsObject(this.log)
                {
                    try this.log.Info("Run too short, discarded (< "
                        . SpeedKalandraApp.MIN_CANCELLED_SAVE_MS . "ms): "
                        . runMs . " ms (reason=" . reason . ")", "App")
                }
                ; TrayTip only for completed — cancelled is expected
                ; to be silent (user cancelled intentionally)
                if (reason = "completed" && !this._headless)
                {
                    try TrayTip("SpeedKalandra",
                        "Run too short (" SpeedKalandraApp._FormatMsForMsg(runMs)
                        "), not saved.", "Mute")
                }
                return
            }

            if !IsObject(this.statsRecorder) || !IsObject(this.plotBuilder)
                return

            snapshot := this.statsRecorder.GetSnapshot(zoneTotals, runMs, zoneFirstEnteredAt)
            buildResult := this.plotBuilder.Build(snapshot)

            ; v17.15.1: captures actCheckpoints NOW and injects into
            ; buildResult before Save. Allows
            ; PersonalBestService.RebuildFromHistory to rebuild per-act
            ; PBs after run deletes. Runs saved before this change have
            ; no persisted checkpoints — rebuild silently ignores them
            ; (read returns an empty Map).
            ;
            ; Capturing here (no longer below) ensures the save
            ; persists the same checkpoints that UpdateFromRun consumes.
            actCheckpoints := Map()
            if IsObject(this.actCheckpoints)
            {
                try this.actCheckpoints.CaptureCurrentAsCheckpoint(runMs)
                try actCheckpoints := this.actCheckpoints.GetCheckpoints()
            }
            buildResult["actCheckpoints"] := actCheckpoints

            saved := this.runHistory.Save(buildResult)
            rid := buildResult.Has("runId") ? buildResult["runId"] : ""
            if (saved && IsObject(this.log))
            {
                this.log.Info("Run saved to history (" . reason . "): " . rid
                    . " (" . runMs . " ms)", "App")
            }

            ; --- Personal bests (v17.13) ---
            ; Updates PBs ONLY on completed runs. Cancelled does not
            ; count toward PB (even if it crosses the threshold).
            pbChanged := false
            if (reason = "completed" && IsObject(this.personalBest))
            {
                ; v17.15.1: uses the actCheckpoints already captured above
                ; (it used to be captured twice — unnecessary).
                try pbChanged := this.personalBest.UpdateFromRun(runMs, rid, zoneTotals, actCheckpoints)
                if (pbChanged && IsObject(this.log))
                {
                    nActs := 0
                    for _, _ms in actCheckpoints
                    {
                        if (_ms > 0)
                            nActs += 1
                    }
                    try this.log.Info("PB updated on run " . rid
                        . " (runMs=" . runMs . ", checkpoints=" . nActs . ")", "App")
                }
            }

            ; --- TrayTip + tray menu "Undo last save" ---
            ; Only for completed. Cancelled (rare now that NewRun
            ; doesn't call CancelRun) is silent.
            if (saved && reason = "completed" && !this._headless)
            {
                durStr := SpeedKalandraApp._FormatMsForMsg(runMs)
                msg := pbChanged
                    ? "Saved (" durStr "). PB updated! Tray menu has Undo (60s)."
                    : "Saved (" durStr "). Tray menu has Undo (60s)."
                try TrayTip("SpeedKalandra", msg, "Mute")
                this._MarkUndoableSave(rid)
            }
        }
        catch as ex
        {
            try this.log.Warn("Failed to save run to history: " ex.Message, "App")
        }
    }

    ; ============================================================
    ; Undo last save (v17.14 — F1)
    ;
    ; Flow:
    ;   1. _SaveRunSnapshot saves run -> _MarkUndoableSave(runId)
    ;   2. _MarkUndoableSave stores runId + adds tray menu item
    ;      + arms a 60s SetTimer
    ;   3a. User clicks "Undo last save" -> UndoLastSave() deletes
    ;       file + clears everything
    ;   3b. 60s pass -> _ExpireUndoableSave() removes menu item and
    ;       clears runId
    ;
    ; PBs are NOT reverted on undo (deliberate decision — see F1).
    ; To clear an incorrect PB, use "Reset PBs" in the tray menu.
    ; ============================================================
    _MarkUndoableSave(runId)
    {
        if (runId = "")
            return
        this._lastSavedRunId := runId

        ; Cancel the old timer if it existed (previous save still undoable)
        if (this._undoTimerFn != "")
        {
            try SetTimer(this._undoTimerFn, 0)
            this._undoTimerFn := ""
        }

        ; Adds tray menu item (global helper in speedkalandra.ahk)
        try SpeedKalandraTrayAddUndoItem()

        ; Arms a timer to expire after 60s (negative = run once)
        this._undoTimerFn := () => this._ExpireUndoableSave()
        try SetTimer(this._undoTimerFn, -60000)
    }

    UndoLastSave()
    {
        ; v0.1.1: local `runId` collides with the `RunId` class. Use `currentRunId`.
        currentRunId := this._lastSavedRunId
        if (currentRunId = "")
        {
            ; Stale menu item — clean up just in case
            try SpeedKalandraTrayRemoveUndoItem()
            return
        }

        ; Delete the history file
        deleted := false
        try
        {
            if IsObject(this.runHistory)
                deleted := this.runHistory.Delete(currentRunId)
        }
        catch
            deleted := false

        ; Clear internal state
        this._lastSavedRunId := ""
        if (this._undoTimerFn != "")
        {
            try SetTimer(this._undoTimerFn, 0)
            this._undoTimerFn := ""
        }
        try SpeedKalandraTrayRemoveUndoItem()

        if IsObject(this.log)
        {
            try this.log.Info("Undo last save: " . currentRunId
                . (deleted ? " (removed)" : " (file not found)"), "App")
        }
        if !this._headless
        {
            msg := deleted
                ? "Last save removed from history. (PBs were not reverted.)"
                : "Last save not found (already removed?)."
            try TrayTip("SpeedKalandra", msg, "Mute")
        }
    }

    _ExpireUndoableSave()
    {
        this._lastSavedRunId := ""
        this._undoTimerFn := ""
        try SpeedKalandraTrayRemoveUndoItem()
    }

    ; ============================================================
    ; _OnResetPersonalBestsRequested (v17.13)
    ;
    ; Subscribed to Commands.ResetPersonalBestsRequested (tray menu).
    ; Shows a confirmation MsgBox (destructive action) and calls
    ; Reset() on PersonalBestService. In headless mode, resets directly
    ; without prompting.
    ; ============================================================
    _OnResetPersonalBestsRequested()
    {
        if !IsObject(this.personalBest)
            return

        if this._headless
        {
            this.personalBest.Reset()
            return
        }

        ; Shows context of what will be lost
        runPbStr := this.personalBest.HasRunPb()
                    ? SpeedKalandraApp._FormatMsForMsg(this.personalBest.GetRunPbMs())
                    : "—"
        zoneCount := 0
        try
        {
            for zk, zv in this.personalBest.GetAllZonePbs()
                zoneCount += 1
        }
        actPbCount := 0
        try
            actPbCount := this.personalBest.CountActPbs()

        result := ""
        try
        {
            result := SpeedKalandraMsgBox(
                "Reset all Personal Bests?`n`n"
                . "Full run PB: " runPbStr "`n"
                . "PBs per act: " actPbCount "`n"
                . "Zone PBs: " zoneCount "`n`n"
                . "This action erases all best times and cannot be undone.",
                "SpeedKalandra - Reset PBs",
                "YesNo Icon? Default2")
        }
        catch
            return

        if (result != "Yes")
            return

        this.personalBest.Reset()
        try this.log.Info("PBs reset by user (run PB: " . runPbStr
            . ", " . actPbCount . " acts, " . zoneCount . " zones)", "App")
        try TrayTip("SpeedKalandra", "Personal Bests reset.", "Mute")
    }

    ; Static helper to format ms as MM:SS or H:MM:SS (for messages).
    ; v0.1.2 (audit #19): delegates to Duration.FormatMs (used to be 4
    ; identical copies scattered around; consolidated in
    ; domain/values/duration.ahk).
    static _FormatMsForMsg(ms) => Duration.FormatMs(ms)

    _PersistRunData()
    {
        try this.runService.PersistTick()

        ; v17.15 (Bug #8): explicit catch — ARCHITECTURE.md forbids
        ; silent try. _PersistRunData runs every 5s; if something
        ; fails (disk full, corrupt INI), we need to know.
        try
        {
            if IsObject(this.loadingTotals)
               && IsObject(this.runService)
               && this.runService.IsActive()
            {
                ltms := this.loadingTotals.GetTotalMs()
                if (ltms != this._lastSavedLoadingTotal)
                {
                    this.runState.SaveLoadingTotal(ltms)
                    this._lastSavedLoadingTotal := ltms
                }
            }
        }
        catch as ex
        {
            try this.log.Warn("Failed to persist loading total: " . ex.Message, "App")
        }

        try
        {
            if IsObject(this.zoneTracker) && this.zoneTracker.IsRunActive()
            {
                snapshot := this.zoneTracker.GetTotals()
                hash := this._ComputeTotalsHash(snapshot)
                if (hash != this._lastSavedZoneTotalsHash)
                {
                    this.runState.SaveZoneTotals(snapshot)
                    this._lastSavedZoneTotalsHash := hash
                }
            }
        }
        catch as ex
        {
            try this.log.Warn("Failed to persist zone totals: " . ex.Message, "App")
        }
    }

    _PersistRunDataFull()
    {
        try this.runService.PersistTick()

        ; v17.15 (Bug #8): explicit catch (same motivation as
        ; _PersistRunData). _PersistRunDataFull is called in Stop()/
        ; OnExit — last chance to save before closing. Failing
        ; silently means data loss with no feedback.
        try
        {
            if IsObject(this.loadingTotals)
               && IsObject(this.runService)
               && this.runService.IsActive()
            {
                ltms := this.loadingTotals.GetTotalMs()
                this.runState.SaveLoadingTotal(ltms)
                this._lastSavedLoadingTotal := ltms
            }
        }
        catch as ex
        {
            try this.log.Warn("Failed to persist loading total (Full): " . ex.Message, "App")
        }

        try
        {
            if IsObject(this.zoneTracker) && this.zoneTracker.IsRunActive()
            {
                snapshot := this.zoneTracker.GetTotalsForSnapshot()
                this.runState.SaveZoneTotals(snapshot)
                this._lastSavedZoneTotalsHash := this._ComputeTotalsHash(snapshot)
            }
        }
        catch as ex
        {
            try this.log.Warn("Failed to persist zone totals (Full): " . ex.Message, "App")
        }
    }

    _ComputeTotalsHash(totalsMap)
    {
        if !IsObject(totalsMap)
            return ""
        parts := ""
        for k, v in totalsMap
            parts .= k "=" v "|"
        return parts
    }

    _GetWidgetPos(widgetId, defaultLeftPct, defaultTopPct)
    {
        if !IsObject(this._cfg.overlay)
            this._cfg.overlay := OverlayLayout.Defaults()

        existing := this._cfg.overlay.GetPosition(widgetId)
        if (existing != "")
            return existing

        pos := OverlayPosition.FromMap(Map(
            "left",     defaultLeftPct,
            "top",      defaultTopPct,
            "scale",    1.0,
            "visible",  true,
            "centered", false
        ))
        this._cfg.overlay.SetPosition(widgetId, pos)
        return pos
    }

    _PersistSettings()
    {
        try this._settingsRepo.Save(this._cfg)
    }

    _DeduceCurrentAct()
    {
        if !IsObject(this.zoneTracker)
            return 0
        zone := this.zoneTracker.GetActiveZone()
        if (zone = "" || !IsObject(this.zonesCatalog))
            return 0
        return this.zonesCatalog.GetActOfName(zone)
    }
}
