; ============================================================
; RunHistoryRepository - persiste runs finalizadas em disco
; ============================================================
;
; ESCOPO (v17.6):
;   Cada run finalizada eh salva como `data/runs/{runId}.ini`. O
;   conteudo eh o "buildResult" produzido por RunStatsPlotBuilder.Build
;   — ou seja, ja agregado em totals + details — pra que o dialog
;   abra runs historicas sem precisar re-executar o builder.
;
; FORMATO (1 arquivo INI por run):
;
;   [meta]
;   runId=20260513_051547
;   profile=Default
;   patch=Unknown
;   firstTs=2026-05-13 05:15:47
;   totalMs=3719000
;   deathCount=3
;   maxActReached=2
;
;   [totals]
;   mapa=2918000
;   cidade=226000
;   loading=44000
;   morte=450000
;
;   [details]
;   count=15
;   0=mapa|Cemetery of the Eternals|220000|Ato 1|
;   1=mapa|Clearfell|156000|Ato 1|
;   2=cidade|The Ardura Caravan|95000|Ato 2|
;   ...
;
; NOTA: runs salvas em versoes antigas podem ter `category=boss` em
; details/totals. O loader le sem reclamar; o builder atual nao tem
; mais a categoria boss em SegmentDefinitions, entao o plot ignora.
;
; SERIALIZACAO DE DETAILS:
;   Cada detail vira uma linha "category|label|ms|note|timestamp".
;   Pipe `|` eh o separador (nao deve aparecer em nomes de zonas do
;   PoE2; se aparecer, escapado pra `\|`).
;
;   Decisao: nao uso JSON pra evitar parser custom. INI ja tem reader
;   estavel no projeto e o formato eh suficiente pra runs.
;
; QUERY API:
;   ListRunIds(maxN := -1)         -> Array<string> ordenado desc por mtime
;   Load(runId)                    -> Map (mesmo formato do builder) | ""
;   LoadSummaries(maxN := -1)      -> Array<Map> com so meta+totals (rapido)
;   Save(buildResult)              -> bool
;   Delete(runId)                  -> bool
;   GetDir()                       -> string
;
; CONSTRUCAO:
;   repo := RunHistoryRepository(A_ScriptDir "\data\runs")


class RunHistoryRepository
{
    _dir := ""

    static DETAIL_SEP := "|"

    __New(dir)
    {
        if (Trim(String(dir)) = "")
            throw ValueError("RunHistoryRepository: 'dir' obrigatorio")
        this._dir := dir
        this._EnsureDir()
    }

    GetDir() => this._dir

