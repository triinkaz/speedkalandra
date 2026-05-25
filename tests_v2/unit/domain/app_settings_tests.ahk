; ============================================================
; AppSettings tests
; ============================================================
;
; AppSettings aggregates ALL the tracker configurations:
;   - General (profileName, gamePatch, logFile)
;   - Character (name, class, level)
;   - CurrentArea (level, code)
;   - LoadingVisual (enabled, pollMs, minMs, maxMs)
;   - autoPauseOnFocus
;   - deathPenaltyEnabled, deathPenaltyMs
;   - disclaimerAcknowledged
;   - eventTracingEnabled (opt-in)
;   - autoFinalizeRegex (strict: "" reverts to default)
;   - autoStartRegex (allow empty: "" accepted explicitly)
;   - vendorRegexes (NOT read by FromMap; repository handles it)
;   - hotkeys (defensive merge with defaults)
;   - window (WindowState or Map)
;   - overlay (OverlayLayout or Map)
;
; Tests pull most of the weight here because AppSettings is the
; aggregate of coherent validations of each section. Type-checking
; the composite is important because historical Bug #4 came from there.

class AppSettingsTests extends TestCase
{
    static Tests := [
        ; --- Defaults ---
        "defaults_has_default_profile_name",
        "defaults_has_unknown_game_patch",
        "defaults_window_is_window_state_instance",
        "defaults_overlay_is_overlay_layout_instance",
        "defaults_hotkeys_includes_seven_actions",
        "defaults_vendor_regexes_are_three_empty_strings",
        "defaults_loading_visual_is_enabled",
        "defaults_auto_pause_on_focus_is_true",
        "defaults_death_penalty_settings",
        "defaults_disclaimer_not_acknowledged",
        "defaults_event_tracing_disabled_by_default",
        "defaults_pb_display_mode_is_pb",
        "defaults_show_outcome_banner_is_true",
        "defaults_route_widget_visible_is_false",
        "defaults_route_rows_visible_is_5",
        "defaults_route_note_font_size_is_8",
        "defaults_auto_finalize_regex_empty",
        "defaults_auto_start_regex_is_wounded_man_line",

        ; --- FromMap validation ---
        "from_map_throws_type_error_on_non_object",
        "from_map_uses_defaults_for_empty_input",

        ; --- FromMap reads per section ---
        "from_map_reads_profile_name",
        "from_map_reads_game_patch_and_log_file",
        "from_map_reads_character_fields",
        "from_map_reads_current_area_fields",
        "from_map_reads_loading_visual_settings",
        "from_map_reads_auto_pause_on_focus",
        "from_map_reads_death_penalty_settings",
        "from_map_clamps_negative_death_penalty_ms_to_zero",
        "from_map_reads_disclaimer_acknowledged",
        "from_map_reads_event_tracing_enabled",
        "from_map_reads_pb_display_mode_avg5",
        "from_map_pb_display_mode_invalid_falls_back_to_pb",
        "from_map_pb_display_mode_accepts_case_variations_as_avg5",
        "from_map_reads_show_outcome_banner",
        "from_map_show_outcome_banner_defaults_true_when_missing",
        "from_map_reads_route_widget_visible",
        "from_map_reads_route_rows_visible",
        "from_map_clamps_route_rows_visible_below_three",
        "from_map_clamps_route_rows_visible_above_ten",
        "from_map_route_rows_visible_invalid_uses_default",
        "from_map_route_rows_visible_missing_uses_default",
        "from_map_reads_route_note_font_size",
        "from_map_clamps_route_note_font_size_below_six",
        "from_map_clamps_route_note_font_size_above_sixteen",
        "from_map_route_note_font_size_invalid_uses_default",
        "from_map_route_note_font_size_missing_uses_default",
        "from_map_reads_auto_finalize_regex",
        "from_map_reads_auto_start_regex_allowing_empty",
        "from_map_strict_string_treats_empty_as_missing",
        "from_map_merges_hotkeys_with_defaults",

        ; --- FromMap composites (WindowState, OverlayLayout) ---
        "from_map_accepts_window_state_instance",
        "from_map_accepts_window_state_as_map",
        "from_map_accepts_overlay_layout_instance",
        "from_map_accepts_overlay_layout_as_map",

        ; --- FromMap coercions ---
        "from_map_coerces_boolean_string_one_to_true",
        "from_map_coerces_boolean_string_zero_to_false",
        "from_map_clamps_negative_integers_to_zero",
        "from_map_ignores_non_object_window_overlay",

        ; --- Hotkey helpers ---
        "has_hotkey_true_for_registered",
        "has_hotkey_false_for_unknown",
        "get_hotkey_returns_registered_keybind",
        "get_hotkey_returns_provided_default_for_unknown",
    ]

