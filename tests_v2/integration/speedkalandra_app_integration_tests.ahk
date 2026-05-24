; ============================================================
; SpeedKalandraAppIntegrationTests
; ============================================================
;
; Integration test of the composition root (SpeedKalandraApp).
;
; Strategy:
;   - headless=true: skips disclaimer, prompts, TrayTip
;   - injected clock (FakeClock) to control run timing
;   - Does NOT call app.Start(): that would render widgets (real Gui).
;     Instead, exercises the bus directly by publishing Commands
;     (NewRunRequested, FinalizeRunRequested) consumed by RunService
;     via subscribers registered in the constructor.
;   - Setup creates a temp directory with a minimal zones.csv, an
;     empty ini, runHistory dir, and empty personal_bests.ini.
;
; Coverage:
;   - Constructor initializes all main services
;   - NewRunRequested -> runService.NewRun -> RunState persisted
;   - FinalizeRunRequested on short run (<3min) -> NOT saved to history
;   - FinalizeRunRequested on long run (>=3min) -> saved
;   - PB updated on completed run
;   - Crash recovery: second instance hydrates state from the first


class SpeedKalandraAppIntegrationTests extends TestCase
{
    tmpDir        := ""
    iniPath       := ""
    zonesCsvPath  := ""
    logPath       := ""
    runHistoryDir := ""
    pbPath        := ""
    deathLogPath  := ""
    routesDir     := ""
    stubClock     := ""
    app           := ""

