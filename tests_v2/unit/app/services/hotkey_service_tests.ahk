; ============================================================
; HotkeyServiceTests
; ============================================================
;
; HotkeyService registers global hotkeys via the Hotkey() builtin.
; In headless=true mode (used in tests), Hotkey()/Send() are not
; called — the service only registers internally in _bound, and
; TriggerAction publishes directly on the bus.
;
; Supported ACTIONS (each maps 1:1 to a Command):
;   StartPause       -> Cmd.TimerToggleRequested
;   NewRun           -> Cmd.NewRunRequested
;   ResetRun         -> Cmd.ResetRunRequested
;   FinalizeRun      -> Cmd.FinalizeRunRequested
;   Settings         -> Cmd.OpenSettingsRequested
;   CycleLayout      -> Cmd.CycleOverlayLayoutRequested
;   PlotRunStats     -> Cmd.OpenRunStatsPlotRequested
;
; FocusChangingActions (Settings, PlotRunStats) have modifier cleanup
; before publishing (anti-regression: stuck Ctrl/Alt after opening dialog).


class HotkeyServiceTests extends TestCase
{
    bus := ""
    svc := ""

    Setup()
    {
        this.bus := Fixtures.MakeBus()
        this.svc := HotkeyService(this.bus, true)   ; headless
    }