    ; ------------------------------------------------------------
    ; Save - persiste buildResult em data/runs/{runId}.ini
    ;
    ; buildResult eh o output de RunStatsPlotBuilder.Build (Map com
    ; runId, profile, patch, firstTs, totals, details, deathCount,
    ; totalMs).
    ;
    ; Run sem runId ou com totalMs < 1000ms (1s) eh ignorada — evita
    ; lixo de runs canceladas imediatamente apos start.
    ; ------------------------------------------------------------
    Save(buildResult)
    {
        if !IsObject(buildResult)
            return false

        runId := buildResult.Has("runId") ? String(buildResult["runId"]) : ""
        if (runId = "")
            return false

        totalMs := buildResult.Has("totalMs") ? buildResult["totalMs"] : 0
        if (totalMs < 1000)
            return false

        path := this._PathForRunId(runId)
        ini := IniFile(path)

        ; --- [meta] ---
        ini.Write(runId, "meta", "runId")
        ini.Write(buildResult.Has("profile") ? buildResult["profile"] : "", "meta", "profile")
        ini.Write(buildResult.Has("patch")   ? buildResult["patch"]   : "", "meta", "patch")
        ini.Write(buildResult.Has("firstTs") ? buildResult["firstTs"] : "", "meta", "firstTs")
        ini.Write(totalMs, "meta", "totalMs")
        ini.Write(buildResult.Has("deathCount") ? buildResult["deathCount"] : 0, "meta", "deathCount")
        ini.Write(buildResult.Has("maxActReached") ? buildResult["maxActReached"] : 0, "meta", "maxActReached")

        ; --- [totals] ---
        ; Limpa section primeiro pra garantir consistencia (caso uma
        ; categoria existisse antes e nao agora — improvavel mas defensivo).
        ini.Delete("totals", "")
        totals := buildResult.Has("totals") ? buildResult["totals"] : Map()
        if IsObject(totals)
        {
            for key, ms in totals
                ini.Write(ms, "totals", key)
        }

        ; --- [checkpoints] (v17.15.1) ---
        ; Tempo TOTAL DA RUN em ms quando cada ato terminou. Map<actNum, ms>.
        ; Persistido aqui pra que PersonalBestService.RebuildFromHistory
        ; consiga reconstruir os PBs por ato apos delete de run. Runs
        ; salvas antes desse campo simplesmente vem sem a section
        ; (Load retorna Map() vazio, rebuild ignora).
        ini.Delete("checkpoints", "")
        ckpts := buildResult.Has("actCheckpoints") ? buildResult["actCheckpoints"] : Map()
        if IsObject(ckpts)
        {
            for actNum, ms in ckpts
            {
                if !IsNumber(actNum) || actNum <= 0
                    continue
                if !IsNumber(ms) || ms <= 0
                    continue
                ini.Write(Integer(ms), "checkpoints", "Act" Integer(actNum) "Ms")
            }
        }

        ; --- [details] ---
        ini.Delete("details", "")
        details := buildResult.Has("details") ? buildResult["details"] : []
        n := 0
        if IsObject(details)
        {
            for _, row in details
            {
                if !IsObject(row)
                    continue
                line := RunHistoryRepository._SerializeDetail(row)
                ini.Write(line, "details", n)
                n += 1
            }
        }
        ini.Write(n, "details", "count")
        return true
    }

    ; ------------------------------------------------------------
    ; ListRunIds(maxN := -1) - lista runIds disponiveis
    ;
    ; Ordenado por modification time DESC (mais recente primeiro).
    ; Se maxN > 0, limita a essa quantidade.
    ;
    ; BUGFIX v17.12: Usa SplitPath em vez de SubStr(runId, -3) pra
    ; tirar a extensao. O bug original tentava comparar SubStr(name, -3)
    ; (= "ini", sem ponto) com ".ini" (= 4 chars), o que nunca batia.
    ; Resultado: runId ficava com ".ini" no nome, e o _PathForRunId
    ; sanitizava o ponto pra "_", buscando "data\runs\NAME_ini.ini" —
    ; arquivo inexistente. LoadSummaries retornava lista vazia.
    ; ------------------------------------------------------------
    ListRunIds(maxN := -1)
    {
        result := []
        if !DirExist(this._dir)
            return result

        ; Coleta {runId, mtime} pra ordenar depois
        candidates := []
        loop files this._dir "\*.ini", "F"
        {
            ; Extrai nome sem extensao via SplitPath
            SplitPath(A_LoopFileName, , , , &runId)
            if (runId = "")
                continue
            ; A_LoopFileTimeModified eh "YYYYMMDDHHMMSS"
            candidates.Push(Map(
                "runId", runId,
                "mtime", A_LoopFileTimeModified
            ))
        }

        ; Sort desc por mtime (insertion sort simples — N tipicamente < 100)
        n := candidates.Length
        i := 2
        while (i <= n)
        {
            j := i
            while (j > 1 && StrCompare(candidates[j]["mtime"], candidates[j-1]["mtime"]) > 0)
            {
                tmp := candidates[j]
                candidates[j] := candidates[j-1]
                candidates[j-1] := tmp
                j--
            }
            i++
        }

        ; Aplica limit
        limit := (maxN > 0 && maxN < n) ? maxN : n
        i := 1
        while (i <= limit)
        {
            result.Push(candidates[i]["runId"])
            i++
        }
        return result
    }

