; ============================================================
; LoadingDetectionServiceTests
; ============================================================
;
; LoadingDetectionService is a state machine that:
;   1. ARM: AreaLevelChanged (from log) or ArmFromAreaChange direct
;   2. POLL: periodic Tick calls scanner.Scan
;   3. END: scan returns visible=true OR timeout
;
; Publishes LoadingMeasured at the end with duration/fromZone/
; toZone/source/etc. Preconditions to arm: setting enabled + timer
; active + not already-armed.
;
; STUBS:
;   - _LdsStubScanner: subclass of HudPixelScanner with a controllable
;     `visible` flag (Scan override). Passes the `is HudPixelScanner`
;     typecheck.
;   - _LdsStubCallable: minimal class with .Call() for zoneProvider/
;     stepProvider/windowProvider. Externally settable `value` field.
;
; REAL DEPS:
;   - EventBus (Fixtures.MakeBus)
;   - FakeClock (Fixtures.MakeFakeClock)
;   - AppSettings (AppSettings.Defaults with loadingVisualEnabled=true)
;   - TimerService (real, Start() for IsActive=true)


; ============================================================
; Top-level stubs (subclass and callable)
; ============================================================

class _LdsStubScanner extends HudPixelScanner
{
    visible := false

    __New()
    {
        ; Initializes parent with dummy pixelReader (unused)
        super.__New((x, y) => 0)
    }

    Scan(wx, wy, ww, wh)
    {
        if this.visible
            return Map("visible", true,  "lifeHits", 5, "manaHits", 0, "hotbarHits", 0)
        return Map("visible", false, "lifeHits", 0, "manaHits", 0, "hotbarHits", 0)
    }
}

class _LdsStubCallable
{
    value := ""

    __New(initial := "")
    {
        this.value := initial
    }

    Call() => this.value
}

; ============================================================
; Test suite
; ============================================================

class LoadingDetectionServiceTests extends TestCase
{
    bus              := ""
    stubClock        := ""
    stubScanner      := ""
    cfg              := ""
    timerSvc         := ""
    zoneProvider     := ""
    stepProvider     := ""
    windowProvider   := ""
    svc              := ""

    Setup()
    {
        this.bus       := Fixtures.MakeBus()
        this.stubClock := Fixtures.MakeFakeClock(100000)
        this.stubScanner := _LdsStubScanner()

        this.cfg := AppSettings.Defaults()
        this.cfg.loadingVisualEnabled := true
        this.cfg.loadingVisualPollMs  := 25
        this.cfg.loadingVisualMinMs   := 250
        this.cfg.loadingVisualMaxMs   := 90000

        ; Real timer service, Start() for IsActive=true
        this.timerSvc := TimerService(this.stubClock, this.bus)
        this.timerSvc.Start()

        this.zoneProvider   := _LdsStubCallable("Mud Burrow")
        this.stepProvider   := _LdsStubCallable(Map("actIndex", 1, "stepId", "step_1"))
        this.windowProvider := _LdsStubCallable(Map("x", 0, "y", 0, "w", 1920, "h", 1080))

        ; headless=true to avoid real SetTimer
        this.svc := LoadingDetectionService(
            this.bus, this.stubClock, this.stubScanner, this.cfg,
            this.timerSvc, this.zoneProvider, this.stepProvider,
            this.windowProvider, true
        )
    }

