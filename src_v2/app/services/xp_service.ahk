; ============================================================
; XpService — character XP state and current area
; ============================================================
;
; Responsibility: keep in memory
;   - characterName, characterClass, characterLevel
;   - currentAreaLevel, currentAreaCode
;
; and expose derived calculations (delegating to XpRules):
;   - GetXpPenaltyInfo()
;   - GetSafeRange()
;
; PHILOSOPHY:
; PURE STATE service. No dependency on bus, clock, repos. Setters
; update state. Getters return state. Calculations delegate to
; XpRules (purely functional).
;
; Does NOT publish events. Does not subscribe to events. The
; composition root wires `Evt.CharacterLevelUp` (from the log
; monitor) to `xpService.SetCharacter(...)`, and
; `Evt.AreaLevelChanged` to `xpService.SetCurrentArea(...)`.
;
; SEMANTICS:
; - characterLevel persists across runs (you don't go to level 1 on a NewRun)
; - currentAreaLevel belongs to the run in progress (reset on zone change)
;
; Construction:
;   xp := XpService()
;
; Optional boot (load from saved state):
;   xp.Hydrate(name, class, level, areaLevel, areaCode)


class XpService
{
    _characterName    := ""
    _characterClass   := ""
    _characterLevel   := 0
    _currentAreaLevel := 0
    _currentAreaCode  := ""

    __New()
    {
        ; No dependencies for now. Pure state.
    }

    ; ============================================================
    ; Setters
    ; ============================================================

    ; SetCharacter — updates character information.
    ;   Empty strings and level <= 0 are IGNORED (preserves old
    ;   values). Useful for partial calls (e.g. log monitor already
    ;   knows the level but not name/class).
    SetCharacter(charName, charClass, charLevel)
    {
        if (charName != "")
            this._characterName := charName
        if (charClass != "")
            this._characterClass := charClass
        if (charLevel > 0)
            this._characterLevel := Integer(charLevel + 0)
    }

    ; SetCurrentArea — updates the current area. areaLevel <= 0 is ignored.
    ;   areaCode may be "" (it still updates).
    SetCurrentArea(areaLevel, areaCode := "")
    {
        if (areaLevel <= 0)
            return
        this._currentAreaLevel := Integer(areaLevel + 0)
        this._currentAreaCode  := areaCode
    }

    ; ============================================================
    ; Hydrate / Reset
    ; ============================================================

    ; Hydrate — loads initial state coming from disk/config.
    ;   In contrast to SetCharacter, accepts zeroed values (does a
    ;   full overwrite of state). Use Hydrate on boot, Set* for
    ;   incremental updates.
    Hydrate(charName := "", charClass := "", charLevel := 0, areaLevel := 0, areaCode := "")
    {
        this._characterName    := charName
        this._characterClass   := charClass
        this._characterLevel   := Integer(charLevel + 0)
        this._currentAreaLevel := Integer(areaLevel + 0)
        this._currentAreaCode  := areaCode
    }

    ; Reset — clears EVERYTHING. Equivalent to Hydrate() with no args.
    ;   Typically not called on NewRun (characterLevel persists),
    ;   only in tests or extreme scenarios.
    Reset()
    {
        this._characterName    := ""
        this._characterClass   := ""
        this._characterLevel   := 0
        this._currentAreaLevel := 0
        this._currentAreaCode  := ""
    }

    ; Reset only the current-area fields. Useful when the zone changes
    ; but the character stays the same.
    ResetCurrentArea()
    {
        this._currentAreaLevel := 0
        this._currentAreaCode  := ""
    }

    ; ============================================================
    ; Getters
    ; ============================================================

    GetCharacterName()    => this._characterName
    GetCharacterClass()   => this._characterClass
    GetCharacterLevel()   => this._characterLevel
    GetCurrentAreaLevel() => this._currentAreaLevel
    GetCurrentAreaCode()  => this._currentAreaCode

    ; ============================================================
    ; Calculations (delegate to Phase 2's XpRules)
    ; ============================================================

    ; GetXpPenaltyInfo() -> XpPenaltyInfo
    ;   Penalty calculated for the current (characterLevel,
    ;   currentAreaLevel). If there's no data, returns info with
    ;   status "unknown" (does not throw).
    GetXpPenaltyInfo()
    {
        return XpRules.Calculate(this._characterLevel, this._currentAreaLevel)
    }

    ; GetXpPenaltyInfoForArea(areaLevel) -> XpPenaltyInfo
    ;   Penalty for an arbitrary areaLevel. Useful for previewing the
    ;   next zone (e.g. a widget showing "if you enter zone X, you'll
    ;   get a penalty").
    GetXpPenaltyInfoForArea(areaLevel)
    {
        return XpRules.Calculate(this._characterLevel, areaLevel)
    }

    ; GetSafeRange() -> [min, max]
    ;   areaLevel range where the character has no penalty.
    GetSafeRange()
    {
        return XpRules.SafeRange(this._characterLevel)
    }
}
