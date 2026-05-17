; ============================================================
; XpServiceTests
; ============================================================
;
; XpService is pure state: no external deps, no bus, no clock.
; Setters update state; Hydrate does a full overwrite (accepts
; zeros); Reset zeroes; calculations delegate to XpRules.
;
; Coverage:
;   - post-__New defaults
;   - SetCharacter (accepts valid, ignores 0/empty, partial)
;   - SetCurrentArea (accepts level>0, ignores <=0)
;   - Hydrate (full overwrite, accepts zeros)
;   - Reset / ResetCurrentArea
;   - Getters
;   - Calculations delegate to XpRules (penalty, safe range)


class XpServiceTests extends TestCase
{
    svc := ""

    Setup()
    {
        this.svc := XpService()
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- defaults ---
        "defaults_after_construction_are_zero_and_empty",

        ; --- SetCharacter ---
        "set_character_stores_name_class_level",
        "set_character_ignores_empty_name",
        "set_character_ignores_empty_class",
        "set_character_ignores_level_zero",
        "set_character_ignores_negative_level",
        "set_character_coerces_numeric_level_to_int",
        "set_character_partial_update_preserves_previous",

        ; --- SetCurrentArea ---
        "set_current_area_stores_level_and_code",
        "set_current_area_ignores_level_zero",
        "set_current_area_ignores_negative_level",
        "set_current_area_accepts_empty_code",
        "set_current_area_overwrites_existing",

        ; --- Hydrate ---
        "hydrate_overwrites_all_fields",
        "hydrate_accepts_zero_level_unlike_setter",
        "hydrate_accepts_empty_strings_unlike_setter",
        "hydrate_no_args_zeroes_everything",

        ; --- Reset ---
        "reset_zeroes_all_fields",
        "reset_current_area_only_zeroes_area_fields",
        "reset_current_area_preserves_character",

        ; --- Calculations (delegate to XpRules) ---
        "get_xp_penalty_info_uses_current_character_and_area",
        "get_xp_penalty_info_returns_unknown_when_level_zero",
        "get_xp_penalty_info_for_area_uses_arbitrary_area",
        "get_safe_range_uses_current_character_level",
        "get_safe_range_returns_zero_zero_for_invalid_level"
    ]

    ; ============================================================
    ; defaults
    ; ============================================================

    defaults_after_construction_are_zero_and_empty()
    {
        Assert.Equal("", this.svc.GetCharacterName())
        Assert.Equal("", this.svc.GetCharacterClass())
        Assert.Equal(0,  this.svc.GetCharacterLevel())
        Assert.Equal(0,  this.svc.GetCurrentAreaLevel())
        Assert.Equal("", this.svc.GetCurrentAreaCode())
    }

    ; ============================================================
    ; SetCharacter
    ; ============================================================

    set_character_stores_name_class_level()
    {
        this.svc.SetCharacter("Olaf", "Warrior", 42)
        Assert.Equal("Olaf",    this.svc.GetCharacterName())
        Assert.Equal("Warrior", this.svc.GetCharacterClass())
        Assert.Equal(42,        this.svc.GetCharacterLevel())
    }

    set_character_ignores_empty_name()
    {
        this.svc.SetCharacter("Olaf", "Warrior", 42)
        this.svc.SetCharacter("", "Sorceress", 50)
        Assert.Equal("Olaf",      this.svc.GetCharacterName(), "name preserved")
        Assert.Equal("Sorceress", this.svc.GetCharacterClass())
        Assert.Equal(50,          this.svc.GetCharacterLevel())
    }

    set_character_ignores_empty_class()
    {
        this.svc.SetCharacter("Olaf", "Warrior", 42)
        this.svc.SetCharacter("Bjorn", "", 50)
        Assert.Equal("Bjorn",   this.svc.GetCharacterName())
        Assert.Equal("Warrior", this.svc.GetCharacterClass(), "class preserved")
        Assert.Equal(50,        this.svc.GetCharacterLevel())
    }