    Teardown()
    {
        if IsObject(this.svc)
            this.svc.Dispose()
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_clock_missing_now_ms",
        "constructor_throws_when_scanner_not_hud_pixel_scanner",
        "constructor_throws_when_cfg_not_app_settings",
        "constructor_throws_when_timer_svc_not_timer_service",
        "constructor_throws_when_zone_provider_not_object",
        "constructor_throws_when_step_provider_not_object",
        "constructor_subscribes_to_area_level_changed",
        "constructor_subscribes_to_zone_changed",

        ; --- Defaults / initial state ---
        "state_idle_initially",
        "is_enabled_false_initially",
        "is_active_false_initially",

        ; --- Start / Stop ---
        "start_sets_enabled_true",
        "start_is_idempotent",
        "stop_sets_enabled_false",
        "stop_cancels_active_state",
        "stop_is_idempotent",
        "dispose_unsubscribes_handlers",
        "dispose_is_idempotent",

        ; --- ArmFromAreaChange preconditions ---
        "arm_returns_false_when_loading_visual_disabled",
        "arm_returns_false_when_timer_not_active",
        "arm_returns_false_when_already_active",
        "arm_returns_true_when_preconditions_met",

        ; --- ArmFromAreaChange state ---
        "arm_sets_state_to_active",
        "arm_captures_start_tick_from_clock",
        "arm_captures_zone_via_provider",
        "arm_captures_step_via_provider",
        "arm_sets_ignore_until_tick_offset_150",
        "arm_zeros_scene_seen_tick",
        "arm_sets_anchor_with_area_code",

        ; --- NotifyScene ---
        "notify_scene_returns_false_when_idle",
        "notify_scene_returns_false_when_duration_below_min",
        "notify_scene_returns_true_when_active_and_above_min",
        "notify_scene_sets_scene_seen_tick",
        "notify_scene_updates_anchor",

        ; --- SuppressForPanel ---
        "suppress_for_panel_when_idle_only_sets_ignore_until",
        "suppress_for_panel_when_active_cancels_state",

        ; --- Tick: preconditions ---
        "tick_no_op_when_state_idle",
        "tick_no_op_when_window_provider_returns_empty",
        "tick_no_op_during_ignore_until_period",

    ; --- Tick: timeout ---
        ; Bug #5 fix: timeout publishes LoadingMeasured
        ; with real durationMs (>= maxMs by construction). Before it
        ; was silently discarded by the `> maxMs` filter in _End,
        ; causing underestimated loading time on slow PCs.
        "tick_timeout_publishes_loading_measured",
        "tick_timeout_event_has_source_timeout_no_hud_return",
        "tick_timeout_event_duration_reflects_real_time_above_max",
        "tick_timeout_event_includes_from_zone",
        "tick_returns_to_idle_after_timeout",

        ; Bug #5 regression: loadings between 90s and absurd must still
        ; be published. Slow PC coverage.
        "bug5_loading_100s_publishes_with_real_duration",
        "bug5_loading_300s_publishes_with_real_duration",

        ; --- Tick: timer stopped ---
        "tick_cancels_when_timer_inactive",
        "tick_cancel_returns_to_idle",

        ; --- Tick: HUD visible (end) ---
        "tick_ends_when_hud_returns_visible",
        "tick_end_publishes_loading_measured",
        "tick_end_uses_hud_returned_fast_when_no_scene_seen",
        "tick_end_uses_scene_then_hud_return_when_scene_seen",
        "tick_end_includes_from_zone",
        "tick_end_includes_to_zone",
        "tick_end_includes_duration_ms",
        "tick_end_includes_start_act_index",
        "tick_end_returns_to_idle",

        ; --- Tick: HUD absent (poll continues) ---
        "tick_continues_polling_when_hud_absent",
        "tick_does_not_publish_when_hud_absent",

        ; --- End filtering by duration ---
        "end_discards_loading_measured_when_below_min_ms",

        ; --- AreaLevelChanged subscribe handler ---
        "area_level_changed_event_triggers_arm",
        "area_level_changed_ignores_non_object_data",

        ; --- ZoneChanged subscribe handler (NotifyScene) ---
        "zone_changed_event_calls_notify_scene_when_active",
        "zone_changed_with_empty_zone_name_ignored",
        "zone_changed_when_idle_no_op"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _CaptureEvents(eventName)
    {
        capturedEvents := []
        this.bus.Subscribe(eventName, (data) => capturedEvents.Push(data))
        return capturedEvents
    }

    ; Advances the clock past the initial ignore period (150ms after arm)
    _SkipIgnorePeriod()
    {
        this.stubClock.AdvanceMs(200)
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        clk := this.stubClock
        sc  := this.stubScanner
        c   := this.cfg
        ts  := this.timerSvc
        zp  := this.zoneProvider
        sp  := this.stepProvider
        Assert.Throws(TypeError, () => LoadingDetectionService("nope", clk, sc, c, ts, zp, sp))
    }

    constructor_throws_when_clock_missing_now_ms()
    {
        b := this.bus
        sc := this.stubScanner
        c := this.cfg
        ts := this.timerSvc
        zp := this.zoneProvider
        sp := this.stepProvider
        emptyObj := { foo: () => 0 }
        Assert.Throws(TypeError, () => LoadingDetectionService(b, emptyObj, sc, c, ts, zp, sp))
    }

    constructor_throws_when_scanner_not_hud_pixel_scanner()
    {
        b := this.bus
        clk := this.stubClock
        c := this.cfg
        ts := this.timerSvc
        zp := this.zoneProvider
        sp := this.stepProvider
        Assert.Throws(TypeError, () => LoadingDetectionService(b, clk, "not a scanner", c, ts, zp, sp))
    }

    constructor_throws_when_cfg_not_app_settings()
    {
        b := this.bus
        clk := this.stubClock
        sc := this.stubScanner
        ts := this.timerSvc
        zp := this.zoneProvider
        sp := this.stepProvider
        Assert.Throws(TypeError, () => LoadingDetectionService(b, clk, sc, "not cfg", ts, zp, sp))
    }

    constructor_throws_when_timer_svc_not_timer_service()
    {
        b := this.bus
        clk := this.stubClock
        sc := this.stubScanner
        c := this.cfg
        zp := this.zoneProvider
        sp := this.stepProvider
        Assert.Throws(TypeError, () => LoadingDetectionService(b, clk, sc, c, "not timer", zp, sp))
    }

    constructor_throws_when_zone_provider_not_object()
    {
        b := this.bus
        clk := this.stubClock
        sc := this.stubScanner
        c := this.cfg
        ts := this.timerSvc
        sp := this.stepProvider
        Assert.Throws(TypeError, () => LoadingDetectionService(b, clk, sc, c, ts, "string", sp))
    }

    constructor_throws_when_step_provider_not_object()
    {
        b := this.bus
        clk := this.stubClock
        sc := this.stubScanner
        c := this.cfg
        ts := this.timerSvc
        zp := this.zoneProvider
        Assert.Throws(TypeError, () => LoadingDetectionService(b, clk, sc, c, ts, zp, "string"))
    }

    constructor_subscribes_to_area_level_changed()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.AreaLevelChanged))
    }

    constructor_subscribes_to_zone_changed()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.ZoneChanged))
    }

    ; ============================================================
    ; Defaults
    ; ============================================================

    state_idle_initially()    => Assert.False(this.svc.IsActive())
    is_enabled_false_initially() => Assert.False(this.svc.IsEnabled())
    is_active_false_initially()  => Assert.False(this.svc.IsActive())

    ; ============================================================
    ; Start / Stop
    ; ============================================================

    start_sets_enabled_true()
    {
        this.svc.Start()
        Assert.True(this.svc.IsEnabled())
    }

    start_is_idempotent()
    {
        this.svc.Start()
        this.svc.Start()
        Assert.True(this.svc.IsEnabled())
    }

    stop_sets_enabled_false()
    {
        this.svc.Start()
        this.svc.Stop()
        Assert.False(this.svc.IsEnabled())
    }

    stop_cancels_active_state()
    {
        this.svc.Start()
        this.svc.ArmFromAreaChange(10, "G1_2")
        this.svc.Stop()
        Assert.False(this.svc.IsActive(),
            "Stop must cancel active state")
    }

    stop_is_idempotent()
    {
        this.svc.Stop()
        this.svc.Stop()
        Assert.False(this.svc.IsEnabled())
    }

    dispose_unsubscribes_handlers()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.AreaLevelChanged))
        Assert.Equal(0, this.bus.Subscribers(Events.ZoneChanged))
    }

    dispose_is_idempotent()
    {
        this.svc.Dispose()
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.AreaLevelChanged))
    }

    ; ============================================================
    ; ArmFromAreaChange preconditions
    ; ============================================================

    arm_returns_false_when_loading_visual_disabled()
    {
        this.cfg.loadingVisualEnabled := false
        Assert.False(this.svc.ArmFromAreaChange(10, "G1_2"))
    }

    arm_returns_false_when_timer_not_active()
    {
        this.timerSvc.Stop()
        Assert.False(this.svc.ArmFromAreaChange(10, "G1_2"))
    }

    arm_returns_false_when_already_active()
    {
        Assert.True(this.svc.ArmFromAreaChange(10, "G1_2"), "First arm passes")
        Assert.False(this.svc.ArmFromAreaChange(11, "G1_3"), "Second doesn't re-arm")
    }

    arm_returns_true_when_preconditions_met()
    {
        Assert.True(this.svc.ArmFromAreaChange(10, "G1_2"))
    }

    ; ============================================================
    ; ArmFromAreaChange state
    ; ============================================================

    arm_sets_state_to_active()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        Assert.True(this.svc.IsActive())
    }

    arm_captures_start_tick_from_clock()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        Assert.Equal(100000, this.svc.GetStartTick(),
            "FakeClock.NowMs at the moment of arm")
    }

    arm_captures_zone_via_provider()
    {
        this.zoneProvider.value := "Vastiri Outskirts"
        this.svc.ArmFromAreaChange(10, "G2_1")

        ; To verify: we need to end and check fromZone in the published event
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this._SkipIgnorePeriod()
        this.stubScanner.visible := true
        this.stubClock.AdvanceMs(300)
        this.svc.Tick()
        Assert.Equal("Vastiri Outskirts", capturedEvents[1]["fromZone"])
    }

    arm_captures_step_via_provider()
    {
        this.stepProvider.value := Map("actIndex", 3, "stepId", "step_99")
        this.svc.ArmFromAreaChange(10, "X")

        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this._SkipIgnorePeriod()
        this.stubScanner.visible := true
        this.stubClock.AdvanceMs(300)
        this.svc.Tick()
        Assert.Equal(3,         capturedEvents[1]["actIndex"])
        Assert.Equal("step_99", capturedEvents[1]["stepId"])
    }

    arm_sets_ignore_until_tick_offset_150()
    {
        ; After arm, Tick during the first 150ms doesn't scan (early ignore)
        this.svc.ArmFromAreaChange(10, "G1_2")
        this.stubScanner.visible := true   ; if it scanned, would end
        this.stubClock.AdvanceMs(100)      ; still within ignore period
        this.svc.Tick()
        Assert.True(this.svc.IsActive(), "Ignore period still valid — Tick no-op")
    }

    arm_zeros_scene_seen_tick()
    {
        ; After a fresh arm, anchor has no "scene:" prefix
        this.svc.ArmFromAreaChange(10, "G1_2")
        Assert.False(InStr(this.svc.GetLastAnchor(), "scene:"))
    }

    arm_sets_anchor_with_area_code()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        Assert.Equal("client_generating:G1_2", this.svc.GetLastAnchor())
    }

    ; ============================================================
    ; NotifyScene
    ; ============================================================

    notify_scene_returns_false_when_idle()
    {
        Assert.False(this.svc.NotifyScene("Some Zone"))
    }

    notify_scene_returns_false_when_duration_below_min()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        ; No AdvanceMs: duration=0 < minMs(250)
        Assert.False(this.svc.NotifyScene("Some Zone"))
    }

    notify_scene_returns_true_when_active_and_above_min()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        this.stubClock.AdvanceMs(300)
        Assert.True(this.svc.NotifyScene("Mud Burrow"))
    }

    notify_scene_sets_scene_seen_tick()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        this.stubClock.AdvanceMs(300)
        this.svc.NotifyScene("Mud Burrow")

        ; Now end with hud visible: source must be "scene_then_hud_return"
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this.stubScanner.visible := true
        this.svc.Tick()
        Assert.Equal("scene_then_hud_return", capturedEvents[1]["source"])
    }

    notify_scene_updates_anchor()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        this.stubClock.AdvanceMs(300)
        this.svc.NotifyScene("Mud Burrow")
        Assert.Equal("scene:Mud Burrow", this.svc.GetLastAnchor())
    }

    ; ============================================================
    ; SuppressForPanel
    ; ============================================================

    suppress_for_panel_when_idle_only_sets_ignore_until()
    {
        this.svc.SuppressForPanel("panel")
        ; Idle continues, but ignoreUntilTick has been set.
        ; To verify indirectly: arm later and see if Tick respects it.
        Assert.False(this.svc.IsActive())
    }

    suppress_for_panel_when_active_cancels_state()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        this.svc.SuppressForPanel("panel")
        Assert.False(this.svc.IsActive(), "Active cancelled")
    }

    ; ============================================================
    ; Tick: preconditions
    ; ============================================================

    tick_no_op_when_state_idle()
    {
        ; State is idle, scanner.visible=true. Tick publishes nothing.
        this.stubScanner.visible := true
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this.svc.Tick()
        Assert.Equal(0, capturedEvents.Length)
    }

    tick_no_op_when_window_provider_returns_empty()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        this._SkipIgnorePeriod()
        this.windowProvider.value := ""   ; window not sampleable
        this.stubScanner.visible := true
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this.svc.Tick()
        Assert.True(this.svc.IsActive(), "Keeps active state awaiting window")
        Assert.Equal(0, capturedEvents.Length)
    }

    tick_no_op_during_ignore_until_period()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        this.stubClock.AdvanceMs(100)   ; still within 150ms post-arm
        this.stubScanner.visible := true
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this.svc.Tick()
        Assert.Equal(0, capturedEvents.Length, "Ignore period active")
    }

    ; ============================================================
    ; Tick: timeout (Bug #5 fix)
    ; ============================================================

    tick_timeout_publishes_loading_measured()
    {
        ; When Tick detects now - startTick > maxMs, it calls
        ; _End("timeout_no_hud_return"). After the Bug #5 fix, the
        ; event is published with the REAL duration (>= maxMs).
        this.svc.ArmFromAreaChange(10, "G1_2")
        this.stubClock.AdvanceMs(100000)   ; > maxMs (90000)
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this.svc.Tick()
        Assert.Equal(1, capturedEvents.Length,
            "Bug #5 fix: timeout MUST publish LoadingMeasured "
            . "(before it was silently discarded)")
    }

    tick_timeout_event_has_source_timeout_no_hud_return()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        this.stubClock.AdvanceMs(100000)
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this.svc.Tick()
        Assert.Equal("timeout_no_hud_return", capturedEvents[1]["source"])
    }

    tick_timeout_event_duration_reflects_real_time_above_max()
    {
        ; The published duration is the REAL one (clock delta), not
        ; clamped to maxMs. Rationale: if the user has a slow PC and
        ; loading lasts 100s, we want the run sum to reflect 100s
        ; (truth), not 90s (cap).
        this.svc.ArmFromAreaChange(10, "G1_2")
        this.stubClock.AdvanceMs(100000)   ; 100s real
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this.svc.Tick()
        Assert.Equal(100000, capturedEvents[1]["durationMs"],
            "Real duration preserved (no clamp to maxMs)")
    }

    tick_timeout_event_includes_from_zone()
    {
        this.zoneProvider.value := "Slow Loading Zone"
        this.svc.ArmFromAreaChange(10, "G1_2")
        this.stubClock.AdvanceMs(100000)
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this.svc.Tick()
        Assert.Equal("Slow Loading Zone", capturedEvents[1]["fromZone"])
    }

    tick_returns_to_idle_after_timeout()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        this.stubClock.AdvanceMs(100000)
        this.svc.Tick()
        Assert.False(this.svc.IsActive())
    }

    ; ============================================================
    ; Bug #5 regression: slow PC (extra-long loadings)
    ; ============================================================

    bug5_loading_100s_publishes_with_real_duration()
    {
        ; Typical slow-PC scenario: 100s loading (> maxMs 90s).
        ; Before the fix: silently discarded. PB stats showed total
        ; loading underestimated by 100s.
        this.svc.ArmFromAreaChange(10, "G1_2")
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this.stubClock.AdvanceMs(100000)
        this.svc.Tick()
        Assert.Equal(1, capturedEvents.Length, "100s loading published")
        Assert.Equal(100000, capturedEvents[1]["durationMs"])
    }

    bug5_loading_300s_publishes_with_real_duration()
    {
        ; Extreme case: 5-minute loading. Must still be visible in
        ; the statistics (signals a real problem to the user).
        this.svc.ArmFromAreaChange(10, "G1_2")
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this.stubClock.AdvanceMs(300000)
        this.svc.Tick()
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal(300000, capturedEvents[1]["durationMs"])
    }

    ; ============================================================
    ; Tick: timer stopped
    ; ============================================================

    tick_cancels_when_timer_inactive()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        this._SkipIgnorePeriod()
        this.timerSvc.Stop()
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this.svc.Tick()
        Assert.Equal(0, capturedEvents.Length, "Cancel does NOT publish LoadingMeasured")
    }

    tick_cancel_returns_to_idle()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        this._SkipIgnorePeriod()
        this.timerSvc.Stop()
        this.svc.Tick()
        Assert.False(this.svc.IsActive())
    }

    ; ============================================================
    ; Tick: HUD visible (end)
    ; ============================================================

    tick_ends_when_hud_returns_visible()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        this._SkipIgnorePeriod()
        this.stubScanner.visible := true
        this.stubClock.AdvanceMs(100)   ; duration ~300ms (200+100), passes min
        this.svc.Tick()
        Assert.False(this.svc.IsActive())
    }

    tick_end_publishes_loading_measured()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this._SkipIgnorePeriod()
        this.stubScanner.visible := true
        this.stubClock.AdvanceMs(100)
        this.svc.Tick()
        Assert.Equal(1, capturedEvents.Length)
    }

    tick_end_uses_hud_returned_fast_when_no_scene_seen()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this._SkipIgnorePeriod()
        this.stubScanner.visible := true
        this.stubClock.AdvanceMs(100)
        this.svc.Tick()
        Assert.Equal("hud_returned_fast", capturedEvents[1]["source"])
    }

    tick_end_uses_scene_then_hud_return_when_scene_seen()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this.stubClock.AdvanceMs(300)
        this.svc.NotifyScene("Mud Burrow")
        this.stubScanner.visible := true
        this.svc.Tick()
        Assert.Equal("scene_then_hud_return", capturedEvents[1]["source"])
    }

    tick_end_includes_from_zone()
    {
        this.zoneProvider.value := "Original Zone"
        this.svc.ArmFromAreaChange(10, "G1_2")
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this._SkipIgnorePeriod()
        this.stubClock.AdvanceMs(100)   ; total 300ms > minMs(250)
        this.zoneProvider.value := "Different Zone"   ; changed after arm
        this.stubScanner.visible := true
        this.svc.Tick()
        Assert.Equal("Original Zone", capturedEvents[1]["fromZone"])
    }

    tick_end_includes_to_zone()
    {
        this.zoneProvider.value := "Original Zone"
        this.svc.ArmFromAreaChange(10, "G1_2")
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this._SkipIgnorePeriod()
        this.stubClock.AdvanceMs(100)
        this.zoneProvider.value := "New Zone"
        this.stubScanner.visible := true
        this.svc.Tick()
        Assert.Equal("New Zone", capturedEvents[1]["toZone"])
    }

    tick_end_includes_duration_ms()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this.stubClock.AdvanceMs(500)   ; total 500ms
        this.stubScanner.visible := true
        this.svc.Tick()
        Assert.Equal(500, capturedEvents[1]["durationMs"])
    }

    tick_end_includes_start_act_index()
    {
        this.stepProvider.value := Map("actIndex", 5, "stepId", "step_x")
        this.svc.ArmFromAreaChange(10, "G5_1")
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this._SkipIgnorePeriod()
        this.stubClock.AdvanceMs(100)   ; total 300ms > minMs(250)
        this.stubScanner.visible := true
        this.svc.Tick()
        Assert.Equal(5, capturedEvents[1]["actIndex"])
    }

    tick_end_returns_to_idle()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        this._SkipIgnorePeriod()
        this.stubScanner.visible := true
        this.stubClock.AdvanceMs(100)
        this.svc.Tick()
        Assert.False(this.svc.IsActive())
    }

    ; ============================================================
    ; Tick: HUD absent (continues polling)
    ; ============================================================

    tick_continues_polling_when_hud_absent()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        this._SkipIgnorePeriod()
        ; scanner.visible default false
        this.svc.Tick()
        Assert.True(this.svc.IsActive(), "Keeps waiting for HUD to return")
    }

    tick_does_not_publish_when_hud_absent()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this._SkipIgnorePeriod()
        this.svc.Tick()
        Assert.Equal(0, capturedEvents.Length)
    }

    ; ============================================================
    ; End filtering
    ; ============================================================

    end_discards_loading_measured_when_below_min_ms()
    {
        ; Force end with duration < minMs: can't wait for minMs in the
        ; natural tick (early-ignore is 150ms, minMs is 250ms). Only
        ; possible by reducing minMs in cfg and arming + scanning fast.
        this.cfg.loadingVisualMinMs := 1000
        this.svc.ArmFromAreaChange(10, "G1_2")
        capturedEvents := this._CaptureEvents(Events.LoadingMeasured)
        this._SkipIgnorePeriod()
        this.stubScanner.visible := true   ; returns fast (300ms < 1000ms)
        this.svc.Tick()
        Assert.Equal(0, capturedEvents.Length, "duration < minMs discarded")
    }

    ; ============================================================
    ; AreaLevelChanged subscribe handler
    ; ============================================================

    area_level_changed_event_triggers_arm()
    {
        this.bus.Publish(Events.AreaLevelChanged, Map("areaLevel", 15, "areaCode", "G2_1"))
        Assert.True(this.svc.IsActive())
    }

    area_level_changed_ignores_non_object_data()
    {
        this.bus.Publish(Events.AreaLevelChanged, "not a map")
        Assert.False(this.svc.IsActive())
    }

    ; ============================================================
    ; ZoneChanged subscribe handler (NotifyScene)
    ; ============================================================

    zone_changed_event_calls_notify_scene_when_active()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        this.stubClock.AdvanceMs(300)   ; passes minMs
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.Equal("scene:Mud Burrow", this.svc.GetLastAnchor())
    }

    zone_changed_with_empty_zone_name_ignored()
    {
        this.svc.ArmFromAreaChange(10, "G1_2")
        anchorBefore := this.svc.GetLastAnchor()
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", ""))
        Assert.Equal(anchorBefore, this.svc.GetLastAnchor(),
            "ZoneChanged with empty zoneName doesn't update anchor")
    }

    zone_changed_when_idle_no_op()
    {
        ; Idle: ZoneChanged via NotifyScene returns false with no effect
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))
        Assert.False(this.svc.IsActive())
    }
}

TestRegistry.Register(LoadingDetectionServiceTests)
