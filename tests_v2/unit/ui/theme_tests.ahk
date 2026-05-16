; ============================================================
; ThemeTests
; ============================================================
;
; Theme: paleta de cores e tamanhos. Static-only, sem state.
;
; - Color(name) retorna hex sem '#', strict (throws ValueError em typo)
; - HasColor / ListColors helpers
; - InputBg / InputFont strings prontas pra Edit/DropDown em dialogs
; - Size(scale, baseSize) arredonda pra inteiro, minimo 1


class ThemeTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Color ---
        "color_returns_hex_for_known_kalandra_palette",
        "color_returns_hex_for_legacy_aliases",
        "color_throws_on_unknown_name",
        "color_throws_on_empty_string",
        "color_returns_hex_without_hash",

        ; --- HasColor ---
        "has_color_true_for_known_name",
        "has_color_false_for_unknown_name",

        ; --- ListColors ---
        "list_colors_includes_kalandra_names",
        "list_colors_includes_legacy_aliases",
        "list_colors_returns_array",

        ; --- Fonts ---
        "font_ui_is_segoe_ui",
        "font_mono_is_consolas",

        ; --- InputBg / InputFont ---
        "input_bg_starts_with_background_prefix",
        "input_font_has_size_and_color",

        ; --- Size ---
        "size_at_scale_1_returns_base",
        "size_at_scale_2_doubles",
        "size_at_scale_half_halves_rounded",
        "size_minimum_is_1",
        "size_throws_on_zero_scale",
        "size_throws_on_negative_scale",
        "size_throws_on_non_numeric_scale",
        "size_throws_on_non_numeric_base",
        "size_rounds_to_nearest_integer"
    ]

    ; ============================================================
    ; Color
    ; ============================================================

    color_returns_hex_for_known_kalandra_palette()
    {
        Assert.Equal("D8492F", Theme.Color("accent"))
        Assert.Equal("0D0F11", Theme.Color("surface"))
        Assert.Equal("A49C91", Theme.Color("muted"))
    }

    color_returns_hex_for_legacy_aliases()
    {
        ; Aliases legacy ainda funcionam (backwards-compat)
        Assert.Equal("E8E2D6", Theme.Color("text"))
        Assert.Equal("15181B", Theme.Color("headerBg"))
        Assert.Equal("60A5FA", Theme.Color("blue"))
    }

    color_throws_on_unknown_name()
    {
        Assert.Throws(ValueError, () => Theme.Color("not_a_real_color"))
    }

    color_throws_on_empty_string()
    {
        Assert.Throws(ValueError, () => Theme.Color(""))
    }

    color_returns_hex_without_hash()
    {
        ; Convencao AHK Gui: cores sem '#'
        result := Theme.Color("accent")
        Assert.False(InStr(result, "#"), "Cor nao tem '#'")
        Assert.Equal(6, StrLen(result), "6 hex chars")
    }

    ; ============================================================
    ; HasColor
    ; ============================================================

    has_color_true_for_known_name()
    {
        Assert.True(Theme.HasColor("accent"))
        Assert.True(Theme.HasColor("text"))   ; alias
    }

    has_color_false_for_unknown_name()
    {
        Assert.False(Theme.HasColor("phantom_color"))
        Assert.False(Theme.HasColor(""))
    }

    ; ============================================================
    ; ListColors
    ; ============================================================

    list_colors_includes_kalandra_names()
    {
        names := Theme.ListColors()
        ; Pelo menos as paletas principais
        foundAccent := false
        foundSurface := false
        for idx, n in names
        {
            if (n = "accent")
                foundAccent := true
            if (n = "surface")
                foundSurface := true
        }
        Assert.True(foundAccent)
        Assert.True(foundSurface)
    }

    list_colors_includes_legacy_aliases()
    {
        names := Theme.ListColors()
        foundText := false
        for idx, n in names
        {
            if (n = "text")
                foundText := true
        }
        Assert.True(foundText)
    }

    list_colors_returns_array()
    {
        Assert.True(Theme.ListColors() is Array)
        Assert.True(Theme.ListColors().Length > 10, "Paleta tem pelo menos 10 cores")
    }

    ; ============================================================
    ; Fonts
    ; ============================================================

    font_ui_is_segoe_ui()
    {
        Assert.Equal("Segoe UI", Theme.FONT_UI)
    }

    font_mono_is_consolas()
    {
        Assert.Equal("Consolas", Theme.FONT_MONO)
    }

    ; ============================================================
    ; InputBg / InputFont
    ; ============================================================

    input_bg_starts_with_background_prefix()
    {
        bg := Theme.InputBg()
        Assert.Equal("Background", SubStr(bg, 1, 10))
    }

    input_font_has_size_and_color()
    {
        font := Theme.InputFont()
        Assert.True(InStr(font, "s9"))
        Assert.True(InStr(font, "c"))
    }

    ; ============================================================
    ; Size
    ; ============================================================

    size_at_scale_1_returns_base()
    {
        Assert.Equal(18, Theme.Size(1.0, 18))
    }

    size_at_scale_2_doubles()
    {
        Assert.Equal(36, Theme.Size(2.0, 18))
    }

    size_at_scale_half_halves_rounded()
    {
        Assert.Equal(9, Theme.Size(0.5, 18))
    }

    size_minimum_is_1()
    {
        ; Mesmo com scale muito pequeno, nunca retorna 0
        Assert.Equal(1, Theme.Size(0.01, 10))
        Assert.Equal(1, Theme.Size(0.5, 1))
    }

    size_throws_on_zero_scale()
    {
        Assert.Throws(ValueError, () => Theme.Size(0, 18))
    }

    size_throws_on_negative_scale()
    {
        Assert.Throws(ValueError, () => Theme.Size(-1.0, 18))
    }

    size_throws_on_non_numeric_scale()
    {
        Assert.Throws(ValueError, () => Theme.Size("not number", 18))
    }

    size_throws_on_non_numeric_base()
    {
        Assert.Throws(ValueError, () => Theme.Size(1.0, "not number"))
    }

    size_rounds_to_nearest_integer()
    {
        ; 18 * 0.7 = 12.6 -> 13 (round half up)
        Assert.Equal(13, Theme.Size(0.7, 18))
        ; 18 * 0.722 = 12.996 -> 13
        Assert.Equal(13, Theme.Size(0.722, 18))
        ; 10 * 0.55 = 5.5 -> 6 (banker's rounding could give 6)
        Assert.True(Theme.Size(0.55, 10) >= 5, "Pelo menos 5")
        Assert.True(Theme.Size(0.55, 10) <= 6, "No maximo 6")
    }
}

TestRegistry.Register(ThemeTests)
