; ============================================================
; Ids — validators para identificadores tipados
; ============================================================
;
; Em vez de criar uma classe envolvente para cada tipo de id (overhead em
; AHK v2 sem trazer beneficio real porque nao temos type-checking), expomos
; classes com metodos estaticos IsValid/MustBeValid.
;
; Uso:
;   StepId.IsValid(id)        ; bool
;   StepId.MustBeValid(id)    ; estoura se invalido, retorna o proprio id
;
; Padroes aceitos:
;
; StepId: <act>_<NN>_<slug>
;   - act: minusculas e digitos, comecando com letra
;     Exemplos: a1, a2, ..., a9, interlude, endgame, custom_xyz
;   - NN: 2 digitos numericos (01..99)
;   - slug: minusculas, digitos, underscores
;   Exemplos validos: a1_01_riverbank_miller, interlude_01_placeholder_start
;
; RunId: YYYYMMDD_HHMMSS
;   - 8 digitos do dia + underscore + 6 digitos da hora
;   Exemplo: 20260425_072055
;   Aceita opcionalmente um sufixo "_<token>" para casos legados onde o
;   profile foi appendado: 20260425_072055_Default
;
; ProfileId: string nao vazia, sem leading/trailing whitespace.
;   Exemplo: "Glacial Cascade/Wind Blast" (espacos e barras OK)


class StepId
{
    ; Pattern compativel com todos os ids do legado:
    ;   a1_01_*, a2_15_*, interlude_01_*, endgame_01_*, custom_99_*
    static _PATTERN := "^[a-z][a-z0-9]*_\d{2}_[a-z0-9_]+$"

    static IsValid(id)
    {
        ; (id = "") implica StrLen=0; checagem unica suficiente.
        if (id = "")
            return false
        return RegExMatch(id, StepId._PATTERN) > 0
    }

    static MustBeValid(id, context := "")
    {
        if !StepId.IsValid(id)
            throw ValueError("StepId invalido: '" id "'" (context != "" ? " (" context ")" : ""))
        return id
    }
}


class RunId
{
    ; YYYYMMDD_HHMMSS
    ; O grupo opcional `(_[a-zA-Z0-9_-]+)?` existe apenas pra back-compat:
    ; runs antigas tinham profile-name appendado ao runId
    ; (ex.: '20260425_072055_Default'). Generate() abaixo NUNCA cria sufixo.
    static _PATTERN := "^\d{8}_\d{6}(_[a-zA-Z0-9_-]+)?$"

    static IsValid(id)
    {
        if (id = "")
            return false
        return RegExMatch(id, RunId._PATTERN) > 0
    }

    static MustBeValid(id, context := "")
    {
        if !RunId.IsValid(id)
            throw ValueError("RunId invalido: '" id "'" (context != "" ? " (" context ")" : ""))
        return id
    }

    ; Gera novo runId a partir do clock. Formato: YYYYMMDD_HHMMSS
    ; clock.Now() retorna YYYYMMDDHHmmss (14 chars). Inserimos '_'
    ; entre data e hora.
    static Generate(clock)
    {
        if !IsObject(clock) || !clock.HasMethod("Now")
            throw TypeError("RunId.Generate: 'clock' deve ter metodo Now()")
        nowStr := clock.Now()
        if (StrLen(nowStr) < 14)
            throw ValueError("RunId.Generate: clock.Now() retornou string invalida: '" nowStr "'")
        return SubStr(nowStr, 1, 8) "_" SubStr(nowStr, 9, 6)
    }
}


class ProfileId
{
    static IsValid(id)
    {
        if (id = "")
            return false
        if (Trim(id) != id)
            return false
        return true
    }

    static MustBeValid(id, context := "")
    {
        if !ProfileId.IsValid(id)
            throw ValueError("ProfileId invalido: '" id "'" (context != "" ? " (" context ")" : ""))
        return id
    }
}
