; ============================================================
; MicroLayoutWidgetTests
; ============================================================
;
; Same shape as Steve / Compact widget tests: constants pinning
; the [Overlay] slot, formatters, and the timer-color resolver.
; Live render is Win32 and validated manually; construction with
; mocks (7 subscriptions, 5 services) isn't worth the setup — the
; integration suite covers the composition wiring end-to-end.


class MicroLayoutWidgetTests extends TestCase
{
    static Tests := [
        ; --- Constants ---
        "constants_widget_id_is_micro_layout",
        "constants_fixed_size_matches_spec",
        "constants_display_name_is_layout_micro",

        ; --- _FormatMs ---
        "format_ms_zero_returns_zero_padded",
        "format_ms_under_hour_includes_centiseconds",
        "format_ms_over_hour_drops_centiseconds",
        "format_ms_negative_treated_as_zero",

        ; --- _ResolveTimerColor ---
        "resolve_timer_color_no_pb_returns_text",
        "resolve_timer_color_zero_current_returns_text",
        "resolve_timer_color_under_pb_returns_good_strong",
        "resolve_timer_color_at_pb_returns_good_strong",
        "resolve_timer_color_over_pb_returns_danger"
    ]

    ; ============================================================
    ; Constants
    ; ============================================================

    constants_widget_id_is_micro_layout()
    {
        Assert.Equal("microLayout", MicroLayoutWidget.WIDGET_ID)
    }

    constants_fixed_size_matches_spec()
    {
        Assert.Equal(200, MicroLayoutWidget.FIXED_W)
        Assert.Equal(32, MicroLayoutWidget.FIXED_H)
    }

    constants_display_name_is_layout_micro()
    {
        Assert.Equal("Layout Micro", MicroLayoutWidget.DISPLAY_NAME)
    }

    ; ============================================================
    ; _FormatMs
    ; ============================================================

    format_ms_zero_returns_zero_padded()
    {
        Assert.Equal("00:00.00", MicroLayoutWidget._FormatMs(0))
    }

    format_ms_under_hour_includes_centiseconds()
    {
        Assert.Equal("02:31.23", MicroLayoutWidget._FormatMs(151234))
    }

    format_ms_over_hour_drops_centiseconds()
    {
        Assert.Equal("1:23:45", MicroLayoutWidget._FormatMs(5025000))
    }

    format_ms_negative_treated_as_zero()
    {
        Assert.Equal("00:00.00", MicroLayoutWidget._FormatMs(-100))
    }

    ; ============================================================
    ; _ResolveTimerColor
    ; ============================================================

    resolve_timer_color_no_pb_returns_text()
    {
        Assert.Equal(Theme.Color("text"),
            MicroLayoutWidget._ResolveTimerColor(15000, 0))
    }

    resolve_timer_color_zero_current_returns_text()
    {
        Assert.Equal(Theme.Color("text"),
            MicroLayoutWidget._ResolveTimerColor(0, 60000))
    }

    resolve_timer_color_under_pb_returns_good_strong()
    {
        Assert.Equal(Theme.Color("goodStrong"),
            MicroLayoutWidget._ResolveTimerColor(45000, 60000))
    }

    resolve_timer_color_at_pb_returns_good_strong()
    {
        Assert.Equal(Theme.Color("goodStrong"),
            MicroLayoutWidget._ResolveTimerColor(60000, 60000))
    }

    resolve_timer_color_over_pb_returns_danger()
    {
        Assert.Equal(Theme.Color("danger"),
            MicroLayoutWidget._ResolveTimerColor(75000, 60000))
    }
}

TestRegistry.Register(MicroLayoutWidgetTests)
