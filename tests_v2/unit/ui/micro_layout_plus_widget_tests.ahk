; ============================================================
; MicroLayoutPlusWidgetTests
; ============================================================
;
; Same shape as Steve / Compact Plus tests: constants pinning the
; shared [Overlay] slot, formatters, and the timer-color resolver.
; Live render is Win32 and validated manually; construction with
; mocks (7 subscriptions, 5 services) isn't worth the setup — the
; integration suite covers the composition wiring end-to-end.


class MicroLayoutPlusWidgetTests extends TestCase
{
    static Tests := [
        ; --- Constants (shared with Classic) ---
        "constants_share_widget_id_with_classic",
        "constants_share_fixed_size_with_classic",
        "constants_display_name_differs_from_classic",

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

    constants_share_widget_id_with_classic()
    {
        Assert.Equal(MicroLayoutWidget.WIDGET_ID,
                     MicroLayoutPlusWidget.WIDGET_ID,
                     "Micro Classic and Plus must share WIDGET_ID")
        Assert.Equal("microLayout", MicroLayoutPlusWidget.WIDGET_ID)
    }

    constants_share_fixed_size_with_classic()
    {
        Assert.Equal(MicroLayoutWidget.FIXED_W, MicroLayoutPlusWidget.FIXED_W)
        Assert.Equal(MicroLayoutWidget.FIXED_H, MicroLayoutPlusWidget.FIXED_H)
    }

    constants_display_name_differs_from_classic()
    {
        Assert.NotEqual(MicroLayoutWidget.DISPLAY_NAME,
                        MicroLayoutPlusWidget.DISPLAY_NAME)
    }

    ; ============================================================
    ; _FormatMs
    ; ============================================================

    format_ms_zero_returns_zero_padded()
    {
        Assert.Equal("00:00.00", MicroLayoutPlusWidget._FormatMs(0))
    }

    format_ms_under_hour_includes_centiseconds()
    {
        Assert.Equal("02:31.23", MicroLayoutPlusWidget._FormatMs(151234))
    }

    format_ms_over_hour_drops_centiseconds()
    {
        Assert.Equal("1:23:45", MicroLayoutPlusWidget._FormatMs(5025000))
    }

    format_ms_negative_treated_as_zero()
    {
        Assert.Equal("00:00.00", MicroLayoutPlusWidget._FormatMs(-100))
    }

    ; ============================================================
    ; _ResolveTimerColor
    ; ============================================================

    resolve_timer_color_no_pb_returns_text()
    {
        Assert.Equal(Theme.Color("text"),
            MicroLayoutPlusWidget._ResolveTimerColor(15000, 0))
    }

    resolve_timer_color_zero_current_returns_text()
    {
        Assert.Equal(Theme.Color("text"),
            MicroLayoutPlusWidget._ResolveTimerColor(0, 60000))
    }

    resolve_timer_color_under_pb_returns_good_strong()
    {
        Assert.Equal(Theme.Color("goodStrong"),
            MicroLayoutPlusWidget._ResolveTimerColor(45000, 60000))
    }

    resolve_timer_color_at_pb_returns_good_strong()
    {
        Assert.Equal(Theme.Color("goodStrong"),
            MicroLayoutPlusWidget._ResolveTimerColor(60000, 60000))
    }

    resolve_timer_color_over_pb_returns_danger()
    {
        Assert.Equal(Theme.Color("danger"),
            MicroLayoutPlusWidget._ResolveTimerColor(75000, 60000))
    }
}

TestRegistry.Register(MicroLayoutPlusWidgetTests)
