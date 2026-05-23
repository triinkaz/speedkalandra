; ============================================================
; OverlayModeServiceTests
; ============================================================
;
; State machine with 3 modes: COMPACT (default), MICRO, STEVE.
; Single user-facing layout action (CycleLayout) walks STEVE ->
; COMPACT -> MICRO -> STEVE. SetMode stays as a programmatic API.
;
; Hydrate reads window.{microLocked,steveLocked} from AppSettings;
; mode flags stay mutually exclusive at runtime so the persisted
; "what was the last layout" is consistent across reloads.

class OverlayModeServiceTests extends TestCase
{
    bus := ""
    cfg := ""
    svc := ""

    Setup()
    {
        this.bus := Fixtures.MakeBus()
        this.cfg := AppSettings.Defaults()
        this.svc := OverlayModeService(this.bus, this.cfg)
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
        "constructor_throws_when_cfg_not_app_settings",
        "constructor_subscribes_to_2_commands",
        "constructor_default_mode_is_compact",
        "constructor_no_locks_active",

        ; --- Hydrate ---
        "hydrate_with_micro_locked_in_settings_sets_micro_mode",
        "hydrate_with_steve_locked_in_settings_sets_steve_mode",
        "hydrate_steve_takes_precedence_over_micro",
        "hydrate_no_locks_sets_compact_mode",
        "hydrate_with_missing_window_settings_defaults_to_compact",

        ; --- CycleLayout (STEVE -> COMPACT -> MICRO -> STEVE) ---
        "cycle_from_compact_goes_to_micro",
        "cycle_from_micro_goes_to_steve",
        "cycle_from_steve_goes_to_compact",
        "cycle_three_times_returns_to_starting_mode",
        "cycle_returns_true",
        "cycle_publishes_overlay_mode_changed",
        "cycle_syncs_to_settings_window_steve_locked",
        "cycle_syncs_to_settings_window_micro_locked",
        "cycle_syncs_to_settings_window_no_locks_on_compact",
        "cycle_keeps_lock_flags_mutually_exclusive",

        ; --- SetMode (programmatic API) ---
        "set_mode_throws_on_invalid_target",
        "set_mode_to_micro_sets_micro_locked",
        "set_mode_to_steve_sets_steve_locked",
        "set_mode_to_compact_clears_all_locks",
        "set_mode_idempotent_returns_false",
        "set_mode_publishes_when_changed",
        "set_mode_does_not_publish_when_idempotent",

        ; --- Commands subscribers ---
        "cycle_overlay_layout_requested_triggers_cycle",
        "cycle_overlay_layout_requested_publishes_event",
        "set_overlay_mode_requested_with_mode_data_triggers_set_mode",
        "set_overlay_mode_requested_ignores_non_object_data",
        "set_overlay_mode_requested_ignores_missing_mode_key",

        ; --- Event payload ---
        "mode_changed_event_includes_prev_mode",
        "mode_changed_event_includes_locked_flags",

        ; --- Dispose ---
        "dispose_unsubscribes_all_commands",
        "dispose_is_idempotent"
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

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        c := this.cfg
        Assert.Throws(TypeError, () => OverlayModeService("not bus", c))
    }

    constructor_throws_when_cfg_not_app_settings()
    {
        b := this.bus
        Assert.Throws(TypeError, () => OverlayModeService(b, "not cfg"))
    }

    constructor_subscribes_to_2_commands()
    {
        ; Cycle (single user-facing action) + SetMode (programmatic).
        ; Down from three after the Toggle* trio was collapsed into
        ; CycleLayout.
        Assert.Equal(1, this.bus.Subscribers(Commands.CycleOverlayLayoutRequested))
        Assert.Equal(1, this.bus.Subscribers(Commands.SetOverlayModeRequested))
    }

    constructor_default_mode_is_compact()
    {
        Assert.Equal(OverlayModes.COMPACT, this.svc.GetMode())
        Assert.True(this.svc.IsCompact())
    }

    constructor_no_locks_active()
    {
        Assert.False(this.svc.IsMicroLocked())
        Assert.False(this.svc.IsSteveLocked())
    }

    ; ============================================================
    ; Hydrate
    ; ============================================================

    hydrate_with_micro_locked_in_settings_sets_micro_mode()
    {
        this.cfg.window.microLocked := true
        this.svc.Hydrate()
        Assert.Equal(OverlayModes.MICRO, this.svc.GetMode())
        Assert.True(this.svc.IsMicroLocked())
    }

    hydrate_with_steve_locked_in_settings_sets_steve_mode()
    {
        this.cfg.window.steveLocked := true
        this.svc.Hydrate()
        Assert.Equal(OverlayModes.STEVE, this.svc.GetMode())
        Assert.True(this.svc.IsSteveLocked())
    }

    hydrate_steve_takes_precedence_over_micro()
    {
        ; Defensive against a conflicting manual edit in the INI \u2014
        ; mode flags are mutually exclusive at runtime so the
        ; persisted state can never be both.
        this.cfg.window.microLocked := true
        this.cfg.window.steveLocked := true
        this.svc.Hydrate()
        Assert.True(this.svc.IsSteveLocked())
        Assert.False(this.svc.IsMicroLocked(),
            "Steve overrides micro when both are true")
    }

