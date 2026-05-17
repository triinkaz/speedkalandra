; ============================================================
; Ids tests - StepId, RunId, ProfileId
; ============================================================
;
; Covers the three domain validators:
;
;   StepId    : <act>_<NN>_<slug>  (lowercase act, 2 digits, lowercase slug)
;   RunId     : YYYYMMDD_HHMMSS    (optionally with legacy suffix)
;   ProfileId : non-empty string without leading/trailing whitespace
;
; Patterns tested via positive (valid) and negative (invalid) cases
; on IsValid, and via Assert.Throws on MustBeValid.

class StepIdTests extends TestCase
{
    static Tests := [
        "is_valid_accepts_act1_pattern",
        "is_valid_accepts_act_with_digits",
        "is_valid_accepts_interlude_endgame_custom",
        "is_valid_accepts_slug_with_underscores",
        "is_valid_rejects_empty_string",
        "is_valid_rejects_act_starting_with_digit",
        "is_valid_rejects_uppercase_act",
        "is_valid_rejects_uppercase_slug",
        "is_valid_rejects_single_digit_NN",
        "is_valid_rejects_three_digit_NN",
        "is_valid_rejects_empty_slug",
        "is_valid_rejects_missing_underscores",
        "must_be_valid_returns_id_when_valid",
        "must_be_valid_throws_on_invalid",
        "must_be_valid_includes_context_in_error",
    ]

    is_valid_accepts_act1_pattern()
    {
        Assert.True(StepId.IsValid("a1_01_riverbank_miller"))
        Assert.True(StepId.IsValid("a3_15_some_zone"))
    }

    is_valid_accepts_act_with_digits()
    {
        Assert.True(StepId.IsValid("a10_01_foo"))
    }

    is_valid_accepts_interlude_endgame_custom()
    {
        Assert.True(StepId.IsValid("interlude_01_placeholder"))
        Assert.True(StepId.IsValid("endgame_99_xyz"))
        Assert.True(StepId.IsValid("custom_03_a"))
    }

    is_valid_accepts_slug_with_underscores()
    {
        Assert.True(StepId.IsValid("a1_01_a_b_c_d"))
        Assert.True(StepId.IsValid("a1_01_zone_with_lots_of_parts"))
    }

    is_valid_rejects_empty_string()
    {
        Assert.False(StepId.IsValid(""))
    }

    is_valid_rejects_act_starting_with_digit()
    {
        Assert.False(StepId.IsValid("1_01_foo"))
    }

    is_valid_rejects_uppercase_act()
    {
        Assert.False(StepId.IsValid("A1_01_foo"))
    }

    is_valid_rejects_uppercase_slug()
    {
        Assert.False(StepId.IsValid("a1_01_FOO"))
        Assert.False(StepId.IsValid("a1_01_Mixed"))
    }

    is_valid_rejects_single_digit_NN()
    {
        Assert.False(StepId.IsValid("a1_1_foo"))
    }

    is_valid_rejects_three_digit_NN()
    {
        Assert.False(StepId.IsValid("a1_001_foo"))
    }

    is_valid_rejects_empty_slug()
    {
        Assert.False(StepId.IsValid("a1_01_"))
    }

    is_valid_rejects_missing_underscores()
    {
        Assert.False(StepId.IsValid("a1-01-foo"))
        Assert.False(StepId.IsValid("a101foo"))
    }

    must_be_valid_returns_id_when_valid()
    {
        Assert.Equal("a1_01_riverbank", StepId.MustBeValid("a1_01_riverbank"))
    }

    must_be_valid_throws_on_invalid()
    {
        Assert.Throws(ValueError, () => StepId.MustBeValid(""))
        Assert.Throws(ValueError, () => StepId.MustBeValid("invalid"))
    }

    must_be_valid_includes_context_in_error()
    {
        bad := ""
        try
        {
            StepId.MustBeValid("bad-id", "in test")
        }
        catch ValueError as e
        {
            bad := e.Message
        }
        Assert.Contains("in test", bad)
        Assert.Contains("bad-id", bad)
    }
}


class RunIdTests extends TestCase
{
    static Tests := [
        "is_valid_accepts_yyyymmdd_hhmmss",
        "is_valid_accepts_legacy_profile_suffix",
        "is_valid_accepts_alphanumeric_suffix",
        "is_valid_rejects_empty_string",
        "is_valid_rejects_no_underscore_separator",
        "is_valid_rejects_wrong_digit_count",
        "is_valid_rejects_non_digit_characters",
        "must_be_valid_returns_id_when_valid",
        "must_be_valid_throws_on_invalid",
        "generate_creates_id_from_clock_now",
        "generate_inserts_underscore_between_date_and_time",
        "generate_throws_when_clock_lacks_now_method",
        "generate_throws_when_clock_now_too_short",
    ]

