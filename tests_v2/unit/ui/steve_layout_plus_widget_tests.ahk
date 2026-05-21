; ============================================================
; SteveLayoutPlusWidgetTests
; ============================================================
;
; Pure helpers + constants. Construction with mocks is heavy
; (7 subscriptions on the bus) and the live render goes through
; Win32 — both tested via the integration suite, not here.
;
; What this file pins:
;   - WIDGET_ID and base dimensions match SteveLayoutWidget so the
;     [Overlay] slot is shared across the Classic↔Plus toggle. A
;     regression that diverged these would silently orphan the
;     user's persisted position when they flipped the flag.
;   - _FormatMs and _FormatMsShort produce the exact strings the
;     mono-timer and PB chips render. A drift in either changes
;     what the user reads on the overlay.
;   - _ResolveTimerColor branches the four cases the live timer
;     paints — anti-regression of the under-PB/over-PB heuristic.


class SteveLayoutPlusWidgetTests extends TestCase
{
    static Tests := [
        ; --- Constants (shared with Classic) ---
        "constants_share_widget_id_with_classic",
        "constants_share_fixed_size_with_classic",
        "constants_display_name_differs_from_classic",

        ; --- _FormatMs (live timer, with centiseconds < 1h) ---
        "format_ms_zero_returns_zero_padded",
        "format_ms_under_minute",
        "format_ms_under_hour_includes_centiseconds",
        "format_ms_over_hour_drops_centiseconds",
        "format_ms_negative_treated_as_zero",
        "format_ms_at_exactly_one_hour",

        ; --- _FormatMsShort (PB chips, no centiseconds) ---
        "format_ms_short_zero",
        "format_ms_short_under_hour_no_centiseconds",
        "format_ms_short_over_hour",
        "format_ms_short_negative_treated_as_zero",

        ; --- _ResolveTimerColor ---
        "resolve_timer_color_no_pb_returns_text",
        "resolve_timer_color_zero_current_returns_text",
        "resolve_timer_color_under_pb_returns_good_strong",
        "resolve_timer_color_at_pb_returns_good_strong",
        "resolve_timer_color_over_pb_returns_danger"
    ]

    ; ============================================================
    ; Constants (shared with Classic)
    ; ============================================================

    constants_share_widget_id_with_classic()
    {
        ; Anti-regression: both variants persist into [Overlay]
        ; under the same key. A divergence here would orphan the
        ; user's position the moment they flipped the toggle.
        Assert.Equal(SteveLayoutWidget.WIDGET_ID,
                     SteveLayoutPlusWidget.WIDGET_ID,
                     "Steve Classic and Plus must share WIDGET_ID")
        Assert.Equal("steveLayout", SteveLayoutPlusWidget.WIDGET_ID)
    }

    constants_share_fixed_size_with_classic()
    {
        ; A divergence here would resize the widget on the toggle
        ; and force the user to reposition.
        Assert.Equal(SteveLayoutWidget.FIXED_W, SteveLayoutPlusWidget.FIXED_W,
            "FIXED_W must match Classic")
        Assert.Equal(SteveLayoutWidget.FIXED_H, SteveLayoutPlusWidget.FIXED_H,
            "FIXED_H must match Classic")
    }

    constants_display_name_differs_from_classic()
    {
        ; Pure UI surface: the OverlayModeApplier inspects the
        ; instance, not the DisplayName, so this just locks the
        ; user-facing label so it doesn't get reused for a different
        ; widget by accident.
        Assert.NotEqual(SteveLayoutWidget.DISPLAY_NAME,
                        SteveLayoutPlusWidget.DISPLAY_NAME)
    }

    ; ============================================================
    ; _FormatMs — live timer
    ; ============================================================

    format_ms_zero_returns_zero_padded()
    {
        Assert.Equal("00:00.00", SteveLayoutPlusWidget._FormatMs(0))
    }

    format_ms_under_minute()
    {
        ; 47.5 s = 47500 ms → "00:47.50"
        Assert.Equal("00:47.50", SteveLayoutPlusWidget._FormatMs(47500))
    }

