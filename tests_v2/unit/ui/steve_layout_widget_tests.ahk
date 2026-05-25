; ============================================================
; SteveLayoutWidgetTests
; ============================================================
;
; Pure helpers + constants. Construction with mocks is heavy
; (7 subscriptions on the bus) and the live render goes through
; Win32 — both tested via the integration suite, not here.
;
; What this file pins:
;   - WIDGET_ID and base dimensions of SteveLayoutWidget so the
;     [Overlay] slot keys stay stable. A regression that changed
;     these would silently orphan the user's persisted position
;     across an upgrade.
;   - _FormatMs and _FormatMsShort produce the exact strings the
;     mono-timer and PB chips render. A drift in either changes
;     what the user reads on the overlay.
;   - _ResolveTimerColor branches the four cases the live timer
;     paints — anti-regression of the under-PB/over-PB heuristic.


class SteveLayoutWidgetTests extends TestCase
{
    static Tests := [
        ; --- Constants ---
        "constants_widget_id_is_steve_layout",
        "constants_fixed_size_matches_spec",
        "constants_display_name_is_layout_steve",

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
        "resolve_timer_color_over_pb_returns_danger",

        ; --- _TruncateToWidth (act/zone overflow on long zone names) ---
        "truncate_short_text_returns_as_is",
        "truncate_long_text_appends_ellipsis",
        "truncate_empty_text_returns_empty",
        "truncate_very_narrow_avail_returns_just_ellipsis"
    ]

    ; ============================================================
    ; Constants
    ; ============================================================

    constants_widget_id_is_steve_layout()
    {
        ; Anti-regression: the user's persisted position is keyed
        ; by WIDGET_ID under [Overlay]. A change here would orphan
        ; that position the moment the upgrade landed.
        Assert.Equal("steveLayout", SteveLayoutWidget.WIDGET_ID)
    }

    constants_fixed_size_matches_spec()
    {
        Assert.Equal(380, SteveLayoutWidget.FIXED_W)
        Assert.Equal(64, SteveLayoutWidget.FIXED_H)
    }

    constants_display_name_is_layout_steve()
    {
        Assert.Equal("Layout Steve", SteveLayoutWidget.DISPLAY_NAME)
    }

    ; ============================================================
    ; _FormatMs — live timer
    ; ============================================================

    format_ms_zero_returns_zero_padded()
    {
        Assert.Equal("00:00.00", SteveLayoutWidget._FormatMs(0))
    }

    format_ms_under_minute()
    {
        ; 47.5 s = 47500 ms → "00:47.50"
        Assert.Equal("00:47.50", SteveLayoutWidget._FormatMs(47500))
    }

    format_ms_under_hour_includes_centiseconds()
    {
        ; 2 min 31 s 234 ms → "02:31.23"
        Assert.Equal("02:31.23", SteveLayoutWidget._FormatMs(151234))
    }

    format_ms_over_hour_drops_centiseconds()
    {
        ; 1 h 23 min 45 s → "1:23:45" (centiseconds dropped to avoid
        ; crop on the right edge of the timer slot).
        Assert.Equal("1:23:45", SteveLayoutWidget._FormatMs(5025000))
    }

    format_ms_negative_treated_as_zero()
    {
        ; Defensive: a corrupt clock or under-flow shouldn't crash
        ; the timer render. Negative is normalized to 0.
        Assert.Equal("00:00.00", SteveLayoutWidget._FormatMs(-100))
    }

    format_ms_at_exactly_one_hour()
    {
        ; Threshold case: 3600 s = 3600000 ms is the first ms that
        ; switches to the H:MM:SS format. Pinned so a `>=` vs `>` flip
        ; in _FormatMs doesn't go unnoticed.
        Assert.Equal("1:00:00", SteveLayoutWidget._FormatMs(3600000))
    }

    ; ============================================================
    ; _FormatMsShort — PB chips
    ; ============================================================

