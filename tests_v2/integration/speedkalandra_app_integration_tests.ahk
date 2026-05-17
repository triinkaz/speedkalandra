; ============================================================
; SpeedKalandraAppIntegrationTests
; ============================================================
;
; Wave 8: integration test of the composition root (SpeedKalandraApp).
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

        ; Create runs dir (RunHistoryRepository doesn't create it automatically)
        try DirCreate(this.runHistoryDir)
        Fixtures.RegisterTempPath(this.runHistoryDir)

        ; FakeClock with base 1000000ms (arbitrary, far from 0)
        this.stubClock := Fixtures.MakeFakeClock(1000000)

        this.app := SpeedKalandraApp(Map(
            "iniPath",          this.iniPath,
            "zonesCsvPath",     this.zonesCsvPath,
            "logPath",          this.logPath,
            "runHistoryDir",    this.runHistoryDir,
            "personalBestPath", this.pbPath,
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

        ; --- Stop ---
        "stop_does_not_throw_when_never_started",
        "stop_is_idempotent",

        ; --- Wave 9: regression tests for cataloged bugs without direct coverage ---
        ; Bug #9 (AUDIT): Riverbank resets level on every entry. Fix:
        ; exact match "The Riverbank" + _riverbankSeenInRun flag that
        ; resets on RunStarted/RunReset/RunCancelled.
        "bug9_first_riverbank_entry_resets_level_to_1",
        "bug9_second_riverbank_entry_does_not_reset_level",
        "bug9_non_exact_match_does_not_trigger_reset",
        "bug9_new_run_clears_riverbank_flag",
        "bug9_run_reset_clears_riverbank_flag",

        ; --- v0.1.3: Death penalty on the real-time timer ---
        ; _OnDeathApplyTimerPenalty handler subscribed to Evt.DeathDetected.
        ; Checks cfg.deathPenaltyEnabled + timer.IsActive() before
        ; calling timer.AddPenaltyMs. Covers all 4 guard paths.
        "death_penalty_applies_to_timer_when_enabled_and_run_active",
        "death_penalty_does_not_apply_when_disabled",
        "death_penalty_does_not_apply_when_no_run_active",
        "death_penalty_accumulates_with_multiple_deaths",
        "death_penalty_uses_configured_ms_value",
        "death_penalty_does_not_apply_when_configured_ms_is_zero"
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
        ; RunCompleted and RunCancelled have _SaveRunSnapshot handlers,
        ; in addition to handlers that widgets/services subscribe.
        ; Verifies that at least 1 subscriber exists.
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
    ; Stop
    ; ============================================================

    stop_does_not_throw_when_never_started()
    {
        ; Setup didn't call Start; Stop must be a silent no-op
        this.app.Stop()
        Assert.True(true)
    }

    stop_is_idempotent()
    {
        this.app.Stop()
        this.app.Stop()
        Assert.True(true)
    }

    ; ============================================================
    ; Wave 9 — Regression: Bug #9 (Riverbank single-reset)
    ; ============================================================
    ;
    ; AUDIT #9: "Riverbank resets level on every entry".
    ;
    ; PRE-fix behavior:
    ;   InStr(zone, "Riverbank") + unconditional reset.
    ;   Problem 1: substring match (any zone with "Riverbank" in the
    ;              name would match).
    ;   Problem 2: re-entry (death respawn, portal, party invite) reset
    ;              the cached level to 1, causing wrong XP display
    ;              until the next CharacterLevelUp.
    ;
    ; Fix (v17.15):
    ;   Exact match "The Riverbank" + _riverbankSeenInRun flag. Flag
    ;   reset on RunStarted (new run unlocks new reset) and on
    ;   RunReset/RunCancelled.
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
    ; v0.1.3 — Death penalty on the real-time timer
    ; ============================================================
    ;
    ; Before v0.1.3, the death penalty (cfg.deathPenaltyMs) only
    ; appeared in the post-finalize plot ("Deaths" category in
    ; RunStatsPlotBuilder). The real-time run timer didn't reflect
    ; the penalty, creating a visual inconsistency: the user would
    ; see 1:05:00 in the overlay but 1:07:30 in the plot after
    ; finalize.
    ;
    ; Fix: _OnDeathApplyTimerPenalty handler subscribed to
    ; Evt.DeathDetected. When it fires and cfg.deathPenaltyEnabled +
    ; timer.IsActive(), calls timer.AddPenaltyMs(cfg.deathPenaltyMs).
    ; The user sees the pointer jump forward in the overlay the
    ; moment they die.
    ;
    ; Relevant AppSettings defaults:
    ;   cfg.deathPenaltyEnabled = true
    ;   cfg.deathPenaltyMs      = 150000  (2min30s)
    ;
    ; These tests publish Evt.DeathDetected directly on the bus to
    ; simulate the event that normally comes from LogMonitorService
    ; (when parsing a death line in Client.txt).

    death_penalty_applies_to_timer_when_enabled_and_run_active()
    {
        ; Start run, advance 1min, fire DeathDetected
        ; -> timer must jump to 1min + 150s (default penalty) = 3min30s
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
        ; Without NewRun, timer.IsActive() = false. Handler returns early.
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
        ; without touching the timer. Covers the handler's last guard.
        this.app._cfg.deathPenaltyMs := 0

        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(60000)
        before := this.app.timer.GetRunMs()

        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        Assert.Equal(before, this.app.timer.GetRunMs(),
            "deathPenaltyMs=0 doesn't move the timer")
    }
}

TestRegistry.Register(SpeedKalandraAppIntegrationTests)