    format_ms_under_hour_includes_centiseconds()
    {
        ; 2 min 31 s 234 ms → "02:31.23"
        Assert.Equal("02:31.23", SteveLayoutPlusWidget._FormatMs(151234))
    }

    format_ms_over_hour_drops_centiseconds()
    {
        ; 1 h 23 min 45 s → "1:23:45" (centiseconds dropped to avoid
        ; crop on the right edge of the timer slot).
        Assert.Equal("1:23:45", SteveLayoutPlusWidget._FormatMs(5025000))
    }

    format_ms_negative_treated_as_zero()
    {
        ; Defensive: a corrupt clock or under-flow shouldn't crash
        ; the timer render. Negative is normalized to 0.
        Assert.Equal("00:00.00", SteveLayoutPlusWidget._FormatMs(-100))
    }

    format_ms_at_exactly_one_hour()
    {
        ; Threshold case: 3600 s = 3600000 ms is the first ms that
        ; switches to the H:MM:SS format. Pinned so a `>=` vs `>` flip
        ; in _FormatMs doesn't go unnoticed.
        Assert.Equal("1:00:00", SteveLayoutPlusWidget._FormatMs(3600000))
    }

    ; ============================================================
    ; _FormatMsShort — PB chips
    ; ============================================================

    format_ms_short_zero()
    {
        ; 0 is rare in practice (callers gate on pbMs > 0) but the
        ; helper still has to return a sane string.
        Assert.Equal("0:00", SteveLayoutPlusWidget._FormatMsShort(0))
    }

    format_ms_short_under_hour_no_centiseconds()
    {
        ; 2 min 15 s → "2:15"  (no leading zero on the minute digit,
        ; no centiseconds — PB chips show stable values, the cs
        ; digits would be visual noise without info gain).
        Assert.Equal("2:15", SteveLayoutPlusWidget._FormatMsShort(135000))
    }

    format_ms_short_over_hour()
    {
        Assert.Equal("1:23:45", SteveLayoutPlusWidget._FormatMsShort(5025000))
    }

    format_ms_short_negative_treated_as_zero()
    {
        Assert.Equal("0:00", SteveLayoutPlusWidget._FormatMsShort(-1))
    }

    ; ============================================================
    ; _ResolveTimerColor — branch coverage
    ; ============================================================

    resolve_timer_color_no_pb_returns_text()
    {
        ; pbMs=0: no PB yet (first run, or PB file fresh). The
        ; timer shows in neutral text color until the user
        ; finishes a run.
        Assert.Equal(Theme.Color("text"),
            SteveLayoutPlusWidget._ResolveTimerColor(15000, 0))
    }

    resolve_timer_color_zero_current_returns_text()
    {
        ; currentMs=0: timer hasn't started ticking yet (paused at
        ; the start of a run). Avoid flashing "under PB" green when
        ; the run hasn't begun.
        Assert.Equal(Theme.Color("text"),
            SteveLayoutPlusWidget._ResolveTimerColor(0, 60000))
    }

    resolve_timer_color_under_pb_returns_good_strong()
    {
        ; Current 45 s < PB 60 s → vivid green so the under-PB
        ; signal pops against the over-PB red.
        Assert.Equal(Theme.Color("goodStrong"),
            SteveLayoutPlusWidget._ResolveTimerColor(45000, 60000))
    }

    resolve_timer_color_at_pb_returns_good_strong()
    {
        ; <= boundary: tying the PB still counts as "under" — the
        ; user is on pace.
        Assert.Equal(Theme.Color("goodStrong"),
            SteveLayoutPlusWidget._ResolveTimerColor(60000, 60000))
    }

    resolve_timer_color_over_pb_returns_danger()
    {
        Assert.Equal(Theme.Color("danger"),
            SteveLayoutPlusWidget._ResolveTimerColor(75000, 60000))
    }
}

TestRegistry.Register(SteveLayoutPlusWidgetTests)
