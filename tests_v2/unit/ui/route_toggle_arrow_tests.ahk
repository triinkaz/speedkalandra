; ============================================================
; RouteToggleArrowTests
; ============================================================
;
; Thin helper that builds the Ctrl+Click arrow on the four
; anchor-eligible timer widgets. Tests focus on the pure parts
; (glyph mapping, callable detection); Build creates a Gui and
; is only exercised via the host-widget tests where the lifecycle
; is naturally driven.

class RouteToggleArrowTests extends TestCase
{
    static Tests := [
        "glyph_for_hidden_returns_down_arrow",
        "glyph_for_visible_returns_up_arrow",
        "glyph_for_truthy_normalizes_to_visible",
        "glyph_for_falsy_normalizes_to_hidden",
        "refresh_glyph_no_op_on_non_object_ctrl",
        "static_constants_match_documented_glyphs"
    ]

    glyph_for_hidden_returns_down_arrow()
    {
        Assert.Equal("▾", RouteToggleArrow.GlyphFor(false))
    }

    glyph_for_visible_returns_up_arrow()
    {
        Assert.Equal("▴", RouteToggleArrow.GlyphFor(true))
    }

    glyph_for_truthy_normalizes_to_visible()
    {
        ; The helper accepts the AHK truthy convention. The host
        ; widgets pass cfg.routeWidgetVisible (bool) directly; this
        ; covers the cases where the value might come from an event
        ; payload as 1 / "1".
        Assert.Equal("▴", RouteToggleArrow.GlyphFor(1))
    }

    glyph_for_falsy_normalizes_to_hidden()
    {
        Assert.Equal("▾", RouteToggleArrow.GlyphFor(0))
        Assert.Equal("▾", RouteToggleArrow.GlyphFor(""))
    }

    refresh_glyph_no_op_on_non_object_ctrl()
    {
        ; A host widget that calls RefreshGlyph before Build (or
        ; after Hide tore down the Gui) must not crash. Silent
        ; no-op on a non-object ctrl is the contract.
        RouteToggleArrow.RefreshGlyph("", true)
        RouteToggleArrow.RefreshGlyph(0,  false)
        ; If we got here without throwing, the contract holds.
        Assert.True(true)
    }

    static_constants_match_documented_glyphs()
    {
        ; Pin the constants so a future "let's use ↑↓ instead"
        ; refactor surfaces here, where it can be debated.
        Assert.Equal("▾", RouteToggleArrow.GLYPH_HIDDEN)
        Assert.Equal("▴", RouteToggleArrow.GLYPH_VISIBLE)
    }
}

TestRegistry.Register(RouteToggleArrowTests)