    Setup()
    {
        this.tmpDir        := Fixtures.TempDir()
        this.iniPath       := this.tmpDir "\settings.ini"
        this.zonesCsvPath  := this.tmpDir "\zones.csv"
        this.logPath       := this.tmpDir "\app.log"
        this.runHistoryDir := this.tmpDir "\runs"
        this.pbPath        := this.tmpDir "\pb.ini"
        this.deathLogPath  := this.tmpDir "\deaths.csv"
        this.routesDir     := this.tmpDir "\routes"

        ; Create a minimal valid zones.csv (real project format)
        FileAppend(
            "name;internal_id;act;is_town`n"
            . "Clearfell Encampment;G1_town;1;1`n"
            . "The Riverbank;G1_1;1;0`n"
            . "Mud Burrow;G1_3;1;0`n"
            . "The Karui Shores;G3_town;3;1`n",
            this.zonesCsvPath, "UTF-8")
        Fixtures.RegisterTempPath(this.zonesCsvPath)
        Fixtures.RegisterTempPath(this.iniPath)
        Fixtures.RegisterTempPath(this.logPath)
        Fixtures.RegisterTempPath(this.pbPath)
        Fixtures.RegisterTempPath(this.deathLogPath)

        ; Create runs dir (RunHistoryRepository doesn't create it automatically)
        try DirCreate(this.runHistoryDir)
        Fixtures.RegisterTempPath(this.runHistoryDir)

        ; Routes dir is created lazily by RouteRepository.__New (DirCreate
        ; with try). Registered with the fixture cleanup pool so any INI
        ; the app may write under it during a test is wiped between runs.
        Fixtures.RegisterTempPath(this.routesDir)

        ; FakeClock with base 1000000ms (arbitrary, far from 0)
        this.stubClock := Fixtures.MakeFakeClock(1000000)

        this.app := SpeedKalandraApp(Map(
            "iniPath",          this.iniPath,
            "zonesCsvPath",     this.zonesCsvPath,
            "logPath",          this.logPath,
            "runHistoryDir",    this.runHistoryDir,
            "personalBestPath", this.pbPath,
            "deathLogPath",     this.deathLogPath,
            "routesDir",        this.routesDir,
            "headless",         true,
            "clock",            this.stubClock
        ))
    }

    Teardown()
    {
        if IsObject(this.app)
        {
            try this.app.Stop()
        }
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor / components ---
        "constructor_creates_all_main_components",
        "constructor_subscribes_run_history_handlers",
        "constructor_loads_zones_catalog",
        "constructor_does_not_throw_with_empty_ini",
        "constructor_no_run_active_initially",
        "constructor_event_tracer_not_enabled_by_default",
        "event_tracer_start_registers_interceptor_on_app_bus",
        "event_tracer_stop_removes_interceptor_from_app_bus",
        "event_tracer_active_captures_events_published_through_app_bus",

        ; --- Run lifecycle via bus ---
        "new_run_via_command_starts_run",
        "new_run_persists_to_ini",
        "new_run_starts_timer",
        "cancel_run_via_command_stops_run",

        ; --- Finalize: 3min threshold ---
        "short_run_finalize_does_not_save_to_history",
        "long_run_finalize_saves_to_history",
        "long_run_finalize_updates_personal_best",
        "very_short_run_does_not_update_pb",

        ; --- Crash recovery ---
        "second_app_instance_hydrates_active_run_from_disk",
        "second_instance_resumes_timer_with_correct_base_ms",
        "hydrated_run_propagates_run_id_to_stats_recorder",
        "hydrated_run_finalize_saves_to_history",

        ; --- Route service hydration ordering + re-sync (B4) ---
        "route_service_subscribed_before_hydrate_so_it_observes_hydrated_run_started",
        "route_widget_highlight_persists_when_run_starts_inside_first_route_zone",

        ; --- Stop (terminal lifecycle) ---
        "stop_does_not_throw_when_never_started",
        "stop_is_idempotent",
        "start_after_stop_throws",
        "start_after_stop_throws_even_when_never_started",

        ; --- Undo last save rebuilds PBs (consistency with Delete) ---
        "undo_last_save_rebuilds_pbs_from_history",

        ; --- _AssertWired (boot-time wiring check) ---
        "assert_wired_passes_after_normal_construction",
        "assert_wired_throws_when_object_field_is_empty",
        "assert_wired_throws_when_persist_fn_is_not_callable",

        ; --- End-to-end run flow ---
        "complete_run_flow_from_start_to_finalize_to_undo",

        ; --- Zone semantics (anti-regression: catalog-id resolution) ---
        "log_monitor_with_catalog_resolves_internal_id_in_zone_tracker",

        ; --- Cancel save flow (anti-regression: bus-subscription FIFO race) ---
        "cancelled_long_run_saves_to_history_with_zone_totals_intact",

        ; --- Zone-PB exclusion (interrupted-by-hotkey visit) ---
        "interrupted_visit_does_not_create_artificial_zone_pb",
        "interrupted_visit_after_complete_visit_preserves_complete_visit_pb",

        ; --- Riverbank single-reset (level rolls back on re-entry) ---
        ; First entry into "The Riverbank" resets the cached character
        ; level to 1 (fresh-character zone). Re-entries (death respawn,
        ; portal, party invite) must NOT reset, or the cached level
        ; rolls back until the next CharacterLevelUp line. Exact-match
        ; on "The Riverbank" + _riverbankSeenInRun flag (cleared on
        ; RunStarted / RunReset / RunCancelled).
        "bug9_first_riverbank_entry_resets_level_to_1",
        "bug9_second_riverbank_entry_does_not_reset_level",
        "bug9_non_exact_match_does_not_trigger_reset",
        "bug9_new_run_clears_riverbank_flag",
        "bug9_run_reset_clears_riverbank_flag",

        ; --- Death penalty on the real-time timer ---
        ; _OnDeathApplyTimerPenalty handler subscribed to Evt.DeathDetected.
        ; Checks cfg.deathPenaltyEnabled + timer.IsActive() before
        ; calling timer.AddPenaltyMs. Covers all 4 guard paths.
        "death_penalty_applies_to_timer_when_enabled_and_run_active",
        "death_penalty_does_not_apply_when_disabled",
        "death_penalty_does_not_apply_when_no_run_active",
        "death_penalty_accumulates_with_multiple_deaths",
        "death_penalty_uses_configured_ms_value",
        "death_penalty_does_not_apply_when_configured_ms_is_zero",

        ; --- Death log (independent of run lifecycle, see DeathLogRepository) ---
        ; The DeathDetected handler captures the active zone via
        ; ZoneTrackingService.GetActiveZone() and appends a row to
        ; data/deaths.csv with the configured patch and profile. The
        ; log is independent of run lifecycle: a death recorded during
        ; a run that is later cancelled remains in the log (and
        ; survives Run history deletion).
        "constructor_creates_death_log_components",
        "death_detected_appends_row_with_active_zone_patch_and_profile",
        "death_detected_with_no_active_zone_silently_skips_append",
        "death_detected_aggregation_via_service_returns_zone_counts",

        ; --- Layout variant branching (Plus opt-in) ---
        ; cfg.layoutVariant flips which Steve widget class the
        ; composition root instantiates. Default ("classic") and
        ; opt-in ("plus") both go through the same WIDGET_ID slot
        ; in OverlayLayout, so the user's position survives the
        ; toggle. PLUS_LAYOUTS_SPEC.md §1.
        "default_layout_variant_constructs_classic_steve_widget",
        "layout_variant_plus_in_ini_constructs_plus_steve_widget",
        "default_layout_variant_constructs_classic_compact_widget",
        "layout_variant_plus_in_ini_constructs_plus_compact_widget",
        "default_layout_variant_constructs_classic_micro_widget",
        "layout_variant_plus_in_ini_constructs_plus_micro_widget"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _ListRunFiles()
    {
        files := []
        Loop Files, this.runHistoryDir "\*.ini"
            files.Push(A_LoopFileName)
        return files
    }

    ; Simulates time in a zone so that ZoneTrackingService.GetTotalsForSnapshot
    ; returns a non-empty totals. RunHistoryRepository.Save rejects buildResult
    ; with totalMs<1000ms (filter for "test garbage"), and the builder computes
    ; totalMs as the sum of categories from totals — without an active zone or
    ; loading, totals stays empty and Save silently returns false.
    _EnterZoneAndAdvance(zoneName, advanceMs)
    {
        this.app.bus.Publish(Events.ZoneChanged, Map(
            "zoneName", zoneName,
            "ts",       FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
        ))
        this.stubClock.AdvanceMs(advanceMs)
    }

    ; ============================================================
    ; Constructor / components
    ; ============================================================

    constructor_creates_all_main_components()
    {
        Assert.True(this.app.bus is EventBus, "bus exists")
        Assert.True(this.app.clock = this.stubClock, "injected clock preserved")
        Assert.True(this.app.timer is TimerService)
        Assert.True(this.app.runService is RunService)
        Assert.True(this.app.runState is RunStateRepository)
        Assert.True(this.app.zoneTracker is ZoneTrackingService)
        Assert.True(this.app.zonesCatalog is ZonesCatalog)
        Assert.True(this.app.personalBest is PersonalBestService)
        Assert.True(this.app.runHistory is RunHistoryRepository)
        Assert.True(this.app.statsRecorder is RunStatsRecorder)
        Assert.True(this.app.overlayMode is OverlayModeService)
        Assert.True(this.app.hotkeyService is HotkeyService)
    }

    constructor_subscribes_run_history_handlers()
    {
        ; RunCompleted / RunCancelled have subscribers wired by
        ; widgets and services (ZoneTrackingService, RunStatsRecorder,
        ; _OnRunEndedClearZones). The run-snapshot save itself runs
        ; through RunService.SetOnBefore{Finalize,Cancel} hooks, not
        ; as a bus subscriber — see the SpeedKalandraApp header.
        ; This test just confirms there are subscribers on each
        ; event so a future refactor that drops them all surfaces
        ; here.
        Assert.True(this.app.bus.Subscribers(Events.RunCompleted) >= 1)
        Assert.True(this.app.bus.Subscribers(Events.RunCancelled) >= 1)
    }

    constructor_loads_zones_catalog()
    {
        ; Setup created zones.csv with 5 lines (4 zones + header). Catalog
        ; must have 4 entries.
        Assert.Equal(4, this.app.zonesCatalog.Count())
    }

    constructor_does_not_throw_with_empty_ini()
    {
        ; Setup doesn't explicitly create settings.ini — the app must accept
        ; a non-existent file and use defaults.
        Assert.True(IsObject(this.app))
    }

    constructor_no_run_active_initially()
    {
        Assert.False(this.app.runService.IsActive())
    }

    constructor_event_tracer_not_enabled_by_default()
    {
        ; EventTraceLogger is opt-in. The interceptor object is
        ; instantiated during __New (so the cost of the constructor
        ; is paid once and Start can later flip it on without
        ; re-wiring), but it must NOT be enabled until Start() runs
        ; AND cfg.eventTracingEnabled is true.
        ;
        ; This test covers the construction half: defaults give
        ; eventTracingEnabled=false and the interceptor reports
        ; IsEnabled()=false. The Start() branch isn't exercised here
        ; because Start triggers real SetTimers / WinActive polling
        ; that we don't want firing inside the test process — the
        ; unit-level coverage of the flag lives in AppSettings and
        ; SettingsRepository tests.
        Assert.False(this.app._cfg.eventTracingEnabled,
            "Default cfg.eventTracingEnabled is false (privacy-preserving)")
        Assert.True(IsObject(this.app.eventTracer),
            "EventTraceLogger object is still instantiated for cheap flip-on later")
        Assert.False(this.app.eventTracer.IsEnabled(),
            "Interceptor not registered on the bus until Start() under the flag")
    }

    event_tracer_start_registers_interceptor_on_app_bus()
    {
        ; Companion to the test above: exercises the Start()-half of
        ; the opt-in contract without going through app.Start() (which
        ; would arm widgets / SetTimers). Verifies that wiring the
        ; production EventTraceLogger against the production EventBus
        ; actually flips IsEnabled() and registers exactly one
        ; interceptor — i.e. the two pieces composed by __New are
        ; compatible and the contract documented in the class header
        ; ("Start adds interceptor") holds in the real app context,
        ; not just in EventTraceLoggerTests's isolated EventBus.
        Assert.Equal(0, this.app.bus.InterceptorCount(),
            "sanity: no interceptor before Start")
        Assert.False(this.app.eventTracer.IsEnabled())

        this.app.eventTracer.Start()

        Assert.True(this.app.eventTracer.IsEnabled())
        Assert.Equal(1, this.app.bus.InterceptorCount(),
            "tracer.Start() registers exactly one interceptor on the app's bus")
    }

    event_tracer_stop_removes_interceptor_from_app_bus()
    {
        ; Symmetric to the test above: Stop must clean up after
        ; itself. Important for any future refactor that adds a
        ; restart path (e.g. a runtime toggle in the Settings
        ; dialog) — each Stop has to leave InterceptorCount() at 0
        ; or the bus would accumulate dead interceptors over time.
        this.app.eventTracer.Start()
        Assert.Equal(1, this.app.bus.InterceptorCount(), "sanity: started")

        this.app.eventTracer.Stop()

        Assert.False(this.app.eventTracer.IsEnabled())
        Assert.Equal(0, this.app.bus.InterceptorCount(),
            "tracer.Stop() removes the interceptor from the app's bus")
    }

    event_tracer_active_captures_events_published_through_app_bus()
    {
        ; End-to-end check of the diagnostic feature: a tracer
        ; registered on the app's production bus captures events
        ; that the app itself publishes during normal operation.
        ; Uses a side-by-side tracer with an InMemoryLogger so the
        ; capture is inspectable without reading from a real log
        ; file (the production `app.log` is a LogService writing to
        ; disk; swapping it out would break dozens of unrelated
        ; subscribers). The probe tracer shares the bus and follows
        ; the same code path the production tracer would.
        memLog := InMemoryLogger()
        probe  := EventTraceLogger(this.app.bus, memLog)
        probe.Start()

        ; Trigger an event through the normal command path — same
        ; thing a hotkey press or settings save would produce in
        ; production. RunService consumes Commands.NewRunRequested
        ; and publishes Events.RunStarted as a side effect, so the
        ; trace should pick up both lines.
        this.app.bus.Publish(Commands.NewRunRequested, Map())

        Assert.True(memLog.HasEntry("INFO", Commands.NewRunRequested),
            "command event captured by tracer registered on app.bus")
        Assert.True(memLog.HasEntry("INFO", Events.RunStarted),
            "derived event also captured (proves the tracer sees the full event stream, not just the trigger)")

        probe.Stop()
    }

    ; ============================================================
    ; Run lifecycle via bus
    ; ============================================================

    new_run_via_command_starts_run()
    {
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        Assert.True(this.app.runService.IsActive())
        Assert.Equal("running", this.app.runService.GetStatus())
    }

    new_run_persists_to_ini()
    {
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        producedId := this.app.runService.GetRunId()
        Assert.True(StrLen(producedId) > 0, "RunId generated")

        ; Verifies persistence: a new RunStateRepository instance over
        ; the same INI reads the saved state
        ini := IniFile(this.iniPath)
        repo := RunStateRepository(ini)
        loaded := repo.Load()
        Assert.Equal(producedId, loaded.runId)
        Assert.Equal("running", loaded.status)
    }

    new_run_starts_timer()
    {
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        Assert.True(this.app.timer.IsRunning())
    }

    cancel_run_via_command_stops_run()
    {
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.app.bus.Publish(Commands.CancelRunRequested, Map())
        Assert.False(this.app.runService.IsActive())
        Assert.Equal("cancelled", this.app.runService.GetStatus())
    }

    ; ============================================================
    ; Finalize: 3min threshold
    ; ============================================================

    short_run_finalize_does_not_save_to_history()
    {
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        ; Advance clock 30s (much less than the 3min threshold)
        this.stubClock.AdvanceMs(30000)
        this.app.bus.Publish(Commands.FinalizeRunRequested, Map())

        files := this._ListRunFiles()
        Assert.Equal(0, files.Length,
            "Run < 3min must not be saved to history")
    }

    long_run_finalize_saves_to_history()
    {
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        ; Helper: simulates an active zone for 5min so totals has time
        ; (without it, buildResult.totalMs=0 and Save rejects).
        this._EnterZoneAndAdvance("The Riverbank", 300000)
        producedId := this.app.runService.GetRunId()
        this.app.bus.Publish(Commands.FinalizeRunRequested, Map())

        files := this._ListRunFiles()
        Assert.Equal(1, files.Length, "Run >= 3min saved to history")
        ; Filename is "{runId}.ini"
        Assert.Equal(producedId ".ini", files[1])
    }

    long_run_finalize_updates_personal_best()
    {
        ; No initial PB
        Assert.False(this.app.personalBest.HasRunPb())

        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(300000)   ; 5min
        producedId := this.app.runService.GetRunId()
        this.app.bus.Publish(Commands.FinalizeRunRequested, Map())

        Assert.True(this.app.personalBest.HasRunPb(),
            "PB updated after finalize of run >= 3min")
        Assert.Equal(producedId, this.app.personalBest.GetRunPbRunId())
        Assert.Equal(300000, this.app.personalBest.GetRunPbMs())
    }

    very_short_run_does_not_update_pb()
    {
        Assert.False(this.app.personalBest.HasRunPb())
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(30000)   ; 30s < 3min threshold
        this.app.bus.Publish(Commands.FinalizeRunRequested, Map())
        Assert.False(this.app.personalBest.HasRunPb(),
            "Run < 3min doesn't update PB")
    }

    ; ============================================================
    ; Crash recovery
    ; ============================================================

    second_app_instance_hydrates_active_run_from_disk()
    {
        ; First instance: create run and persist
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        firstRunId := this.app.runService.GetRunId()
        this.stubClock.AdvanceMs(60000)   ; 1min into the run
        ; Force timer persistence (normally via SetTimer)
        this.app.runService.PersistTick()

        ; "Crash": destroy first instance
        try this.app.Stop()
        this.app := ""

        ; Second instance: must hydrate the active run from the INI
        secondClock := Fixtures.MakeFakeClock(2000000)
        app2 := SpeedKalandraApp(Map(
            "iniPath",          this.iniPath,
            "zonesCsvPath",     this.zonesCsvPath,
            "logPath",          this.logPath,
            "runHistoryDir",    this.runHistoryDir,
            "personalBestPath", this.pbPath,
            "headless",         true,
            "clock",            secondClock
        ))

        Assert.True(app2.runService.IsActive(),
            "Active run hydrated from INI")
        Assert.Equal(firstRunId, app2.runService.GetRunId(),
            "Same runId preserved")

        try app2.Stop()
    }

    second_instance_resumes_timer_with_correct_base_ms()
    {
        ; First: 1min into the run
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(60000)
        this.app.runService.PersistTick()

        try this.app.Stop()
        this.app := ""

        ; Second: timer must continue with base = 60000ms
        secondClock := Fixtures.MakeFakeClock(2000000)
        app2 := SpeedKalandraApp(Map(
            "iniPath",          this.iniPath,
            "zonesCsvPath",     this.zonesCsvPath,
            "logPath",          this.logPath,
            "runHistoryDir",    this.runHistoryDir,
            "personalBestPath", this.pbPath,
            "headless",         true,
            "clock",            secondClock
        ))

        ; Timer hydrated as running with 60s already counted.
        ; Advancing 30s must result in 90s total.
        secondClock.AdvanceMs(30000)
        Assert.Equal(90000, app2.timer.GetRunMs())

        try app2.Stop()
    }

    ; ============================================================
    ; Hydration ordering: deferred Hydrate at end of __New
    ; ============================================================
    ;
    ; Anti-pattern: a previous version of SpeedKalandraApp.__New
    ; called runService.Hydrate(hydratedState) in the MIDDLE of
    ; construction -- right after the run service itself was built,
    ; well before RunStatsRecorder, the app's own _OnRunStartedForXp
    ; wiring, etc.
    ;
    ; When the loaded state had an active run, Hydrate published
    ; Evt.RunStarted{hydrated:true}. The interceptors that hadn't
    ; been constructed yet missed the event entirely. The most
    ; visible consequence: RunStatsRecorder._runId stayed "", so
    ; finalizing the hydrated run produced a snapshot with runId=""
    ; which RunHistoryRepository.Save silently rejected (`if
    ; currentRunId = "" return false`). The user lost the run.
    ;
    ; Fix: defer runService.Hydrate to the very end of __New, after
    ; _WireEventHandlers(). All subscribers are then in place when
    ; RunStarted{hydrated:true} fires. ZoneTrackingService had to be
    ; updated to respect the hydrated:true flag so the event no
    ; longer wipes the totals that were just restored from disk.

    hydrated_run_propagates_run_id_to_stats_recorder()
    {
        ; Set up an in-progress run on disk via the first app instance.
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        firstRunId := this.app.runService.GetRunId()
        this.stubClock.AdvanceMs(60000)
        this.app.runService.PersistTick()

        try this.app.Stop()
        this.app := ""

        ; Construct a second instance — this triggers Hydrate.
        secondClock := Fixtures.MakeFakeClock(2000000)
        app2 := SpeedKalandraApp(Map(
            "iniPath",          this.iniPath,
            "zonesCsvPath",     this.zonesCsvPath,
            "logPath",          this.logPath,
            "runHistoryDir",    this.runHistoryDir,
            "personalBestPath", this.pbPath,
            "headless",         true,
            "clock",            secondClock
        ))

        ; Pre-fix this returned "" because RunStatsRecorder
        ; was constructed after Hydrate fired.
        Assert.Equal(firstRunId, app2.statsRecorder.GetRunId(),
            "RunStatsRecorder receives runId from hydrated RunStarted")

        try app2.Stop()
    }

    hydrated_run_finalize_saves_to_history()
    {
        ; Set up a long enough run with zone time on disk.
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        firstRunId := this.app.runService.GetRunId()

        ; 5 minutes in Riverbank (well above the 3-min save threshold).
        this._EnterZoneAndAdvance("The Riverbank", 300000)

        ; Persist both timer baseMs and zone totals. In production
        ; this happens every 5s through the _runPersistTimer SetTimer,
        ; but the test setup does not call app.Start.
        this.app.runService.PersistTick()
        this.app.runState.SaveZoneTotals(
            this.app.zoneTracker.GetTotalsForSnapshot())

        try this.app.Stop()
        this.app := ""

        ; "Reboot" — second instance hydrates the in-progress run.
        secondClock := Fixtures.MakeFakeClock(2000000)
        app2 := SpeedKalandraApp(Map(
            "iniPath",          this.iniPath,
            "zonesCsvPath",     this.zonesCsvPath,
            "logPath",          this.logPath,
            "runHistoryDir",    this.runHistoryDir,
            "personalBestPath", this.pbPath,
            "headless",         true,
            "clock",            secondClock
        ))

        ; Sanity: hydration produced a coherent state.
        Assert.True(app2.runService.IsActive(), "sanity: hydrated as active")
        Assert.Equal(firstRunId, app2.runService.GetRunId())
        Assert.Equal(firstRunId, app2.statsRecorder.GetRunId(),
            "sanity: statsRecorder received runId")
        Assert.True(app2.zoneTracker.GetTotals().Has("The Riverbank"),
            "sanity: zone totals survived RunStarted{hydrated:true}")

        ; Finalize the hydrated run.
        app2.bus.Publish(Commands.FinalizeRunRequested, Map())

        ; A history file should now exist with the original runId.
        ; Pre-fix the save silently failed because the snapshot had
        ; runId="".
        files := []
        Loop Files, this.runHistoryDir "\*.ini"
            files.Push(A_LoopFileName)
        Assert.Equal(1, files.Length,
            "Hydrated run finalize saved to history (pre-fix silently failed)")
        Assert.Equal(firstRunId ".ini", files[1],
            "Saved file has the hydrated runId")

        try app2.Stop()
    }

    ; ============================================================
    ; Route service hydration ordering + re-sync (B4 hotfix)
    ; ============================================================
    ;
    ; Two anti-regression pins for the route widget feature:
    ;
    ;   1. The composition root must construct RouteService BEFORE
    ;      it calls runService.Hydrate() — same GSG §17 item 1
    ;      contract that the statsRecorder test above enforces.
    ;      Without it, a hydrated RunStarted at boot would land on
    ;      an empty subscriber list, and the route widget would
    ;      stay out of sync for the rest of the session (the next
    ;      ZoneEntered would NOT re-sync because there's no Reset
    ;      to trigger the zoneProvider lookup).
    ;
    ;   2. When the player is ALREADY standing in the first route
    ;      zone and a fresh RunStarted fires (autoStart matching
    ;      dialogue, or manual New Run after loading into the
    ;      zone), the highlight must persist. Pre-fix this was the
    ;      "falei com o homem ferido e o destaque sumiu" bug —
    ;      Reset cleared currentIdx to -1, and no new ZoneEntered
    ;      came because the player hadn't moved.
    ;
    ; Both rely on the closure wired in app.ahk:
    ;   zoneProvider := () => IsObject(this.zoneTracker)
    ;                         ? this.zoneTracker.GetActiveZone()
    ;                         : ""
    ; which is passed as the 4th arg to RouteService.__New. The
    ; unit tests cover the service in isolation with a stub
    ; provider; these integration tests prove the closure
    ; resolves through the real composition root.

    route_service_subscribed_before_hydrate_so_it_observes_hydrated_run_started()
    {
        ; Mirror of hydrated_run_propagates_run_id_to_stats_recorder
        ; (same pattern, different service).
        ;
        ; Set up an in-progress run on disk via the first app instance.
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(60000)
        this.app.runService.PersistTick()

        try this.app.Stop()
        this.app := ""

        ; Second instance: constructor calls runService.Hydrate(),
        ; which publishes RunStarted{hydrated:true}. RouteService
        ; must be wired and subscribed at that moment, or the
        ; event lands on no listener and the route widget will be
        ; out of sync for the session.
        secondClock := Fixtures.MakeFakeClock(2000000)
        app2 := SpeedKalandraApp(Map(
            "iniPath",          this.iniPath,
            "zonesCsvPath",     this.zonesCsvPath,
            "logPath",          this.logPath,
            "runHistoryDir",    this.runHistoryDir,
            "personalBestPath", this.pbPath,
            "deathLogPath",     this.deathLogPath,
            "headless",         true,
            "clock",            secondClock
        ))

        Assert.True(app2.routeService is RouteService,
            "RouteService wired on app2")
        Assert.True(app2.routeRepo is RouteRepository,
            "RouteRepository wired on app2")
        Assert.True(app2.bus.Subscribers(Events.RunStarted) >= 1,
            "At least one subscriber to RunStarted (includes RouteService)")
        Assert.True(app2.bus.Subscribers(Events.ZoneEntered) >= 1,
            "At least one subscriber to ZoneEntered (includes RouteService)")

        ; A clean construction without throw is the strongest
        ; assertion here: a RouteService constructed AFTER Hydrate
        ; published RunStarted would land in the wrong state
        ; (`_route` left as the empty-string field default), and
        ; the next ZoneEntered would crash with the production
        ; error we saw in the logs: `This value of type "String"
        ; has no method named "AdvanceTo"`. Reaching this line
        ; without throw means the ordering held.
        Assert.True(app2.runService.IsActive(),
            "sanity: hydrated active run survived the boot")

        try app2.Stop()
    }

    route_widget_highlight_persists_when_run_starts_inside_first_route_zone()
    {
        ; Anti-regression for the B4 hotfix scenario the user
        ; reproduced visually: runner already inside The Riverbank,
        ; talks to the wounded man, autoStart matches and fires
        ; RunStarted, highlight used to disappear until the next
        ; ZoneEntered (which might be minutes away).
        ;
        ; This test wires the real composition through to prove
        ; that the zoneProvider closure (`() => zoneTracker.
        ; GetActiveZone()`) resolves correctly when the route
        ; service's _OnRunLifecycleReset invokes it. The unit
        ; tests cover the re-sync logic in isolation with a
        ; stubbed provider; this integration test pins the wiring.
        ;
        ; Subscriber FIFO order matters here: RouteService is
        ; constructed BEFORE ZoneTrackingService in app.ahk, so
        ; when RunStarted fans out, RouteService's handler runs
        ; first — while ZoneTracker._activeZone is still populated.
        ; (Note: ZoneTracker._OnRunStarted does NOT clear
        ; _activeZone, but it does clear it on RunReset /
        ; RunCancelled. The FIFO ordering protects the Reset case;
        ; the no-clear-on-RunStarted convention protects this one.)

        ; Save a route file for the active profile, then refresh
        ; the in-memory service to pick it up. We touch the repo
        ; directly because the Settings UI for editing routes is
        ; not implemented yet (planned in B4 Commit 3).
        profileName := this.app._cfg.profileName
        this.app.routeRepo.Save(profileName,
            Route(["The Riverbank", "Mud Burrow"]))
        this.app.routeService.Refresh()
        Assert.Equal(2, this.app.routeService.Count(),
            "sanity: route loaded with 2 zones")

        ; The runner enters Riverbank BEFORE starting the run.
        ; _EnterZoneAndAdvance publishes ZoneChanged; ZoneTracker
        ; consumes that and re-publishes ZoneEntered (enriched
        ; with isTown from ZonesCatalog), which RouteService
        ; listens for and forwards to Route.AdvanceTo.
        this._EnterZoneAndAdvance("The Riverbank", 5000)
        Assert.Equal(0, this.app.routeService.GetCurrentIdx(),
            "sanity: ZoneEntered advanced the route to idx 0")
        Assert.Equal("The Riverbank", this.app.zoneTracker.GetActiveZone(),
            "sanity: zone tracker holds the active zone")

        ; Now start a new run. _OnRunLifecycleReset fires the path
        ; that used to strip the highlight: Reset() takes
        ; currentIdx to -1, then the zoneProvider lookup re-syncs
        ; via AdvanceTo("The Riverbank") back to idx 0.
        this.app.bus.Publish(Commands.NewRunRequested, Map())

        Assert.Equal(0, this.app.routeService.GetCurrentIdx(),
            "Bug fix: re-sync via zoneProvider keeps Riverbank "
            . "highlighted across RunStarted (was -1 pre-fix, "
            . "would have stayed -1 until the next ZoneEntered)")
    }

    ; ============================================================
    ; Stop (terminal lifecycle)
    ; ============================================================
    ;
    ; SpeedKalandraApp.Stop marks the instance terminal: `_stopped`
    ; flips to true and Start() throws afterwards. Stop itself is
    ; idempotent (multiple calls are safe), and stopping a
    ; never-Start()ed instance also marks it terminal.
    ;
    ; The integration setup never calls Start() (Start arms real
    ; SetTimer callbacks and creates real GUIs), so the Start()-throws
    ; tests below exercise the terminal-guard path directly: the
    ; throw fires BEFORE any side effect inside Start.

    stop_does_not_throw_when_never_started()
    {
        ; Setup didn't call Start; Stop must be a safe no-op for the
        ; cleanup work (no widgets to Hide, no timers to clear),
        ; while still marking the instance terminal.
        this.app.Stop()
        Assert.True(true)
    }

    stop_is_idempotent()
    {
        ; Calling Stop repeatedly is safe; the cleanup gate
        ; (`if !_started`) short-circuits subsequent calls so they
        ; don't try to Hide widgets twice or kill timers that no
        ; longer exist.
        this.app.Stop()
        this.app.Stop()
        Assert.True(true)
    }

    start_after_stop_throws()
    {
        ; The whole point of the terminal lifecycle: once Stop has
        ; run, Start refuses to ressurrect the instance. The throw
        ; runs before any side effect in Start, so we can assert
        ; against it directly even though Setup never built Start's
        ; world (widgets, SetTimers, etc.).
        this.app.Stop()
        Assert.Throws(Error, () => this.app.Start())
    }

    start_after_stop_throws_even_when_never_started()
    {
        ; Stop on a never-Start()ed instance still marks it terminal.
        ; There's no scenario where stopping makes Start viable — a
        ; user that calls Stop is explicitly declaring "I'm done
        ; with this instance". (The integration Setup doesn't call
        ; Start, so reaching this test means Stop was the only
        ; lifecycle call against the instance.)
        Assert.False(this.app._started, "Setup did not call Start")
        this.app.Stop()
        Assert.Throws(Error, () => this.app.Start())
    }

    ; ============================================================
    ; Undo last save rebuilds PBs from remaining history
    ; ============================================================
    ;
    ; Anti-pattern: a previous version of UndoLastSave deleted the
    ; run file but left PersonalBests pointing at the deleted run.
    ; The user had to manually click "Reset PBs" to fix the stale
    ; state -- inconsistent with the "Delete" button in
    ; RunHistoryDialog, which DID rebuild PBs.
    ;
    ; Fix: UndoLastSave calls PersonalBestService.RebuildFromHistory
    ; after a successful delete (mirrors RunHistoryDialog). The
    ; _RebuildPbsFromHistory helper on the app loads every surviving
    ; run and re-derives PBs from them.

    undo_last_save_rebuilds_pbs_from_history()
    {
        ; Complete one run — it becomes the PB.
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this._EnterZoneAndAdvance("The Riverbank", 300000)
        producedRunId := this.app.runService.GetRunId()
        this.app.bus.Publish(Commands.FinalizeRunRequested, Map())

        ; Sanity: PB is set and the run file exists.
        Assert.True(this.app.personalBest.HasRunPb(),
            "sanity: PB updated after finalize")
        Assert.Equal(producedRunId, this.app.personalBest.GetRunPbRunId())
        Assert.Equal(1, this._ListRunFiles().Length, "sanity: run saved to disk")

        ; Production sets _lastSavedRunId inside RunSnapshotSaver._MarkUndoable,
        ; but that path is gated by !_headless (it also adds a tray menu
        ; entry and arms a 60 s SetTimer). In headless tests we poke the
        ; saver's field directly so UndoLastSave has a target.
        this.app._snapshotSaver._lastSavedRunId := producedRunId

        this.app.UndoLastSave()

        ; File removed from disk.
        Assert.Equal(0, this._ListRunFiles().Length,
            "Run file removed from history after undo")

        ; PB rebuilt from the (now empty) history: the undone run no
        ; longer contributes, and with no surviving runs the PB is
        ; cleared. This is the assertion that would have FAILED before
        ; the fix -- the PB used to be left pointing at the deleted
        ; run.
        Assert.False(this.app.personalBest.HasRunPb(),
            "PB rebuilt from history: no surviving runs => no PB")
        Assert.Equal(0,  this.app.personalBest.GetRunPbMs())
        Assert.Equal("", this.app.personalBest.GetRunPbRunId())
    }

    ; ============================================================
    ; _AssertWired — boot-time wiring validation
    ; ============================================================
    ;
    ; Called at the end of SpeedKalandraApp.__New, after
    ; _WireEventHandlers and before runService.Hydrate. Catches
    ; refactor mistakes that drop or reorder a constructor at
    ; construction time, with a clear error pointing at the missing
    ; field, instead of letting the failure surface much later as a
    ; cryptic null-method-access during event dispatch.

    assert_wired_passes_after_normal_construction()
    {
        ; Setup already constructed `this.app` successfully, which
        ; means _AssertWired ran inside __New and didn't throw. Call
        ; it explicitly anyway as a smoke check — if it throws here,
        ; the assertion list and the real wiring have drifted apart.
        this.app._AssertWired()
        Assert.True(true, "_AssertWired re-callable post-construction")
    }

    assert_wired_throws_when_object_field_is_empty()
    {
        ; Force one of the validated object fields to the empty
        ; string and confirm the next call to _AssertWired raises a
        ; clear Error mentioning that field. This is what the
        ; in-__New call would have done on a real wiring regression.
        ;
        ; Note on the try/catch shape: an external `threwAsExpected`
        ; flag is used instead of putting `Assert.Fail` inside `try`,
        ; because Assert.Fail itself throws AssertionFailed and would
        ; be silently swallowed by the same `catch`, giving a false
        ; positive when _AssertWired didn't actually throw.
        this.app.statsRecorder := ""
        threwAsExpected := false
        capturedMessage := ""
        try
        {
            this.app._AssertWired()
        }
        catch as ex
        {
            threwAsExpected := true
            capturedMessage := ex.Message
        }
        Assert.True(threwAsExpected,
            "_AssertWired should have thrown for unwired statsRecorder")
        Assert.True(InStr(capturedMessage, "statsRecorder") > 0,
            "Error message names the unwired field: " . capturedMessage)
        Assert.True(InStr(capturedMessage, "_AssertWired") > 0,
            "Error message identifies the source: " . capturedMessage)
    }

    assert_wired_throws_when_persist_fn_is_not_callable()
    {
        ; _persistFn is checked separately from the object fields
        ; because in AHK v2 closures aren't necessarily classified as
        ; objects for every IsObject path — the validation uses
        ; (is Func || HasMethod "Call"). Confirm that branch fires.
        this.app._persistFn := ""
        threwAsExpected := false
        capturedMessage := ""
        try
        {
            this.app._AssertWired()
        }
        catch as ex
        {
            threwAsExpected := true
            capturedMessage := ex.Message
        }
        Assert.True(threwAsExpected,
            "_AssertWired should have thrown for non-callable _persistFn")
        Assert.True(InStr(capturedMessage, "_persistFn") > 0,
            "Error message names the unwired closure: " . capturedMessage)
    }

    ; ============================================================
    ; End-to-end run flow
    ; ============================================================
    ;
    ; The other integration tests cover each piece of a run
    ; individually (start, area level, zone, finalize, undo). This
    ; test runs the sequence the user actually performs, with every
    ; intermediate event the production pipeline would publish, and
    ; asserts that each subsystem ended up in the right post-state.
    ; Designed as the canonical smoke test for the whole bus topology:
    ; if a new field gets wired into the chain incorrectly, this
    ; test breaks before any of the narrower tests do, and the
    ; failure points at which subsystem disagrees.

    cancelled_long_run_saves_to_history_with_zone_totals_intact()
    {
        ; Anti-regression (bus-subscription FIFO race):
        ;
        ; A run that is cancelled after the 3-minute threshold must
        ; still be persisted to history, AND the saved snapshot must
        ; include the zone totals — even though ZoneTrackingService
        ; clears `_totals` and RunStatsRecorder calls `Reset()` on
        ; RunCancelled. The save runs through RunService's
        ; SetOnBeforeCancel hook, which fires after the timer is
        ; stopped and BEFORE the lifecycle event is published, so
        ; subscriber state-clearing happens strictly after the save.
        ;
        ; The earlier design relied on FIFO ordering of subscriptions
        ; in SpeedKalandraApp.__New (Save subscribed before
        ; zoneTracker/statsRecorder so it ran first when the event
        ; fanned out). That contract was implicit and easy to break
        ; by reordering constructors; this test catches a regression
        ; in either the hook semantics OR a hypothetical revert to
        ; bus-subscription save.
        this.app.bus.Publish(Commands.NewRunRequested, Map())

        ; 5 minutes of zone time — well above the 3-minute save
        ; threshold, and gives _totals a real value to verify.
        this._EnterZoneAndAdvance("Mud Burrow", 300000)
        producedId := this.app.runService.GetRunId()

        this.app.bus.Publish(Commands.CancelRunRequested, Map())

        ; Run saved to history.
        files := this._ListRunFiles()
        Assert.Equal(1, files.Length,
            "long-cancelled run is persisted (>= 3 min threshold)")
        Assert.Equal(producedId ".ini", files[1],
            "saved file is named after the runId")

        ; And the saved snapshot carries the run's totals (proves the
        ; hook saw _totals before zoneTracker._OnRunEnded cleared them).
        loadedRun := this.app.runHistory.Load(producedId)
        Assert.True(IsObject(loadedRun),
            "saved run loads back")
        Assert.True(loadedRun["totalMs"] >= 300000,
            "saved totalMs covers the 5 min of zone time")

        ; State-clearing on the bus subscribers should have happened
        ; AFTER the save — _totals is now empty.
        Assert.Equal(0, this.app.zoneTracker.GetTotals().Count,
            "zone tracker state is cleared post-RunCancelled (subscriber ran after the hook)")
    }