    is_valid_accepts_yyyymmdd_hhmmss()
    {
        Assert.True(RunId.IsValid("20260512_142345"))
        Assert.True(RunId.IsValid("20300101_000000"))
    }

    is_valid_accepts_legacy_profile_suffix()
    {
        Assert.True(RunId.IsValid("20260512_142345_Default"))
        Assert.True(RunId.IsValid("20260512_142345_My_Profile"))
    }

    is_valid_accepts_alphanumeric_suffix()
    {
        Assert.True(RunId.IsValid("20260512_142345_abc-123"))
    }

    is_valid_rejects_empty_string()
    {
        Assert.False(RunId.IsValid(""))
    }

    is_valid_rejects_no_underscore_separator()
    {
        Assert.False(RunId.IsValid("20260512142345"))
    }

    is_valid_rejects_wrong_digit_count()
    {
        Assert.False(RunId.IsValid("2026051_142345"))     ; 7-digit date
        Assert.False(RunId.IsValid("20260512_14234"))     ; 5-digit time
    }

    is_valid_rejects_non_digit_characters()
    {
        Assert.False(RunId.IsValid("2026-05-12_14:23:45"))
        Assert.False(RunId.IsValid("abcdefgh_ijklmn"))
    }

    must_be_valid_returns_id_when_valid()
    {
        Assert.Equal("20260512_142345", RunId.MustBeValid("20260512_142345"))
    }

    must_be_valid_throws_on_invalid()
    {
        Assert.Throws(ValueError, () => RunId.MustBeValid(""))
        Assert.Throws(ValueError, () => RunId.MustBeValid("invalid"))
    }

    generate_creates_id_from_clock_now()
    {
        ; AHK v2: case-insensitive lookup makes the local `fakeClock`
        ; shadow the `FakeClock` class throughout the function body -
        ; we use `stubClock` to avoid that. Same pitfall mentioned in
        ; ARCHITECTURE.md (`timerService` vs class `TimerService`).
        stubClock := FakeClock("20260512142345", 0)
        Assert.Equal("20260512_142345", RunId.Generate(stubClock))
    }

    generate_inserts_underscore_between_date_and_time()
    {
        stubClock := FakeClock("20300101120000", 0)
        produced := RunId.Generate(stubClock)
        Assert.Equal("20300101_120000", produced)
        Assert.True(RunId.IsValid(produced), "Generated id must pass IsValid")
    }

    generate_throws_when_clock_lacks_now_method()
    {
        Assert.Throws(TypeError, () => RunId.Generate("not a clock"))
        Assert.Throws(TypeError, () => RunId.Generate(42))
    }

    generate_throws_when_clock_now_too_short()
    {
        ; Clock that returns a string with fewer than 14 chars
        shortClock := FakeClock("12345", 0)
        Assert.Throws(ValueError, () => RunId.Generate(shortClock))
    }
}


class ProfileIdTests extends TestCase
{
    static Tests := [
        "is_valid_accepts_non_empty_string",
        "is_valid_accepts_string_with_spaces_inside",
        "is_valid_accepts_string_with_slashes",
        "is_valid_rejects_empty_string",
        "is_valid_rejects_leading_whitespace",
        "is_valid_rejects_trailing_whitespace",
        "must_be_valid_returns_id_when_valid",
        "must_be_valid_throws_on_invalid",
    ]

    is_valid_accepts_non_empty_string()
    {
        Assert.True(ProfileId.IsValid("Default"))
        Assert.True(ProfileId.IsValid("MyProfile"))
    }

    is_valid_accepts_string_with_spaces_inside()
    {
        Assert.True(ProfileId.IsValid("Glacial Cascade Build"))
    }

    is_valid_accepts_string_with_slashes()
    {
        Assert.True(ProfileId.IsValid("Glacial Cascade/Wind Blast"))
    }

    is_valid_rejects_empty_string()
    {
        Assert.False(ProfileId.IsValid(""))
    }

    is_valid_rejects_leading_whitespace()
    {
        Assert.False(ProfileId.IsValid(" Default"))
        Assert.False(ProfileId.IsValid("`tDefault"))
    }

    is_valid_rejects_trailing_whitespace()
    {
        Assert.False(ProfileId.IsValid("Default "))
        Assert.False(ProfileId.IsValid("Default`t"))
    }

    must_be_valid_returns_id_when_valid()
    {
        Assert.Equal("Default", ProfileId.MustBeValid("Default"))
    }

    must_be_valid_throws_on_invalid()
    {
        Assert.Throws(ValueError, () => ProfileId.MustBeValid(""))
        Assert.Throws(ValueError, () => ProfileId.MustBeValid(" leading"))
    }
}

TestRegistry.Register(StepIdTests)
TestRegistry.Register(RunIdTests)
TestRegistry.Register(ProfileIdTests)