    hydrate_no_locks_sets_compact_mode()
    {
        this.cfg.window.microLocked := false
        this.cfg.window.steveLocked := false
        this.svc.Hydrate()
        Assert.Equal(OverlayModes.COMPACT, this.svc.GetMode())
    }

    hydrate_with_missing_window_settings_defaults_to_compact()
    {
        this.cfg.window := ""   ; no object
        this.svc.Hydrate()
        Assert.Equal(OverlayModes.COMPACT, this.svc.GetMode())
        Assert.False(this.svc.IsMicroLocked())
        Assert.False(this.svc.IsSteveLocked())
    }

    ; ============================================================
    ; CycleLayout
    ;
    ; The cycle order is fixed: STEVE -> COMPACT -> MICRO -> STEVE.
    ; Picked to walk from densest to lightest layout (Steve = full
    ; SteveTheHappyWhale layout; Micro = minimal bar) so a user
    ; cycling through finds the smaller layouts via successive
    ; presses rather than having to remember individual hotkeys.
    ; ============================================================

    cycle_from_compact_goes_to_micro()
    {
        ; Default mode is COMPACT \u2014 next stop is MICRO.
        this.svc.CycleLayout()
        Assert.Equal(OverlayModes.MICRO, this.svc.GetMode())
        Assert.True(this.svc.IsMicroLocked())
        Assert.False(this.svc.IsSteveLocked())
    }

    cycle_from_micro_goes_to_steve()
    {
        this.svc.SetMode(OverlayModes.MICRO)
        this.svc.CycleLayout()
        Assert.Equal(OverlayModes.STEVE, this.svc.GetMode())
        Assert.True(this.svc.IsSteveLocked())
        Assert.False(this.svc.IsMicroLocked())
    }

    cycle_from_steve_goes_to_compact()
    {
        this.svc.SetMode(OverlayModes.STEVE)
        this.svc.CycleLayout()
        Assert.Equal(OverlayModes.COMPACT, this.svc.GetMode())
        Assert.False(this.svc.IsSteveLocked())
        Assert.False(this.svc.IsMicroLocked())
    }

    cycle_three_times_returns_to_starting_mode()
    {
        ; The cycle is a closed loop of length 3. Three presses from
        ; any starting mode land back on the same mode.
        this.svc.SetMode(OverlayModes.STEVE)
        this.svc.CycleLayout()    ; -> COMPACT
        this.svc.CycleLayout()    ; -> MICRO
        this.svc.CycleLayout()    ; -> STEVE
        Assert.Equal(OverlayModes.STEVE, this.svc.GetMode())
    }

    cycle_returns_true()
    {
        ; Cycle always changes mode (one of three values), so always
        ; returns true. Symmetric with SetMode for non-idempotent
        ; transitions.
        Assert.True(this.svc.CycleLayout())
    }

    cycle_publishes_overlay_mode_changed()
    {
        capturedEvents := this._CaptureEvents(Events.OverlayModeChanged)
        this.svc.CycleLayout()
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal(OverlayModes.MICRO, capturedEvents[1]["mode"])
        Assert.Equal(OverlayModes.COMPACT, capturedEvents[1]["prevMode"])
    }

    cycle_syncs_to_settings_window_steve_locked()
    {
        ; Land on STEVE via the cycle (MICRO -> STEVE) and check
        ; the persistence-bound flag flipped accordingly.
        this.svc.SetMode(OverlayModes.MICRO)
        this.svc.CycleLayout()
        Assert.True(this.cfg.window.steveLocked,
            "STEVE lock written to settings.window")
        Assert.False(this.cfg.window.microLocked,
            "MICRO lock cleared when leaving MICRO mode")
    }

    cycle_syncs_to_settings_window_micro_locked()
    {
        this.svc.CycleLayout()    ; COMPACT -> MICRO
        Assert.True(this.cfg.window.microLocked)
        Assert.False(this.cfg.window.steveLocked)
    }

    cycle_syncs_to_settings_window_no_locks_on_compact()
    {
        ; Cycle from STEVE lands on COMPACT \u2014 both lock flags clear.
        this.svc.SetMode(OverlayModes.STEVE)
        this.svc.CycleLayout()
        Assert.False(this.cfg.window.steveLocked)
        Assert.False(this.cfg.window.microLocked)
    }

    cycle_keeps_lock_flags_mutually_exclusive()
    {
        ; Walk the whole cycle and assert that at every step at most
        ; one lock flag is set. This is the invariant that the rest
        ; of the system (Hydrate path, AppSettings.window persist)
        ; depends on.
        for _, _ in [1, 2, 3, 4, 5]
        {
            this.svc.CycleLayout()
            both := this.svc.IsMicroLocked() && this.svc.IsSteveLocked()
            Assert.False(both, "lock flags must remain mutually exclusive at every step")
        }
    }