    ; ------------------------------------------------------------
    ; Load(runId) - reconstrói buildResult salvo
    ; Retorna Map (mesmo formato do builder) ou "" se nao encontrado.
    ; ------------------------------------------------------------
    Load(runId)
    {
        path := this._PathForRunId(runId)
        if !FileExist(path)
            return ""

        ini := IniFile(path)

        ; --- meta ---
        result := Map(
            "runId",         ini.Read("meta", "runId", runId),
            "profile",       ini.Read("meta", "profile", ""),
            "patch",         ini.Read("meta", "patch", ""),
            "firstTs",       ini.Read("meta", "firstTs", ""),
            "totalMs",       Integer(ini.Read("meta", "totalMs", "0") + 0),
            "deathCount",    Integer(ini.Read("meta", "deathCount", "0") + 0),
            "maxActReached", Integer(ini.Read("meta", "maxActReached", "0") + 0)
        )

        ; --- totals ---
        totals := Map()
        totalsMap := ini.ReadSectionAsMap("totals")
        for key, val in totalsMap
        {
            try
                totals[key] := Integer(val + 0)
            catch
                totals[key] := 0
        }
        result["totals"] := totals

        ; --- checkpoints (v17.15.1) ---
        ; Reconstroi Map<actNum, ms> da section [checkpoints]. Runs
        ; antigas sem essa section retornam Map vazio.
        checkpoints := Map()
        try
        {
            ckptMap := ini.ReadSectionAsMap("checkpoints")
            if IsObject(ckptMap)
            {
                for k, v in ckptMap
                {
                    keyStr := String(k)
                    if !RegExMatch(keyStr, "i)^Act(\d+)Ms$", &m)
                        continue
                    actNum := Integer(m[1] + 0)
                    if (actNum <= 0)
                        continue
                    try
                    {
                        ms := Integer(v + 0)
                        if (ms > 0)
                            checkpoints[actNum] := ms
                    }
                    catch
                        continue
                }
            }
        }
        result["actCheckpoints"] := checkpoints

        ; --- details ---
        details := []
        count := 0
        try
            count := Integer(ini.Read("details", "count", "0") + 0)
        catch
            count := 0
        i := 0
        while (i < count)
        {
            line := ini.Read("details", i, "")
            if (line != "")
            {
                parsed := RunHistoryRepository._ParseDetail(line)
                if IsObject(parsed)
                    details.Push(parsed)
            }
            i++
        }
        result["details"] := details

        return result
    }

    ; ------------------------------------------------------------
    ; LoadSummaries(maxN := -1) - carrega so meta+totals (sem details)
    ;
    ; Mais rapido pra listar runs no historico/grafico comparativo.
    ; Cada elemento eh um Map com mesmo formato do builder, mas com
    ; details := [] (vazio).
    ; ------------------------------------------------------------
    LoadSummaries(maxN := -1)
    {
        result := []
        ids := this.ListRunIds(maxN)
        for _, runId in ids
        {
            path := this._PathForRunId(runId)
            if !FileExist(path)
                continue
            ini := IniFile(path)

            summary := Map(
                "runId",         ini.Read("meta", "runId", runId),
                "profile",       ini.Read("meta", "profile", ""),
                "patch",         ini.Read("meta", "patch", ""),
                "firstTs",       ini.Read("meta", "firstTs", ""),
                "totalMs",       Integer(ini.Read("meta", "totalMs", "0") + 0),
                "deathCount",    Integer(ini.Read("meta", "deathCount", "0") + 0),
                "maxActReached", Integer(ini.Read("meta", "maxActReached", "0") + 0),
                "details",       []
            )

            totals := Map()
            totalsMap := ini.ReadSectionAsMap("totals")
            for key, val in totalsMap
            {
                try
                    totals[key] := Integer(val + 0)
                catch
                    totals[key] := 0
            }
            summary["totals"] := totals

            result.Push(summary)
        }
        return result
    }

