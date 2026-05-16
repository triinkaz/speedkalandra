; ============================================================
; AppSettings tests
; ============================================================
;
; AppSettings agrega TODAS as configuracoes do tracker:
;   - General (profileName, gamePatch, logFile)
;   - Character (name, class, level)
;   - CurrentArea (level, code)
;   - LoadingVisual (enabled, pollMs, minMs, maxMs)
;   - autoPauseOnFocus
;   - deathPenaltyEnabled, deathPenaltyMs (v17.15.1 re-adicionado)
;   - disclaimerAcknowledged (v17.15.2)
;   - autoFinalizeRegex (strict: "" volta pra default)
;   - autoStartRegex (allow empty: "" aceito explicitamente)
;   - vendorRegexes (NAO lido por FromMap; repository lida)
;   - hotkeys (merge defensivo com defaults)
;   - window (WindowState ou Map)
;   - overlay (OverlayLayout ou Map)
;
; Testes pull a maior parte do peso aqui porque AppSettings eh a coleta
; de validacoes coerentes de cada seccao. Tipo-check do composite eh
; importante porque Bug #4 historico veio dai.

class AppSettingsTests extends TestCase
{
    static Tests := [
        ; --- Defaults ---
        "defaults_has_default_profile_name",
        "defaults_has_unknown_game_patch",
        "defaults_window_is_window_state_instance",
        "defaults_overlay_is_overlay_layout_instance",
        "defaults_hotkeys_includes_nine_actions",
        "defaults_vendor_regexes_are_three_empty_strings",
        "defaults_loading_visual_is_enabled",
        "defaults_auto_pause_on_focus_is_true",
        "defaults_death_penalty_settings",
        "defaults_disclaimer_not_acknowledged",
        "defaults_auto_finalize_and_auto_start_regexes_empty",

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
        "from_map_reads_auto_finalize_regex",
        "from_map_reads_auto_start_regex_allowing_empty",
        "from_map_strict_string_treats_empty_as_missing",
        "from_map_merges_hotkeys_with_defaults",

        ; --- FromMap compostos (WindowState, OverlayLayout) ---
        "from_map_accepts_window_state_instance",
        "from_map_accepts_window_state_as_map",
        "from_map_accepts_overlay_layout_instance",
        "from_map_accepts_overlay_layout_as_map",

        ; --- FromMap coercoes ---
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

    defaults_hotkeys_includes_nine_actions()
    {
        cfg := AppSettings.Defaults()
        Assert.Equal(9, cfg.hotkeys.Count, "9 acoes registradas por default")

        ; Sanity check em algumas mais conhecidas
        Assert.True(cfg.hotkeys.Has("ToggleOverlay"))
        Assert.True(cfg.hotkeys.Has("NewRun"))
        Assert.True(cfg.hotkeys.Has("Settings"))

        Assert.Equal("F8",   cfg.hotkeys["ToggleOverlay"])
        Assert.Equal("^!n",  cfg.hotkeys["NewRun"])
        Assert.Equal("^!s",  cfg.hotkeys["Settings"])
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
        Assert.True(cfg.deathPenaltyEnabled)
        Assert.Equal(150000, cfg.deathPenaltyMs, "Default 2m30s")
    }

    defaults_disclaimer_not_acknowledged()
    {
        Assert.False(AppSettings.Defaults().disclaimerAcknowledged)
    }

    defaults_auto_finalize_and_auto_start_regexes_empty()
    {
        cfg := AppSettings.Defaults()
        Assert.Equal("", cfg.autoFinalizeRegex)
        Assert.Equal("", cfg.autoStartRegex)
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
        ; Deveria estar identico a Defaults()
        Assert.Equal("Default", cfg.profileName)
        Assert.Equal(9,         cfg.hotkeys.Count)
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

    from_map_reads_auto_finalize_regex()
    {
        cfg := AppSettings.FromMap(Map("autoFinalizeRegex", "the goddess granted"))
        Assert.Equal("the goddess granted", cfg.autoFinalizeRegex)
    }

    from_map_reads_auto_start_regex_allowing_empty()
    {
        ; autoStartRegex usa _GetStrAllowEmpty: aceita "" explicito
        cfg := AppSettings.FromMap(Map("autoStartRegex", ""))
        Assert.Equal("", cfg.autoStartRegex)

        cfg2 := AppSettings.FromMap(Map("autoStartRegex", "i am about to embark"))
        Assert.Equal("i am about to embark", cfg2.autoStartRegex)
    }

    from_map_strict_string_treats_empty_as_missing()
    {
        ; profileName usa _GetStr (strict): "" cai pra default
        cfg := AppSettings.FromMap(Map("profileName", ""))
        Assert.Equal("Default", cfg.profileName,
            "_GetStr trata empty como missing - mantem default")
    }

    from_map_merges_hotkeys_with_defaults()
    {
        cfg := AppSettings.FromMap(Map(
            "hotkeys", Map("NewRun", "F4", "MyCustom", "^F12")
        ))
        ; Sobrescreve NewRun
        Assert.Equal("F4", cfg.hotkeys["NewRun"])
        ; Adiciona MyCustom
        Assert.Equal("^F12", cfg.hotkeys["MyCustom"])
        ; Preserva defaults nao mencionados
        Assert.Equal("^!s", cfg.hotkeys["Settings"])
    }

    ; ============================================================
    ; FromMap compostos
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
    ; FromMap coercoes e clamps
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
        ; Mantem defaults
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
        Assert.Equal("^!n",  cfg.GetHotkey("NewRun"))
        Assert.Equal("F8",   cfg.GetHotkey("ToggleOverlay"))
    }

    get_hotkey_returns_provided_default_for_unknown()
    {
        cfg := AppSettings.Defaults()
        Assert.Equal("",     cfg.GetHotkey("Nonexistent"))
        Assert.Equal("none", cfg.GetHotkey("Nonexistent", "none"))
    }
}

TestRegistry.Register(AppSettingsTests)
