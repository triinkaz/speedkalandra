; ============================================================
; SettingsRepository tests
; ============================================================
;
; AppSettings <-> INI with multiple sections:
;   [General] [Character] [CurrentArea] [Rules] [LoadingVisual]
;   [AutoFinalize] [AutoStart] [VendorRegexes] [Disclaimer]
;   [Diagnostics] [Layouts]
;   [Hotkeys] [Window] [Overlay]
;
; Strategy: most tests do a roundtrip (Save with modified cfg, Load,
; compare). Also covers specific invariants (VendorRegexes truncation
; at 250 chars, Overlay sanitization).

class SettingsRepositoryTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_ini_not_inifile",

        ; --- Load: defaults ---
        "load_returns_defaults_when_ini_empty",

        ; --- Save: validation ---
        "save_throws_when_not_app_settings",

        ; --- Roundtrip per section ---
        "save_load_preserves_general",
        "save_load_preserves_character",
        "save_load_preserves_current_area",
        "save_load_preserves_rules",
        "save_load_preserves_loading_visual",
        "save_load_preserves_auto_finalize_regex",
        "save_load_preserves_auto_start_regex",
        "save_load_preserves_vendor_regexes",
        "save_load_preserves_disclaimer_ack",
        "save_load_preserves_diagnostics_event_tracing",
        "save_load_preserves_layout_variant_plus",
        "load_layout_variant_falls_back_to_classic_on_invalid_ini",
        "save_load_preserves_hotkeys",
        "save_load_preserves_window_micro_locked",
        "save_load_preserves_window_steve_locked",
        "save_load_preserves_window_both_locks_independently",
        "save_load_preserves_overlay_hover_hide",
        "save_load_preserves_overlay_positions",

        ; --- VendorRegexes invariants ---
        "save_truncates_long_vendor_regex_to_250_chars",
        "load_truncates_long_vendor_regex_to_250_chars",

        ; --- Obsolete keys cleanup ---
        "save_removes_obsolete_hotkey_keys",
        "save_removes_obsolete_overlay_keys",

        ; --- Static helpers ---
        "read_int_returns_default_when_value_empty",
        "read_int_returns_default_when_value_non_numeric",
        "read_int_parses_valid_integer",

        ; --- Bool coercion ---
        "bool_one_reads_as_true",
        "bool_zero_reads_as_false",
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_ini_not_inifile()
    {
        Assert.Throws(TypeError, () => SettingsRepository("not ini"))
        Assert.Throws(TypeError, () => SettingsRepository(Map()))
    }

    ; ============================================================
    ; Load defaults
    ; ============================================================

    load_returns_defaults_when_ini_empty()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)
        loaded := repo.Load()

        defaults := AppSettings.Defaults()
        Assert.Equal(defaults.profileName,       loaded.profileName)
        Assert.Equal(defaults.gamePatch,         loaded.gamePatch)
        Assert.Equal(defaults.loadingVisualPollMs, loaded.loadingVisualPollMs)
    }

    ; ============================================================
    ; Save validation
    ; ============================================================

    save_throws_when_not_app_settings()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)
        Assert.Throws(TypeError, () => repo.Save("not settings"))
        Assert.Throws(TypeError, () => repo.Save(Map()))
    }

    ; ============================================================
    ; Roundtrip per section
    ; ============================================================

    save_load_preserves_general()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        cfg.profileName := "MyProfile"
        cfg.gamePatch   := "0.2.0"
        cfg.logFile     := "C:\\PoE2\\Client.txt"
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.Equal("MyProfile",            loaded.profileName)
        Assert.Equal("0.2.0",                loaded.gamePatch)
        Assert.Equal("C:\\PoE2\\Client.txt", loaded.logFile)
    }

    save_load_preserves_character()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        cfg.characterName  := "Lechtansi"
        cfg.characterClass := "Warrior"
        cfg.characterLevel := 75
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.Equal("Lechtansi", loaded.characterName)
        Assert.Equal("Warrior",   loaded.characterClass)
        Assert.Equal(75,          loaded.characterLevel)
    }

    save_load_preserves_current_area()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        cfg.currentAreaLevel := 42
        cfg.currentAreaCode  := "G2_5"
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.Equal(42,     loaded.currentAreaLevel)
        Assert.Equal("G2_5", loaded.currentAreaCode)
    }

    save_load_preserves_rules()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        cfg.autoPauseOnFocus    := false
        cfg.deathPenaltyEnabled := false
        cfg.deathPenaltyMs      := 30000
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.False(loaded.autoPauseOnFocus)
        Assert.False(loaded.deathPenaltyEnabled)
        Assert.Equal(30000, loaded.deathPenaltyMs)
    }

    save_load_preserves_loading_visual()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        cfg.loadingVisualEnabled := false
        cfg.loadingVisualPollMs  := 150
        cfg.loadingVisualMinMs   := 250
        cfg.loadingVisualMaxMs   := 7500
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.False(loaded.loadingVisualEnabled)
        Assert.Equal(150,  loaded.loadingVisualPollMs)
        Assert.Equal(250,  loaded.loadingVisualMinMs)
        Assert.Equal(7500, loaded.loadingVisualMaxMs)
    }

    save_load_preserves_auto_finalize_regex()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        cfg.autoFinalizeRegex := "i)^Boss .* defeated$"
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.Equal("i)^Boss .* defeated$", loaded.autoFinalizeRegex)
    }

    save_load_preserves_auto_start_regex()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        cfg.autoStartRegex := "i)Clearfell Encampment"
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.Equal("i)Clearfell Encampment", loaded.autoStartRegex)
    }

    save_load_preserves_vendor_regexes()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        cfg.vendorRegexes := ["fire|cold", "rare lightning", "phys"]
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.Equal("fire|cold",      loaded.vendorRegexes[1])
        Assert.Equal("rare lightning", loaded.vendorRegexes[2])
        Assert.Equal("phys",           loaded.vendorRegexes[3])
    }

    save_load_preserves_disclaimer_ack()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        cfg.disclaimerAcknowledged := true
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.True(loaded.disclaimerAcknowledged)
    }

    save_load_preserves_diagnostics_event_tracing()
    {
        ; Opt-in event tracing flag.
        ; Default is false (privacy-preserving), but the user can flip
        ; it on for diagnosing event-order bugs and we must round-trip
        ; the choice across app restarts.
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        Assert.False(cfg.eventTracingEnabled, "sanity: default is false")

        cfg.eventTracingEnabled := true
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.True(loaded.eventTracingEnabled,
            "[Diagnostics].EventTracingEnabled round-trips through INI")

        ; Flip back off and confirm the false value also round-trips
        loaded.eventTracingEnabled := false
        repo.Save(loaded)
        reloaded := repo.Load()
        Assert.False(reloaded.eventTracingEnabled,
            "Flipping back to false also persists")
    }

    save_load_preserves_layout_variant_plus()
    {
        ; Plus is the opt-in BETA variant. A user who flipped it on
        ; in Settings must find it still selected after a restart.
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        Assert.Equal("classic", cfg.layoutVariant, "sanity: default is classic")

        cfg.layoutVariant := "plus"
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.Equal("plus", loaded.layoutVariant,
            "[Layouts].Variant round-trips through INI")

        ; Flip back to classic and confirm the classic value also persists
        loaded.layoutVariant := "classic"
        repo.Save(loaded)
        reloaded := repo.Load()
        Assert.Equal("classic", reloaded.layoutVariant,
            "Flipping back to classic also persists")
    }

    load_layout_variant_falls_back_to_classic_on_invalid_ini()
    {
        ; A hand-edited INI with a value the repo doesn't recognize
        ; ('Plus' capitalized, an unknown future variant, a typo) must
        ; load as 'classic' rather than enter a runtime branch that
        ; doesn't exist. Mirrors the AppSettings.FromMap normalization
        ; — defense in depth.
        mainIni := IniFile(Fixtures.TempPath("ini"))
        mainIni.Write("experimental_v2", "Layouts", "Variant")

        repo := SettingsRepository(mainIni)
        loaded := repo.Load()

        Assert.Equal("classic", loaded.layoutVariant,
            "Unknown variant in INI normalizes to classic on load")
    }

    save_load_preserves_hotkeys()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        cfg.hotkeys["pause"]    := "F1"
        cfg.hotkeys["finalize"] := "F2"
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.Equal("F1", loaded.hotkeys["pause"])
        Assert.Equal("F2", loaded.hotkeys["finalize"])
    }

    save_load_preserves_window_micro_locked()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        cfg.window := WindowState.FromMap(Map("microLocked", true))
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.True(loaded.window.microLocked)
    }

    save_load_preserves_window_steve_locked()
    {
        ; Anti-regression: SteveLocked used to be silently dropped on
        ; Save (only MicroLocked was written to [Window]), so a Ctrl+F8
        ; lock survived the in-memory toggle but never the next boot.
        ; This test pins SteveLocked through the full roundtrip.
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        cfg.window := WindowState.FromMap(Map("steveLocked", true))
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.True(loaded.window.steveLocked, "SteveLocked must survive Save/Load")
    }

    save_load_preserves_window_both_locks_independently()
    {
        ; The two locks are mutually exclusive at runtime (handled by
        ; OverlayModeService.ToggleMicroLock / ToggleSteveLock), but at
        ; the persistence layer they are independent flags. A manually
        ; hand-edited INI with both = 1 must round-trip both as true;
        ; the runtime is the only place that enforces exclusion.
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        cfg.window := WindowState.FromMap(Map(
            "microLocked", true,
            "steveLocked", true
        ))
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.True(loaded.window.microLocked, "MicroLocked round-trips independently")
        Assert.True(loaded.window.steveLocked, "SteveLocked round-trips independently")
    }

    save_load_preserves_overlay_hover_hide()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        cfg.overlay.hoverHide := false
        repo.Save(cfg)

        loaded := repo.Load()
        Assert.False(loaded.overlay.hoverHide)
    }

    save_load_preserves_overlay_positions()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        pos := OverlayPosition.FromMap(Map(
            "left",     0.5,
            "top",      0.25,
            "scale",    1.5,
            "visible",  true,
            "centered", false
        ))
        cfg.overlay.SetPosition("MainWidget", pos)
        repo.Save(cfg)

        loaded := repo.Load()
        loadedPos := loaded.overlay.GetPosition("MainWidget")
        Assert.Near(0.5,  loadedPos.left,  0.001)
        Assert.Near(0.25, loadedPos.top,   0.001)
        Assert.Near(1.5,  loadedPos.scale, 0.001)
        Assert.True(loadedPos.visible)
        Assert.False(loadedPos.centered)
    }

    ; ============================================================
    ; VendorRegexes invariants
    ; ============================================================

    save_truncates_long_vendor_regex_to_250_chars()
    {
        ; Cap raised from 50→250 in PoE 0.x to match the in-game
        ; vendor filter limit. Defensive truncation in Save guarantees
        ; the invariant even if cfg.vendorRegexes was set programmatically
        ; to a string longer than the UI's Limit250.
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := SettingsRepository(mainIni)

        cfg := AppSettings.Defaults()
        longRegex := ""
        Loop 300
            longRegex .= "a"   ; 300 chars
        cfg.vendorRegexes := [longRegex, "", ""]
        repo.Save(cfg)

        ; INI must have the regex truncated at 250
        written := mainIni.Read("VendorRegexes", "Slot1")
        Assert.Equal(250, StrLen(written))
    }

    load_truncates_long_vendor_regex_to_250_chars()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        ; Manually write a 300-char regex to the INI (bypass Save)
        longRegex := ""
        Loop 300
            longRegex .= "x"
        mainIni.Write(longRegex, "VendorRegexes", "Slot1")

        repo := SettingsRepository(mainIni)
        loaded := repo.Load()

        Assert.Equal(250, StrLen(loaded.vendorRegexes[1]),
            "Load must defensively truncate at 250 chars")
    }

    ; ============================================================
    ; Obsolete keys cleanup
    ; ============================================================

    save_removes_obsolete_hotkey_keys()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        ; Create an old key manually
        mainIni.Write("Ctrl+X", "Hotkeys", "obsolete_action")

        repo := SettingsRepository(mainIni)
        cfg := AppSettings.Defaults()
        cfg.hotkeys := Map("pause", "F1")
        repo.Save(cfg)

        ; Obsolete key must have been deleted
        Assert.Equal("", mainIni.Read("Hotkeys", "obsolete_action"))
        Assert.Equal("F1", mainIni.Read("Hotkeys", "pause"))
    }

    save_removes_obsolete_overlay_keys()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        ; Create an old key manually
        mainIni.Write("0.5", "Overlay", "obsoleteWidget.left")

        repo := SettingsRepository(mainIni)
        cfg := AppSettings.Defaults()
        ; Adds only one widget (not 'obsoleteWidget')
        cfg.overlay.SetPosition("MainWidget", OverlayPosition.FromMap(
            Map("left", 0.1, "top", 0.1)))
        repo.Save(cfg)

        Assert.Equal("", mainIni.Read("Overlay", "obsoleteWidget.left"))
    }

    ; ============================================================
    ; Static helpers
    ; ============================================================

    read_int_returns_default_when_value_empty()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        mainIni.Write("", "S", "K")
        Assert.Equal(99, SettingsRepository._ReadInt(mainIni, "S", "K", 99))
    }

    read_int_returns_default_when_value_non_numeric()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        mainIni.Write("not a number", "S", "K")
        Assert.Equal(99, SettingsRepository._ReadInt(mainIni, "S", "K", 99))
    }

    read_int_parses_valid_integer()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        mainIni.Write(42, "S", "K")
        Assert.Equal(42, SettingsRepository._ReadInt(mainIni, "S", "K", 99))
    }

    ; ============================================================
    ; Bool coercion
    ; ============================================================

    bool_one_reads_as_true()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        mainIni.Write("1", "Rules", "AutoPauseOnFocus")

        repo := SettingsRepository(mainIni)
        loaded := repo.Load()
        Assert.True(loaded.autoPauseOnFocus)
    }

    bool_zero_reads_as_false()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        mainIni.Write("0", "Rules", "AutoPauseOnFocus")

        repo := SettingsRepository(mainIni)
        loaded := repo.Load()
        Assert.False(loaded.autoPauseOnFocus)
    }
}

TestRegistry.Register(SettingsRepositoryTests)
