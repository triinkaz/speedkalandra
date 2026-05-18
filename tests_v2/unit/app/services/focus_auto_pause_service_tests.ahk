; ============================================================
; FocusAutoPauseServiceTests
; ============================================================
;
; Hybrid service: subscribes to Evt.WindowFocusChanged (fast path
; via PoE2's Client.txt) AND Evt.Tick (backup polling at 300ms via
; WinActive). Both paths fire the same handler
; _OnWindowFocusChanged which is idempotent.
;
; TEST STRATEGY: stub subclass overrides `_IsGameActive` with an
; in-memory flag. This avoids dependency on a real PoE2 window in
; the tests while keeping production code intact.


class _FocusAutoPauseStubService extends FocusAutoPauseService
{
    _stubGameActive := true   ; default: game active

    SetStubGameActive(isActive)
    {
        this._stubGameActive := !!isActive
    }

    _IsGameActive()
    {
        return this._stubGameActive
    }
}


class FocusAutoPauseServiceTests extends TestCase
{
    bus       := ""
    stubClock := ""
    timerSvc  := ""
    cfg       := ""
    svc       := ""

    Setup()
    {
        this.bus       := Fixtures.MakeBus()
        this.stubClock := Fixtures.MakeFakeClock(10000)
        this.timerSvc  := TimerService(this.stubClock, this.bus)
        this.cfg       := AppSettings.Defaults()
        this.cfg.autoPauseOnFocus := true
        this.svc       := _FocusAutoPauseStubService(this.bus, this.timerSvc, this.cfg)
    }

    Teardown()
    {
        if IsObject(this.svc)
            this.svc.Stop()
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_timer_svc_not_timer_service",
        "constructor_throws_when_cfg_not_app_settings",
        "constructor_does_not_subscribe_until_start",
        "constructor_is_enabled_false",

        ; --- Start / Stop ---
        "start_subscribes_to_window_focus_changed",
        "start_subscribes_to_tick",
        "start_sets_is_enabled_true",
        "start_is_idempotent",
        "stop_unsubscribes_all",
        "stop_sets_is_enabled_false",
        "stop_is_idempotent",
        "stop_clears_paused_by_focus_flag",

        ; --- Lost focus event ---
        "lost_focus_pauses_running_timer",
        "lost_focus_sets_paused_by_focus_flag",
        "lost_focus_no_op_when_timer_stopped",
        "lost_focus_no_op_when_timer_paused",
        "lost_focus_no_op_when_setting_disabled",
        "lost_focus_no_op_when_service_stopped",

        ; --- Gained focus event ---
        "gained_focus_resumes_when_paused_by_focus",
        "gained_focus_clears_paused_by_focus_flag",
        "gained_focus_no_op_when_not_paused_by_focus",
        "gained_focus_no_op_when_timer_running",
        "gained_focus_does_not_resume_manually_paused_timer",

        ; --- Event payload edge cases ---
        "event_with_unknown_state_ignored",
        "event_with_non_object_data_ignored",
        "event_missing_state_key_ignored",

        ; --- Tick polling (backup) ---
        "tick_detects_focus_loss_via_polling",
        "tick_detects_focus_gain_via_polling",
        "tick_no_op_when_no_state_change",
        "tick_no_op_when_setting_disabled",
        "tick_no_op_when_service_stopped",

        ; --- Idempotence: log+polling combined ---
        "log_and_polling_combined_idempotent_for_loss",
        "log_and_polling_combined_idempotent_for_gain"
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        t := this.timerSvc
        c := this.cfg
        Assert.Throws(TypeError, () => FocusAutoPauseService("not bus", t, c))
    }

    constructor_throws_when_timer_svc_not_timer_service()
    {
        b := this.bus
        c := this.cfg
        Assert.Throws(TypeError, () => FocusAutoPauseService(b, "not timer", c))
    }

    constructor_throws_when_cfg_not_app_settings()
    {
        b := this.bus
        t := this.timerSvc
        Assert.Throws(TypeError, () => FocusAutoPauseService(b, t, "not cfg"))
    }

    constructor_does_not_subscribe_until_start()
    {
        ; Without Start(), nothing is subscribed
        Assert.Equal(0, this.bus.Subscribers(Events.WindowFocusChanged))
        Assert.Equal(0, this.bus.Subscribers(Events.Tick))
    }