    ; ============================================================
    ; Defaults
    ; ============================================================

    defaults_has_default_profile_name()
    {
        cfg := AppSettings.Defaults()
        Assert.Equal("Default", cfg.profileName)
    }

    defaults_has_unknown_game_patch()
    {
        Assert.Equal("Unknown", AppSettings.Defaults().gamePatch)
    }

    defaults_window_is_window_state_instance()
    {
        Assert.IsType(WindowState, AppSettings.Defaults().window)
    }

    defaults_overlay_is_overlay_layout_instance()
    {
        Assert.IsType(OverlayLayout, AppSettings.Defaults().overlay)
    }

    defaults_hotkeys_includes_seven_actions()
    {
        ; Down from nine: the ToggleOverlay / ToggleMicroLock /
        ; ToggleSteveLock trio was collapsed into the single
        ; CycleLayout action (see Commands.CycleOverlayLayoutRequested).
        ; Existing INIs with the old keys are migrated by
        ; SettingsRepository._LoadHotkeys; this test just locks the
        ; in-memory default count + presence of the new key.
        cfg := AppSettings.Defaults()
        Assert.Equal(7, cfg.hotkeys.Count, "7 actions registered by default")

        ; Sanity check on a few entries — the unified cycle, a
        ; lifecycle action, and the most-used dialog.
        Assert.True(cfg.hotkeys.Has("CycleLayout"))
        Assert.True(cfg.hotkeys.Has("NewRun"))
        Assert.True(cfg.hotkeys.Has("Settings"))

        Assert.Equal("^F8", cfg.hotkeys["CycleLayout"])
        Assert.Equal("^!n", cfg.hotkeys["NewRun"])
        Assert.Equal("^!s", cfg.hotkeys["Settings"])

        ; Removed actions must NOT be present — the cycle replaced
        ; them and ToggleOverlay was dropped entirely. Locking the
        ; absence so a future refactor that re-adds them by accident
        ; surfaces here.
        Assert.False(cfg.hotkeys.Has("ToggleOverlay"))
        Assert.False(cfg.hotkeys.Has("ToggleMicroLock"))
        Assert.False(cfg.hotkeys.Has("ToggleSteveLock"))
    }

    defaults_vendor_regexes_are_three_empty_strings()
    {
        Assert.Equal(["", "", ""], AppSettings.Defaults().vendorRegexes)
    }

    defaults_loading_visual_is_enabled()
    {
        cfg := AppSettings.Defaults()
        Assert.True(cfg.loadingVisualEnabled)
        Assert.Equal(25,    cfg.loadingVisualPollMs)
        Assert.Equal(250,   cfg.loadingVisualMinMs)
        Assert.Equal(90000, cfg.loadingVisualMaxMs)
    }

    defaults_auto_pause_on_focus_is_true()
    {
        Assert.True(AppSettings.Defaults().autoPauseOnFocus)
    }

    defaults_death_penalty_settings()
    {
        cfg := AppSettings.Defaults()
        Assert.False(cfg.deathPenaltyEnabled,
            "Disabled by default — opt-in via Settings")
        Assert.Equal(150000, cfg.deathPenaltyMs,
            "ms kept at 150_000 (2:30) so the value is sane when the user enables it")
    }

    defaults_disclaimer_not_acknowledged()
    {
        Assert.False(AppSettings.Defaults().disclaimerAcknowledged)
    }

    defaults_event_tracing_disabled_by_default()
    {
        ; EventTraceLogger is opt-in. A fresh install never
        ; starts the interceptor unless the user explicitly enables
        ; it under [Diagnostics] in speedkalandra.ini.
        Assert.False(AppSettings.Defaults().eventTracingEnabled)
    }

