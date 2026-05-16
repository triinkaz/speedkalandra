; ============================================================
; PersonalBestRepository - persiste tempos de PB em disco (v17.13)
; ============================================================
;
; ESCOPO:
;   Persiste 2 categorias de Personal Bests:
;     - PB de run inteira (melhor runDurationMs em uma run completed)
;     - PB por zona (melhor zoneTotalMs final em uma run completed)
;
;   Salva no INI `data/personal_bests.ini`. Atualizado pelo
;   PersonalBestService apos cada RunCompleted (NAO em RunCancelled —
;   runs canceladas nao viram PB).
;
; FORMATO DO INI:
;
;   [Run]
;   BestMs=410000
;   BestRunId=20260512_142345
;
;   [RunByAct]
;   Act1Ms=1725000
;   Act2Ms=3900000
;   Act3Ms=6900000
;   ...
;
;   [Zones]
;   Mud Burrow=215000
;   Clearfell=180000
;   The Riverbank=95000
;   ...
;
; [RunByAct] (v17.13): PB do tempo TOTAL DA RUN no momento que cada
; ato terminou. Key = "Act<N>Ms" onde N eh o numero do ato (1-10).
; Substitui o PB global de run inteira (que misturava runs de Ato 1
; com runs de campanha completa, inutilmente).
;
; NOTA SOBRE ZONA COMO KEY:
;   Nomes de zona do PoE2 nao tem `=` ou `]` ou quebra de linha, entao
;   funcionam como keys de INI sem escape. Espacos sao permitidos.
;   Se uma zona com caracteres problematicos aparecer, o IniFile.Write
;   vai falhar e o save eh skipado (try silencia).
;
; API:
;   Load() -> Map{ "runPbMs": int, "runPbRunId": string, "zonePbs": Map<zone, ms> }
;   Save(data) -> bool
;   GetPath() -> string
;
; CONSTRUCAO:
;   repo := PersonalBestRepository(A_ScriptDir "\data\personal_bests.ini")


class PersonalBestRepository
{
    _path := ""

    __New(path)
    {
        if (Trim(String(path)) = "")
            throw ValueError("PersonalBestRepository: 'path' obrigatorio")
        this._path := path
    }

    GetPath() => this._path

    ; ------------------------------------------------------------
    ; Load - retorna Map com PBs (vazio se arquivo nao existe)
    ; ------------------------------------------------------------
    Load()
    {
        result := Map(
            "runPbMs",    0,
            "runPbRunId", "",
            "runPbByAct", Map(),
            "zonePbs",    Map()
        )

        if !FileExist(this._path)
            return result

        ini := IniFile(this._path)

        ; [Run]
        try
            result["runPbMs"] := Integer(ini.Read("Run", "BestMs", "0") + 0)
        catch
            result["runPbMs"] := 0
        try
            result["runPbRunId"] := String(ini.Read("Run", "BestRunId", ""))
        catch
            result["runPbRunId"] := ""

        ; [RunByAct] (v17.13) — PB por ato
        try
        {
            byActMap := ini.ReadSectionAsMap("RunByAct")
            if IsObject(byActMap)
            {
                for k, v in byActMap
                {
                    keyStr := String(k)
                    if (keyStr = "")
                        continue
                    ; Match "Act<N>Ms" -> extrai N
                    if !RegExMatch(keyStr, "i)^Act(\d+)Ms$", &m)
                        continue
                    actNum := Integer(m[1] + 0)
                    if (actNum <= 0)
                        continue
                    try
                    {
                        ms := Integer(v + 0)
                        if (ms > 0)
                            result["runPbByAct"][actNum] := ms
                    }
                    catch
                        continue
                }
            }
        }

        ; [Zones]
        try
        {
            zonesMap := ini.ReadSectionAsMap("Zones")
            if IsObject(zonesMap)
            {
                for k, v in zonesMap
                {
                    if (String(k) = "")
                        continue
                    try
                    {
                        ms := Integer(v + 0)
                        if (ms > 0)
                            result["zonePbs"][String(k)] := ms
                    }
                    catch
                        continue
                }
            }
        }

        return result
    }

