; ============================================================
; XpService — estado de XP do personagem e da area atual
; ============================================================
;
; Responsabilidade: manter em memoria
;   - characterName, characterClass, characterLevel
;   - currentAreaLevel, currentAreaCode
;
; e expor calculos derivados (delegando pra XpRules da Fase 2):
;   - GetXpPenaltyInfo()
;   - GetSafeRange()
;
; FILOSOFIA:
; Service de ESTADO PURO. Sem dependencia de bus, clock, repos.
; Setters atualizam state. Getters retornam state. Calculos delegam
; para XpRules (puramente funcional).
;
; NAO publica eventos. Nao assina eventos. O App composition root
; (Fase 5) ligara `Evt.CharacterLevelUp` (do log monitor) ao
; `xpService.SetCharacter(...)`, e `Evt.AreaLevelChanged` ao
; `xpService.SetCurrentArea(...)`.
;
; SEMANTICA:
; - characterLevel persiste entre runs (voce nao vira level 1 num NewRun)
; - currentAreaLevel eh da run em curso (resetado quando muda de zona)
;
; Construcao:
;   xp := XpService()
;
; Boot opcional (carrega de saved state):
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
        ; Sem dependencias por enquanto. Estado puro.
    }

    ; ============================================================
    ; Setters
    ; ============================================================

    ; SetCharacter — atualiza informacoes do personagem.
    ;   Strings vazias e level <= 0 sao IGNORADOS (preserva valores
    ;   antigos). Util para chamadas parciais (ex: log monitor ja sabe
    ;   o level mas nao name/class).
    SetCharacter(charName, charClass, charLevel)
    {
        if (charName != "")
            this._characterName := charName
        if (charClass != "")
            this._characterClass := charClass
        if (charLevel > 0)
            this._characterLevel := Integer(charLevel + 0)
    }

    ; SetCurrentArea — atualiza area atual. areaLevel <= 0 eh ignorado.
    ;   areaCode pode ser "" (ainda atualiza).
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

    ; Hydrate — carrega state inicial vindo do disco/config.
    ;   Em contraste com SetCharacter, aceita valores zerados (faz overwrite
    ;   completo do state). Use Hydrate no boot, Set* nas atualizacoes
    ;   incrementais.
    Hydrate(charName := "", charClass := "", charLevel := 0, areaLevel := 0, areaCode := "")
    {
        this._characterName    := charName
        this._characterClass   := charClass
        this._characterLevel   := Integer(charLevel + 0)
        this._currentAreaLevel := Integer(areaLevel + 0)
        this._currentAreaCode  := areaCode
    }

    ; Reset — zera TUDO. Equivalente a Hydrate() sem args.
    ;   Tipicamente nao chamado em NewRun (characterLevel persiste),
    ;   apenas em testes ou em cenarios extremos.
    Reset()
    {
        this._characterName    := ""
        this._characterClass   := ""
        this._characterLevel   := 0
        this._currentAreaLevel := 0
        this._currentAreaCode  := ""
    }

    ; Reset apenas dos campos da area atual. Util quando muda de zona
    ; mas o personagem continua o mesmo.
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
    ; Calculos (delegam para XpRules da Fase 2)
    ; ============================================================

    ; GetXpPenaltyInfo() -> XpPenaltyInfo
    ;   Penalty calculado para o (characterLevel, currentAreaLevel) atual.
    ;   Se nao ha dados, retorna info com status "unknown" (nao estoura).
    GetXpPenaltyInfo()
    {
        return XpRules.Calculate(this._characterLevel, this._currentAreaLevel)
    }

    ; GetXpPenaltyInfoForArea(areaLevel) -> XpPenaltyInfo
    ;   Penalty para uma areaLevel arbitraria. Util para preview da
    ;   proxima zona (ex: widget mostrando "se voce entrar na zona X,
    ;   vai dar penalty").
    GetXpPenaltyInfoForArea(areaLevel)
    {
        return XpRules.Calculate(this._characterLevel, areaLevel)
    }

    ; GetSafeRange() -> [min, max]
    ;   Faixa de areaLevel onde o personagem nao sofre penalty.
    GetSafeRange()
    {
        return XpRules.SafeRange(this._characterLevel)
    }
}
