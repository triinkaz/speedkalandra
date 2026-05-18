; SpeedKalandraApp — composition root.
;
; Persistence: timer base + loading total + per-zone totals are
; written to the INI every 5 s by _PersistRunData, with a hash cache
; that skips IniWrite when nothing has changed (a naive write was
; blocking the thread for 1–2 s every tick).
;
; Run history: every run is saved to data/runs/{runId}.ini, triggered
; by RunCompleted (always) or RunCancelled (only if >= 3 min). The
; save handlers are subscribed in __New BEFORE RunStatsRecorder and
; ZoneTrackingService are constructed — the bus is FIFO, and those
; services clear their state on the same events. Subscribing later
; in Start() would hand the save handler an empty snapshot.
; The handler itself lives in RunSnapshotSaver; the subscription is
; late-bound (`(data) => this._snapshotSaver.Save(...)`) because the
; saver depends on services that don't exist yet at subscription time
; and gets constructed near the end of __New, once they do.


class SpeedKalandraApp
{
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
    actCheckpoints   := ""
    statsRecorder    := ""
    plotBuilder      := ""
    autoFinalize     := ""
    autoStart        := ""

    runHistory      := ""

    overlayMode     := ""
    overlayApplier  := ""
    focusAutoPause  := ""
    hudScanner      := ""
    hotkeyService   := ""
    overlayInter    := ""
    tickEmitter     := ""
    eventTracer     := ""    ; EventTraceLogger — records every bus Publish; opt-in (see [Diagnostics] in the INI)

    compactWidget := ""
    microWidget   := ""
    steveWidget   := ""
    widgets       := ""

    settingsDialog     := ""
    plotDialog         := ""
    runHistoryDialog   := ""
    exportDialog       := ""
    importPreviewDialog := ""

    runExportService   := ""
    runImportService   := ""

    ; Boot-time modal prompts (disclaimer, Client.txt setup, hydrated
    ; run). Extracted out of SpeedKalandraApp so __New stays focused
    ; on wiring; the prompts run from Start() and own no state of
    ; their own beyond the references handed in at construction.
    _bootPrompts := ""

    ; Run-finalization + undo flow. Subscribed to RunCompleted /
    ; RunCancelled in __New via a late-bound callback (the saver is
    ; constructed later, after every collaborator it needs exists).
    _snapshotSaver := ""

    _started   := false
    _persistFn := ""
    _logMonitorTimer  := ""
    _runPersistTimer  := ""
    _headless         := false

    _lastSavedLoadingTotal := -1
    _lastSavedZoneTotalsHash := ""

    ; First entry into the Riverbank in a run resets the cached
    ; character level (the game shows the level-1 zone for the
    ; first time of a fresh char). Subsequent re-entries (death,
    ; portal, party invite) must NOT reset, or the cached level
    ; goes back to 1 until the next CharacterLevelUp line.
    _riverbankSeenInRun := false

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
        ; The event-trace interceptor is registered BEFORE any service
        ; subscribes — guarantees the trace captures every Publish
        ; from the moment wiring starts. It's only started later in
        ; Start() (and only if cfg.eventTracingEnabled is set).
        this.eventTracer := EventTraceLogger(this.bus, this.log)
        ; Clock is injectable so integration tests can plug in FakeClock.
        this.clock := cfgMap.Has("clock") ? cfgMap["clock"] : RealClock()

        ini := IniFile(iniPath)
        this._settingsRepo := SettingsRepository(ini)
        this._cfg := this._settingsRepo.Load()

        this.zonesCatalog := ZonesCatalog(zonesCsvPath)
        this.log.Info("Zones catalog loaded: " this.zonesCatalog.Count() " zones", "App")

        ; Run history
        this.runHistory := RunHistoryRepository(runHistoryDir)

        ; Personal bests are loaded by the repository inside
        ; PersonalBestService.__New, then updated by RunSnapshotSaver
        ; when reason="completed".
        this.personalBest := PersonalBestService(PersonalBestRepository(pbPath))
        if this.personalBest.HasRunPb()
        {
            try this.log.Info("Run PB loaded: "
                . this.personalBest.GetRunPbMs() . " ms ("
                . this.personalBest.GetRunPbRunId() . ")", "App")
        }

