; SpeedKalandraApp — composition root.
;
; The class itself does little: it wires every service together,
; subscribes the cross-cutting handlers on the bus, and drives the
; lifecycle (Start / Stop). The substantive flows live in dedicated
; classes constructed here and addressed by reference:
;
;   BootPrompts                  disclaimer / Client.txt setup /
;                                hydrated-run resume modals.
;   RunSnapshotSaver             RunCompleted / RunCancelled
;                                handler + tray-undo flow.
;   RunStatePersister            5 s persistence tick + final
;                                flush from Stop().
;   LiveReconfigurationHandlers  death-penalty timer update,
;                                hotkey rebind, PB reset.
;
; Lifecycle is `__New → Start → Stop` and is **terminal**: once Stop
; runs, this instance cannot be Start()ed again — the second Start
; throws. The right way to relaunch is to construct a new
; SpeedKalandraApp. Re-starting an old instance would re-arm
; SetTimers and call Show() on widgets the OS already destroyed,
; producing silent state corruption. Stop itself is idempotent
; (calling it N times is safe), and Stop on a never-Start()ed
; instance also marks the instance terminal — there is no scenario
; where stopping makes Start viable.
;
; Two responsibilities still live here because they need direct
; access to fields owned by the composition root: `_OnLogFilePathChanged`
; (mutates `_logMonitorTimer`) and the small `_On*` handlers for
; XP / area / zone / Riverbank / run-ended state.
;
; Run history: every run is saved to data/runs/{runId}.ini, triggered
; by RunCompleted (always) or RunCancelled (only if >= 3 min). The
; save runs through `RunService.SetOnBefore{Finalize,Cancel}` pre-publish
; hooks, not as a bus subscriber, so it sees the run's final in-memory
; state regardless of where other RunCompleted/RunCancelled subscribers
; are wired. (Pre-hook: ZoneTrackingService keeps _totals on
; RunCompleted for the plot dialog, but clears them on RunCancelled;
; RunStatsRecorder mirrors that. A bus-subscriber Save used to rely
; on FIFO ordering of __New's Subscribe calls to run before the
; cancel-path clears, which was a silent reordering risk.) The Save
; itself lives in RunSnapshotSaver; the hooks are wired near the end
; of __New, after the saver has been constructed.


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

    ; Death log + aggregation service. Independent of run lifecycle
    ; (see DeathLogRepository class header) — appends every detected
    ; death to data/deaths.csv even when the run is later cancelled
    ; or reset. Consumed by DeathStatsDialog via DeathStatsService.
    ;
    ; deathLogScanner is the alternative read path for the dialog's
    ; "All-time (from log)" view: a one-shot scan of the raw
    ; Client.txt that bypasses the CSV entirely. Independent of
    ; deathLog — the two never share state, and the scanner has no
    ; side effects (no writes, no event publishing).
    deathLog          := ""
    deathStatsService := ""
    deathLogScanner   := ""

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
    deathStatsDialog   := ""
    exportDialog       := ""
    importPreviewDialog := ""

    runExportService   := ""
    runImportService   := ""

    ; Boot-time modal prompts (disclaimer, Client.txt setup, hydrated
    ; run). Extracted out of SpeedKalandraApp so __New stays focused
    ; on wiring; the prompts run from Start() and own no state of
    ; their own beyond the references handed in at construction.
    _bootPrompts := ""

    ; Run-finalization + undo flow. Wired into RunService via
    ; SetOnBefore{Finalize,Cancel} near the end of __New, after
    ; every collaborator the saver needs has been constructed.
    _snapshotSaver := ""

    ; Periodic 5 s persistence of run base / loading total / zone
    ; totals + final flush from Stop(). Owns its own dirty-cache;
    ; the composition root primes the cache after hydration and
    ; clears it via ResetCache when a run ends.
    _persister := ""

    ; Hot-reload + destructive-action handlers (death-penalty timer
    ; update, hotkey rebind, PB reset). Each is subscribed in
    ; _WireEventHandlers via a one-line delegate.
    _reconfig := ""

    _started   := false
    _stopped   := false   ; Terminal flag. Once Stop() runs (even on an
                          ; instance that was never Start()ed), this flips
                          ; to true and stays true; Start() then throws.
                          ; See the header comment and Start/Stop bodies.
    _persistFn := ""
    _logMonitorTimer  := ""
    _runPersistTimer  := ""
    _headless         := false

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
        deathLogPath := cfgMap.Has("deathLogPath") ? cfgMap["deathLogPath"]
                                                    : (scriptDir "\data\deaths.csv")

        headless := cfgMap.Has("headless") ? !!cfgMap["headless"] : false
        this._headless := headless

        this.log   := LogService(logPath, "INFO", headless ? 1 : 32)
        this.bus   := EventBus(this.log)
        ; The event-trace interceptor object is constructed here so
        ; a later flip-on in Start() can register it without re-wiring
        ; anything. AddInterceptor on the bus is NOT called yet — it
        ; runs in tracer.Start() inside SpeedKalandraApp.Start, and
        ; only if cfg.eventTracingEnabled. Events published during
        ; construction (notably the RunStarted{hydrated:true} that
        ; runService.Hydrate emits near the end of __New) are NOT
        ; captured by the tracer — the flag is opt-in and the
        ; interceptor is not on the bus until Start.
        this.eventTracer := EventTraceLogger(this.bus, this.log)
        ; Clock is injectable so integration tests can plug in FakeClock.
        this.clock := cfgMap.Has("clock") ? cfgMap["clock"] : RealClock()

        ; Warning sinks for infra/services that don't take a direct
        ; LogService dependency (keeps the layered architecture honest;
        ; see ARCHITECTURE.md § 14). Each carries a fixed context tag
        ; so a grep of `[PB]` / `[RunState]` / `[RunHistory]` in
        ; data/speedkalandra.log isolates failures by source layer.
        pbSink         := LogServiceWarningSink(this.log, "PB")
        runStateSink   := LogServiceWarningSink(this.log, "RunState")
        runHistorySink := LogServiceWarningSink(this.log, "RunHistory")
        deathLogSink   := LogServiceWarningSink(this.log, "DeathLog")

        ini := IniFile(iniPath)
        this._settingsRepo := SettingsRepository(ini)
        this._cfg := this._settingsRepo.Load()

        this.zonesCatalog := ZonesCatalog(zonesCsvPath)
        this.log.Info("Zones catalog loaded: " this.zonesCatalog.Count() " zones", "App")

        ; Run history
        this.runHistory := RunHistoryRepository(runHistoryDir, runHistorySink)

        ; Death log: append-only CSV of every detected death. The file
        ; is created lazily on the first Append (see DeathLogRepository),
        ; so a fresh install does not carry an empty deaths.csv.
        this.deathLog := DeathLogRepository(deathLogPath, deathLogSink)

        ; Personal bests are loaded by the repository inside
        ; PersonalBestService.__New, then updated by RunSnapshotSaver
        ; when reason="completed". The same pbSink goes into both the
        ; repo (Save I/O failures) and the service (persist-after-
        ; mutation failures) so all PB-related WARNs land under one
        ; greppable tag.
        this.personalBest := PersonalBestService(
            PersonalBestRepository(pbPath, pbSink),
            pbSink
        )
        if this.personalBest.HasRunPb()
        {
            try this.log.Info("Run PB loaded: "
                . this.personalBest.GetRunPbMs() . " ms ("
                . this.personalBest.GetRunPbRunId() . ")", "App")
        }

        this.runState   := RunStateRepository(ini, runStateSink)
        this.timer      := TimerService(this.clock, this.bus)
        this.runService := RunService(this.clock, this.bus, this.timer, this.runState, this.log)

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

        this.logMonitor := LogMonitorService(this.clock, this.bus, this.log, this.zonesCatalog)
        this.logMonitor.Configure(this._cfg.logFile)
        ; Character name is hydrated here so the DeathDetected filter
        ; is armed before the first log line is read. Without this,
        ; deaths between boot and the first CharacterLevelUp event
        ; would be skipped.
        this.logMonitor.SetCharacterName(this._cfg.characterName)

        this.zoneTracker := ZoneTrackingService(this.bus, this.clock, this.zonesCatalog)

        ; Hydrated values are captured here in locals; the
        ; RunStatePersister doesn't exist yet (depends on services
        ; constructed below) and is primed with these once it does.
        hydratedLoadingMs  := -1
        hydratedZoneTotals := ""

        try
        {
            zoneTotals := this.runState.LoadZoneTotals()
            this.zoneTracker.Hydrate(zoneTotals)
            if (hydratedState is RunState && hydratedState.IsRunning())
            {
                this.zoneTracker.SetRunActive(true)
                this.log.Info("Zone tracker hydrated: " . zoneTotals.Count . " zones with accumulated time (run in progress)", "App")
            }
            hydratedZoneTotals := zoneTotals
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
                hydratedLoadingMs := loadingMs
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

        ; Aggregation over deathLog for the DeathStatsDialog. Pure
        ; read service: no cache, re-reads the CSV on every Aggregate
        ; call. Catalog used to drop town zones from the stats.
        this.deathStatsService := DeathStatsService(this.deathLog, this.zonesCatalog)

        ; One-shot Client.txt scanner for the dialog's "All-time
        ; (from log)" view. Catalog used to resolve internal ids to
        ; canonical names and to drop towns — same convention as the
        ; CSV path. No event bus, no I/O outside the read.
        this.deathLogScanner := DeathLogScanner(this.zonesCatalog)

        this.autoFinalize := AutoFinalizeService(this.bus, this._cfg)
        ; AutoStartService receives runService so it can read the
        ; hydrated active-run state at construction. Without it, an
        ; in-progress run would be overwritten by the next log line
        ; that matches autoStartRegex.
        this.autoStart := AutoStartService(this.bus, this._cfg, this.runService)

        compactPos := this._GetWidgetPos("compactLayout", 10, 1.5)
        microPos   := this._GetWidgetPos("microLayout",   75, 92)
        stevePos   := this._GetWidgetPos("steveLayout",   10, 1.5)

        ; Periodic persistence + settings save. Created here because
        ; every dependency it needs has been wired above; the
        ; _persistFn closure (passed to widgets, dialogs, and the
        ; boot prompts) routes through this single instance so the
        ; on-disk INI sees one consistent stream of writes.
        this._persister := RunStatePersister(
            this.runService, this.runState, this.loadingTotals,
            this.zoneTracker, this._settingsRepo, this._cfg, this.log
        )
        this._persister.PrimeLoadingTotalCache(hydratedLoadingMs)
        this._persister.PrimeZoneTotalsCache(hydratedZoneTotals)

        this._persistFn := () => this._persister.PersistSettings()

        ; Compact widget: Classic vs Plus chosen by cfg.layoutVariant.
        ; Both share WIDGET_ID and constructor signature, so Plus is
        ; a drop-in replacement at this site.
        if (this._cfg.layoutVariant = "plus")
        {
            this.compactWidget := CompactLayoutPlusWidget(
                this.bus, compactPos, this._persistFn,
                this.timer, this.zoneTracker, this.xpService,
                this.zonesCatalog, this.loadingTotals, this._cfg,
                this.personalBest
            )
        }
        else
        {
            this.compactWidget := CompactLayoutWidget(
                this.bus, compactPos, this._persistFn,
                this.timer, this.zoneTracker, this.xpService,
                this.zonesCatalog, this.loadingTotals, this._cfg,
                this.personalBest
            )
        }

        ; Micro widget: Classic vs Plus chosen by cfg.layoutVariant.
        ; Plus re-injects zoneTracker / zonesCatalog / personalBest;
        ; Classic doesn't need them (only timer + xp).
        if (this._cfg.layoutVariant = "plus")
        {
            this.microWidget := MicroLayoutPlusWidget(
                this.bus, microPos, this._persistFn,
                this.timer, this.zoneTracker, this.xpService,
                this.zonesCatalog, this.personalBest
            )
        }
        else
        {
            this.microWidget := MicroLayoutWidget(
                this.bus, microPos, this._persistFn,
                this.timer, this.xpService
            )
        }

        ; Steve widget: Classic vs Plus chosen by cfg.layoutVariant.
        ; Plus re-injects loadingTotals + cfg. The flag is read once
        ; at boot; SettingsDialog prompts the user to restart on flip.
        if (this._cfg.layoutVariant = "plus")
        {
            this.steveWidget := SteveLayoutPlusWidget(
                this.bus, stevePos, this._persistFn,
                this.timer, this.zoneTracker, this.xpService,
                this.zonesCatalog, this.personalBest,
                this.loadingTotals, this._cfg
            )
        }
        else
        {
            this.steveWidget := SteveLayoutWidget(
                this.bus, stevePos, this._persistFn,
                this.timer, this.zoneTracker, this.xpService,
                this.zonesCatalog, this.personalBest
            )
        }

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

        ; Death stats dialog: aggregation surface over deathLog,
        ; opened by Cmd.OpenDeathStatsRequested (button in
        ; RunStatsPlotDialog). The scanner is also injected so the
        ; dialog can offer the "All-time (from log)" view that reads
        ; Client.txt directly; cfg is read at toggle time for the
        ; log path and character name.
        this.deathStatsDialog := DeathStatsDialog(this.bus, this.deathStatsService, this.deathLogScanner, this._cfg, headless)

        this.runExportService := RunExportService(this.bus, this.runHistory, this.personalBest)
        this.runImportService := RunImportService(this.bus, this.runHistory, this.personalBest)
        this.exportDialog := ExportOptionsDialog(this.bus, this.runExportService, headless)
        this.importPreviewDialog := ImportPreviewDialog(this.bus, this.runImportService, headless)

        this._bootPrompts := BootPrompts(
            this._cfg,
            () => this._persister.PersistSettings(),
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

        ; Wire the run-finalization save through RunService's
        ; pre-publish hooks instead of as a bus subscriber. This sees
        ; the run's in-memory state before subscribers (notably
        ; ZoneTrackingService and RunStatsRecorder on RunCancelled)
        ; have a chance to clear it. Subscription-order races on the
        ; bus are now impossible — nobody can step between hook and
        ; Publish. The closures capture `this` and use `_snapshotSaver`
        ; which exists from the previous line.
        this.runService.SetOnBeforeFinalize(
            () => this._snapshotSaver.Save("completed"))
        this.runService.SetOnBeforeCancel(
            () => this._snapshotSaver.Save("cancelled"))

        this._reconfig := LiveReconfigurationHandlers(
            this._cfg,
            this.log,
            this.timer,
            this.hotkeyService,
            this.personalBest,
            headless
        )

        this._WireEventHandlers()

        ; Validate that every field referenced by handlers in this
        ; class (and in the extracted cross-cutting handlers) has been
        ; wired. Detects regressions in the boot order — e.g. a future
        ; refactor that moves a constructor below a subscription that
        ; reads it, or that drops a field by accident — at construction
        ; time instead of at first event dispatch. Cheaper than tests
        ; that mock the entire bus.
        this._AssertWired()

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
        ; Terminal-state guard. Stop() flips `_stopped` to true and
        ; this instance is intentionally not reusable past that
        ; point. Re-starting would re-arm `SetTimer` callbacks, call
        ; `Show()` on widgets the OS already tore down, and replay
        ; boot prompts against `_cfg` that may have drifted — silent
        ; corruption at best. A throw makes the bug visible at the
        ; callsite trying to resurrect the instance; the right answer
        ; is to construct a fresh `SpeedKalandraApp`.
        ;
        ; Note: the throw path runs BEFORE any side effect, so the
        ; integration tests can call `Stop()` then assert
        ; `Throws(Error, () => app.Start())` without actually
        ; entering Start's body.
        if this._stopped
            throw Error("SpeedKalandraApp.Start: instance was already stopped — create a new SpeedKalandraApp instead")

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

        ; Note: the run snapshot save is wired through RunService's
        ; SetOnBefore{Finalize,Cancel} hooks in __New, not as a bus
        ; subscription. Do not subscribe Save here — see the class
        ; header for the rationale.

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

        this._runPersistTimer := () => this._persister.Tick()
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
        ; Idempotent + terminal. `_stopped` is always set, even when
        ; `Start` was never called — there's no scenario where
        ; stopping should make `Start` viable again. The cleanup
        ; work below runs only when an actual Start happened
        ; (gated by `_started`); a Stop on a never-started instance
        ; only flips the terminal flag and returns.
        if !this._started
        {
            this._stopped := true
            return
        }
        this._started := false
        this._stopped := true

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
            this._persister.PersistSettings()
        }
        catch as ex
        {
            try this.log.Warn("Stop: persist settings failed: " . ex.Message, "App")
        }
        try
        {
            this._persister.Flush()
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
            (data) => this._reconfig.ResetPersonalBests())

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
            (data) => this._reconfig.ApplyDeathPenaltyToTimer(data))

        ; Death log: persist a row to data/deaths.csv. Independent
        ; subscriber from the death-penalty one above — different
        ; concerns (live-timer adjustment vs append-only history).
        ; Keeping them split makes each handler trivial to read and
        ; lets a future change to one path not risk the other.
        this.bus.Subscribe(Events.DeathDetected,
            (data) => this._OnDeathDetectedForLog(data))

        ; Hot-reload paths: the Settings dialog publishes these so
        ; the user doesn't have to reload the whole app on common
        ; config changes (Client.txt path, hotkey bindings).
        this.bus.Subscribe(Events.LogFilePathChanged,
            (data) => this._OnLogFilePathChanged(data))
        this.bus.Subscribe(Events.HotkeysChanged,
            (data) => this._reconfig.RebindHotkeys(data))
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

    ; Persists the death to data/deaths.csv with the run's context
    ; (active zone, configured patch, configured profile). Independent
    ; of run lifecycle — see DeathLogRepository class header for why
    ; this is decoupled from RunStatsRecorder's per-run deathCount.
    ;
    ; `data` is the Evt.DeathDetected payload ({character}). We don't
    ; use it: the upstream filter in LogMonitorService already
    ; validated `character` against cfg.characterName, so by the time
    ; this fires we already implicitly own the run that died.
    ;
    ; Empty active zone is silently dropped (legitimate gap: a death
    ; line can arrive before any ZoneChanged seeded the active zone).
    ; The early return saves a bus dispatch and keeps the Append's
    ; warn-on-CR/LF path reachable for real upstream bugs.
    _OnDeathDetectedForLog(data)
    {
        if !IsObject(this.deathLog) || !IsObject(this.zoneTracker)
            return
        zoneName := this.zoneTracker.GetActiveZone()
        if (Trim(String(zoneName)) = "")
            return
        patch   := IsObject(this._cfg) ? String(this._cfg.gamePatch)   : ""
        profile := IsObject(this._cfg) ? String(this._cfg.profileName) : ""
        try this.deathLog.Append(zoneName, patch, profile)
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
        if IsObject(this._persister)
            this._persister.ResetCache()
        ; Release the Riverbank reset flag for the next run.
        this._riverbankSeenInRun := false
    }

    ; Tray menu callback — delegates to the snapshot saver. Kept as a
    ; public method on the app so the entry script's tray wiring stays
    ; agnostic of where the implementation lives.
    UndoLastSave() => this._snapshotSaver.UndoLastSave()

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

    _DeduceCurrentAct()
    {
        if !IsObject(this.zoneTracker)
            return 0
        zone := this.zoneTracker.GetActiveZone()
        if (zone = "" || !IsObject(this.zonesCatalog))
            return 0
        return this.zonesCatalog.GetActOfName(zone)
    }

    ; Asserts that every field that __New is responsible for wiring
    ; was actually set to an object. Called at the end of __New,
    ; after _WireEventHandlers and before runService.Hydrate (which
    ; can publish events that subscribers consume — a half-wired
    ; subscriber would crash on dispatch with a confusing stack).
    ;
    ; What's checked: every collaborator and handler that is
    ; constructed inside __New. Late-bound fields owned by Start()
    ; (_logMonitorTimer, _runPersistTimer, _started flag) are
    ; deliberately excluded — they are not __New's responsibility.
    ; Scalar flags (_headless, _riverbankSeenInRun) and the runtime
    ; closure (_persistFn) are checked for non-empty but not for
    ; IsObject; the rest must be objects.
    ;
    ; The list is deliberately written out by hand rather than
    ; reflected from `this.OwnProps()` so that adding a new field
    ; forces a conscious decision about whether __New owns it.
    ; Failure mode is a clear error like:
    ;   "SpeedKalandraApp._AssertWired: field 'statsRecorder'
    ;    was not wired (expected object, got String '')"
    _AssertWired()
    {
        ; Fields that must be set to an object after __New.
        ; Grouped by purpose for readability; the order doesn't
        ; matter — the loop reports the first failure either way.
        objectFields := [
            ; Core infrastructure
            "log", "bus", "clock", "_settingsRepo", "_cfg", "zonesCatalog",
            ; Core services
            "timer", "runState", "runService", "actCheckpoints",
            "xpService", "logMonitor", "zoneTracker",
            "loadingDetection", "loadingTotals",
            "personalBest", "runHistory",
            "deathLog", "deathStatsService", "deathLogScanner",
            "statsRecorder", "plotBuilder",
            "autoFinalize", "autoStart",
            ; Input + presentation
            "focusAutoPause", "hudScanner", "hotkeyService",
            "overlayInter", "overlayMode", "overlayApplier",
            "tickEmitter", "eventTracer",
            ; Widgets
            "compactWidget", "microWidget", "steveWidget", "widgets",
            ; Dialogs
            "settingsDialog", "plotDialog", "runHistoryDialog",
            "deathStatsDialog",
            "exportDialog", "importPreviewDialog",
            ; Import / export
            "runExportService", "runImportService",
            ; Extracted cross-cutting handlers
            "_bootPrompts", "_snapshotSaver", "_persister", "_reconfig"
        ]

        for _, fieldName in objectFields
        {
            value := this.%fieldName%
            if !IsObject(value)
            {
                shape := (value = "") ? "String ''" : Type(value) . " '" . value . "'"
                throw Error("SpeedKalandraApp._AssertWired: field '"
                    . fieldName . "' was not wired (expected object, got " . shape . ")")
            }
        }

        ; _persistFn is a closure (Func / BoundFunc / Closure depending
        ; on the AHK runtime path), not a generic object — check it
        ; carefully. We don't call it; we just verify it's callable.
        if !(this._persistFn is Func) && !HasMethod(this._persistFn, "Call")
        {
            throw Error("SpeedKalandraApp._AssertWired: field '_persistFn' was not wired (expected callable, got "
                . Type(this._persistFn) . ")")
        }
    }
}