    ; ============================================================
    ; Zone-PB exclusion: interrupted-by-hotkey visit
    ; ============================================================
    ;
    ; End-to-end guardrail for the fix that excludes the zone visit
    ; interrupted by the FinalizeRun hotkey from PB-eligible zone
    ; totals. The fix touches three layers (ZoneTrackingService
    ; tracks per-visit elapsed; RunSnapshotSaver discounts it from
    ; the totals passed to PersonalBestService.UpdateFromRun; the
    ; same discount is mirrored by RebuildFromHistory on Undo). The
    ; unit tests cover each layer in isolation; these two integration
    ; tests prove the wiring works through the real composition root.

    interrupted_visit_does_not_create_artificial_zone_pb()
    {
        ; Original bug scenario: user is deep into a run, then
        ; presses the FinalizeRun hotkey right after entering a
        ; fresh zone. Pre-fix, that zone's PB became the 3 s spent
        ; in it (its only visit's total was 3 s, so 3 s landed in
        ; the zonePbs map). The fix keeps the zone out of PB-eligible
        ; totals when its only visit was the interrupted one.
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this._EnterZoneAndAdvance("The Riverbank",         180000)  ; 3 min
        this._EnterZoneAndAdvance("Mud Burrow",             60000)  ; 1 min
        this._EnterZoneAndAdvance("Clearfell Encampment",   3000)  ; 3 s, will be interrupted
        producedRunId := this.app.runService.GetRunId()
        this.app.bus.Publish(Commands.FinalizeRunRequested, Map())

        ; History was written; the run is long enough.
        Assert.Equal(1, this._ListRunFiles().Length,
            "sanity: run saved (>=3min)")
        Assert.Equal(producedRunId, this.app.personalBest.GetRunPbRunId(),
            "sanity: global run PB recorded")

        ; The first two zones each had a single complete visit;
        ; they're PB-eligible.
        Assert.Equal(180000, this.app.personalBest.GetZonePbMs("The Riverbank"),
            "Riverbank closed via transition: full visit is a PB candidate")
        Assert.Equal(60000, this.app.personalBest.GetZonePbMs("Mud Burrow"),
            "Mud Burrow closed via transition: full visit is a PB candidate")

        ; The interrupted zone has no PB at all -- this is the
        ; assertion that would have FAILED before the fix (it would
        ; have been 3000 ms).
        Assert.Equal(0, this.app.personalBest.GetZonePbMs("Clearfell Encampment"),
            "Interrupted-only visit is NOT a PB candidate (would have been 3000ms pre-fix)")

        ; The factual history still records the visit -- the discount
        ; is for PBs only, not for the run's totals or details.
        loadedRun := this.app.runHistory.Load(producedRunId)
        Assert.True(IsObject(loadedRun))
        Assert.Equal("Clearfell Encampment", loadedRun["interruptedZoneName"],
            "buildResult records which zone was interrupted")
        Assert.Equal(3000, loadedRun["interruptedZoneVisitMs"],
            "buildResult records the interrupted visit's elapsed")
    }