    set_character_ignores_level_zero()
    {
        this.svc.SetCharacter("Olaf", "Warrior", 42)
        this.svc.SetCharacter("Bjorn", "Sorceress", 0)
        Assert.Equal("Bjorn",     this.svc.GetCharacterName())
        Assert.Equal("Sorceress", this.svc.GetCharacterClass())
        Assert.Equal(42,          this.svc.GetCharacterLevel(), "level preserved")
    }

    set_character_ignores_negative_level()
    {
        this.svc.SetCharacter("Olaf", "Warrior", 42)
        this.svc.SetCharacter("Bjorn", "Sorceress", -5)
        Assert.Equal(42, this.svc.GetCharacterLevel(), "level preserved when negative")
    }

    set_character_coerces_numeric_level_to_int()
    {
        this.svc.SetCharacter("Olaf", "Warrior", 42.7)
        Assert.Equal("Integer", Type(this.svc.GetCharacterLevel()))
        Assert.Equal(42, this.svc.GetCharacterLevel())
    }

    set_character_partial_update_preserves_previous()
    {
        this.svc.SetCharacter("Olaf", "Warrior", 42)
        ; Only level changes (name "" and class "" ignored)
        this.svc.SetCharacter("", "", 50)
        Assert.Equal("Olaf",    this.svc.GetCharacterName())
        Assert.Equal("Warrior", this.svc.GetCharacterClass())
        Assert.Equal(50,        this.svc.GetCharacterLevel())
    }

    ; ============================================================
    ; SetCurrentArea
    ; ============================================================

    set_current_area_stores_level_and_code()
    {
        this.svc.SetCurrentArea(45, "G1_1")
        Assert.Equal(45,     this.svc.GetCurrentAreaLevel())
        Assert.Equal("G1_1", this.svc.GetCurrentAreaCode())
    }

    set_current_area_ignores_level_zero()
    {
        this.svc.SetCurrentArea(45, "G1_1")
        this.svc.SetCurrentArea(0, "G2_2")
        Assert.Equal(45,     this.svc.GetCurrentAreaLevel(), "level preserved")
        Assert.Equal("G1_1", this.svc.GetCurrentAreaCode(), "code preserved at level zero")
    }

    set_current_area_ignores_negative_level()
    {
        this.svc.SetCurrentArea(45, "G1_1")
        this.svc.SetCurrentArea(-1, "G2_2")
        Assert.Equal(45,     this.svc.GetCurrentAreaLevel())
        Assert.Equal("G1_1", this.svc.GetCurrentAreaCode())
    }

    set_current_area_accepts_empty_code()
    {
        this.svc.SetCurrentArea(45)   ; areaCode default ""
        Assert.Equal(45, this.svc.GetCurrentAreaLevel())
        Assert.Equal("", this.svc.GetCurrentAreaCode())
    }

    set_current_area_overwrites_existing()
    {
        this.svc.SetCurrentArea(45, "G1_1")
        this.svc.SetCurrentArea(50, "G2_2")
        Assert.Equal(50,     this.svc.GetCurrentAreaLevel())
        Assert.Equal("G2_2", this.svc.GetCurrentAreaCode())
    }

    ; ============================================================
    ; Hydrate
    ; ============================================================

    hydrate_overwrites_all_fields()
    {
        this.svc.SetCharacter("Olaf", "Warrior", 42)
        this.svc.SetCurrentArea(45, "G1_1")
        this.svc.Hydrate("Bjorn", "Sorceress", 60, 65, "G3_3")
        Assert.Equal("Bjorn",     this.svc.GetCharacterName())
        Assert.Equal("Sorceress", this.svc.GetCharacterClass())
        Assert.Equal(60,          this.svc.GetCharacterLevel())
        Assert.Equal(65,          this.svc.GetCurrentAreaLevel())
        Assert.Equal("G3_3",      this.svc.GetCurrentAreaCode())
    }

    hydrate_accepts_zero_level_unlike_setter()
    {
        this.svc.SetCharacter("Olaf", "Warrior", 42)
        this.svc.Hydrate("Olaf", "Warrior", 0, 0, "")
        Assert.Equal(0, this.svc.GetCharacterLevel(), "Hydrate zeroes (Set would ignore)")
        Assert.Equal(0, this.svc.GetCurrentAreaLevel())
    }

