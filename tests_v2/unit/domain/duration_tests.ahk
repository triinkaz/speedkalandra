; ============================================================
; Duration tests
; ============================================================
;
; Covers the Duration value object:
;   - Constructor with validation (TypeError, ValueError)
;   - Float -> integer coercion
;   - Static factories (Zero, FromSeconds, FromMinutes)
;   - Formatted() with MM:SS padding
;   - Plus/Minus (Minus does not go below 0)
;   - Equals/GreaterThan/LessThan/IsZero
;   - Immutability (Plus/Minus return new instances)

class DurationTests extends TestCase
{
    static Tests := [
        ; --- Constructor ---
        "constructor_stores_ms",
        "constructor_coerces_float_to_integer",
        "constructor_accepts_zero",
        "constructor_throws_type_error_on_non_number",
        "constructor_throws_value_error_on_negative",

        ; --- Factories ---
        "zero_factory_returns_zero_ms",
        "from_seconds_multiplies_by_1000",
        "from_minutes_multiplies_by_60000",

        ; --- Formatted ---
        "formatted_zero_is_00_00",
        "formatted_below_one_second_is_00_00",
        "formatted_one_second_is_00_01",
        "formatted_one_minute_is_01_00",
        "formatted_pads_with_zeros",
        "formatted_above_one_hour_uses_long_minutes",

        ; --- FormatMs static (consolidation of duplicated helpers) ---
        "format_ms_zero_is_00_00",
        "format_ms_below_one_second_is_00_00",
        "format_ms_one_second_is_00_01",
        "format_ms_under_one_hour_uses_mm_ss",
        "format_ms_at_one_hour_uses_h_mm_ss",
        "format_ms_pads_minutes_and_seconds",
        "format_ms_negative_clamps_to_zero",
        "format_ms_non_number_clamps_to_zero",
        "format_ms_coerces_float_to_int",

        ; --- Arithmetic ---
        "plus_returns_sum_in_new_instance",
        "minus_returns_difference_in_new_instance",
        "minus_clamps_at_zero",
        "plus_is_immutable",
        "minus_is_immutable",

        ; --- Comparisons ---
        "equals_compares_ms",
        "greater_than_compares_ms",
        "less_than_compares_ms",
        "is_zero_returns_true_for_zero_only",
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_stores_ms()
    {
        d := Duration(1500)
        Assert.Equal(1500, d.ms)
    }

    constructor_coerces_float_to_integer()
    {
        d := Duration(1500.7)
        Assert.Equal(1500, d.ms)   ; Integer() truncates
    }

    constructor_accepts_zero()
    {
        d := Duration(0)
        Assert.Equal(0, d.ms)
    }

    constructor_throws_type_error_on_non_number()
    {
        Assert.Throws(TypeError, () => Duration("abc"))
    }

    constructor_throws_value_error_on_negative()
    {
        Assert.Throws(ValueError, () => Duration(-1))
        Assert.Throws(ValueError, () => Duration(-1000))
    }

    ; ============================================================
    ; Factories
    ; ============================================================

    zero_factory_returns_zero_ms()
    {
        Assert.Equal(0, Duration.Zero().ms)
    }

    from_seconds_multiplies_by_1000()
    {
        Assert.Equal(5000, Duration.FromSeconds(5).ms)
        Assert.Equal(500,  Duration.FromSeconds(0.5).ms)
    }

    from_minutes_multiplies_by_60000()
    {
        Assert.Equal(60000,  Duration.FromMinutes(1).ms)
        Assert.Equal(180000, Duration.FromMinutes(3).ms)
    }

    ; ============================================================
    ; Formatted
    ; ============================================================

    formatted_zero_is_00_00()
    {
        Assert.Equal("00:00", Duration(0).Formatted())
    }

    formatted_below_one_second_is_00_00()
    {
        Assert.Equal("00:00", Duration(999).Formatted())
    }

    formatted_one_second_is_00_01()
    {
        Assert.Equal("00:01", Duration(1000).Formatted())
    }

    formatted_one_minute_is_01_00()
    {
        Assert.Equal("01:00", Duration(60000).Formatted())
    }

    formatted_pads_with_zeros()
    {
        Assert.Equal("00:05", Duration(5000).Formatted())
        Assert.Equal("05:09", Duration(309000).Formatted())   ; 5min 9s
    }

    formatted_above_one_hour_uses_long_minutes()
    {
        ; 1h = 60min, formatted as "60:00"
        Assert.Equal("60:00", Duration(3600000).Formatted())
        ; 1h45min30s = 105min 30s
        Assert.Equal("105:30", Duration(6330000).Formatted())
    }

    ; ============================================================
    ; FormatMs static
    ; ============================================================
    ;
    ; Unlike Formatted() (always MM:SS), FormatMs alternates between
    ; MM:SS and H:MM:SS when the time crosses 1 hour. Used in TrayTip,
    ; dialogs and overlay widgets.

    format_ms_zero_is_00_00()
    {
        Assert.Equal("00:00", Duration.FormatMs(0))
    }

    format_ms_below_one_second_is_00_00()
    {
        Assert.Equal("00:00", Duration.FormatMs(999))
    }

    format_ms_one_second_is_00_01()
    {
        Assert.Equal("00:01", Duration.FormatMs(1000))
    }

    format_ms_under_one_hour_uses_mm_ss()
    {
        Assert.Equal("59:59", Duration.FormatMs(3599000))
    }

    format_ms_at_one_hour_uses_h_mm_ss()
    {
        Assert.Equal("1:00:00", Duration.FormatMs(3600000))
        Assert.Equal("1:45:30", Duration.FormatMs(6330000))
        Assert.Equal("5:00:00", Duration.FormatMs(18000000))
    }

    format_ms_pads_minutes_and_seconds()
    {
        Assert.Equal("00:05", Duration.FormatMs(5000))
        Assert.Equal("05:09", Duration.FormatMs(309000))
    }

    format_ms_negative_clamps_to_zero()
    {
        ; FormatMs is defensive (unlike the constructor that throws).
        Assert.Equal("00:00", Duration.FormatMs(-1))
        Assert.Equal("00:00", Duration.FormatMs(-1000))
    }

    format_ms_non_number_clamps_to_zero()
    {
        ; Strings/objects silently become 0 (defensive for integrating
        ; with INI snapshots that may have corrupted values).
        Assert.Equal("00:00", Duration.FormatMs("abc"))
        Assert.Equal("00:00", Duration.FormatMs(""))
    }

    format_ms_coerces_float_to_int()
    {
        Assert.Equal("00:01", Duration.FormatMs(1500.7))   ; truncated to 1500
    }

    ; ============================================================
    ; Arithmetic
    ; ============================================================

    plus_returns_sum_in_new_instance()
    {
        a := Duration(1000)
        b := Duration(500)
        c := a.Plus(b)
        Assert.Equal(1500, c.ms)
    }

    minus_returns_difference_in_new_instance()
    {
        a := Duration(1000)
        b := Duration(300)
        c := a.Minus(b)
        Assert.Equal(700, c.ms)
    }

    minus_clamps_at_zero()
    {
        a := Duration(500)
        b := Duration(1000)
        c := a.Minus(b)
        Assert.Equal(0, c.ms, "Minus must not produce a negative Duration")
    }

    plus_is_immutable()
    {
        a := Duration(1000)
        b := Duration(500)
        a.Plus(b)
        Assert.Equal(1000, a.ms, "Plus must not mutate the original")
        Assert.Equal(500,  b.ms)
    }

    minus_is_immutable()
    {
        a := Duration(1000)
        b := Duration(300)
        a.Minus(b)
        Assert.Equal(1000, a.ms)
        Assert.Equal(300,  b.ms)
    }

    ; ============================================================
    ; Comparisons
    ; ============================================================

    equals_compares_ms()
    {
        Assert.True(Duration(500).Equals(Duration(500)))
        Assert.False(Duration(500).Equals(Duration(501)))
    }

    greater_than_compares_ms()
    {
        Assert.True(Duration(501).GreaterThan(Duration(500)))
        Assert.False(Duration(500).GreaterThan(Duration(500)))
        Assert.False(Duration(499).GreaterThan(Duration(500)))
    }

    less_than_compares_ms()
    {
        Assert.True(Duration(499).LessThan(Duration(500)))
        Assert.False(Duration(500).LessThan(Duration(500)))
        Assert.False(Duration(501).LessThan(Duration(500)))
    }

    is_zero_returns_true_for_zero_only()
    {
        Assert.True(Duration(0).IsZero())
        Assert.False(Duration(1).IsZero())
        Assert.False(Duration(1000).IsZero())
    }
}

TestRegistry.Register(DurationTests)
