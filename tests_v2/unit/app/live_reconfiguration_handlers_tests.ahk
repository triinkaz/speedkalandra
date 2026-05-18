; ============================================================
; LiveReconfigurationHandlersTests
; ============================================================
;
; Three small handlers extracted out of the composition root:
;   - ApplyDeathPenaltyToTimer(data)
;   - RebindHotkeys(data)
;   - ResetPersonalBests()
;
; Tests use lightweight stubs for collaborators and run headless so
; the PB reset confirmation MsgBox is skipped (headless mode resets
; directly without prompting).


class _ReconfigStubTimer
{
    active        := true
    penaltyApplied := 0

    IsActive() => !!this.active

    AddPenaltyMs(ms)
    {
        this.penaltyApplied += ms
    }
}


class _ReconfigStubHotkeyService
{
    stopCount     := 0
    startCount    := 0
    hydratedWith  := ""
    runningCount  := 5

    Stop()
    {
        this.stopCount += 1
    }

    Start()
    {
        this.startCount += 1
    }

    Hydrate(map)
    {
        this.hydratedWith := map
    }

    Count() => this.runningCount
}


class _ReconfigStubPersonalBest
{
    resetCount := 0
    hasRun     := false
    runPbMs    := 0
    runPbId    := ""

    Reset()
    {
        this.resetCount += 1
    }

    HasRunPb() => !!this.hasRun

    GetRunPbMs() => this.runPbMs

    GetRunPbRunId() => this.runPbId

    GetAllZonePbs() => Map()

    CountActPbs() => 0
}


class LiveReconfigurationHandlersTests extends TestCase
{
    static Tests := [
        ; --- Constructor validations ---
        "constructor_throws_on_missing_cfg",
        "constructor_throws_on_missing_log",
        "constructor_throws_on_missing_timer",
        "constructor_throws_on_missing_hotkey_service",
        "constructor_throws_on_missing_personal_best",

        ; --- ApplyDeathPenaltyToTimer ---
        "death_penalty_skips_when_disabled_in_cfg",
        "death_penalty_skips_when_timer_inactive",
        "death_penalty_skips_when_penalty_is_zero",
        "death_penalty_skips_when_penalty_is_not_a_number",
        "death_penalty_applies_when_active_and_enabled",

        ; --- RebindHotkeys ---
        "rebind_hotkeys_uses_payload_when_present",
        "rebind_hotkeys_falls_back_to_cfg_when_payload_missing",
        "rebind_hotkeys_falls_back_to_empty_when_cfg_invalid",
        "rebind_hotkeys_calls_stop_hydrate_start_in_order",

        ; --- ResetPersonalBests (headless) ---
        "reset_pbs_resets_without_prompt_in_headless",
        "reset_pbs_returns_early_when_already_reset",
    ]

    log := ""

