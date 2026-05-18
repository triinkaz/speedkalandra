; ============================================================
; OverlayModeServiceTests
; ============================================================
;
; State machine with 3 modes: COMPACT (default), MICRO, STEVE.
; Locked modes (microLocked/steveLocked) are mutually exclusive.
; AUTO MICRO mode is a temporary entry via panel keys
; (i/v/c/g/p/u/m), but the publisher is currently disconnected
; — _heldKeys is always empty in real use. The OnPanelKeyDown/Up +
; ClearHeldKeys methods are still externally callable (covered by
; the tests).
;
; Subscribes to 3 Commands. Publishes OverlayModeChanged on
; transitions. Hydrate reads window.{microLocked,steveLocked} from
; AppSettings.

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
        "constructor_subscribes_to_3_commands",
        "constructor_default_mode_is_compact",
        "constructor_no_locks_active",
        "constructor_held_keys_empty",

        ; --- Hydrate ---
        "hydrate_with_micro_locked_in_settings_sets_micro_mode",
        "hydrate_with_steve_locked_in_settings_sets_steve_mode",
        "hydrate_steve_takes_precedence_over_micro",
        "hydrate_no_locks_sets_compact_mode",
        "hydrate_with_missing_window_settings_defaults_to_compact",

        ; --- ToggleMicroLock ---
        "toggle_micro_lock_from_compact_activates_micro",
        "toggle_micro_lock_from_micro_back_to_compact",
        "toggle_micro_lock_clears_steve_when_active",
        "toggle_micro_lock_returns_true",
        "toggle_micro_lock_publishes_overlay_mode_changed",
        "toggle_micro_lock_syncs_to_settings_window",

        ; --- ToggleSteveLock ---
        "toggle_steve_lock_from_compact_activates_steve",
        "toggle_steve_lock_from_steve_back_to_compact",
        "toggle_steve_lock_clears_micro_when_active",
        "toggle_steve_lock_returns_true",
        "toggle_steve_lock_publishes_overlay_mode_changed",
        "toggle_steve_lock_syncs_to_settings_window",

        ; --- SetMode ---
        "set_mode_throws_on_invalid_target",
        "set_mode_to_micro_sets_micro_locked",
        "set_mode_to_steve_sets_steve_locked",
        "set_mode_to_compact_clears_all_locks",
        "set_mode_idempotent_returns_false",
        "set_mode_publishes_when_changed",
        "set_mode_does_not_publish_when_idempotent",

        ; --- OnPanelKeyDown (toggle semantics) ---
        "panel_key_down_first_press_activates_auto_micro",
        "panel_key_down_second_press_same_key_closes_panel",
        "panel_key_down_with_micro_locked_does_not_change_mode",
        "panel_key_down_with_steve_locked_does_not_change_mode",
        "panel_key_down_normalizes_key_case",
        "panel_key_down_empty_key_returns_false",
        "panel_key_down_publishes_when_mode_changes",
        "panel_key_up_is_no_op",

        ; --- ClearHeldKeys ---
        "clear_held_keys_removes_all_keys",
        "clear_held_keys_returns_to_compact_when_auto_micro",
        "clear_held_keys_no_op_when_already_empty",
        "clear_held_keys_does_not_change_mode_when_locked",

        ; --- Commands subscribers ---
        "toggle_micro_lock_requested_triggers_toggle",
        "toggle_steve_lock_requested_triggers_toggle",
        "set_overlay_mode_requested_with_mode_data_triggers_set_mode",
        "set_overlay_mode_requested_ignores_non_object_data",
        "set_overlay_mode_requested_ignores_missing_mode_key",

        ; --- Event payload ---
        "mode_changed_event_includes_prev_mode",
        "mode_changed_event_includes_locked_flag",
        "mode_changed_event_includes_held_keys_array",

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

    constructor_subscribes_to_3_commands()
    {
        Assert.Equal(1, this.bus.Subscribers(Commands.ToggleMicroLockRequested))
        Assert.Equal(1, this.bus.Subscribers(Commands.ToggleSteveLockRequested))
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

    constructor_held_keys_empty()
    {
        Assert.Equal(0, this.svc.GetHeldKeyCount())
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
        ; Defensive against conflicting manual edit in the INI
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
    ; ToggleMicroLock
    ; ============================================================

    toggle_micro_lock_from_compact_activates_micro()
    {
        this.svc.ToggleMicroLock()
        Assert.Equal(OverlayModes.MICRO, this.svc.GetMode())
        Assert.True(this.svc.IsMicroLocked())
    }

    toggle_micro_lock_from_micro_back_to_compact()
    {
        this.svc.ToggleMicroLock()   ; -> micro
        this.svc.ToggleMicroLock()   ; -> compact
        Assert.Equal(OverlayModes.COMPACT, this.svc.GetMode())
        Assert.False(this.svc.IsMicroLocked())
    }

    toggle_micro_lock_clears_steve_when_active()
    {
        this.svc.SetMode(OverlayModes.STEVE)
        this.svc.ToggleMicroLock()
        Assert.True(this.svc.IsMicroLocked())
        Assert.False(this.svc.IsSteveLocked(),
            "Steve deactivated when activating micro (mutually exclusive)")
    }

    toggle_micro_lock_returns_true()
    {
        Assert.True(this.svc.ToggleMicroLock())
    }

    toggle_micro_lock_publishes_overlay_mode_changed()
    {
        capturedEvents := this._CaptureEvents(Events.OverlayModeChanged)
        this.svc.ToggleMicroLock()
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal(OverlayModes.MICRO, capturedEvents[1]["mode"])
    }

    toggle_micro_lock_syncs_to_settings_window()
    {
        this.svc.ToggleMicroLock()
        Assert.True(this.cfg.window.microLocked,
            "Flag written to settings.window to persist across runs")
    }

    ; ============================================================
    ; ToggleSteveLock
    ; ============================================================

    toggle_steve_lock_from_compact_activates_steve()
    {
        this.svc.ToggleSteveLock()
        Assert.Equal(OverlayModes.STEVE, this.svc.GetMode())
        Assert.True(this.svc.IsSteveLocked())
    }

    toggle_steve_lock_from_steve_back_to_compact()
    {
        this.svc.ToggleSteveLock()
        this.svc.ToggleSteveLock()
        Assert.Equal(OverlayModes.COMPACT, this.svc.GetMode())
        Assert.False(this.svc.IsSteveLocked())
    }

    toggle_steve_lock_clears_micro_when_active()
    {
        this.svc.SetMode(OverlayModes.MICRO)
        this.svc.ToggleSteveLock()
        Assert.True(this.svc.IsSteveLocked())
        Assert.False(this.svc.IsMicroLocked())
    }

    toggle_steve_lock_returns_true()
    {
        Assert.True(this.svc.ToggleSteveLock())
    }

    toggle_steve_lock_publishes_overlay_mode_changed()
    {
        capturedEvents := this._CaptureEvents(Events.OverlayModeChanged)
        this.svc.ToggleSteveLock()
        Assert.Equal(1, capturedEvents.Length)
    }

    toggle_steve_lock_syncs_to_settings_window()
    {
        this.svc.ToggleSteveLock()
        Assert.True(this.cfg.window.steveLocked)
    }

    ; ============================================================
    ; SetMode
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
    ; OnPanelKeyDown (TOGGLE semantics)
    ; ============================================================

    panel_key_down_first_press_activates_auto_micro()
    {
        this.svc.OnPanelKeyDown("i")
        Assert.Equal(OverlayModes.MICRO, this.svc.GetMode())
        Assert.True(this.svc.IsMicroAuto(), "MICRO but not locked = auto")
    }

    panel_key_down_second_press_same_key_closes_panel()
    {
        this.svc.OnPanelKeyDown("i")
        this.svc.OnPanelKeyDown("i")   ; toggle closes
        Assert.Equal(0, this.svc.GetHeldKeyCount())
        Assert.Equal(OverlayModes.COMPACT, this.svc.GetMode())
    }

    panel_key_down_with_micro_locked_does_not_change_mode()
    {
        this.svc.ToggleMicroLock()
        capturedEvents := this._CaptureEvents(Events.OverlayModeChanged)
        this.svc.OnPanelKeyDown("i")
        ; Mode stays MICRO (locked), but keys were registered
        Assert.Equal(OverlayModes.MICRO, this.svc.GetMode())
        Assert.Equal(1, this.svc.GetHeldKeyCount())
        Assert.Equal(0, capturedEvents.Length, "Locked: doesn't publish")
    }

    panel_key_down_with_steve_locked_does_not_change_mode()
    {
        this.svc.ToggleSteveLock()
        this.svc.OnPanelKeyDown("i")
        Assert.Equal(OverlayModes.STEVE, this.svc.GetMode())
    }

    panel_key_down_normalizes_key_case()
    {
        this.svc.OnPanelKeyDown("I")
        Assert.True(this.svc.HasHeldKey("i"), "Key normalized to lowercase")
        Assert.True(this.svc.HasHeldKey("I"), "Lookup also normalizes")
    }

    panel_key_down_empty_key_returns_false()
    {
        Assert.False(this.svc.OnPanelKeyDown(""))
        Assert.Equal(0, this.svc.GetHeldKeyCount())
    }

    panel_key_down_publishes_when_mode_changes()
    {
        capturedEvents := this._CaptureEvents(Events.OverlayModeChanged)
        this.svc.OnPanelKeyDown("i")
        Assert.Equal(1, capturedEvents.Length)
    }

    panel_key_up_is_no_op()
    {
        this.svc.OnPanelKeyDown("i")
        Assert.False(this.svc.OnPanelKeyUp("i"),
            "Toggle semantics: UP is no-op, returns false")
        Assert.Equal(1, this.svc.GetHeldKeyCount(), "Key stays held")
    }

    ; ============================================================
    ; ClearHeldKeys
    ; ============================================================

    clear_held_keys_removes_all_keys()
    {
        this.svc.OnPanelKeyDown("i")
        this.svc.OnPanelKeyDown("v")
        this.svc.ClearHeldKeys()
        Assert.Equal(0, this.svc.GetHeldKeyCount())
    }

    clear_held_keys_returns_to_compact_when_auto_micro()
    {
        this.svc.OnPanelKeyDown("i")   ; auto MICRO
        this.svc.ClearHeldKeys()
        Assert.Equal(OverlayModes.COMPACT, this.svc.GetMode())
    }

    clear_held_keys_no_op_when_already_empty()
    {
        Assert.False(this.svc.ClearHeldKeys())
    }

    clear_held_keys_does_not_change_mode_when_locked()
    {
        this.svc.ToggleMicroLock()
        this.svc.OnPanelKeyDown("i")
        this.svc.ClearHeldKeys()
        Assert.Equal(OverlayModes.MICRO, this.svc.GetMode(),
            "Locked: ClearHeldKeys doesn't pull out of MICRO")
    }

    ; ============================================================
    ; Commands subscribers
    ; ============================================================

    toggle_micro_lock_requested_triggers_toggle()
    {
        this.bus.Publish(Commands.ToggleMicroLockRequested, Map())
        Assert.True(this.svc.IsMicroLocked())
    }

    toggle_steve_lock_requested_triggers_toggle()
    {
        this.bus.Publish(Commands.ToggleSteveLockRequested, Map())
        Assert.True(this.svc.IsSteveLocked())
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
        this.svc.ToggleMicroLock()
        Assert.Equal(OverlayModes.COMPACT, capturedEvents[1]["prevMode"])
        Assert.Equal(OverlayModes.MICRO,   capturedEvents[1]["mode"])
    }

    mode_changed_event_includes_locked_flag()
    {
        capturedEvents := this._CaptureEvents(Events.OverlayModeChanged)
        this.svc.ToggleMicroLock()
        Assert.True(capturedEvents[1]["locked"])
        Assert.False(capturedEvents[1]["steveLocked"])
    }

    mode_changed_event_includes_held_keys_array()
    {
        capturedEvents := this._CaptureEvents(Events.OverlayModeChanged)
        this.svc.OnPanelKeyDown("i")
        Assert.True(capturedEvents[1]["heldKeys"] is Array)
        Assert.Equal(1, capturedEvents[1]["heldKeys"].Length)
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_all_commands()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Commands.ToggleMicroLockRequested))
        Assert.Equal(0, this.bus.Subscribers(Commands.ToggleSteveLockRequested))
        Assert.Equal(0, this.bus.Subscribers(Commands.SetOverlayModeRequested))
    }

    dispose_is_idempotent()
    {
        this.svc.Dispose()
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Commands.ToggleMicroLockRequested))
    }
}

TestRegistry.Register(OverlayModeServiceTests)