    defaults_pb_display_mode_is_pb()
    {
        ; A fresh install keeps the original PB-driven behavior.
        ; "avg5" is opt-in via the Display section in Settings.
        Assert.Equal("pb", AppSettings.Defaults().pbDisplayMode)
    }

    defaults_show_outcome_banner_is_true()
    {
        ; Opt-out feature: default true so the "did it save?"
        ; feedback gap that prompted the banner is closed on a
        ; fresh install. Speedrunners who find it distracting flip
        ; the checkbox off; absent that, it's on. Mirrors the
        ; SettingsRepository default ("1") so a fresh INI and a
        ; FromMap(empty) land on the same value.
        Assert.True(AppSettings.Defaults().showOutcomeBanner)
    }

    defaults_route_widget_visible_is_false()
    {
        ; B4 Stage 2: master visibility flag for the route
        ; walkthrough widget. Default false so the widget stays
        ; invisible on the first boot after the feature ships —
        ; a returning user upgrading over an existing install
        ; doesn't get an unsolicited extra surface on screen. The
        ; opt-in is via the bottom-right Ctrl+Click arrow on any
        ; of the four eligible timer widgets.
        Assert.False(AppSettings.Defaults().routeWidgetVisible)
    }

    defaults_route_rows_visible_is_5()
    {
        ; B4 Stage 2: how many route rows the widget shows at
        ; once, starting from the current zone. Default 5: enough
        ; lookahead for a typical Act 1 segment (4-5 zones)
        ; without dominating the overlay. Configurable in
        ; Settings → ROUTE; the slider clamps to [3, 10].
        Assert.Equal(5, AppSettings.Defaults().routeRowsVisible)
    }

    defaults_route_note_font_size_is_8()
    {
        ; B4 follow-up (TUGs feedback): base font size of the
        ; per-zone note row. Default 8 matches the pre-config
        ; NOTE_FONT_SIZE_BASE constant in RouteWidget so a returning
        ; user upgrading over an existing install sees no visual
        ; change until they touch the slider. Configurable in
        ; Settings → ROUTE; the slider clamps to [6, 16].
        Assert.Equal(8, AppSettings.Defaults().routeNoteFontSize)
    }

    defaults_auto_finalize_regex_empty()
    {
        Assert.Equal("", AppSettings.Defaults().autoFinalizeRegex)
    }