    ; ------------------------------------------------------------
    ; Save - persiste PBs em disco ATOMICAMENTE (v17.15, Bug #7)
    ;
    ; Antes: 6-8 IniWrite sequenciais com Delete entre eles. Crash
    ; entre Delete("RunByAct") e Write -> PBs acumulados ao longo de
    ; semanas eram perdidos.
    ;
    ; Agora: serializa INI inteiro em memoria e escreve via AtomicWriter
    ; (.tmp + FileMove). Crash antes do FileMove deixa .tmp orfao mas
    ; o INI original intacto.
    ;
    ; ENCODING (v0.1.0): AtomicWriter usa "UTF-16" em vez de "UTF-8".
    ; Descoberta na Wave 4 de testes: IniRead key-lookup
    ; (`IniRead(path, section, key, default)`) em AHK v2 NAO funciona
    ; em arquivos UTF-8 BOM, retornando sempre o default. Funciona
    ; apenas em UTF-16 LE BOM (formato nativo de IniWrite). Bug latente
    ; no R11 do projeto (TextEncoding.MigrateIniToUtf8) tambem.
    ;
    ; Falhas: loga OutputDebug e retorna false. Caller (service) decide
    ; o que fazer (atualmente silencia, mas pelo menos tem o sinal).
    ; ------------------------------------------------------------
    Save(data)
    {
        if !IsObject(data)
            return false

        try
        {
            content := PersonalBestRepository._Serialize(data)
            AtomicWriter.WriteAll(this._path, content, "UTF-16")
            return true
        }
        catch as ex
        {
            OutputDebug("PersonalBestRepository.Save falhou: " ex.Message)
            return false
        }
    }

    ; ------------------------------------------------------------
    ; _Serialize - monta conteudo INI completo em string
    ;
    ; Output compativel com IniRead (que Load usa pra parsear).
    ; Defensivo: valida tipos, sanitiza chaves de zona.
    ;
    ; LINE ENDINGS: usa CRLF (`r`n) porque IniRead chama Win32
    ; GetPrivateProfileString, que em arquivos UTF-8 BOM NAO reconhece
    ; key=value separados por LF puro. Section-reads (`IniRead(file,
    ; section)`) toleram LF, mas key-lookups (`IniRead(file, section,
    ; key, default)`) retornam default. v0.1.0 fix: convencao Windows.
    ; ------------------------------------------------------------
    static _Serialize(data)
    {
        ; --- [Run] ---
        runMs := (data.Has("runPbMs") && IsNumber(data["runPbMs"]))
                 ? Integer(data["runPbMs"]) : 0
        ; v0.1.0: renomeado de `runId` pra `currentRunId` (case-insensitive
        ; collision com classe `RunId` do domain disparava #Warn).
        currentRunId := data.Has("runPbRunId") ? String(data["runPbRunId"]) : ""
        ; Sanitiza id (paranoia: nao deveria ter caracteres invalidos)
        currentRunId := StrReplace(currentRunId, "`r", "")
        currentRunId := StrReplace(currentRunId, "`n", "")

        content := "[Run]`r`n"
        content .= "BestMs=" runMs "`r`n"
        content .= "BestRunId=" currentRunId "`r`n`r`n"

        ; --- [RunByAct] ---
        content .= "[RunByAct]`r`n"
        byAct := data.Has("runPbByAct") ? data["runPbByAct"] : ""
        if IsObject(byAct)
        {
            for actNum, ms in byAct
            {
                if !IsNumber(actNum) || actNum <= 0
                    continue
                if !IsNumber(ms) || ms <= 0
                    continue
                content .= "Act" Integer(actNum) "Ms=" Integer(ms) "`r`n"
            }
        }
        content .= "`r`n"

        ; --- [Zones] ---
        content .= "[Zones]`r`n"
        zones := data.Has("zonePbs") ? data["zonePbs"] : ""
        if IsObject(zones)
        {
            for zone, ms in zones
            {
                zStr := String(zone)
                if (zStr = "")
                    continue
                if !IsNumber(ms) || ms <= 0
                    continue
                ; Sanitiza nome da zona contra chars que quebrariam INI
                zStr := StrReplace(zStr, "`r", "")
                zStr := StrReplace(zStr, "`n", "")
                zStr := StrReplace(zStr, "=", "")
                zStr := StrReplace(zStr, "[", "")
                zStr := StrReplace(zStr, "]", "")
                if (zStr = "")
                    continue
                content .= zStr "=" Integer(ms) "`r`n"
            }
        }
        return content
    }
}
