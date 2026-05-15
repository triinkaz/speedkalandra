; ============================================================
; XpRules — calculo de penalidade de XP de PoE2
; ============================================================
;
; Port direto de GetXpPenaltyInfo (xp.ahk legado), removendo dependencia
; de globais. Pure function: recebe (charLevel, areaLevel) -> XpPenaltyInfo.
;
; Regra do jogo:
;   threshold = 3 + floor(charLevel / 16)
;   diff      = charLevel - areaLevel
;   absDiff   = |diff|
;   outside   = absDiff - threshold
;
;   if outside > 0   -> penalty   (vermelho)
;     direction = diff > 0 ? "zona baixa" : "zona alta"
;   if absDiff = threshold -> limit (amber)
;   else             -> ok        (verde)
;
; Uso:
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
    direction  := ""           ; "" | "zona baixa" | "zona alta"
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
    ; Se qualquer parametro for <= 0, retorna info com status "unknown"
    ; (cor cinza, threshold 0). Nao estoura.
    ; ------------------------------------------------------------
    static Calculate(charLevel, areaLevel)
    {
        info := XpPenaltyInfo()
        info.level     := Integer(charLevel + 0)
        info.areaLevel := Integer(areaLevel + 0)

        if (info.level <= 0 || info.areaLevel <= 0)
        {
            ; Sem dados suficientes
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
            info.direction := diff > 0 ? "zona baixa" : "zona alta"
            info.text      := "XP PENALTY"
        }
        else if (absDiff = threshold)
        {
            info.status := "limit"
            info.color  := XpRules.COLOR_LIMIT
            info.text   := "XP LIMITE"
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
    ; Helper: faixa de areaLevel onde NAO ha penalty para o personagem.
    ; Retorna [0, 0] se charLevel for invalido.
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
