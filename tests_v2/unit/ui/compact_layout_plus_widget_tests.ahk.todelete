; ============================================================
; CompactLayoutPlusWidgetTests
; ============================================================
;
; Pure helpers + constants. Construction with mocks isn't worth the
; setup (9 bus subscriptions + 9 services); the integration suite
; covers the wiring end-to-end. The live render goes through Win32
; and can only be checked manually.
;
; What this file pins:
;   - WIDGET_ID and base dimensions match CompactLayoutWidget (the
;     [Overlay] slot is shared, the toggle preserves position).
;   - _FormatMs / _FormatMsShort produce the strings the live timer
;     and PB chips render — a drift changes what the user reads.
;   - _ResolveTimerColor branches the four PB-comparison cases.
;   - _TruncateToWidth replaces Classic's font-shrink with the
;     "..." ellipsis rule from PLUS_LAYOUTS_SPEC.md §6.b.


class CompactLayoutPlusWidgetTests extends TestCase
{
    static Tests := [
        ; --- Constants (shared with Classic) ---
        "constants_share_widget_id_with_classic",
        "constants_share_fixed_size_with_classic",
        "constants_display_name_differs_from_classic",

        ; --- _FormatMs / _FormatMsShort ---
        "format_ms_zero_returns_mm_ss",
        "format_ms_under_hour_returns_mm_ss",
        "format_ms_over_hour_drops_centiseconds",
        "format_ms_negative_treated_as_zero",
        "format_ms_short_under_hour_no_centiseconds",
        "format_ms_short_over_hour",

        ; --- _ResolveTimerColor ---
        "resolve_timer_color_no_pb_returns_text",
        "resolve_timer_color_zero_current_returns_text",
        "resolve_timer_color_under_pb_returns_good_strong",
        "resolve_timer_color_at_pb_returns_good_strong",
        "resolve_timer_color_over_pb_returns_danger",

        ; --- _TruncateToWidth (Plus-only ellipsis policy, spec §6.b) ---
        "truncate_short_text_returns_as_is",
        "truncate_long_text_appends_ellipsis",
        "truncate_avail_zero_returns_empty",
        "truncate_empty_text_returns_empty",
        "truncate_very_narrow_avail_returns_just_ellipsis",

        ; --- _SplitToTwoWords (word-split policy for zone name lines) ---
        "split_to_two_words_empty_returns_empty_lines",
        "split_to_two_words_single_word_goes_to_line1",
        "split_to_two_words_two_words_split_correctly",
        "split_to_two_words_more_than_two_words_drops_extras"
    ]

    ; ============================================================
    ; Constants
    ; ============================================================

    constants_share_widget_id_with_classic()
    {
        Assert.Equal(CompactLayoutWidget.WIDGET_ID,
                     CompactLayoutPlusWidget.WIDGET_ID,
                     "Compact Classic and Plus must share WIDGET_ID")
        Assert.Equal("compactLayout", CompactLayoutPlusWidget.WIDGET_ID)
    }

    constants_share_fixed_size_with_classic()
    {
        Assert.Equal(CompactLayoutWidget.FIXED_W, CompactLayoutPlusWidget.FIXED_W)
        Assert.Equal(CompactLayoutWidget.FIXED_H, CompactLayoutPlusWidget.FIXED_H)
    }

    constants_display_name_differs_from_classic()
    {
        Assert.NotEqual(CompactLayoutWidget.DISPLAY_NAME,
                        CompactLayoutPlusWidget.DISPLAY_NAME)
    }

    ; ============================================================
    ; _FormatMs / _FormatMsShort
    ; ============================================================

    format_ms_zero_returns_mm_ss()
    {
        ; Compact Plus drops centiseconds from the live timer
        ; (different from Steve Plus / Micro Plus, which still
        ; include cs). See _FormatMs header comment for the
        ; rationale.
        Assert.Equal("00:00", CompactLayoutPlusWidget._FormatMs(0))
    }

    format_ms_under_hour_returns_mm_ss()
    {
        ; 151234 ms = 2:31.234. Under 1h, format is MM:SS with no
        ; centiseconds.
        Assert.Equal("02:31", CompactLayoutPlusWidget._FormatMs(151234))
    }

    format_ms_over_hour_drops_centiseconds()
    {
        Assert.Equal("1:23:45", CompactLayoutPlusWidget._FormatMs(5025000))
    }

    format_ms_negative_treated_as_zero()
    {
        Assert.Equal("00:00", CompactLayoutPlusWidget._FormatMs(-100))
    }

    format_ms_short_under_hour_no_centiseconds()
    {
        Assert.Equal("2:15", CompactLayoutPlusWidget._FormatMsShort(135000))
    }

    format_ms_short_over_hour()
    {
        Assert.Equal("1:23:45", CompactLayoutPlusWidget._FormatMsShort(5025000))
    }

    ; ============================================================
    ; _ResolveTimerColor
    ; ============================================================

