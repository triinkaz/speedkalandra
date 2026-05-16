; ============================================================
; XpRules tests
; ============================================================
;
; Cobre a regra de penalidade de XP de PoE2:
;
;   threshold = 3 + floor(charLevel / 16)
;
;   |charLevel - areaLevel| > threshold  -> penalty (vermelho)
;     diff > 0  -> direction = "zona baixa"
;     diff < 0  -> direction = "zona alta"
;
;   |charLevel - areaLevel| = threshold  -> limit (amber)
;
;   |charLevel - areaLevel| < threshold  -> ok (verde)
;
;   level <= 0 OR areaLevel <= 0         -> unknown (cinza)
;
; SafeRange(level) retorna [min, max] do areaLevel sem penalty.

class XpRulesTests extends TestCase
{
    static Tests := [
        ; --- Inputs invalidos ---
        "unknown_when_char_level_is_zero",
        "unknown_when_area_level_is_zero",
        "unknown_when_both_are_negative",
        "unknown_status_uses_gray_color_and_question_text",

        ; --- Threshold calculation ---
        "threshold_at_level_15_is_3",
        "threshold_at_level_16_is_4",
        "threshold_at_level_31_is_4",
        "threshold_at_level_32_is_5",

        ; --- Status: ok ---
        "ok_when_diff_below_threshold",
        "ok_uses_green_color",
        "ok_text_is_xp_ok",

        ; --- Status: limit ---
        "limit_when_diff_equals_threshold_positive",
        "limit_when_diff_equals_threshold_negative",
        "limit_uses_amber_color",
        "limit_text_is_xp_limite",

        ; --- Status: penalty ---
        "penalty_when_diff_exceeds_threshold",
        "penalty_direction_zona_baixa_when_area_below_char",
        "penalty_direction_zona_alta_when_area_above_char",
        "penalty_uses_red_color",
        "penalty_outside_field_reflects_distance_beyond_threshold",

        ; --- Output object ---
        "info_records_input_levels",

        ; --- SafeRange ---
        "safe_range_for_level_15_is_12_to_18",
        "safe_range_for_level_16_is_12_to_20",
        "safe_range_clamps_min_to_1_for_low_levels",
        "safe_range_returns_zero_zero_for_invalid_level",
    ]

    ; ============================================================
    ; Inputs invalidos
    ; ============================================================

    unknown_when_char_level_is_zero()
    {
        info := XpRules.Calculate(0, 10)
        Assert.Equal("unknown", info.status)
    }

    unknown_when_area_level_is_zero()
    {
        info := XpRules.Calculate(10, 0)
        Assert.Equal("unknown", info.status)
    }

    unknown_when_both_are_negative()
    {
        info := XpRules.Calculate(-1, -1)
        Assert.Equal("unknown", info.status)
    }

    unknown_status_uses_gray_color_and_question_text()
    {
        info := XpRules.Calculate(0, 0)
        Assert.Equal(XpRules.COLOR_UNKNOWN, info.color)
        Assert.Equal("XP ?", info.text)
    }

    ; ============================================================
    ; Threshold (3 + floor(level/16))
    ; ============================================================

    threshold_at_level_15_is_3()
    {
        info := XpRules.Calculate(15, 15)
        Assert.Equal(3, info.threshold)
    }

    threshold_at_level_16_is_4()
    {
        info := XpRules.Calculate(16, 16)
        Assert.Equal(4, info.threshold)
    }

    threshold_at_level_31_is_4()
    {
        info := XpRules.Calculate(31, 31)
        Assert.Equal(4, info.threshold)
    }

    threshold_at_level_32_is_5()
    {
        info := XpRules.Calculate(32, 32)
        Assert.Equal(5, info.threshold)
    }

    ; ============================================================
    ; Status: ok
    ; ============================================================

    ok_when_diff_below_threshold()
    {
        ; level 15, threshold 3, area 14 -> diff 1, absDiff 1 < 3
        info := XpRules.Calculate(15, 14)
        Assert.Equal("ok", info.status)
    }

    ok_uses_green_color()
    {
        info := XpRules.Calculate(15, 15)
        Assert.Equal(XpRules.COLOR_OK, info.color)
    }

    ok_text_is_xp_ok()
    {
        info := XpRules.Calculate(15, 15)
        Assert.Equal("XP OK", info.text)
    }

    ; ============================================================
    ; Status: limit
    ; ============================================================

    limit_when_diff_equals_threshold_positive()
    {
        ; level 15, threshold 3, area 12 -> diff 3, absDiff 3 = threshold
        info := XpRules.Calculate(15, 12)
        Assert.Equal("limit", info.status)
    }

    limit_when_diff_equals_threshold_negative()
    {
        ; level 15, threshold 3, area 18 -> diff -3, absDiff 3 = threshold
        info := XpRules.Calculate(15, 18)
        Assert.Equal("limit", info.status)
    }

    limit_uses_amber_color()
    {
        info := XpRules.Calculate(15, 12)
        Assert.Equal(XpRules.COLOR_LIMIT, info.color)
    }

    limit_text_is_xp_limite()
    {
        info := XpRules.Calculate(15, 12)
        Assert.Equal("XP LIMITE", info.text)
    }

    ; ============================================================
    ; Status: penalty
    ; ============================================================

    penalty_when_diff_exceeds_threshold()
    {
        ; level 15, threshold 3, area 11 -> diff 4, absDiff 4, outside 1
        info := XpRules.Calculate(15, 11)
        Assert.Equal("penalty", info.status)
    }

    penalty_direction_zona_baixa_when_area_below_char()
    {
        ; area < char => diff > 0 => "zona baixa"
        info := XpRules.Calculate(20, 5)
        Assert.Equal("penalty", info.status)
        Assert.Equal("zona baixa", info.direction)
    }

    penalty_direction_zona_alta_when_area_above_char()
    {
        ; area > char => diff < 0 => "zona alta"
        info := XpRules.Calculate(5, 20)
        Assert.Equal("penalty", info.status)
        Assert.Equal("zona alta", info.direction)
    }

    penalty_uses_red_color()
    {
        info := XpRules.Calculate(20, 5)
        Assert.Equal(XpRules.COLOR_PENALTY, info.color)
    }

    penalty_outside_field_reflects_distance_beyond_threshold()
    {
        ; level 20, threshold 3+1=4, area 5 -> diff 15, outside 11
        info := XpRules.Calculate(20, 5)
        Assert.Equal(11, info.outside)
    }

    ; ============================================================
    ; Output object
    ; ============================================================

    info_records_input_levels()
    {
        info := XpRules.Calculate(15, 12)
        Assert.Equal(15, info.level)
        Assert.Equal(12, info.areaLevel)
    }

    ; ============================================================
    ; SafeRange
    ; ============================================================

    safe_range_for_level_15_is_12_to_18()
    {
        rng := XpRules.SafeRange(15)
        Assert.Equal([12, 18], rng)
    }

    safe_range_for_level_16_is_12_to_20()
    {
        rng := XpRules.SafeRange(16)
        Assert.Equal([12, 20], rng)
    }

    safe_range_clamps_min_to_1_for_low_levels()
    {
        ; level 1, threshold 3 -> min seria -2, clampado para 1
        rng := XpRules.SafeRange(1)
        Assert.Equal(1, rng[1])
        Assert.Equal(4, rng[2])
    }

    safe_range_returns_zero_zero_for_invalid_level()
    {
        Assert.Equal([0, 0], XpRules.SafeRange(0))
        Assert.Equal([0, 0], XpRules.SafeRange(-5))
    }
}

TestRegistry.Register(XpRulesTests)