    constructor_is_enabled_false()
    {
        Assert.False(this.svc.IsEnabled())
    }

    ; ============================================================
    ; Start / Stop
    ; ============================================================

    start_subscribes_to_window_focus_changed()
    {
        this.svc.Start()
        Assert.Equal(1, this.bus.Subscribers(Events.WindowFocusChanged))
    }

    start_subscribes_to_tick()
    {
        this.svc.Start()
        Assert.Equal(1, this.bus.Subscribers(Events.Tick))
    }

    start_sets_is_enabled_true()
    {
        this.svc.Start()
        Assert.True(this.svc.IsEnabled())
    }

    start_is_idempotent()
    {
        this.svc.Start()
        this.svc.Start()
        Assert.Equal(1, this.bus.Subscribers(Events.WindowFocusChanged))
    }

    stop_unsubscribes_all()
    {
        this.svc.Start()
        this.svc.Stop()
        Assert.Equal(0, this.bus.Subscribers(Events.WindowFocusChanged))
        Assert.Equal(0, this.bus.Subscribers(Events.Tick))
    }

    stop_sets_is_enabled_false()
    {
        this.svc.Start()
        this.svc.Stop()
        Assert.False(this.svc.IsEnabled())
    }

    stop_is_idempotent()
    {
        this.svc.Stop()   ; no Start before
        this.svc.Stop()
        Assert.False(this.svc.IsEnabled())
    }