    interrupted_visit_after_complete_visit_preserves_complete_visit_pb()
    {
        ; Permissive scenario: zone X visited twice in the same run
        ; (60 s closed via transition, then 3 s interrupted by
        ; hotkey). The factual zoneTotals for X is 63000 ms (sum of
        ; both visits), but the PB-eligible total is the closed
        ; visit's 60000 ms -- only the interrupted visit's 3000 ms
        ; is subtracted, the prior complete-visit time is preserved.
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this._EnterZoneAndAdvance("Mud Burrow",     60000)   ; visit 1: closed
        this._EnterZoneAndAdvance("The Riverbank", 180000)   ; intermediate zone
        this._EnterZoneAndAdvance("Mud Burrow",      3000)   ; visit 2: interrupted
        producedRunId := this.app.runService.GetRunId()
        this.app.bus.Publish(Commands.FinalizeRunRequested, Map())

        Assert.Equal(1, this._ListRunFiles().Length, "sanity: run saved")

        ; The Riverbank is a normal closed visit.
        Assert.Equal(180000, this.app.personalBest.GetZonePbMs("The Riverbank"))

        ; Mud Burrow's PB is the closed-visit time, NOT the sum and
        ; NOT the interrupted visit. Pre-fix this would have been
        ; 63000 (the factual sum).
        Assert.Equal(60000, this.app.personalBest.GetZonePbMs("Mud Burrow"),
            "Permissive: closed visit (60s) is the PB candidate; "
            . "interrupted visit (3s) discounted, prior visit preserved")

        ; Factual history: both visits show up in the run's details
        ; (the plot builder produces detail rows per zone visit). The
        ; discount applies only to PB candidates, NOT to the saved
        ; history -- the run's full timeline survives intact.
        ;
        ; Note: loadedRun["totals"] is the per-category map
        ; (mapa/cidade/loading/morte), not a per-zone lookup; the
        ; per-zone data lives in loadedRun["details"]. We sum the
        ; Mud Burrow detail rows defensively (the builder may emit
        ; one row aggregating both visits, or one per visit; either
        ; way the total is 63000ms).
        loadedRun := this.app.runHistory.Load(producedRunId)
        Assert.True(IsObject(loadedRun))
        mudBurrowMs := 0
        for _, d in loadedRun["details"]
        {
            if (d.Has("label") && d["label"] = "Mud Burrow")
                mudBurrowMs += d["ms"]
        }
        Assert.Equal(63000, mudBurrowMs,
            "Factual ms is the sum of both visits (no discount in history)")
        Assert.Equal("Mud Burrow", loadedRun["interruptedZoneName"])
        Assert.Equal(3000, loadedRun["interruptedZoneVisitMs"])
    }

