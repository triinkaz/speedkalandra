; ============================================================
; HotkeyFormatterTests
; ============================================================
;
; Static-only. Converte bidirecionalmente entre:
;   AHK syntax: "^!f"       (^ Ctrl, ! Alt, + Shift, # Win)
;   Human:      "Ctrl+Alt+F"
;
; Usado por SettingsDialog (ToHuman pra display; ToAhk pra persistir).
;
; Tolerancias importantes:
;   - case-insensitive em ToAhk ("ctrl+alt+f")
;   - espacos em ToAhk ("Ctrl + Alt + F")
;   - passthrough quando ja eh AHK syntax ("^!f" -> "^!f")
;   - empty input retorna empty


class HotkeyFormatterTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- ToHuman: AHK -> human ---
        "to_human_ctrl_alt_letter",
        "to_human_single_modifier_ctrl",
        "to_human_single_modifier_alt",
        "to_human_single_modifier_shift",
        "to_human_single_modifier_win",
        "to_human_all_4_modifiers",
        "to_human_no_modifier_just_key",
        "to_human_f_key_passthrough",
        "to_human_special_key_capitalized",
        "to_human_empty_string",
        "to_human_letter_uppercased",
        "to_human_digit_passthrough",

        ; --- ToAhk: human -> AHK ---
        "to_ahk_ctrl_alt_letter",
        "to_ahk_case_insensitive",
        "to_ahk_with_spaces",
        "to_ahk_letter_lowercased",
        "to_ahk_f_key_preserved",
        "to_ahk_empty_string",
        "to_ahk_passthrough_when_already_ahk_syntax",
        "to_ahk_control_alternate_name",
        "to_ahk_win_variants",
        "to_ahk_no_modifier_just_key",
        "to_ahk_special_key_passthrough",
        "to_ahk_only_modifiers_returns_empty",
        "to_ahk_modifiers_combined",

        ; --- Roundtrip ---
        "roundtrip_to_ahk_to_human",
        "roundtrip_to_human_to_ahk"
    ]

    ; ============================================================
    ; ToHuman
    ; ============================================================

    to_human_ctrl_alt_letter()
    {
        Assert.Equal("Ctrl+Alt+F", HotkeyFormatter.ToHuman("^!f"))
    }

    to_human_single_modifier_ctrl()
    {
        Assert.Equal("Ctrl+A", HotkeyFormatter.ToHuman("^a"))
    }

    to_human_single_modifier_alt()
    {
        Assert.Equal("Alt+A", HotkeyFormatter.ToHuman("!a"))
    }

    to_human_single_modifier_shift()
    {
        Assert.Equal("Shift+A", HotkeyFormatter.ToHuman("+a"))
    }

    to_human_single_modifier_win()
    {
        Assert.Equal("Win+A", HotkeyFormatter.ToHuman("#a"))
    }

    to_human_all_4_modifiers()
    {
        Assert.Equal("Ctrl+Alt+Shift+Win+X", HotkeyFormatter.ToHuman("^!+#x"))
    }

    to_human_no_modifier_just_key()
    {
        Assert.Equal("F8", HotkeyFormatter.ToHuman("F8"))
        Assert.Equal("A", HotkeyFormatter.ToHuman("a"))
    }

    to_human_f_key_passthrough()
    {
        Assert.Equal("Ctrl+F1", HotkeyFormatter.ToHuman("^F1"))
        Assert.Equal("F12", HotkeyFormatter.ToHuman("F12"))
    }

    to_human_special_key_capitalized()
    {
        Assert.Equal("Esc", HotkeyFormatter.ToHuman("esc"))
        Assert.Equal("Tab", HotkeyFormatter.ToHuman("tab"))
        Assert.Equal("Space", HotkeyFormatter.ToHuman("space"))
    }

    to_human_empty_string()
    {
        Assert.Equal("", HotkeyFormatter.ToHuman(""))
    }

    to_human_letter_uppercased()
    {
        Assert.Equal("Ctrl+A", HotkeyFormatter.ToHuman("^a"),
            "Letra unica vira uppercase no display")
    }

    to_human_digit_passthrough()
    {
        Assert.Equal("Ctrl+5", HotkeyFormatter.ToHuman("^5"))
    }

    ; ============================================================
    ; ToAhk
    ; ============================================================

    to_ahk_ctrl_alt_letter()
    {
        Assert.Equal("^!f", HotkeyFormatter.ToAhk("Ctrl+Alt+F"))
    }

    to_ahk_case_insensitive()
    {
        Assert.Equal("^!f", HotkeyFormatter.ToAhk("ctrl+alt+f"))
        Assert.Equal("^!f", HotkeyFormatter.ToAhk("CTRL+ALT+F"))
        Assert.Equal("^!f", HotkeyFormatter.ToAhk("CtRl+aLt+f"))
    }

    to_ahk_with_spaces()
    {
        Assert.Equal("^!f", HotkeyFormatter.ToAhk("Ctrl + Alt + F"))
        Assert.Equal("^!f", HotkeyFormatter.ToAhk("  Ctrl+Alt+F  "))
    }

    to_ahk_letter_lowercased()
    {
        Assert.Equal("^f", HotkeyFormatter.ToAhk("Ctrl+F"),
            "Letra unica vira lowercase na sintaxe AHK")
    }

    to_ahk_f_key_preserved()
    {
        Assert.Equal("^F1", HotkeyFormatter.ToAhk("Ctrl+F1"))
        Assert.Equal("F12", HotkeyFormatter.ToAhk("F12"))
    }

    to_ahk_empty_string()
    {
        Assert.Equal("", HotkeyFormatter.ToAhk(""))
    }

    to_ahk_passthrough_when_already_ahk_syntax()
    {
        ; Power user typa direto — passthrough
        Assert.Equal("^!f", HotkeyFormatter.ToAhk("^!f"))
        Assert.Equal("+a",  HotkeyFormatter.ToAhk("+a"))
        Assert.Equal("#x",  HotkeyFormatter.ToAhk("#x"))
    }

    to_ahk_control_alternate_name()
    {
        ; "Control" tambem aceito (alias de "Ctrl")
        Assert.Equal("^a", HotkeyFormatter.ToAhk("Control+A"))
    }

    to_ahk_win_variants()
    {
        Assert.Equal("#a", HotkeyFormatter.ToAhk("Win+A"))
        Assert.Equal("#a", HotkeyFormatter.ToAhk("LWin+A"))
        Assert.Equal("#a", HotkeyFormatter.ToAhk("RWin+A"))
    }

    to_ahk_no_modifier_just_key()
    {
        Assert.Equal("F8", HotkeyFormatter.ToAhk("F8"))
    }

    to_ahk_special_key_passthrough()
    {
        ; Special keys passam como-vieram (case-insensitive no AHK)
        Assert.Equal("^Esc", HotkeyFormatter.ToAhk("Ctrl+Esc"))
    }

    to_ahk_only_modifiers_returns_empty()
    {
        ; Sem key real -> empty
        Assert.Equal("", HotkeyFormatter.ToAhk("Ctrl+Alt+"))
        Assert.Equal("", HotkeyFormatter.ToAhk("Ctrl+"))
    }

    to_ahk_modifiers_combined()
    {
        Assert.Equal("^!+#x", HotkeyFormatter.ToAhk("Ctrl+Alt+Shift+Win+X"))
    }

    ; ============================================================
    ; Roundtrip
    ; ============================================================

    roundtrip_to_ahk_to_human()
    {
        cases := ["Ctrl+Alt+F", "Shift+Tab", "F12", "Win+A"]
        for _, original in cases
        {
            ahk    := HotkeyFormatter.ToAhk(original)
            backToHuman := HotkeyFormatter.ToHuman(ahk)
            Assert.Equal(original, backToHuman,
                "Roundtrip falhou: " original " -> " ahk " -> " backToHuman)
        }
    }

    roundtrip_to_human_to_ahk()
    {
        cases := ["^!f", "^a", "F8", "#x", "+F1"]
        for _, original in cases
        {
            human := HotkeyFormatter.ToHuman(original)
            backToAhk := HotkeyFormatter.ToAhk(human)
            Assert.Equal(original, backToAhk,
                "Roundtrip falhou: " original " -> " human " -> " backToAhk)
        }
    }
}

TestRegistry.Register(HotkeyFormatterTests)