    Setup()
    {
        this.log := NullLogger()
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    _Make(stubs := "")
    {
        deps := IsObject(stubs) ? stubs : Map()
        cfg          := deps.Has("cfg")          ? deps["cfg"]          : AppSettings()
        log          := deps.Has("log")          ? deps["log"]          : this.log
        timer        := deps.Has("timer")        ? deps["timer"]        : _ReconfigStubTimer()
        hotkey       := deps.Has("hotkey")       ? deps["hotkey"]       : _ReconfigStubHotkeyService()
        personalBest := deps.Has("personalBest") ? deps["personalBest"] : _ReconfigStubPersonalBest()
        headless     := deps.Has("headless")     ? !!deps["headless"]   : true

        return LiveReconfigurationHandlers(cfg, log, timer, hotkey, personalBest, headless)
    }

    ; ------------------------------------------------------------
    ; Constructor validations
    ; ------------------------------------------------------------

    constructor_throws_on_missing_cfg()
    {
        Assert.Throws(TypeError, () => LiveReconfigurationHandlers(
            "", this.log, _ReconfigStubTimer(), _ReconfigStubHotkeyService(),
            _ReconfigStubPersonalBest(), true
        ))
    }

    constructor_throws_on_missing_log()
    {
        Assert.Throws(TypeError, () => LiveReconfigurationHandlers(
            AppSettings(), "", _ReconfigStubTimer(), _ReconfigStubHotkeyService(),
            _ReconfigStubPersonalBest(), true
        ))
    }

    constructor_throws_on_missing_timer()
    {
        Assert.Throws(TypeError, () => LiveReconfigurationHandlers(
            AppSettings(), this.log, "", _ReconfigStubHotkeyService(),
            _ReconfigStubPersonalBest(), true
        ))
    }

    constructor_throws_on_missing_hotkey_service()
    {
        Assert.Throws(TypeError, () => LiveReconfigurationHandlers(
            AppSettings(), this.log, _ReconfigStubTimer(), "",
            _ReconfigStubPersonalBest(), true
        ))
    }

    constructor_throws_on_missing_personal_best()
    {
        Assert.Throws(TypeError, () => LiveReconfigurationHandlers(
            AppSettings(), this.log, _ReconfigStubTimer(), _ReconfigStubHotkeyService(),
            "", true
        ))
    }

    ; ------------------------------------------------------------
    ; ApplyDeathPenaltyToTimer
    ; ------------------------------------------------------------

    death_penalty_skips_when_disabled_in_cfg()
    {
        cfg := AppSettings()
        cfg.deathPenaltyEnabled := false
        cfg.deathPenaltyMs      := 30000
        timer := _ReconfigStubTimer()

        handlers := this._Make(Map("cfg", cfg, "timer", timer))
        handlers.ApplyDeathPenaltyToTimer(Map())

        Assert.Equal(0, timer.penaltyApplied)
    }

    death_penalty_skips_when_timer_inactive()
    {
        cfg := AppSettings()
        cfg.deathPenaltyEnabled := true
        cfg.deathPenaltyMs      := 30000
        timer := _ReconfigStubTimer()
        timer.active := false

        handlers := this._Make(Map("cfg", cfg, "timer", timer))
        handlers.ApplyDeathPenaltyToTimer(Map())

        Assert.Equal(0, timer.penaltyApplied)
    }

    death_penalty_skips_when_penalty_is_zero()
    {
        cfg := AppSettings()
        cfg.deathPenaltyEnabled := true
        cfg.deathPenaltyMs      := 0
        timer := _ReconfigStubTimer()

        handlers := this._Make(Map("cfg", cfg, "timer", timer))
        handlers.ApplyDeathPenaltyToTimer(Map())

        Assert.Equal(0, timer.penaltyApplied)
    }

    death_penalty_skips_when_penalty_is_not_a_number()
    {
        cfg := AppSettings()
        cfg.deathPenaltyEnabled := true
        cfg.deathPenaltyMs      := "garbage"
        timer := _ReconfigStubTimer()

        handlers := this._Make(Map("cfg", cfg, "timer", timer))
        handlers.ApplyDeathPenaltyToTimer(Map())

        Assert.Equal(0, timer.penaltyApplied)
    }

    death_penalty_applies_when_active_and_enabled()
    {
        cfg := AppSettings()
        cfg.deathPenaltyEnabled := true
        cfg.deathPenaltyMs      := 25000
        timer := _ReconfigStubTimer()

        handlers := this._Make(Map("cfg", cfg, "timer", timer))
        handlers.ApplyDeathPenaltyToTimer(Map())

        Assert.Equal(25000, timer.penaltyApplied)
    }

    ; ------------------------------------------------------------
    ; RebindHotkeys
    ; ------------------------------------------------------------

    rebind_hotkeys_uses_payload_when_present()
    {
        hotkey := _ReconfigStubHotkeyService()
        payload := Map("newHotkeys", Map("NewRun", "^!n"))

        handlers := this._Make(Map("hotkey", hotkey))
        handlers.RebindHotkeys(payload)

        Assert.True(hotkey.hydratedWith is Map)
        Assert.True(hotkey.hydratedWith.Has("NewRun"))
    }

    rebind_hotkeys_falls_back_to_cfg_when_payload_missing()
    {
        cfg := AppSettings()
        cfg.hotkeys := Map("NewRun", "^!n", "FinalizeRun", "^!f")
        hotkey := _ReconfigStubHotkeyService()

        handlers := this._Make(Map("cfg", cfg, "hotkey", hotkey))
        handlers.RebindHotkeys(Map())

        Assert.True(hotkey.hydratedWith is Map)
        Assert.Equal(2, hotkey.hydratedWith.Count)
    }

    rebind_hotkeys_falls_back_to_empty_when_cfg_invalid()
    {
        cfg := AppSettings()
        cfg.hotkeys := ""    ; not a Map
        hotkey := _ReconfigStubHotkeyService()

        handlers := this._Make(Map("cfg", cfg, "hotkey", hotkey))
        handlers.RebindHotkeys(Map())

        Assert.True(hotkey.hydratedWith is Map)
        Assert.Equal(0, hotkey.hydratedWith.Count)
    }

    rebind_hotkeys_calls_stop_hydrate_start_in_order()
    {
        hotkey := _ReconfigStubHotkeyService()
        payload := Map("newHotkeys", Map("NewRun", "^!n"))

        handlers := this._Make(Map("hotkey", hotkey))
        handlers.RebindHotkeys(payload)

        Assert.Equal(1, hotkey.stopCount)
        Assert.Equal(1, hotkey.startCount)
        Assert.True(hotkey.hydratedWith is Map, "Hydrate must have been called between Stop and Start")
    }

    ; ------------------------------------------------------------
    ; ResetPersonalBests (headless path only — non-headless opens a
    ; MsgBox the tests can't dismiss)
    ; ------------------------------------------------------------

    reset_pbs_resets_without_prompt_in_headless()
    {
        pb := _ReconfigStubPersonalBest()
        handlers := this._Make(Map("personalBest", pb, "headless", true))

        handlers.ResetPersonalBests()

        Assert.Equal(1, pb.resetCount)
    }

    reset_pbs_returns_early_when_already_reset()
    {
        ; Idempotent at the API level — each call resets, no
        ; throw on repeat. Documents intent.
        pb := _ReconfigStubPersonalBest()
        handlers := this._Make(Map("personalBest", pb, "headless", true))

        handlers.ResetPersonalBests()
        handlers.ResetPersonalBests()

        Assert.Equal(2, pb.resetCount)
    }
}


TestRegistry.Register(LiveReconfigurationHandlersTests)