    log_monitor_with_catalog_resolves_internal_id_in_zone_tracker()
    {
        ; Anti-regression (zone internal id leaking as human name):
        ;
        ; Prove end-to-end that when LogMonitor parses a [SCENE]
        ; line carrying an engine internal id, the zone tracker
        ; stores time under the canonical human name from the
        ; catalog, NOT the raw id. Without resolution, the same
        ; physical zone could be split across two keys (e.g. one
        ; "You have entered Mud Burrow" emits "Mud Burrow" and a
        ; later "[SCENE] Set Source [G1_3]" emits "G1_3"), and any
        ; tally that walked _totals would double-count or skip the
        ; zone depending on which key the consumer looked up.
        ;
        ; Path under test:
        ;   logMonitor.ProcessText → publishes ZoneChanged with
        ;   zoneName resolved via the catalog → zoneTracker._OnZoneChanged
        ;   stores _totals[humanName].
        this.app.bus.Publish(Commands.NewRunRequested, Map())

        ; Simulate PoE2 emitting the engine id for Mud Burrow.
        this.app.logMonitor.ProcessText("[SCENE] Set Source [G1_3]`n")
        this.stubClock.AdvanceMs(5000)

        ; Move to a second zone so _FlushActive runs and writes the
        ; first zone's total into _totals.
        this.app.logMonitor.ProcessText("[SCENE] Set Source [G1_town]`n")

        totals := this.app.zoneTracker.GetTotals()
        Assert.True(totals.Has("Mud Burrow"),
            "totals key is canonical human name from catalog")
        Assert.False(totals.Has("G1_3"),
            "raw internal id G1_3 must not appear as a totals key")
        Assert.True(totals["Mud Burrow"] >= 5000,
            "accumulated time landed under the human-name key")
    }

