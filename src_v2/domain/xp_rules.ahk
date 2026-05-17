; ============================================================
; XpRules — PoE2 XP penalty calculation
; ============================================================
;
; Direct port of GetXpPenaltyInfo (legacy xp.ahk), removing the dependency
; on globals. Pure function: takes (charLevel, areaLevel) -> XpPenaltyInfo.
;
; Game rule:
;   threshold = 3 + floor(charLevel / 16)
;   diff      = charLevel - areaLevel
;   absDiff   = |diff|
;   outside   = absDiff - threshold
;
;   if outside > 0   -> penalty   (red)
;     direction = diff > 0 ? "low zone" : "high zone"
;   if absDiff = threshold -> limit (amber)
;   else             -> ok        (green)
;
; Usage:
;   info := XpRules.Calculate(15, 12)
;   info.status     ; "ok"
;   info.color      ; "22C55E"
;   info.threshold  ; 3
;
;   info := XpRules.Calculate(20, 5)
;   info.status     ; "penalty"
;   info.outside    ; 12  (|20-5|=15, threshold=4, outside=11)


class XpPenaltyInfo
{
    status     := "unknown"   ; unknown | ok | limit | penalty
    color      := "8B8B8B"
    text       := "XP ?"
    threshold  := 0
    outside    := 0
    level      := 0
    areaLevel  := 0
    direction  := ""           ; "" | "low zone" | "high zone"
}


class XpRules
{
    static COLOR_UNKNOWN := "8B8B8B"
    static COLOR_OK      := "22C55E"
    static COLOR_LIMIT   := "F59E0B"
    static COLOR_PENALTY := "EF4444"

    ; ------------------------------------------------------------
    ; Calculate(charLevel, areaLevel) -> XpPenaltyInfo
    ;
    ; If any parameter is <= 0, returns info with status "unknown"
    ; (gray color, threshold 0). Does not throw.
    ; ------------------------------------------------------------
    static Calculate(charLevel, areaLevel)
    {
        info := XpPenaltyInfo()
        info.level     := Integer(charLevel + 0)
        info.areaLevel := Integer(areaLevel + 0)

        if (info.level <= 0 || info.areaLevel <= 0)
        {
            ; Not enough data
            info.text := "XP ?"
            return info
        }

        threshold := 3 + Floor(info.level / 16)
        diff      := info.level - info.areaLevel
        absDiff   := Abs(diff)
        outsideBy := absDiff - threshold

        info.threshold := threshold
        info.outside   := outsideBy > 0 ? outsideBy : 0

        if (outsideBy > 0)
        {
            info.status    := "penalty"
            info.color     := XpRules.COLOR_PENALTY
            info.direction := diff > 0 ? "low zone" : "high zone"
            info.text      := "XP PENALTY"
        }
        else if (absDiff = threshold)
        {
            info.status := "limit"
            info.color  := XpRules.COLOR_LIMIT
            info.text   := "XP LIMIT"
        }
        else
        {
            info.status := "ok"
            info.color  := XpRules.COLOR_OK
            info.text   := "XP OK"
        }

        return info
    }

    ; ------------------------------------------------------------
    ; SafeRange(charLevel) -> [min, max]
    ;
    ; Helper: areaLevel range where NO penalty applies for the character.
    ; Returns [0, 0] if charLevel is invalid.
    ; ------------------------------------------------------------
    static SafeRange(charLevel)
    {
        lvl := Integer(charLevel + 0)
        if (lvl <= 0)
            return [0, 0]
        threshold := 3 + Floor(lvl / 16)
        return [Max(1, lvl - threshold), lvl + threshold]
    }
}