    ; ------------------------------------------------------------
    ; Delete(runId) - apaga arquivo da run
    ; ------------------------------------------------------------
    Delete(runId)
    {
        path := this._PathForRunId(runId)
        if !FileExist(path)
            return false
        try
        {
            FileDelete(path)
            return true
        }
        catch as ex
        {
            ; v17.15 (Bug #8): registra falha pra diagnostico em vez
            ; de retornar false silencioso. Sem logger injetado.
            OutputDebug("RunHistoryRepository.Delete falhou (" runId "): " ex.Message)
            return false
        }
    }

    ; ------------------------------------------------------------
    ; Helpers privados
    ; ------------------------------------------------------------

    _PathForRunId(runId)
    {
        ; Sanitiza runId pra path seguro (deve ser timestamp formato
        ; "YYYYMMDD_HHMMSS" mas defensivo).
        safe := RegExReplace(String(runId), "[^A-Za-z0-9_\-]", "_")
        return this._dir "\" safe ".ini"
    }

    _EnsureDir()
    {
        if (this._dir != "" && !DirExist(this._dir))
        {
            try DirCreate(this._dir)
        }
    }

    ; Serializa um detail Map em string "category|label|ms|note|timestamp"
    static _SerializeDetail(detail)
    {
        cat   := detail.Has("category")  ? detail["category"]  : ""
        label := detail.Has("label")     ? detail["label"]     : ""
        ms    := detail.Has("ms")        ? detail["ms"]        : 0
        note  := detail.Has("note")      ? detail["note"]      : ""
        ts    := detail.Has("timestamp") ? detail["timestamp"] : ""

        sep := RunHistoryRepository.DETAIL_SEP
        return RunHistoryRepository._Escape(String(cat))   sep
             . RunHistoryRepository._Escape(String(label)) sep
             . String(ms)                                  sep
             . RunHistoryRepository._Escape(String(note))  sep
             . RunHistoryRepository._Escape(String(ts))
    }

    ; Inverso do _SerializeDetail. Retorna Map ou "".
    static _ParseDetail(line)
    {
        if (line = "")
            return ""
        sep := RunHistoryRepository.DETAIL_SEP
        parts := RunHistoryRepository._SplitEscaped(line, sep)
        if (parts.Length < 3)
            return ""

        cat   := parts.Has(1) ? parts[1] : ""
        label := parts.Has(2) ? parts[2] : ""
        ms    := 0
        try
            ms := Integer((parts.Has(3) ? parts[3] : "0") + 0)
        catch
            ms := 0
        note := parts.Has(4) ? parts[4] : ""
        ts   := parts.Has(5) ? parts[5] : ""

        return Map(
            "category",      cat,
            "categoryLabel", RunStatsPlotBuilder.CategoryLabel(cat),
            "label",         label,
            "ms",            ms,
            "note",          note,
            "timestamp",     ts
        )
    }

    ; Escape pra serializacao: troca | por \|, e \ por \\ (precisa
    ; ser nessa ordem na hora do escape, e invertida no parse).
    static _Escape(s)
    {
        s := StrReplace(s, "\", "\\")
        s := StrReplace(s, "|", "\|")
        return s
    }

    static _Unescape(s)
    {
        s := StrReplace(s, "\|", "|")
        s := StrReplace(s, "\\", "\")
        return s
    }

    ; Split que respeita escapes. Quebra em separadores nao escapados.
    static _SplitEscaped(line, sep)
    {
        out := []
        current := ""
        i := 1
        len := StrLen(line)
        while (i <= len)
        {
            ch := SubStr(line, i, 1)
            if (ch = "\" && i < len)
            {
                ; Escape: pega proximo char literal
                current .= ch . SubStr(line, i+1, 1)
                i += 2
                continue
            }
            if (ch = sep)
            {
                out.Push(RunHistoryRepository._Unescape(current))
                current := ""
                i++
                continue
            }
            current .= ch
            i++
        }
        out.Push(RunHistoryRepository._Unescape(current))
        return out
    }
}