        ; Save handlers subscribed NOW, before the services that
        ; clear their state on RunCancelled (zoneTracker and
        ; statsRecorder, further down). The bus is FIFO; our handler
        ; needs to run first while the snapshot is still intact.
        ; The callbacks are late-bound: this._snapshotSaver is still
        ; "" at this point and gets assigned later in __New, after
        ; every service it consumes has been constructed.
        this.bus.Subscribe(Events.RunCompleted,
            (data) => this._snapshotSaver.Save("completed"))
        this.bus.Subscribe(Events.RunCancelled,
            (data) => this._snapshotSaver.Save("cancelled"))

        this.runState   := RunStateRepository(ini)
        this.timer      := TimerService(this.clock, this.bus)
        this.runService := RunService(this.clock, this.bus, this.timer, this.runState)

        ; Tracks total run time at each act transition; feeds the
        ; per-act PB on finalize. Depends on this.timer for GetRunMs.
        this.actCheckpoints := ActCheckpointTracker(this.bus, this.timer)

        hydratedState := this.runState.Load()
        ; runService.Hydrate intentionally NOT called here. When the
        ; hydrated state has an active run, Hydrate publishes
        ; Evt.RunStarted{hydrated:true} — several services that need
        ; that event (RunStatsRecorder, ZoneTrackingService, the
        ; _OnRunStartedForXp handler) are constructed below. Hydrating
        ; here would leave RunStatsRecorder._runId="", which makes
        ; the finalized hydrated run silently fail to save. Deferred
        ; to the end of __New after every service is wired up.

        ; LogService is passed so focus/process transitions appear in
        ; speedkalandra.log for diagnostics.
        this.focusAutoPause := FocusAutoPauseService(this.bus, this.timer, this._cfg, this.log)

        this.hotkeyService := HotkeyService(this.bus, headless)
        this.hotkeyService.Hydrate(this._cfg.hotkeys)

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
        ; Character name is hydrated here so the DeathDetected filter
        ; is armed before the first log line is read. Without this,
        ; deaths between boot and the first CharacterLevelUp event
        ; would be skipped.
        this.logMonitor.SetCharacterName(this._cfg.characterName)

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

        this.statsRecorder := RunStatsRecorder(this.bus, this.clock)
        this.plotBuilder   := RunStatsPlotBuilder(this.zonesCatalog, this._cfg)

        this.autoFinalize := AutoFinalizeService(this.bus, this._cfg)
        ; AutoStartService receives runService so it can read the
        ; hydrated active-run state at construction. Without it, an
        ; in-progress run would be overwritten by the next log line
        ; that matches autoStartRegex.
        this.autoStart := AutoStartService(this.bus, this._cfg, this.runService)

        compactPos := this._GetWidgetPos("compactLayout", 10, 1.5)
        microPos   := this._GetWidgetPos("microLayout",   75, 92)
        stevePos   := this._GetWidgetPos("steveLayout",   10, 1.5)

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

        this.runExportService := RunExportService(this.bus, this.runHistory, this.personalBest)
        this.runImportService := RunImportService(this.bus, this.runHistory, this.personalBest)
        this.exportDialog := ExportOptionsDialog(this.bus, this.runExportService, headless)
        this.importPreviewDialog := ImportPreviewDialog(this.bus, this.runImportService, headless)

        this._bootPrompts := BootPrompts(
            this._cfg,
            () => this._PersistSettings(),
            this.logMonitor,
            this.runService,
            this.timer,
            this.log,
            headless
        )

        this._snapshotSaver := RunSnapshotSaver(
            this.runHistory,
            this.zoneTracker,
            this.timer,
            this.statsRecorder,
            this.plotBuilder,
            this.actCheckpoints,
            this.personalBest,
            this.log,
            headless
        )

        this._WireEventHandlers()