    defaults_auto_start_regex_is_wounded_man_line()
    {
        ; Default = the Wounded Man's line at the start of the PoE2
        ; campaign, with the `i)` PCRE flag for case-insensitive
        ; matching. See the comment in app_settings.ahk for the
        ; rationale + Bug #11 caveat (non-EN players edit via the
        ; Settings dialog).
        Assert.Equal("i)Wounded Man: By the First Ones!", AppSettings.Defaults().autoStartRegex)
    }

    ; ============================================================
    ; FromMap validation
    ; ============================================================

    from_map_throws_type_error_on_non_object()
    {
        Assert.Throws(TypeError, () => AppSettings.FromMap("not a map"))
        Assert.Throws(TypeError, () => AppSettings.FromMap(42))
    }

    from_map_uses_defaults_for_empty_input()
    {
        cfg := AppSettings.FromMap(Map())
        ; Should be identical to Defaults()
        Assert.Equal("Default", cfg.profileName)
        Assert.Equal(7,         cfg.hotkeys.Count)
        Assert.IsType(WindowState,   cfg.window)
        Assert.IsType(OverlayLayout, cfg.overlay)
    }

    ; ============================================================
    ; FromMap reads per section
    ; ============================================================

    from_map_reads_profile_name()
    {
        cfg := AppSettings.FromMap(Map("profileName", "MyProfile"))
        Assert.Equal("MyProfile", cfg.profileName)
    }

    from_map_reads_game_patch_and_log_file()
    {
        cfg := AppSettings.FromMap(Map(
            "gamePatch", "0.2.0",
            "logFile",   "C:\\path\\Client.txt"
        ))
        Assert.Equal("0.2.0", cfg.gamePatch)
        Assert.Equal("C:\\path\\Client.txt", cfg.logFile)
    }

    from_map_reads_character_fields()
    {
        cfg := AppSettings.FromMap(Map(
            "characterName",  "MyChar",
            "characterClass", "Monk",
            "characterLevel", 47
        ))
        Assert.Equal("MyChar", cfg.characterName)
        Assert.Equal("Monk",   cfg.characterClass)
        Assert.Equal(47,       cfg.characterLevel)
    }

    from_map_reads_current_area_fields()
    {
        cfg := AppSettings.FromMap(Map(
            "currentAreaLevel", 50,
            "currentAreaCode",  "G3_2_2"
        ))
        Assert.Equal(50,      cfg.currentAreaLevel)
        Assert.Equal("G3_2_2", cfg.currentAreaCode)
    }

    from_map_reads_loading_visual_settings()
    {
        cfg := AppSettings.FromMap(Map(
            "loadingVisualEnabled", false,
            "loadingVisualPollMs",  10,
            "loadingVisualMinMs",   100,
            "loadingVisualMaxMs",   60000
        ))
        Assert.False(cfg.loadingVisualEnabled)
        Assert.Equal(10,    cfg.loadingVisualPollMs)
        Assert.Equal(100,   cfg.loadingVisualMinMs)
        Assert.Equal(60000, cfg.loadingVisualMaxMs)
    }

    from_map_reads_auto_pause_on_focus()
    {
        cfg := AppSettings.FromMap(Map("autoPauseOnFocus", false))
        Assert.False(cfg.autoPauseOnFocus)
    }

    from_map_reads_death_penalty_settings()
    {
        cfg := AppSettings.FromMap(Map(
            "deathPenaltyEnabled", false,
            "deathPenaltyMs",      60000
        ))
        Assert.False(cfg.deathPenaltyEnabled)
        Assert.Equal(60000, cfg.deathPenaltyMs)
    }

    from_map_clamps_negative_death_penalty_ms_to_zero()
    {
        cfg := AppSettings.FromMap(Map("deathPenaltyMs", -1000))
        Assert.Equal(0, cfg.deathPenaltyMs)
    }

    from_map_reads_disclaimer_acknowledged()
    {
        cfg := AppSettings.FromMap(Map("disclaimerAcknowledged", true))
        Assert.True(cfg.disclaimerAcknowledged)
    }

    from_map_reads_event_tracing_enabled()
    {
        ; Explicit true accepted
        cfg := AppSettings.FromMap(Map("eventTracingEnabled", true))
        Assert.True(cfg.eventTracingEnabled)

        ; String coercion (matches how SettingsRepository delivers the value)
        cfg2 := AppSettings.FromMap(Map("eventTracingEnabled", "1"))
        Assert.True(cfg2.eventTracingEnabled)

        ; Missing key falls back to the safe default (false)
        cfg3 := AppSettings.FromMap(Map())
        Assert.False(cfg3.eventTracingEnabled)
    }

    from_map_reads_pb_display_mode_avg5()
    {
        cfg := AppSettings.FromMap(Map("pbDisplayMode", "avg5"))
        Assert.Equal("avg5", cfg.pbDisplayMode)

        ; Missing key keeps the default
        cfg2 := AppSettings.FromMap(Map())
        Assert.Equal("pb", cfg2.pbDisplayMode)

        ; Explicit "pb" round-trips too
        cfg3 := AppSettings.FromMap(Map("pbDisplayMode", "pb"))
        Assert.Equal("pb", cfg3.pbDisplayMode)
    }

    from_map_pb_display_mode_invalid_falls_back_to_pb()
    {
        ; Anything other than the literal "avg5" normalizes to "pb".
        ; Hand-edited INI typos, future-mode names, or stray
        ; whitespace land on the safe default rather than enter an
        ; undefined runtime branch.
        for _, badValue in ["average", "avg10", "", " avg5 ", "random", "av5"]
        {
            cfg := AppSettings.FromMap(Map("pbDisplayMode", badValue))
            Assert.Equal("pb", cfg.pbDisplayMode,
                "Invalid value '" badValue "' must normalize to pb")
        }
    }

    from_map_pb_display_mode_accepts_case_variations_as_avg5()
    {
        ; AHK v2 `=` is case-insensitive. The Settings dialog writes
        ; lowercase "avg5"; this only covers hand-edited INIs with
        ; "Avg5" / "AVG5".
        for _, variant in ["Avg5", "AVG5", "aVg5"]
        {
            cfg := AppSettings.FromMap(Map("pbDisplayMode", variant))
            Assert.Equal("avg5", cfg.pbDisplayMode,
                "Case variation '" variant "' must load as avg5")
        }
    }

    from_map_reads_show_outcome_banner()
    {
        ; Explicit false honored
        cfg := AppSettings.FromMap(Map("showOutcomeBanner", false))
        Assert.False(cfg.showOutcomeBanner)

        ; Explicit true honored
        cfg2 := AppSettings.FromMap(Map("showOutcomeBanner", true))
        Assert.True(cfg2.showOutcomeBanner)

        ; String coercion (how SettingsRepository delivers the value
        ; after IniRead returns "1" / "0")
        cfg3 := AppSettings.FromMap(Map("showOutcomeBanner", "0"))
        Assert.False(cfg3.showOutcomeBanner)

        cfg4 := AppSettings.FromMap(Map("showOutcomeBanner", "1"))
        Assert.True(cfg4.showOutcomeBanner)
    }

    from_map_show_outcome_banner_defaults_true_when_missing()
    {
        ; Missing key keeps the AppSettings default (true). Lock-in
        ; test for the opt-out semantic: a fresh install or an
        ; older INI that predates the key must NOT silently turn
        ; the banner off.
        cfg := AppSettings.FromMap(Map())
        Assert.True(cfg.showOutcomeBanner)
    }

    ; --- Route ---

    from_map_reads_route_widget_visible()
    {
        ; Boolean coercion: both AHK true and string "1" must work,
        ; because the in-memory edit path delivers a real bool but
        ; SettingsRepository routes through IniRead which returns
        ; the string "1". Both shapes have to land on the same value.
        cfg := AppSettings.FromMap(Map("routeWidgetVisible", true))
        Assert.True(cfg.routeWidgetVisible)

        cfg2 := AppSettings.FromMap(Map("routeWidgetVisible", "1"))
        Assert.True(cfg2.routeWidgetVisible)

        cfg3 := AppSettings.FromMap(Map("routeWidgetVisible", false))
        Assert.False(cfg3.routeWidgetVisible)
    }

    from_map_reads_route_rows_visible()
    {
        ; Within the clamped range [3, 10]: read verbatim.
        cfg := AppSettings.FromMap(Map("routeRowsVisible", 7))
        Assert.Equal(7, cfg.routeRowsVisible)

        ; Boundary values: 3 and 10 are accepted as-is.
        cfg2 := AppSettings.FromMap(Map("routeRowsVisible", 3))
        Assert.Equal(3, cfg2.routeRowsVisible)

        cfg3 := AppSettings.FromMap(Map("routeRowsVisible", 10))
        Assert.Equal(10, cfg3.routeRowsVisible)
    }

    from_map_clamps_route_rows_visible_below_three()
    {
        ; Out-of-range LOW values clamp to 3 (not to the default 5).
        ; The user clearly wanted a small count; honoring the
        ; nearest bound is more useful than a silent default that
        ; doesn't reflect their intent. Contrast with FromMap's
        ; treatment of fully invalid values (non-numeric), which
        ; DO fall back to the default — there "intent" is undefined.
        cfg := AppSettings.FromMap(Map("routeRowsVisible", 2))
        Assert.Equal(3, cfg.routeRowsVisible)

        cfg2 := AppSettings.FromMap(Map("routeRowsVisible", 0))
        Assert.Equal(3, cfg2.routeRowsVisible)

        cfg3 := AppSettings.FromMap(Map("routeRowsVisible", -5))
        Assert.Equal(3, cfg3.routeRowsVisible)
    }

    from_map_clamps_route_rows_visible_above_ten()
    {
        cfg := AppSettings.FromMap(Map("routeRowsVisible", 11))
        Assert.Equal(10, cfg.routeRowsVisible)

        cfg2 := AppSettings.FromMap(Map("routeRowsVisible", 999))
        Assert.Equal(10, cfg2.routeRowsVisible)
    }

    from_map_route_rows_visible_invalid_uses_default()
    {
        ; Non-numeric / empty values can't be clamped to anything
        ; meaningful, so they fall back to the default 5. A user
        ; with a typo in their INI lands on the safe default rather
        ; than silently getting bound 3 or 10.
        cfg := AppSettings.FromMap(Map("routeRowsVisible", "not a number"))
        Assert.Equal(5, cfg.routeRowsVisible)

        cfg2 := AppSettings.FromMap(Map("routeRowsVisible", ""))
        Assert.Equal(5, cfg2.routeRowsVisible)
    }

    from_map_route_rows_visible_missing_uses_default()
    {
        cfg := AppSettings.FromMap(Map())
        Assert.Equal(5, cfg.routeRowsVisible)
    }

    from_map_reads_route_note_font_size()
    {
        ; Within the clamped range [6, 16]: read verbatim.
        cfg := AppSettings.FromMap(Map("routeNoteFontSize", 11))
        Assert.Equal(11, cfg.routeNoteFontSize)

        ; Boundary values: 6 and 16 are accepted as-is.
        cfg2 := AppSettings.FromMap(Map("routeNoteFontSize", 6))
        Assert.Equal(6, cfg2.routeNoteFontSize)

        cfg3 := AppSettings.FromMap(Map("routeNoteFontSize", 16))
        Assert.Equal(16, cfg3.routeNoteFontSize)
    }

    from_map_clamps_route_note_font_size_below_six()
    {
        ; Out-of-range LOW values clamp to 6 (not to the default 8).
        ; Same clamp-to-nearest-bound policy as routeRowsVisible:
        ; honoring the user's intent (smaller value) beats silently
        ; reverting to the default.
        cfg := AppSettings.FromMap(Map("routeNoteFontSize", 5))
        Assert.Equal(6, cfg.routeNoteFontSize)

        cfg2 := AppSettings.FromMap(Map("routeNoteFontSize", 0))
        Assert.Equal(6, cfg2.routeNoteFontSize)

        cfg3 := AppSettings.FromMap(Map("routeNoteFontSize", -3))
        Assert.Equal(6, cfg3.routeNoteFontSize)
    }

    from_map_clamps_route_note_font_size_above_sixteen()
    {
        cfg := AppSettings.FromMap(Map("routeNoteFontSize", 17))
        Assert.Equal(16, cfg.routeNoteFontSize)

        cfg2 := AppSettings.FromMap(Map("routeNoteFontSize", 200))
        Assert.Equal(16, cfg2.routeNoteFontSize)
    }

    from_map_route_note_font_size_invalid_uses_default()
    {
        ; Non-numeric / empty values can't be clamped to anything
        ; meaningful, so they fall back to the default 8. A user
        ; with a typo in their INI lands on the safe default rather
        ; than silently getting bound 6 or 16.
        cfg := AppSettings.FromMap(Map("routeNoteFontSize", "not a number"))
        Assert.Equal(8, cfg.routeNoteFontSize)

        cfg2 := AppSettings.FromMap(Map("routeNoteFontSize", ""))
        Assert.Equal(8, cfg2.routeNoteFontSize)
    }

    from_map_route_note_font_size_missing_uses_default()
    {
        cfg := AppSettings.FromMap(Map())
        Assert.Equal(8, cfg.routeNoteFontSize)
    }

    from_map_reads_auto_finalize_regex()
    {
        cfg := AppSettings.FromMap(Map("autoFinalizeRegex", "the goddess granted"))
        Assert.Equal("the goddess granted", cfg.autoFinalizeRegex)
    }

    from_map_reads_auto_start_regex_allowing_empty()
    {
        ; autoStartRegex uses _GetStrAllowEmpty: explicit "" accepted
        cfg := AppSettings.FromMap(Map("autoStartRegex", ""))
        Assert.Equal("", cfg.autoStartRegex)

        cfg2 := AppSettings.FromMap(Map("autoStartRegex", "i am about to embark"))
        Assert.Equal("i am about to embark", cfg2.autoStartRegex)
    }

    from_map_strict_string_treats_empty_as_missing()
    {
        ; profileName uses _GetStr (strict): "" falls back to default
        cfg := AppSettings.FromMap(Map("profileName", ""))
        Assert.Equal("Default", cfg.profileName,
            "_GetStr treats empty as missing - keeps default")
    }

    from_map_merges_hotkeys_with_defaults()
    {
        cfg := AppSettings.FromMap(Map(
            "hotkeys", Map("NewRun", "F4", "MyCustom", "^F12")
        ))
        ; Overrides NewRun
        Assert.Equal("F4", cfg.hotkeys["NewRun"])
        ; Adds MyCustom
        Assert.Equal("^F12", cfg.hotkeys["MyCustom"])
        ; Preserves unmentioned defaults
        Assert.Equal("^!s", cfg.hotkeys["Settings"])
    }

    ; ============================================================
    ; FromMap composites
    ; ============================================================

    from_map_accepts_window_state_instance()
    {
        ws := WindowState()
        ws.microLocked := true
        cfg := AppSettings.FromMap(Map("window", ws))
        Assert.IsType(WindowState, cfg.window)
        Assert.True(cfg.window.microLocked)
    }

    from_map_accepts_window_state_as_map()
    {
        cfg := AppSettings.FromMap(Map(
            "window", Map("microLocked", true, "steveLocked", true)
        ))
        Assert.IsType(WindowState, cfg.window)
        Assert.True(cfg.window.microLocked)
        Assert.True(cfg.window.steveLocked)
    }

    from_map_accepts_overlay_layout_instance()
    {
        ol := OverlayLayout.Defaults()
        ol.hoverHide := false
        cfg := AppSettings.FromMap(Map("overlay", ol))
        Assert.IsType(OverlayLayout, cfg.overlay)
        Assert.False(cfg.overlay.hoverHide)
    }

    from_map_accepts_overlay_layout_as_map()
    {
        cfg := AppSettings.FromMap(Map(
            "overlay", Map("hoverHide", false)
        ))
        Assert.IsType(OverlayLayout, cfg.overlay)
        Assert.False(cfg.overlay.hoverHide)
    }

    ; ============================================================
    ; FromMap coercions and clamps
    ; ============================================================

    from_map_coerces_boolean_string_one_to_true()
    {
        cfg := AppSettings.FromMap(Map("autoPauseOnFocus", "1"))
        Assert.True(cfg.autoPauseOnFocus)
    }

    from_map_coerces_boolean_string_zero_to_false()
    {
        cfg := AppSettings.FromMap(Map("autoPauseOnFocus", "0"))
        Assert.False(cfg.autoPauseOnFocus)
    }

    from_map_clamps_negative_integers_to_zero()
    {
        cfg := AppSettings.FromMap(Map(
            "characterLevel",   -5,
            "currentAreaLevel", -1
        ))
        Assert.Equal(0, cfg.characterLevel)
        Assert.Equal(0, cfg.currentAreaLevel)
    }

    from_map_ignores_non_object_window_overlay()
    {
        cfg := AppSettings.FromMap(Map(
            "window",  "not an object",
            "overlay", 42
        ))
        ; Keeps defaults
        Assert.IsType(WindowState,   cfg.window)
        Assert.IsType(OverlayLayout, cfg.overlay)
    }

    ; ============================================================
    ; Hotkey helpers
    ; ============================================================

    has_hotkey_true_for_registered()
    {
        cfg := AppSettings.Defaults()
        Assert.True(cfg.HasHotkey("NewRun"))
        Assert.True(cfg.HasHotkey("Settings"))
    }

    has_hotkey_false_for_unknown()
    {
        Assert.False(AppSettings.Defaults().HasHotkey("UnknownAction"))
    }

    get_hotkey_returns_registered_keybind()
    {
        cfg := AppSettings.Defaults()
        Assert.Equal("^!n", cfg.GetHotkey("NewRun"))
        Assert.Equal("^F8", cfg.GetHotkey("CycleLayout"))
    }

    get_hotkey_returns_provided_default_for_unknown()
    {
        cfg := AppSettings.Defaults()
        Assert.Equal("",     cfg.GetHotkey("Nonexistent"))
        Assert.Equal("none", cfg.GetHotkey("Nonexistent", "none"))
    }
}

TestRegistry.Register(AppSettingsTests)