    Teardown()
    {
        if IsObject(this.svc)
        {
            try this.svc.Stop()
        }
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_default_headless_false",
        "constructor_accepts_headless_true",

        ; --- Hydrate ---
        "hydrate_throws_when_not_map",
        "hydrate_stores_hotkeys_map",
        "hydrate_coerces_values_to_string",
        "hydrate_replaces_previous_hotkeys",

        ; --- ActionToCommand mapping ---
        "action_to_command_includes_all_7_actions",
        "action_to_command_start_pause_maps_to_timer_toggle",
        "action_to_command_new_run_maps_to_new_run_requested",
        "action_to_command_cycle_layout_maps_to_cycle_command",

        ; --- FocusChangingActions ---
        "focus_changing_actions_includes_settings",
        "focus_changing_actions_includes_plot_run_stats",
        "focus_changing_actions_does_not_include_start_pause",

        ; --- Start ---
        "start_registers_hotkeys_for_known_actions",
        "start_skips_unknown_actions",
        "start_skips_empty_keybinds",
        "start_sets_is_running_true",
        "start_is_idempotent",
        "start_count_matches_valid_actions",

        ; --- Stop ---
        "stop_clears_bound_keys",
        "stop_sets_is_running_false",
        "stop_is_idempotent",

        ; --- GetBoundKeys / Count ---
        "get_bound_keys_returns_defensive_copy",
        "count_zero_initially",
        "count_returns_bound_count",

        ; --- TriggerAction ---
        "trigger_action_publishes_command",
        "trigger_action_with_unknown_returns_false",
        "trigger_action_with_known_returns_true",
        "trigger_action_event_includes_source_hotkey",
        "trigger_action_event_includes_action_name",
        "trigger_action_all_7_actions_publish_correctly"
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

    _StandardHotkeyMap()
    {
        ; Mirrors the seven actions registered after the layout-control
        ; collapse: the trio of ToggleOverlay / ToggleMicroLock /
        ; ToggleSteveLock became the single CycleLayout. Used by Start
        ; tests that need a full, realistic Hydrate payload.
        return Map(
            "StartPause",   "^!t",
            "NewRun",       "^!n",
            "ResetRun",     "^!r",
            "FinalizeRun",  "^!f",
            "Settings",     "^!s",
            "CycleLayout",  "^!o",
            "PlotRunStats", "^!p"
        )
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        Assert.Throws(TypeError, () => HotkeyService("not bus"))
    }

    constructor_default_headless_false()
    {
        ; Default headless=false — but we won't call Start() here to
        ; avoid real Hotkey(). Just instantiate and see it doesn't crash.
        svc2 := HotkeyService(this.bus)
        Assert.False(svc2.IsRunning())
    }

    constructor_accepts_headless_true()
    {
        Assert.False(this.svc.IsRunning())   ; not Start()-ed yet
    }

    ; ============================================================
    ; Hydrate
    ; ============================================================

    hydrate_throws_when_not_map()
    {
        s := this.svc
        Assert.Throws(TypeError, () => s.Hydrate("not map"))
        Assert.Throws(TypeError, () => s.Hydrate([1, 2]))
    }

    hydrate_stores_hotkeys_map()
    {
        this.svc.Hydrate(Map("StartPause", "^!t"))
        this.svc.Start()
        Assert.Equal(1, this.svc.Count())
    }

    hydrate_coerces_values_to_string()
    {
        ; Integer key value becomes string
        this.svc.Hydrate(Map("StartPause", 123))
        this.svc.Start()
        bound := this.svc.GetBoundKeys()
        Assert.True(bound.Has("123"))
    }

    hydrate_replaces_previous_hotkeys()
    {
        this.svc.Hydrate(Map("StartPause", "^!t"))
        this.svc.Hydrate(Map("NewRun", "^!n"))
        this.svc.Start()
        Assert.Equal(1, this.svc.Count(), "Hydrate replaces, doesn't accumulate")
        Assert.True(this.svc.GetBoundKeys().Has("^!n"))
    }

    ; ============================================================
    ; ActionToCommand mapping
    ; ============================================================

    action_to_command_includes_all_7_actions()
    {
        ; Down from nine: the trio of ToggleOverlay / ToggleMicroLock
        ; / ToggleSteveLock collapsed into the single CycleLayout.
        ; This count pins the new shape so a regression that drops or
        ; double-adds an action surfaces here, not at runtime.
        Assert.Equal(7, HotkeyService.ActionToCommand.Count)
    }

    action_to_command_start_pause_maps_to_timer_toggle()
    {
        Assert.Equal(Commands.TimerToggleRequested,
            HotkeyService.ActionToCommand["StartPause"])
    }

    action_to_command_new_run_maps_to_new_run_requested()
    {
        Assert.Equal(Commands.NewRunRequested,
            HotkeyService.ActionToCommand["NewRun"])
    }

    action_to_command_cycle_layout_maps_to_cycle_command()
    {
        ; The new single layout-control action must route to the
        ; cycle command published to OverlayModeService. Locking the
        ; wiring here so a future rename doesn't silently break the
        ; only user-facing layout hotkey.
        Assert.Equal(Commands.CycleOverlayLayoutRequested,
            HotkeyService.ActionToCommand["CycleLayout"])
    }

    ; ============================================================
    ; FocusChangingActions
    ; ============================================================

    focus_changing_actions_includes_settings()
    {
        Assert.True(HotkeyService.FocusChangingActions.Has("Settings"))
    }

    focus_changing_actions_includes_plot_run_stats()
    {
        Assert.True(HotkeyService.FocusChangingActions.Has("PlotRunStats"))
    }

    focus_changing_actions_does_not_include_start_pause()
    {
        ; StartPause is frequent, cleanup would break PoE2 combos
        Assert.False(HotkeyService.FocusChangingActions.Has("StartPause"))
    }

    ; ============================================================
    ; Start
    ; ============================================================

    start_registers_hotkeys_for_known_actions()
    {
        this.svc.Hydrate(this._StandardHotkeyMap())
        this.svc.Start()
        Assert.Equal(7, this.svc.Count())
    }

    start_skips_unknown_actions()
    {
        this.svc.Hydrate(Map(
            "StartPause",      "^!t",
            "UnknownAction",   "^!x"   ; no entry in ActionToCommand
        ))
        this.svc.Start()
        Assert.Equal(1, this.svc.Count(), "UnknownAction skipped")
    }

    start_skips_empty_keybinds()
    {
        this.svc.Hydrate(Map(
            "StartPause", "^!t",
            "NewRun",     ""
        ))
        this.svc.Start()
        Assert.Equal(1, this.svc.Count(), "Empty keybind skipped")
    }

    start_sets_is_running_true()
    {
        this.svc.Start()
        Assert.True(this.svc.IsRunning())
    }

    start_is_idempotent()
    {
        this.svc.Hydrate(Map("StartPause", "^!t"))
        this.svc.Start()
        this.svc.Start()
        Assert.Equal(1, this.svc.Count())
    }

    start_count_matches_valid_actions()
    {
        this.svc.Hydrate(Map(
            "StartPause",     "^!t",
            "Settings",       "^!s",
            "Unknown",        "^!x",
            "ResetRun",       ""
        ))
        this.svc.Start()
        Assert.Equal(2, this.svc.Count(),
            "StartPause + Settings valid; Unknown + ResetRun(empty) skipped")
    }

    ; ============================================================
    ; Stop
    ; ============================================================

    stop_clears_bound_keys()
    {
        this.svc.Hydrate(this._StandardHotkeyMap())
        this.svc.Start()
        this.svc.Stop()
        Assert.Equal(0, this.svc.Count())
    }

    stop_sets_is_running_false()
    {
        this.svc.Start()
        this.svc.Stop()
        Assert.False(this.svc.IsRunning())
    }

    stop_is_idempotent()
    {
        this.svc.Stop()
        this.svc.Stop()
        Assert.False(this.svc.IsRunning())
    }

    ; ============================================================
    ; GetBoundKeys / Count
    ; ============================================================

    get_bound_keys_returns_defensive_copy()
    {
        this.svc.Hydrate(Map("StartPause", "^!t"))
        this.svc.Start()
        copy := this.svc.GetBoundKeys()
        copy["hacked"] := true
        Assert.False(this.svc.GetBoundKeys().Has("hacked"))
    }

    count_zero_initially()
    {
        Assert.Equal(0, this.svc.Count())
    }

    count_returns_bound_count()
    {
        this.svc.Hydrate(Map(
            "StartPause", "^!t",
            "NewRun",     "^!n",
            "Settings",   "^!s"
        ))
        this.svc.Start()
        Assert.Equal(3, this.svc.Count())
    }

    ; ============================================================
    ; TriggerAction
    ; ============================================================

    trigger_action_publishes_command()
    {
        capturedEvents := this._CaptureEvents(Commands.TimerToggleRequested)
        this.svc.TriggerAction("StartPause")
        Assert.Equal(1, capturedEvents.Length)
    }

    trigger_action_with_unknown_returns_false()
    {
        Assert.False(this.svc.TriggerAction("BogusAction"))
    }

    trigger_action_with_known_returns_true()
    {
        Assert.True(this.svc.TriggerAction("NewRun"))
    }

    trigger_action_event_includes_source_hotkey()
    {
        capturedEvents := this._CaptureEvents(Commands.NewRunRequested)
        this.svc.TriggerAction("NewRun")
        Assert.Equal("hotkey", capturedEvents[1]["source"])
    }

    trigger_action_event_includes_action_name()
    {
        capturedEvents := this._CaptureEvents(Commands.NewRunRequested)
        this.svc.TriggerAction("NewRun")
        Assert.Equal("NewRun", capturedEvents[1]["action"])
    }

    trigger_action_all_7_actions_publish_correctly()
    {
        ; Verifies that each of the seven actions registered after
        ; the layout-control collapse publishes to the correct
        ; command. The previous trio of ToggleOverlay / ToggleMicroLock
        ; / ToggleSteveLock cases dropped out with the collapse.
        cases := [
            ["StartPause",   Commands.TimerToggleRequested],
            ["NewRun",       Commands.NewRunRequested],
            ["ResetRun",     Commands.ResetRunRequested],
            ["FinalizeRun",  Commands.FinalizeRunRequested],
            ["Settings",     Commands.OpenSettingsRequested],
            ["CycleLayout",  Commands.CycleOverlayLayoutRequested],
            ["PlotRunStats", Commands.OpenRunStatsPlotRequested]
        ]
        for _, pair in cases
        {
            actionName := pair[1]
            cmdName    := pair[2]
            capturedEvents := []
            this.bus.Subscribe(cmdName, (data) => capturedEvents.Push(data))
            this.svc.TriggerAction(actionName)
            Assert.Equal(1, capturedEvents.Length, "Action " actionName " did not publish")
        }
    }
}

TestRegistry.Register(HotkeyServiceTests)