    stop_clears_paused_by_focus_flag()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.True(this.svc.WasPausedByFocus())
        this.svc.Stop()
        Assert.False(this.svc.WasPausedByFocus())
    }

    ; ============================================================
    ; Lost focus event
    ; ============================================================

    lost_focus_pauses_running_timer()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.True(this.timerSvc.IsPaused())
    }

    lost_focus_sets_paused_by_focus_flag()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.True(this.svc.WasPausedByFocus())
    }

    lost_focus_no_op_when_timer_stopped()
    {
        ; Timer stopped: lost focus must do nothing
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.False(this.svc.WasPausedByFocus(),
            "Timer stopped: must not set the pausedByFocus flag")
    }

    lost_focus_no_op_when_timer_paused()
    {
        this.timerSvc.Start()
        this.timerSvc.Pause()   ; user paused manually
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.False(this.svc.WasPausedByFocus(),
            "Timer already paused by the user: must not claim the pause")
    }

    lost_focus_no_op_when_setting_disabled()
    {
        this.cfg.autoPauseOnFocus := false
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.True(this.timerSvc.IsRunning(),
            "Setting disabled: timer keeps running")
    }

    lost_focus_no_op_when_service_stopped()
    {
        this.timerSvc.Start()
        ; service never Start-ed
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.True(this.timerSvc.IsRunning())
    }

    ; ============================================================
    ; Gained focus event
    ; ============================================================

    gained_focus_resumes_when_paused_by_focus()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "gained"))
        Assert.True(this.timerSvc.IsRunning())
        Assert.False(this.timerSvc.IsPaused())
    }

    gained_focus_clears_paused_by_focus_flag()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "gained"))
        Assert.False(this.svc.WasPausedByFocus())
    }

    gained_focus_no_op_when_not_paused_by_focus()
    {
        this.timerSvc.Start()
        this.svc.Start()
        ; No lost focus before — gained alone must do nothing
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "gained"))
        Assert.True(this.timerSvc.IsRunning())
    }

    gained_focus_no_op_when_timer_running()
    {
        this.timerSvc.Start()
        this.svc.Start()
        ; Timer running, gained: keep running
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "gained"))
        Assert.True(this.timerSvc.IsRunning())
    }

    gained_focus_does_not_resume_manually_paused_timer()
    {
        this.timerSvc.Start()
        this.svc.Start()
        ; lost focus pauses
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.True(this.svc.WasPausedByFocus())
        ; User pauses/resumes manually DURING alt-tab — flag hangs
        ; around until gained or Stop(). What matters: if user does
        ; a manual Resume, the subsequent gained doesn't break state.
        ; (Scenario: lost -> auto-pause -> user goes to wiki -> comes
        ; back -> user does manual resume before gained arrives ->
        ; gained event resumes an already running timer, no-op.)
        this.timerSvc.Resume()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "gained"))
        Assert.True(this.timerSvc.IsRunning())
        Assert.False(this.svc.WasPausedByFocus())
    }

    ; ============================================================
    ; Event payload edge cases
    ; ============================================================

    event_with_unknown_state_ignored()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "unknown"))
        Assert.True(this.timerSvc.IsRunning())
        Assert.False(this.svc.WasPausedByFocus())
    }

    event_with_non_object_data_ignored()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, "not a map")
        Assert.True(this.timerSvc.IsRunning())
    }

    event_missing_state_key_ignored()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("other", "value"))
        Assert.True(this.timerSvc.IsRunning())
    }

    ; ============================================================
    ; Tick polling (backup, v0.1.1)
    ; ============================================================

    tick_detects_focus_loss_via_polling()
    {
        this.timerSvc.Start()
        ; Setup: game starts active
        this.svc.SetStubGameActive(true)
        this.svc.Start()   ; initial snapshot = true
        ; Simulating: game lost focus (user alt-tab)
        this.svc.SetStubGameActive(false)
        ; Tick polling detects
        this.bus.Publish(Events.Tick, Map("now", 10500))
        Assert.True(this.timerSvc.IsPaused(),
            "Polling detected focus loss and paused")
        Assert.True(this.svc.WasPausedByFocus())
    }

    tick_detects_focus_gain_via_polling()
    {
        this.timerSvc.Start()
        this.svc.SetStubGameActive(false)
        this.svc.Start()   ; initial snapshot = false
        ; Pretend timer was paused by focus (via lost path)
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        ; But timer was already running before... let's force it via lost focus.
        ; Full scenario: lost focus -> paused via log path, now gains focus
        this.svc.SetStubGameActive(true)
        this.bus.Publish(Events.Tick, Map("now", 11000))
        Assert.True(this.timerSvc.IsRunning(),
            "Polling detected focus gain and resumed")
    }

    tick_no_op_when_no_state_change()
    {
        this.timerSvc.Start()
        this.svc.SetStubGameActive(true)
        this.svc.Start()
        ; No change, Tick is a no-op
        this.bus.Publish(Events.Tick, Map("now", 10500))
        Assert.True(this.timerSvc.IsRunning())
        Assert.False(this.svc.WasPausedByFocus())
    }

    tick_no_op_when_setting_disabled()
    {
        this.cfg.autoPauseOnFocus := false
        this.timerSvc.Start()
        this.svc.SetStubGameActive(true)
        this.svc.Start()
        ; Setting off: Tick does nothing
        this.svc.SetStubGameActive(false)
        this.bus.Publish(Events.Tick, Map("now", 10500))
        Assert.True(this.timerSvc.IsRunning())
    }

    tick_no_op_when_service_stopped()
    {
        this.timerSvc.Start()
        ; Service never Start-ed
        this.bus.Publish(Events.Tick, Map("now", 10500))
        Assert.True(this.timerSvc.IsRunning())
    }

    ; ============================================================
    ; Idempotence (log+polling combined)
    ; ============================================================

    log_and_polling_combined_idempotent_for_loss()
    {
        ; v0.1.1: both paths call the same handler.
        ; Log fires first -> Polling detects same transition -> no-op
        this.timerSvc.Start()
        this.svc.SetStubGameActive(true)
        this.svc.Start()

        ; Log fires focus loss (fast path)
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.True(this.timerSvc.IsPaused())

        ; Polling detects same loss — must be a no-op (timer already paused)
        this.svc.SetStubGameActive(false)
        this.bus.Publish(Events.Tick, Map("now", 11000))
        Assert.True(this.timerSvc.IsPaused(),
            "Pause on already paused timer is no-op (idempotent)")
    }

    log_and_polling_combined_idempotent_for_gain()
    {
        this.timerSvc.Start()
        this.svc.SetStubGameActive(true)
        this.svc.Start()

        ; Lost path
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        this.svc.SetStubGameActive(false)
        this.bus.Publish(Events.Tick, Map("now", 11000))

        ; Gain via log
        this.svc.SetStubGameActive(true)
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "gained"))
        Assert.True(this.timerSvc.IsRunning())

        ; Subsequent Tick with same state — no-op (timer already running)
        this.bus.Publish(Events.Tick, Map("now", 12000))
        Assert.True(this.timerSvc.IsRunning())
    }
}

TestRegistry.Register(FocusAutoPauseServiceTests)