    ; ============================================================
    ; SetMode (programmatic API)
    ; ============================================================

    set_mode_throws_on_invalid_target()
    {
        s := this.svc
        Assert.Throws(ValueError, () => s.SetMode("invalid_mode"))
    }

    set_mode_to_micro_sets_micro_locked()
    {
        this.svc.SetMode(OverlayModes.MICRO)
        Assert.True(this.svc.IsMicroLocked())
        Assert.False(this.svc.IsSteveLocked())
    }

    set_mode_to_steve_sets_steve_locked()
    {
        this.svc.SetMode(OverlayModes.STEVE)
        Assert.True(this.svc.IsSteveLocked())
        Assert.False(this.svc.IsMicroLocked())
    }

    set_mode_to_compact_clears_all_locks()
    {
        this.svc.SetMode(OverlayModes.STEVE)
        this.svc.SetMode(OverlayModes.COMPACT)
        Assert.False(this.svc.IsMicroLocked())
        Assert.False(this.svc.IsSteveLocked())
    }

    set_mode_idempotent_returns_false()
    {
        this.svc.SetMode(OverlayModes.MICRO)
        Assert.False(this.svc.SetMode(OverlayModes.MICRO),
            "Setting same mode: nothing changes, returns false")
    }

    set_mode_publishes_when_changed()
    {
        capturedEvents := this._CaptureEvents(Events.OverlayModeChanged)
        this.svc.SetMode(OverlayModes.MICRO)
        Assert.Equal(1, capturedEvents.Length)
    }

    set_mode_does_not_publish_when_idempotent()
    {
        this.svc.SetMode(OverlayModes.MICRO)
        capturedEvents := this._CaptureEvents(Events.OverlayModeChanged)
        this.svc.SetMode(OverlayModes.MICRO)
        Assert.Equal(0, capturedEvents.Length)
    }

    ; ============================================================
    ; Commands subscribers
    ; ============================================================

    cycle_overlay_layout_requested_triggers_cycle()
    {
        ; Default mode COMPACT \u2014 publishing the command moves it
        ; to MICRO (next step in the STEVE -> COMPACT -> MICRO loop).
        this.bus.Publish(Commands.CycleOverlayLayoutRequested, Map())
        Assert.Equal(OverlayModes.MICRO, this.svc.GetMode())
        Assert.True(this.svc.IsMicroLocked())
    }

    cycle_overlay_layout_requested_publishes_event()
    {
        ; End-to-end: the command handler routes through CycleLayout,
        ; which in turn publishes Evt.OverlayModeChanged. Subscribers
        ; that listen only to the event (not the command) still see
        ; the transition.
        captured := this._CaptureEvents(Events.OverlayModeChanged)
        this.bus.Publish(Commands.CycleOverlayLayoutRequested, Map())
        Assert.Equal(1, captured.Length)
    }

    set_overlay_mode_requested_with_mode_data_triggers_set_mode()
    {
        this.bus.Publish(Commands.SetOverlayModeRequested, Map("mode", OverlayModes.MICRO))
        Assert.Equal(OverlayModes.MICRO, this.svc.GetMode())
    }

    set_overlay_mode_requested_ignores_non_object_data()
    {
        this.bus.Publish(Commands.SetOverlayModeRequested, "not a map")
        Assert.Equal(OverlayModes.COMPACT, this.svc.GetMode())
    }

    set_overlay_mode_requested_ignores_missing_mode_key()
    {
        this.bus.Publish(Commands.SetOverlayModeRequested, Map("other", "value"))
        Assert.Equal(OverlayModes.COMPACT, this.svc.GetMode())
    }

    ; ============================================================
    ; Event payload
    ; ============================================================

    mode_changed_event_includes_prev_mode()
    {
        capturedEvents := this._CaptureEvents(Events.OverlayModeChanged)
        this.svc.CycleLayout()
        Assert.Equal(OverlayModes.COMPACT, capturedEvents[1]["prevMode"])
        Assert.Equal(OverlayModes.MICRO,   capturedEvents[1]["mode"])
    }

    mode_changed_event_includes_locked_flags()
    {
        ; The two lock flags survive in the payload because
        ; downstream subscribers (e.g. AppSettings.window persist)
        ; still consume them. Payload shape pinned to avoid silent
        ; field drops in a future refactor.
        capturedEvents := this._CaptureEvents(Events.OverlayModeChanged)
        this.svc.CycleLayout()    ; COMPACT -> MICRO
        Assert.True(capturedEvents[1]["locked"], "micro lock flag in payload")
        Assert.False(capturedEvents[1]["steveLocked"], "steve lock flag in payload")
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_all_commands()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Commands.CycleOverlayLayoutRequested))
        Assert.Equal(0, this.bus.Subscribers(Commands.SetOverlayModeRequested))
    }

    dispose_is_idempotent()
    {
        this.svc.Dispose()
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Commands.CycleOverlayLayoutRequested))
    }
}

TestRegistry.Register(OverlayModeServiceTests)