    complete_run_flow_from_start_to_finalize_to_undo()
    {
        ; ---- 1. Start a run ----
        Assert.False(this.app.runService.IsActive(),
            "pre: no active run")
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        producedRunId := this.app.runService.GetRunId()
        Assert.True(this.app.runService.IsActive(),
            "step 1: run is now active")
        Assert.True(this.app.timer.IsRunning(),
            "step 1: timer is running")
        Assert.Equal(producedRunId, this.app.statsRecorder.GetRunId(),
            "step 1: statsRecorder received runId from RunStarted")

        ; ---- 2. Area level changed (Act 1 starting area) ----
        ; In production this comes through the bus as
        ; Events.AreaLevelChanged, but the subscriber lives in
        ; SpeedKalandraApp.Start() — which the integration tests
        ; deliberately don't call (it renders real widgets and arms
        ; SetTimers). Calling the handler directly is equivalent for
        ; the purpose of this end-to-end check; the bus topology of
        ; Start() is left to whatever future tests want to exercise it.
        this.app._OnAreaLevelChanged(Map(
            "areaLevel", 1,
            "areaCode",  "G1_1"
        ))
        Assert.Equal(1,      this.app._cfg.currentAreaLevel,
            "step 2: area level propagated to cfg")
        Assert.Equal("G1_1", this.app._cfg.currentAreaCode,
            "step 2: area code propagated to cfg")

        ; ---- 3. Zone entered: Mud Burrow + 60 s in zone ----
        this._EnterZoneAndAdvance("Mud Burrow", 60000)
        Assert.Equal("Mud Burrow", this.app.zoneTracker.GetActiveZone(),
            "step 3: ZoneTracker tracks the active zone")

        ; ---- 4. Loading measured between Mud Burrow and Riverbank ----
        ; Normally published by LoadingDetectionService after a
        ; pixel-anchored loading screen closes. We publish directly
        ; because pixel detection isn't exercisable in headless tests.
        this.app.bus.Publish(Events.LoadingMeasured, Map(
            "durationMs", 5000,
            "fromZone",   "Mud Burrow",
            "toZone",     "The Riverbank",
            "source",     "anchor",
            "score",      0.95,
            "anchor",     "hud"
        ))
        Assert.Equal(5000, this.app.loadingTotals.GetTotalMs(),
            "step 4: LoadingTotalsService accumulated the measured loading")

        ; ---- 5. Continue through zones (totalling > 3 min) ----
        this._EnterZoneAndAdvance("The Riverbank",       120000)  ; 2 min
        this._EnterZoneAndAdvance("Clearfell Encampment", 60000)  ; 1 min (town)
        this._EnterZoneAndAdvance("Mud Burrow",          120000)  ; 2 min back
        ; Cumulative: 60 + 120 + 60 + 120 = 360 s = 6 min (above the
        ; 3-min save threshold; far enough above to leave slack for
        ; any rounding the snapshot does).

        ; ---- 6. Persist mid-run state (production: 5 s SetTimer) ----
        this.app.runService.PersistTick()
        this.app.runState.SaveZoneTotals(
            this.app.zoneTracker.GetTotalsForSnapshot())

        ; ---- 7. Finalize the run ----
        this.app.bus.Publish(Commands.FinalizeRunRequested, Map())
        Assert.False(this.app.runService.IsActive(),
            "step 7: run is finalized, no longer active")
        Assert.Equal("completed", this.app.runService.GetStatus(),
            "step 7: status is completed")

        ; ---- 8. History was saved ----
        files := this._ListRunFiles()
        Assert.Equal(1, files.Length,
            "step 8: exactly one history file produced")
        Assert.Equal(producedRunId . ".ini", files[1],
            "step 8: file is named after the runId")

        ; Reload the saved run from disk and check it carries the
        ; key facts the user expects to see in their history.
        loadedRun := this.app.runHistory.Load(producedRunId)
        Assert.True(IsObject(loadedRun),
            "step 8: saved run loads back")
        Assert.Equal(producedRunId, loadedRun["runId"],
            "step 8: saved runId matches")
        Assert.True(loadedRun["totalMs"] >= 360000,
            "step 8: saved totalMs covers the >=6min of zone time")

        ; ---- 9. Personal best updated ----
        Assert.True(this.app.personalBest.HasRunPb(),
            "step 9: PB recorded for completed run")
        Assert.Equal(producedRunId, this.app.personalBest.GetRunPbRunId(),
            "step 9: PB points at this run")
        Assert.True(this.app.personalBest.GetRunPbMs() >= 360000,
            "step 9: PB ms matches saved totalMs")

        ; ---- 10. Undo the save ----
        ; In headless mode RunSnapshotSaver doesn't arm the tray-undo
        ; menu entry (it's gated by !_headless), so _lastSavedRunId
        ; stays empty. Set it manually so UndoLastSave has a target.
        this.app._snapshotSaver._lastSavedRunId := producedRunId
        this.app.UndoLastSave()

        Assert.Equal(0, this._ListRunFiles().Length,
            "step 10: history file removed by undo")
        Assert.False(this.app.personalBest.HasRunPb(),
            "step 10: PB rebuilt from now-empty history")
        Assert.Equal("", this.app.personalBest.GetRunPbRunId(),
            "step 10: PB runId cleared")
        Assert.Equal(0, this.app.personalBest.GetRunPbMs(),
            "step 10: PB ms zeroed")
    }