    format_ms_short_zero()
    {
        ; 0 is rare in practice (callers gate on pbMs > 0) but the
        ; helper still has to return a sane string.
        Assert.Equal("0:00", SteveLayoutWidget._FormatMsShort(0))
    }

    format_ms_short_under_hour_no_centiseconds()
    {
        ; 2 min 15 s → "2:15"  (no leading zero on the minute digit,
        ; no centiseconds — PB chips show stable values, the cs
        ; digits would be visual noise without info gain).
        Assert.Equal("2:15", SteveLayoutWidget._FormatMsShort(135000))
    }

    format_ms_short_over_hour()
    {
        Assert.Equal("1:23:45", SteveLayoutWidget._FormatMsShort(5025000))
    }

    format_ms_short_negative_treated_as_zero()
    {
        Assert.Equal("0:00", SteveLayoutWidget._FormatMsShort(-1))
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
            SteveLayoutWidget._ResolveTimerColor(15000, 0))
    }

    resolve_timer_color_zero_current_returns_text()
    {
        ; currentMs=0: timer hasn't started ticking yet (paused at
        ; the start of a run). Avoid flashing "under PB" green when
        ; the run hasn't begun.
        Assert.Equal(Theme.Color("text"),
            SteveLayoutWidget._ResolveTimerColor(0, 60000))
    }

    resolve_timer_color_under_pb_returns_good_strong()
    {
        ; Current 45 s < PB 60 s → vivid green so the under-PB
        ; signal pops against the over-PB red.
        Assert.Equal(Theme.Color("goodStrong"),
            SteveLayoutWidget._ResolveTimerColor(45000, 60000))
    }

    resolve_timer_color_at_pb_returns_good_strong()
    {
        ; <= boundary: tying the PB still counts as "under" — the
        ; user is on pace.
        Assert.Equal(Theme.Color("goodStrong"),
            SteveLayoutWidget._ResolveTimerColor(60000, 60000))
    }

    resolve_timer_color_over_pb_returns_danger()
    {
        Assert.Equal(Theme.Color("danger"),
            SteveLayoutWidget._ResolveTimerColor(75000, 60000))
    }

    ; ============================================================
    ; _TruncateToWidth — prevents AHK Text wrap on long zone names
    ;
    ; Anti-regression: the LINE1 act/zone control has h=30 (matches
    ; the mono timer height), which is enough room for two lines
    ; of FONT_ACT_ZONE=9pt text. Without truncation, AHK Text
    ; word-wraps long composed strings like
    ; "Act 1 · Clearfell Encampment" onto a second line, colliding
    ; with the chip row below.
    ; ============================================================

    truncate_short_text_returns_as_is()
    {
        ; 6 chars x 9 x 0.6 = ~32 px estimate; well under 200 avail.
        Assert.Equal("Act 1",
            SteveLayoutWidget._TruncateToWidth("Act 1", 9, 200))
    }

    truncate_long_text_appends_ellipsis()
    {
        ; "Act 1 · Clearfell Encampment" is the canonical case from
        ; the design discussion: 28 chars x 9 x 0.6 = ~151 px,
        ; over the ~140 px available next to the wide mono timer.
        result := SteveLayoutWidget._TruncateToWidth(
            "Act 1 " Chr(0x00B7) " Clearfell Encampment", 9, 100)
        Assert.Equal("...", SubStr(result, -3),
            "Truncated text must end in '...': got '" result "'")
        Assert.True(StrLen(result) < StrLen("Act 1 · Clearfell Encampment"),
            "Truncated text must be shorter than the original")
    }

    truncate_empty_text_returns_empty()
    {
        Assert.Equal("", SteveLayoutWidget._TruncateToWidth("", 9, 200))
    }

    truncate_very_narrow_avail_returns_just_ellipsis()
    {
        ; availW < ellipsisW: helper returns "..." alone (still
        ; signals truncation visually) rather than a half-rendered
        ; ellipsis or crashing.
        Assert.Equal("...",
            SteveLayoutWidget._TruncateToWidth("anything", 9, 5))
    }
}

TestRegistry.Register(SteveLayoutWidgetTests)