        ; Subscribers are all in place — now it is safe to hydrate the
        ; run service. If the loaded RunState has an active run, this
        ; publishes Evt.RunStarted{hydrated:true} which propagates to
        ; RunStatsRecorder (sets _runId), ZoneTrackingService (re-arms
        ; timing without wiping the totals just hydrated from disk),
        ; AutoStartService (sets _runActive), and _OnRunStartedForXp
        ; (no-op on hydrate by design).
        try
        {
            this.runService.Hydrate(hydratedState)
        }
        catch as ex
        {
            ; Recoverable (the user can start a fresh run) but logged
            ; so it doesn't look like a clean first boot. Failure
            ; modes seen so far: corrupt RunState INI, type mismatch
            ; on loaded fields, TimerService internal error.
            try this.log.Warn("Failed to hydrate run service: " . ex.Message
                . " | What: " . (ex.HasOwnProp("What") ? ex.What : "?")
                . " | Line: " . (ex.HasOwnProp("Line") ? ex.Line : "?")
                . " | File: " . (ex.HasOwnProp("File") ? ex.File : "?"), "App")
        }
    }

    Start()
    {
        if this._started
            return
        this._started := true

        ; Three modal prompts on boot, blocking the rest of Start()
        ; until each is dismissed. Skipped in headless mode (each
        ; method early-returns when this._headless is true).
        this._bootPrompts.ShowDisclaimerIfNeeded()
        this._bootPrompts.PromptLogFileSetupIfNeeded()
        this._bootPrompts.PromptHydratedRun()

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

        ; Note: the RunCompleted/RunCancelled subscriptions that drive
        ; RunSnapshotSaver live in __New (above the services that
        ; clear state on those events). Do not re-subscribe here.

        if (this._cfg.logFile != "" && FileExist(this._cfg.logFile))
        {
            this.logMonitor.Start(true)
            this._logMonitorTimer := () => this.logMonitor.Tick()
            try SetTimer(this._logMonitorTimer, 250)
            this.log.Info("Log monitor started: " this._cfg.logFile, "App")
        }
        else if (this._cfg.logFile = "")
        {
            ; Fresh install — empty logFile is expected. INFO instead
            ; of WARN so the boot doesn't trigger the "boot with
            ; warnings" TrayTip on the user's first launch.
            this.log.Info("Log file not configured. Configure the Client.txt path in Settings (tray menu) to enable zone detection.", "App")
        }
        else
        {
            ; Path configured but missing — the user got it wrong.
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

        ; Event tracing is opt-in via cfg.eventTracingEnabled. When
        ; on, the interceptor persists raw Client.txt lines (the
        ; LogLineRead payload) to speedkalandra.log alongside the
        ; usual INFO/WARN/ERROR entries — useful for bug reports,
        ; noisy otherwise. Off by default so a normal install never
        ; writes raw game text to disk.
        if this._cfg.eventTracingEnabled
        {
            try this.eventTracer.Start()
            try this.log.Info("Event tracing ENABLED (interceptor active). Disable in [Diagnostics] when not diagnosing.", "App")
        }

        this._runPersistTimer := () => this._PersistRunData()
        try SetTimer(this._runPersistTimer, 5000)

        this.bus.Publish(Events.AppStarted, Map())
        this.log.Info("SpeedKalandra started", "App")

        ; LogService counts WARN/ERROR regardless of minLevel; if the
        ; boot logged anything, surface it via TrayTip so silent
        ; warnings don't go unnoticed. Counters are reset after
        ; surfacing so runtime warnings don't pile up into the next
        ; boot prompt.
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

        try
        {
            this._PersistSettings()
        }
        catch as ex
        {
            try this.log.Warn("Stop: persist settings failed: " . ex.Message, "App")
        }
        try
        {
            this._PersistRunDataFull()
        }
        catch as ex
        {
            try this.log.Warn("Stop: full run-data flush failed: " . ex.Message, "App")
        }
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

        this.bus.Subscribe(Commands.ResetPersonalBestsRequested,
            (data) => this._OnResetPersonalBestsRequested())

        this.bus.Subscribe(Commands.ExportRunsRequested,
            (data) => this._OnExportRunsRequested(data))
        this.bus.Subscribe(Commands.ImportRunsRequested,
            (data) => this._OnImportRunsRequested(data))

        ; Export/import logging: services don't carry a log dependency
        ; by design, so we mirror their outcome events here.
        this.bus.Subscribe(Events.RunsExported,
            (data) => this._LogRunsExported(data))
        this.bus.Subscribe(Events.RunsImported,
            (data) => this._LogRunsImported(data))

        ; Death penalty applied to the live timer (the post-finalize
        ; plot already accounted for it; this makes the overlay agree
        ; with the plot in real time).
        this.bus.Subscribe(Events.DeathDetected,
            (data) => this._OnDeathApplyTimerPenalty(data))

        ; Hot-reload paths: the Settings dialog publishes these so
        ; the user doesn't have to reload the whole app on common
        ; config changes (Client.txt path, hotkey bindings).
        this.bus.Subscribe(Events.LogFilePathChanged,
            (data) => this._OnLogFilePathChanged(data))
        this.bus.Subscribe(Events.HotkeysChanged,
            (data) => this._OnHotkeysChanged(data))
    }

    ; Adds the configured death penalty to the live timer when a
    ; death is detected. The post-finalize plot already accounts for
    ; this via count*penalty; applying it here keeps the visible
    ; timer in sync.
    _OnDeathApplyTimerPenalty(data)
    {
        if !IsObject(this._cfg) || !this._cfg.deathPenaltyEnabled
            return
        if !IsObject(this.timer) || !this.timer.IsActive()
            return
        penaltyMs := this._cfg.deathPenaltyMs
        if (!IsNumber(penaltyMs) || penaltyMs <= 0)
            return
        try
        {
            this.timer.AddPenaltyMs(penaltyMs)
        }
        catch as ex
        {
            if IsObject(this.log)
                try this.log.Warn("Failed to apply death penalty to timer (" . penaltyMs . " ms): " . ex.Message, "App")
        }
        if IsObject(this.log)
            try this.log.Info("Death penalty applied to timer: +" . penaltyMs . " ms", "App")
    }

    ; Rebinds hotkeys live when the user changes them in Settings.
    ; Stop + Hydrate + Start so the previous bindings are released
    ; before the new ones are registered.
    _OnHotkeysChanged(data)
    {
        if !IsObject(this.hotkeyService)
            return

        ; Prefer the payload; fall back to cfg if it's missing/malformed.
        newHotkeys := ""
        if (IsObject(data) && data.Has("newHotkeys") && data["newHotkeys"] is Map)
            newHotkeys := data["newHotkeys"]
        else if (IsObject(this._cfg) && this._cfg.hotkeys is Map)
            newHotkeys := this._cfg.hotkeys
        else
            newHotkeys := Map()

        try
        {
            this.hotkeyService.Stop()
            this.hotkeyService.Hydrate(newHotkeys)
            this.hotkeyService.Start()
        }
        catch as ex
        {
            try this.log.Warn("Hotkey rebind failed (" . newHotkeys.Count . " action(s)): " . ex.Message, "App")
        }

        if IsObject(this.log)
        {
            try this.log.Info("Hotkeys rebound: " . newHotkeys.Count
                . " action(s), " . this.hotkeyService.Count() . " registered", "App")
        }
        if !this._headless
            try TrayTip("SpeedKalandra", "Hotkeys updated.", "Mute")
    }

    ; Restarts LogMonitor against a new Client.txt path when the user
    ; updates it in Settings. The polling timer is stopped first so a
    ; Tick can't fire mid-restart. Empty path leaves the monitor
    ; stopped; invalid path is logged but doesn't crash the app.
    _OnLogFilePathChanged(data)
    {
        if !IsObject(data)
            return
        newPath := data.Has("newPath") ? String(data["newPath"]) : ""
        oldPath := data.Has("oldPath") ? String(data["oldPath"]) : ""

        if IsObject(this.log)
            try this.log.Info("Log file path changed: '" . oldPath . "' -> '" . newPath . "'", "App")

        ; Stop the polling SetTimer first so a Tick can't fire between
        ; Stop and Start and read a half-configured state.
        if (this._logMonitorTimer != "")
        {
            try SetTimer(this._logMonitorTimer, 0)
            this._logMonitorTimer := ""
        }

        if IsObject(this.logMonitor)
            try this.logMonitor.Stop()

        if IsObject(this.logMonitor)
        {
            try
            {
                this.logMonitor.Configure(newPath)
            }
            catch as ex
            {
                try this.log.Warn("LogMonitor.Configure failed for '" . newPath . "': " . ex.Message, "App")
            }
        }

        if (newPath != "" && FileExist(newPath))
        {
            try
            {
                this.logMonitor.Start(true)
            }
            catch as ex
            {
                try this.log.Warn("LogMonitor.Start failed for '" . newPath . "': " . ex.Message, "App")
            }
            ; Re-apply the character name so the DeathDetected filter
            ; survives the swap.
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
        ; `class` collides with the AHK v2 `class` keyword; rename locally.
        charClass := data.Has("class")     ? data["class"]     : ""
        level     := data.Has("level")     ? data["level"]     : 0
        this.xpService.SetCharacter(name, charClass, level)
        if (name != "")
        {
            this._cfg.characterName := name
            ; Propagate to the DeathDetected filter so deaths attributed
            ; to this character are recognized.
            try
            {
                this.logMonitor.SetCharacterName(name)
            }
            catch as ex
            {
                try this.log.Warn("LogMonitor.SetCharacterName failed: " . ex.Message, "App")
            }
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
        ; The first entry into The Riverbank in a run resets the
        ; cached level to 1 (fresh-character zone). Subsequent
        ; re-entries (death respawn, portal back, party invite)
        ; must NOT reset, or the cached level rolls back until the
        ; next CharacterLevelUp line. The flag is cleared on
        ; RunStarted (fresh) and RunReset/RunCancelled (end).
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

    ; RunStarted handler that does NOT reset XP area when the event
    ; comes from Hydrate (hydrated:true). On hydrate we want to keep
    ; the persisted XP accumulators intact.
    _OnRunStartedForXp(data)
    {
        isHydrate := IsObject(data) && data.Has("hydrated") && data["hydrated"]
        if isHydrate
            return
        try this.xpService.ResetCurrentArea()
        ; Release the Riverbank reset flag for the new run.
        this._riverbankSeenInRun := false
    }

    _OnRunEndedClearZones(data)
    {
        try
        {
            this.runState.ClearZoneTotals()
        }
        catch as ex
        {
            try this.log.Warn("ClearZoneTotals failed: " . ex.Message, "App")
        }
        this._lastSavedLoadingTotal := -1
        this._lastSavedZoneTotalsHash := ""
        ; Release the Riverbank reset flag for the next run.
        this._riverbankSeenInRun := false
    }

    ; Tray menu callback — delegates to the snapshot saver. Kept as a
    ; public method on the app so the entry script's tray wiring stays
    ; agnostic of where the implementation lives.
    UndoLastSave() => this._snapshotSaver.UndoLastSave()

    ; Subscribed to Commands.ResetPersonalBestsRequested (tray menu).
    ; Shows a confirmation MsgBox (destructive action). Headless mode
    ; resets without prompting.
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

    ; Formats ms as MM:SS or H:MM:SS for user-facing messages.
    ; Delegates to Duration.FormatMs (used to be four near-identical
    ; copies scattered across services).
    static _FormatMsForMsg(ms) => Duration.FormatMs(ms)

    _PersistRunData()
    {
        try
        {
            this.runService.PersistTick()
        }
        catch as ex
        {
            try this.log.Warn("PersistTick failed (tick): " . ex.Message, "App")
        }

        ; Explicit catch on both branches: this runs every 5 s, and
        ; silent failure here (disk full, corrupt INI) would mean
        ; persistent data loss with no signal.
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
        try
        {
            this.runService.PersistTick()
        }
        catch as ex
        {
            try this.log.Warn("PersistTick failed (full flush): " . ex.Message, "App")
        }

        ; Called from Stop() / OnExit — last chance to flush before
        ; closing. Silent failure here would lose data without a peep.
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
        try
        {
            this._settingsRepo.Save(this._cfg)
        }
        catch as ex
        {
            try this.log.Warn("Failed to persist settings: " . ex.Message, "App")
        }
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