    ; ============================================================
    ; Riverbank single-reset (Bug #9)
    ; ============================================================
    ;
    ; Anti-pattern: a previous version of _OnZoneEnteredForLevel
    ; matched "Riverbank" as a substring and reset unconditionally.
    ;   Problem 1: substring match (any zone with "Riverbank" in the
    ;              name would match).
    ;   Problem 2: re-entry (death respawn, portal, party invite) reset
    ;              the cached level to 1, causing wrong XP display
    ;              until the next CharacterLevelUp.
    ;
    ; Fix: exact match "The Riverbank" + _riverbankSeenInRun flag.
    ; Flag reset on RunStarted (new run unlocks new reset) and on
    ; RunReset/RunCancelled.
    ;
    ; The tests call `_OnZoneEnteredForLevel` directly on the instance
    ; (handler is subscribed in app.Start() which we don't call here).
    ; That covers the once-only logic without needing the widget Show.

    bug9_first_riverbank_entry_resets_level_to_1()
    {
        ; Active run + level set to 50
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.app.xpService.SetCharacter("Olaf", "Warrior", 50)
        Assert.Equal(50, this.app.xpService.GetCharacterLevel())

        ; First entry into "The Riverbank" must reset level to 1
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank"))
        Assert.Equal(1, this.app.xpService.GetCharacterLevel(),
            "Bug #9: first entry into The Riverbank resets level to 1")
    }

    bug9_second_riverbank_entry_does_not_reset_level()
    {
        ; Setup: active run, first entry into Riverbank already happened
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.app.xpService.SetCharacter("Olaf", "Warrior", 50)
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank"))
        Assert.Equal(1, this.app.xpService.GetCharacterLevel())

        ; Simulate progression: player leveled up to 5 since the first
        ; entry (e.g. via CharacterLevelUp event that set the level)
        this.app.xpService.SetCharacter("Olaf", "Warrior", 5)
        Assert.Equal(5, this.app.xpService.GetCharacterLevel())

        ; Second entry into Riverbank (death respawn / portal / invite):
        ; must NOT reset (Bug #9 fix)
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank"))
        Assert.Equal(5, this.app.xpService.GetCharacterLevel(),
            "Bug #9: re-entry into Riverbank does NOT reset level (flag blocks)")
    }

    bug9_non_exact_match_does_not_trigger_reset()
    {
        ; Pre-fix, "InStr(zone, \"Riverbank\")" would match any substring.
        ; Fix uses exact match, so similar but non-exact zones don't
        ; reset (defensive against hypothetical PoE2 name changes).
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.app.xpService.SetCharacter("Olaf", "Warrior", 50)

        ; Zones with "Riverbank" in the name but not exact
        this.app._OnZoneEnteredForLevel(Map("zoneName", "Riverbank"))           ; no "The"
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank East"))  ; suffix
        this.app._OnZoneEnteredForLevel(Map("zoneName", "Old Riverbank"))       ; prefix

        Assert.Equal(50, this.app.xpService.GetCharacterLevel(),
            "Bug #9: exact match 'The Riverbank' — substrings don't match")
    }

    bug9_new_run_clears_riverbank_flag()
    {
        ; Setup: run 1 with Riverbank already visited
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.app.xpService.SetCharacter("Olaf", "Warrior", 50)
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank"))
        ; Level reset to 1, _riverbankSeenInRun = true

        ; Set level to 10 (simulating progression in the run)
        this.app.xpService.SetCharacter("Olaf", "Warrior", 10)

        ; New run: fires RunStarted -> _OnRunStartedForXp clears flag
        ; (handler is subscribed in __New via _WireEventHandlers, active
        ; even without Start)
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        ; Set level again (NewRun zeroes area but not character level)
        this.app.xpService.SetCharacter("Olaf", "Warrior", 10)

        ; First entry into Riverbank in the new run: MUST reset
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank"))
        Assert.Equal(1, this.app.xpService.GetCharacterLevel(),
            "Bug #9: NewRun clears flag, allowing new reset in the new run")
    }

    bug9_run_reset_clears_riverbank_flag()
    {
        ; Same scenario as _new_run but via Reset instead of NewRun.
        ; _OnRunEndedClearZones is subscribed on RunReset and RunCancelled.
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.app.xpService.SetCharacter("Olaf", "Warrior", 50)
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank"))

        this.app.xpService.SetCharacter("Olaf", "Warrior", 10)
        this.app.bus.Publish(Commands.ResetRunRequested, Map())

        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.app.xpService.SetCharacter("Olaf", "Warrior", 10)
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank"))
        Assert.Equal(1, this.app.xpService.GetCharacterLevel(),
            "Bug #9: Reset also clears flag (via _OnRunEndedClearZones)")
    }

    ; ============================================================
    ; Death penalty on the real-time timer
    ; ============================================================
    ;
    ; Anti-pattern: a previous version of the death-handling path
    ; only fed cfg.deathPenaltyMs into the post-finalize plot
    ; ("Deaths" category in RunStatsPlotBuilder). The real-time run
    ; timer didn't reflect the penalty, creating a visual
    ; inconsistency: the user would see 1:05:00 in the overlay but
    ; 1:07:30 in the plot after finalize.
    ;
    ; Fix: _OnDeathApplyTimerPenalty handler subscribed to
    ; Evt.DeathDetected. When it fires and cfg.deathPenaltyEnabled +
    ; timer.IsActive(), calls timer.AddPenaltyMs(cfg.deathPenaltyMs).
    ; The user sees the pointer jump forward in the overlay the
    ; moment they die.
    ;
    ; AppSettings.deathPenaltyEnabled is opt-in (default false) and
    ; AppSettings.deathPenaltyMs defaults to 150_000 (2:30). Tests
    ; that exercise the enabled path flip the flag explicitly so the
    ; assertion below is robust to future default changes; tests that
    ; exercise a downstream guard (no-run-active, ms<=0, etc.) also
    ; flip enabled=true so they reach the guard they promise to test
    ; rather than short-circuiting on the enabled gate.
    ;
    ; These tests publish Evt.DeathDetected directly on the bus to
    ; simulate the event that normally comes from LogMonitorService
    ; (when parsing a death line in Client.txt).

    death_penalty_applies_to_timer_when_enabled_and_run_active()
    {
        ; Start run, advance 1min, fire DeathDetected
        ; -> timer must jump to 1min + 150s (default penalty) = 3min30s
        this.app._cfg.deathPenaltyEnabled := true
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(60000)   ; 1min
        Assert.Equal(60000, this.app.timer.GetRunMs())

        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        ; 60000 (clock) + 150000 (default penalty) = 210000
        Assert.Equal(210000, this.app.timer.GetRunMs(),
            "Death penalty (150s) added to the real-time timer")
    }

    death_penalty_does_not_apply_when_disabled()
    {
        ; cfg.deathPenaltyEnabled := false disables the handler.
        ; Publish DeathDetected and the timer must not move.
        this.app._cfg.deathPenaltyEnabled := false

        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(60000)
        before := this.app.timer.GetRunMs()

        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        Assert.Equal(before, this.app.timer.GetRunMs(),
            "With flag off, DeathDetected doesn't move the timer")
    }

    death_penalty_does_not_apply_when_no_run_active()
    {
        ; Without NewRun, timer.IsActive() = false. Handler returns early
        ; on the IsActive guard (NOT on the enabled gate — we flip enabled
        ; on so the test reaches the guard it promises to cover).
        this.app._cfg.deathPenaltyEnabled := true
        Assert.False(this.app.timer.IsActive())
        before := this.app.timer.GetRunMs()   ; 0

        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        Assert.Equal(before, this.app.timer.GetRunMs(),
            "Without active run, DeathDetected is ignored")
        Assert.False(this.app.timer.IsActive(),
            "Timer stays IDLE after a death outside a run")
    }

    death_penalty_accumulates_with_multiple_deaths()
    {
        ; 3 deaths in the same run -> timer gains 3 * penalty
        this.app._cfg.deathPenaltyEnabled := true
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(60000)   ; 1min

        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))
        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))
        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        ; 60s + 3 * 150s = 60 + 450 = 510s
        Assert.Equal(510000, this.app.timer.GetRunMs(),
            "3 deaths accumulate 3 * 150s on the timer")
    }

    death_penalty_uses_configured_ms_value()
    {
        ; Custom cfg.deathPenaltyMs (90s) must be respected.
        this.app._cfg.deathPenaltyEnabled := true
        this.app._cfg.deathPenaltyMs := 90000

        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(60000)
        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        Assert.Equal(150000, this.app.timer.GetRunMs(),
            "60s + cfg.deathPenaltyMs (90s) = 150s")
    }

    death_penalty_does_not_apply_when_configured_ms_is_zero()
    {
        ; Defensive edge case: if cfg.deathPenaltyMs = 0 (the user
        ; explicitly configured "no penalty"), handler returns early
        ; on the ms<=0 guard. Flip enabled=true so the test reaches
        ; that guard rather than short-circuiting on the enabled gate.
        this.app._cfg.deathPenaltyEnabled := true
        this.app._cfg.deathPenaltyMs := 0

        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(60000)
        before := this.app.timer.GetRunMs()

        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        Assert.Equal(before, this.app.timer.GetRunMs(),
            "deathPenaltyMs=0 doesn't move the timer")
    }

    ; ============================================================
    ; Death log (independent of run lifecycle)
    ; ============================================================

    constructor_creates_death_log_components()
    {
        Assert.True(this.app.deathLog is DeathLogRepository,
            "DeathLogRepository wired on the app")
        Assert.True(this.app.deathStatsService is DeathStatsService,
            "DeathStatsService wired on the app")
        Assert.True(this.app.deathLogScanner is DeathLogScanner,
            "DeathLogScanner wired on the app (drives the dialog's "
            . "All-time view; independent of deathLog)")
    }

    death_detected_appends_row_with_active_zone_patch_and_profile()
    {
        ; A run is active, the player just entered Mud Burrow. Patch
        ; and profile are configured to recognizable test values so
        ; the round-trip is unambiguous.
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this._EnterZoneAndAdvance("Mud Burrow", 10000)

        this.app._cfg.gamePatch   := "0.4-test"
        this.app._cfg.profileName := "IntegrationBuild"

        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        rows := this.app.deathLog.LoadAll()
        Assert.Equal(1, rows.Length, "One row written per DeathDetected")
        Assert.Equal("Mud Burrow",       rows[1]["zoneName"],
            "Active zone captured from ZoneTrackingService")
        Assert.Equal("0.4-test",         rows[1]["patch"],
            "cfg.gamePatch captured")
        Assert.Equal("IntegrationBuild", rows[1]["profile"],
            "cfg.profileName captured")
    }

    death_detected_with_no_active_zone_silently_skips_append()
    {
        ; Legitimate gap: a death line can arrive before any
        ; ZoneChanged seeded the active zone (e.g. log seed on boot
        ; before the player moves). The handler must early-return
        ; and the log file must stay absent.
        Assert.Equal("", this.app.zoneTracker.GetActiveZone(),
            "sanity: no active zone before any ZoneChanged")

        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        Assert.Equal(0, this.app.deathLog.LoadAll().Length,
            "No append when active zone is empty")
        Assert.False(FileExist(this.deathLogPath) != "",
            "deaths.csv not created when nothing was appended")
    }

    death_detected_aggregation_via_service_returns_zone_counts()
    {
        ; End-to-end via the production service the dialog will
        ; consume: 3 deaths across 2 zones, in the order the player
        ; would experience them. Aggregate must reflect both the
        ; total and the per-zone breakdown sorted by count desc.
        this.app.bus.Publish(Commands.NewRunRequested, Map())

        this._EnterZoneAndAdvance("Mud Burrow", 5000)
        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))
        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        this._EnterZoneAndAdvance("The Riverbank", 5000)
        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        result := this.app.deathStatsService.Aggregate()
        Assert.Equal(3, result["totalDeaths"])
        Assert.Equal(2, result["perZone"].Length)
        Assert.Equal("Mud Burrow",    result["perZone"][1]["zoneName"])
        Assert.Equal(2,               result["perZone"][1]["count"])
        Assert.Equal("The Riverbank", result["perZone"][2]["zoneName"])
        Assert.Equal(1,               result["perZone"][2]["count"])
    }

    ; ============================================================
    ; Layout variant branching (Plus opt-in)
    ; ============================================================

    default_layout_variant_constructs_classic_steve_widget()
    {
        ; Setup() built the app without writing [Layouts] to the INI,
        ; so AppSettings.layoutVariant defaults to "classic" and the
        ; composition root picks SteveLayoutWidget (not Plus). Pinning
        ; the default keeps a future change of the default opt-in from
        ; flipping every existing user's overlay without warning.
        Assert.True(this.app.steveWidget is SteveLayoutWidget,
            "default cfg.layoutVariant=classic constructs Classic Steve")
        Assert.False(this.app.steveWidget is SteveLayoutPlusWidget,
            "and not Plus")
        Assert.Equal("classic", this.app._cfg.layoutVariant,
            "sanity: default cfg.layoutVariant is classic")
    }

    layout_variant_plus_in_ini_constructs_plus_steve_widget()
    {
        ; Stop the default-variant app, then write [Layouts]
        ; Variant=plus into the same INI and construct a second
        ; instance. Verifies the entire load path: SettingsRepository
        ; reads the [Layouts] section, AppSettings normalizes the
        ; string, and SpeedKalandraApp.__New branches on it.
        ;
        ; Both Plus and Classic share WIDGET_ID, so the user's
        ; position carries across — also pinned here.
        try this.app.Stop()
        this.app := ""

        ; Write the opt-in to the INI we'll point the new instance at.
        ; Other sections are untouched, so this exercises the merge
        ; path (AppSettings.FromMap fills defaults around the one
        ; field we set).
        ini := IniFile(this.iniPath)
        ini.Write("plus", "Layouts", "Variant")

        secondClock := Fixtures.MakeFakeClock(2000000)
        app2 := SpeedKalandraApp(Map(
            "iniPath",          this.iniPath,
            "zonesCsvPath",     this.zonesCsvPath,
            "logPath",          this.logPath,
            "runHistoryDir",    this.runHistoryDir,
            "personalBestPath", this.pbPath,
            "deathLogPath",     this.deathLogPath,
            "headless",         true,
            "clock",            secondClock
        ))

        Assert.Equal("plus", app2._cfg.layoutVariant,
            "AppSettings read layoutVariant=plus from INI")
        Assert.True(app2.steveWidget is SteveLayoutPlusWidget,
            "cfg.layoutVariant=plus constructs Plus Steve")
        Assert.True(app2.steveWidget is LayoutWidgetBase,
            "Plus extends LayoutWidgetBase — sanity check on the"
            . " class hierarchy (the OverlayModeApplier dispatches"
            . " on LayoutWidgetBase methods like Show/Hide)")
        Assert.False(app2.steveWidget is SteveLayoutWidget,
            "Plus does NOT extend SteveLayoutWidget (sibling classes,"
            . " both under LayoutWidgetBase); a regression that made"
            . " Plus inherit from Classic would silently double-subscribe"
            . " every bus handler.")

        try app2.Stop()
    }

    default_layout_variant_constructs_classic_compact_widget()
    {
        ; Companion to the Steve test: default cfg.layoutVariant
        ; means Compact also picks Classic. Both branches in
        ; app.ahk read the same flag, so a future change that
        ; flipped the default would affect both widgets together —
        ; this test would catch the drift before users do.
        Assert.True(this.app.compactWidget is CompactLayoutWidget,
            "default cfg.layoutVariant=classic constructs Classic Compact")
        Assert.False(this.app.compactWidget is CompactLayoutPlusWidget,
            "and not Plus")
    }

    layout_variant_plus_in_ini_constructs_plus_compact_widget()
    {
        ; Same scaffold as the Steve Plus test — separate test
        ; because each widget is its own composition path in
        ; app.ahk and a regression in one shouldn't be masked by
        ; the other passing.
        try this.app.Stop()
        this.app := ""

        ini := IniFile(this.iniPath)
        ini.Write("plus", "Layouts", "Variant")

        secondClock := Fixtures.MakeFakeClock(2000000)
        app2 := SpeedKalandraApp(Map(
            "iniPath",          this.iniPath,
            "zonesCsvPath",     this.zonesCsvPath,
            "logPath",          this.logPath,
            "runHistoryDir",    this.runHistoryDir,
            "personalBestPath", this.pbPath,
            "deathLogPath",     this.deathLogPath,
            "headless",         true,
            "clock",            secondClock
        ))

        Assert.True(app2.compactWidget is CompactLayoutPlusWidget,
            "cfg.layoutVariant=plus constructs Plus Compact")
        Assert.True(app2.compactWidget is LayoutWidgetBase,
            "Plus extends LayoutWidgetBase — dispatched by OverlayModeApplier")
        Assert.False(app2.compactWidget is CompactLayoutWidget,
            "Plus does NOT extend Classic (siblings under LayoutWidgetBase);"
            . " inheritance from Classic would double-subscribe handlers.")

        try app2.Stop()
    }

    default_layout_variant_constructs_classic_micro_widget()
    {
        ; Companion to the Steve / Compact tests — the third widget
        ; also branches on cfg.layoutVariant. Default = Classic.
        Assert.True(this.app.microWidget is MicroLayoutWidget,
            "default cfg.layoutVariant=classic constructs Classic Micro")
        Assert.False(this.app.microWidget is MicroLayoutPlusWidget,
            "and not Plus")
    }

    layout_variant_plus_in_ini_constructs_plus_micro_widget()
    {
        ; Plus opt-in via INI — same scaffold as the Steve / Compact
        ; Plus tests. Separate test so each widget's composition path
        ; is independently validated.
        try this.app.Stop()
        this.app := ""

        ini := IniFile(this.iniPath)
        ini.Write("plus", "Layouts", "Variant")

        secondClock := Fixtures.MakeFakeClock(2000000)
        app2 := SpeedKalandraApp(Map(
            "iniPath",          this.iniPath,
            "zonesCsvPath",     this.zonesCsvPath,
            "logPath",          this.logPath,
            "runHistoryDir",    this.runHistoryDir,
            "personalBestPath", this.pbPath,
            "deathLogPath",     this.deathLogPath,
            "headless",         true,
            "clock",            secondClock
        ))

        Assert.True(app2.microWidget is MicroLayoutPlusWidget,
            "cfg.layoutVariant=plus constructs Plus Micro")
        Assert.True(app2.microWidget is LayoutWidgetBase,
            "Plus extends LayoutWidgetBase — dispatched by OverlayModeApplier")
        Assert.False(app2.microWidget is MicroLayoutWidget,
            "Plus does NOT extend Classic (siblings under LayoutWidgetBase);"
            . " inheritance from Classic would double-subscribe handlers.")

        try app2.Stop()
    }
}

TestRegistry.Register(SpeedKalandraAppIntegrationTests)