    resolve_timer_color_no_pb_returns_text()
    {
        Assert.Equal(Theme.Color("text"),
            CompactLayoutPlusWidget._ResolveTimerColor(15000, 0))
    }

    resolve_timer_color_zero_current_returns_text()
    {
        Assert.Equal(Theme.Color("text"),
            CompactLayoutPlusWidget._ResolveTimerColor(0, 60000))
    }

    resolve_timer_color_under_pb_returns_good_strong()
    {
        Assert.Equal(Theme.Color("goodStrong"),
            CompactLayoutPlusWidget._ResolveTimerColor(45000, 60000))
    }

    resolve_timer_color_at_pb_returns_good_strong()
    {
        Assert.Equal(Theme.Color("goodStrong"),
            CompactLayoutPlusWidget._ResolveTimerColor(60000, 60000))
    }

    resolve_timer_color_over_pb_returns_danger()
    {
        Assert.Equal(Theme.Color("danger"),
            CompactLayoutPlusWidget._ResolveTimerColor(75000, 60000))
    }

    ; ============================================================
    ; _TruncateToWidth — Plus-only ellipsis policy (spec §6.b)
    ; ============================================================

    truncate_short_text_returns_as_is()
    {
        ; "Riverbank" = 9 chars × 10 × 0.6 = 54 estimated; well
        ; under 200 avail. No truncation needed.
        Assert.Equal("Riverbank",
            CompactLayoutPlusWidget._TruncateToWidth("Riverbank", 10, 200))
    }

    truncate_long_text_appends_ellipsis()
    {
        ; "Cemetery of the Eternals" = 24 chars × 10 × 0.6 = 144 est;
        ; doesn't fit in 60 px avail. Result must end in "..." and
        ; total fit within the budget.
        result := CompactLayoutPlusWidget._TruncateToWidth(
            "Cemetery of the Eternals", 10, 60)
        ; SubStr(s, -3) returns the last 3 chars (AHK v2 negative
        ; StartingPos counts from the end).
        Assert.Equal("...", SubStr(result, -3),
            "Truncated text must end in '...': got '" result "'")
        Assert.True(StrLen(result) < StrLen("Cemetery of the Eternals"),
            "Truncated text must be shorter than the original")
    }

    truncate_avail_zero_returns_empty()
    {
        ; Defensive: a layout glitch that hands availW=0 must produce
        ; an empty string rather than a crash. Real call site clamps
        ; availW to >= 20 in _RefreshLine1, but the helper itself
        ; stays robust.
        Assert.Equal("", CompactLayoutPlusWidget._TruncateToWidth("anything", 10, 0))
    }

    truncate_empty_text_returns_empty()
    {
        Assert.Equal("", CompactLayoutPlusWidget._TruncateToWidth("", 10, 200))
    }

    truncate_very_narrow_avail_returns_just_ellipsis()
    {
        ; availW < ellipsisW means we can't even fit the "..." plus
        ; one char. The helper returns "..." alone (still visibly
        ; signals truncation) rather than a half-rendered ellipsis.
        Assert.Equal("...",
            CompactLayoutPlusWidget._TruncateToWidth("anything", 10, 5))
    }

    ; ============================================================
    ; _SplitToTwoWords — zone name -> 2 stacked lines (left column)
    ; ============================================================

    split_to_two_words_empty_returns_empty_lines()
    {
        ; Defensive: when there's no current zone (boot, between
        ; runs), _RefreshLine1 hands an em-dash or empty string
        ; here. Both lines must come back empty so the second
        ; control renders blank rather than echoing whatever was
        ; on it before.
        result := CompactLayoutPlusWidget._SplitToTwoWords("")
        Assert.Equal("", result["line1"])
        Assert.Equal("", result["line2"])
    }

    split_to_two_words_single_word_goes_to_line1()
    {
        ; "Manor" -> line1="Manor", line2="" (so the second
        ; control renders blank rather than duplicating the word).
        result := CompactLayoutPlusWidget._SplitToTwoWords("Manor")
        Assert.Equal("Manor", result["line1"])
        Assert.Equal("",      result["line2"])
    }

    split_to_two_words_two_words_split_correctly()
    {
        ; The canonical case from the design discussion:
        ; "Clearfell Encampment" -> line1="Clearfell",
        ; line2="Encampment".
        result := CompactLayoutPlusWidget._SplitToTwoWords("Clearfell Encampment")
        Assert.Equal("Clearfell",  result["line1"])
        Assert.Equal("Encampment", result["line2"])
    }

    split_to_two_words_more_than_two_words_drops_extras()
    {
        ; "The Twilight Strand" -> line1="The", line2="Twilight".
        ; "Strand" is dropped: showing partial tails of the name
        ; would clutter the left column without communicating the
        ; rest. The truncation is by intent, not by width.
        result := CompactLayoutPlusWidget._SplitToTwoWords("The Twilight Strand")
        Assert.Equal("The",      result["line1"])
        Assert.Equal("Twilight", result["line2"])
    }
}

TestRegistry.Register(CompactLayoutPlusWidgetTests)