    hydrate_accepts_empty_strings_unlike_setter()
    {
        this.svc.SetCharacter("Olaf", "Warrior", 42)
        this.svc.Hydrate("", "", 0, 0, "")
        Assert.Equal("", this.svc.GetCharacterName())
        Assert.Equal("", this.svc.GetCharacterClass())
    }

    hydrate_no_args_zeroes_everything()
    {
        this.svc.SetCharacter("Olaf", "Warrior", 42)
        this.svc.SetCurrentArea(45, "G1_1")
        this.svc.Hydrate()
        Assert.Equal("", this.svc.GetCharacterName())
        Assert.Equal("", this.svc.GetCharacterClass())
        Assert.Equal(0,  this.svc.GetCharacterLevel())
        Assert.Equal(0,  this.svc.GetCurrentAreaLevel())
        Assert.Equal("", this.svc.GetCurrentAreaCode())
    }

    ; ============================================================
    ; Reset
    ; ============================================================

    reset_zeroes_all_fields()
    {
        this.svc.SetCharacter("Olaf", "Warrior", 42)
        this.svc.SetCurrentArea(45, "G1_1")
        this.svc.Reset()
        Assert.Equal("", this.svc.GetCharacterName())
        Assert.Equal("", this.svc.GetCharacterClass())
        Assert.Equal(0,  this.svc.GetCharacterLevel())
        Assert.Equal(0,  this.svc.GetCurrentAreaLevel())
        Assert.Equal("", this.svc.GetCurrentAreaCode())
    }

    reset_current_area_only_zeroes_area_fields()
    {
        this.svc.SetCurrentArea(45, "G1_1")
        this.svc.ResetCurrentArea()
        Assert.Equal(0,  this.svc.GetCurrentAreaLevel())
        Assert.Equal("", this.svc.GetCurrentAreaCode())
    }

    reset_current_area_preserves_character()
    {
        this.svc.SetCharacter("Olaf", "Warrior", 42)
        this.svc.SetCurrentArea(45, "G1_1")
        this.svc.ResetCurrentArea()
        Assert.Equal("Olaf",    this.svc.GetCharacterName())
        Assert.Equal("Warrior", this.svc.GetCharacterClass())
        Assert.Equal(42,        this.svc.GetCharacterLevel())
    }

    ; ============================================================
    ; Calculations (delegate to XpRules)
    ; ============================================================

    get_xp_penalty_info_uses_current_character_and_area()
    {
        ; Char 20, area 20 -> OK (diff 0 < threshold)
        this.svc.SetCharacter("Olaf", "Warrior", 20)
        this.svc.SetCurrentArea(20, "G1_1")
        info := this.svc.GetXpPenaltyInfo()
        Assert.Equal("ok", info.status)
    }

    get_xp_penalty_info_returns_unknown_when_level_zero()
    {
        ; No data: char level 0 -> XpRules.Calculate returns unknown
        info := this.svc.GetXpPenaltyInfo()
        Assert.Equal("unknown", info.status)
    }

    get_xp_penalty_info_for_area_uses_arbitrary_area()
    {
        ; Char 20 + arbitrary area 50 -> high penalty (50 > 20 + threshold)
        this.svc.SetCharacter("Olaf", "Warrior", 20)
        ; Note that currentAreaLevel can be something else (15)
        this.svc.SetCurrentArea(15, "G1_1")
        info := this.svc.GetXpPenaltyInfoForArea(50)
        Assert.Equal("penalty", info.status,
            "GetXpPenaltyInfoForArea ignores currentAreaLevel and uses the param")
    }

    get_safe_range_uses_current_character_level()
    {
        ; Char 15: threshold=3 -> [12, 18]
        this.svc.SetCharacter("Olaf", "Warrior", 15)
        range := this.svc.GetSafeRange()
        Assert.Equal(12, range[1])
        Assert.Equal(18, range[2])
    }

    get_safe_range_returns_zero_zero_for_invalid_level()
    {
        ; Char level 0 -> XpRules returns [0, 0]
        range := this.svc.GetSafeRange()
        Assert.Equal(0, range[1])
        Assert.Equal(0, range[2])
    }
}

TestRegistry.Register(XpServiceTests)
