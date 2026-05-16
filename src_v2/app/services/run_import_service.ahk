; ============================================================
; RunImportService - import de runs de JSON (v0.1.0)
; ============================================================
;
; Padrao Preview/Execute: caller chama Preview pra ver o que VAI
; acontecer (sem mutar nada), inspeciona, e so entao chama Execute
; com a estrategia de PBs escolhida.
;
; CONFLICT RESOLUTION:
;   - runId nao existe localmente -> "new" (importa direto)
;   - runId existe + conteudo identico (signature match) -> "identical"
;     (skip, no-op pra idempotencia em re-imports)
;   - runId existe + conteudo diferente -> "rename"
;     (importa com sufixo "_imported", ou "_imported_2", _3... se necessario)
;
; Signature de identidade: runId + totalMs + deathCount + maxActReached
; + details.Length. Suficiente pra detectar "isso eh a mesma run"
; sem comparar campo-a-campo (que daria falsos negativos por
; mudancas trivias tipo categoryLabel re-derivado).
;
; PB STRATEGIES:
;   "keep"    : nao toca em PBs (default, nao-destrutivo)
;   "rebuild" : chama PersonalBestService.RebuildFromHistory com
;               historico ATUAL (incluindo runs recem-importadas)
;   "replace" : substitui PBs locais pelos do arquivo de import
;               (destrutivo - user precisa ter escolhido conscientemente)
;
; DEPS:
;   bus          : EventBus (pra publicar Evt.RunsImported)
;   runHistory   : RunHistoryRepository (Load p/ conflict check, Save p/ import)
;   personalBest : PersonalBestService (opcional, pra strategies rebuild/replace)
;
; ImportPreview:
;   Map{
;     success     : bool,
;     path        : string,
;     errors[]    : Array<string>,
;     warnings[]  : Array<string>,
;     meta        : Map{exportedAt, exportedBy, anonymized},
;     toImport    : Array<Map{run, runId, totalMs, conflict, finalRunId}>,
;     importedPbs : Map ou "" (PB data do arquivo, pra display + replace strategy),
;     summary     : Map{total, new, identical, rename}
;   }
;
; ImportResult:
;   Map{
;     success  : bool,
;     imported : int (runs efetivamente escritas),
;     renamed  : int (subset de imported que renomeou por conflito),
;     skipped  : int (identical no-ops),
;     errors[] : Array<string>,
;     pbAction : string (descricao do que aconteceu com PBs)
;   }
;
; CONSTRUCAO:
;   svc := RunImportService(bus, runHistory, personalBest)


class RunImportService
{
    static MAX_RENAME_ATTEMPTS := 10

    _bus          := ""
    _runHistory   := ""
    _personalBest := ""

    __New(bus, runHistory, personalBest := "")
    {
        if !(bus is EventBus)
            throw TypeError("RunImportService: 'bus' deve ser EventBus")
        if !(runHistory is RunHistoryRepository)
            throw TypeError("RunImportService: 'runHistory' deve ser RunHistoryRepository")
        if (personalBest != "" && !(personalBest is PersonalBestService))
            throw TypeError("RunImportService: 'personalBest' deve ser PersonalBestService ou vazio")

        this._bus          := bus
        this._runHistory   := runHistory
        this._personalBest := personalBest
    }

    ; ============================================================
    ; Preview(inputPath) -> ImportPreview
    ;
    ; Le arquivo, valida schema, deserializa, calcula conflict
    ; resolution. NAO muta nada em disco. Resultado eh consumido
    ; pelo Execute (ou descartado se user cancelar).
    ; ============================================================
    Preview(inputPath)
    {
        result := Map(
            "success",     false,
            "path",        String(inputPath),
            "errors",      [],
            "warnings",    [],
            "meta",        Map(),
            "toImport",    [],
            "importedPbs", "",
            "summary",     Map("total", 0, "new", 0, "identical", 0, "rename", 0)
        )

        if (Trim(String(inputPath)) = "")
        {
            result["errors"].Push("Empty input path")
            return result
        }
        if !FileExist(inputPath)
        {
            result["errors"].Push("File not found: " inputPath)
            return result
        }

        ; --- Read ---
        jsonStr := ""
        try
            jsonStr := FileRead(inputPath, "UTF-8")
        catch as ex
        {
            result["errors"].Push("Failed to read file: " ex.Message)
            return result
        }
        if (Trim(jsonStr) = "")
        {
            result["errors"].Push("File is empty")
            return result
        }

        ; --- Parse JSON ---
        parsed := ""
        try
            parsed := JsonFile.Parse(jsonStr)
        catch as ex
        {
            result["errors"].Push("JSON parse error: " ex.Message)
            return result
        }

        ; --- Validate schema ---
        validation := RunExportFormat.ValidateSchema(parsed)
        if !validation["valid"]
        {
            for _, e in validation["errors"]
                result["errors"].Push(e)
            return result
        }
        for _, w in validation["warnings"]
            result["warnings"].Push(w)

        ; --- Deserialize ---
        decoded := ""
        try
            decoded := RunExportFormat.Deserialize(parsed)
        catch as ex
        {
            result["errors"].Push("Deserialize error: " ex.Message)
            return result
        }

        result["meta"] := decoded["meta"]
        if IsObject(decoded["personalBests"])
            result["importedPbs"] := decoded["personalBests"]

        ; --- Conflict resolution per run ---
        ; v0.1.0 Fase 5: trackear finalRunIds ja reservados pra detectar
        ; duplicatas DENTRO do mesmo arquivo (ex: file editado a mao com
        ; 2 runs de mesmo runId, ou bug que duplicou entries). Sem isso,
        ; o segundo Save sobrescreveria o primeiro no disco.
        seenFinalIds := Map()

        for _, runItem in decoded["runs"]
        {
            if !IsObject(runItem)
                continue

            currentRunId := runItem.Has("runId") ? String(runItem["runId"]) : ""
            if (currentRunId = "")
            {
                result["warnings"].Push("Run with empty runId in file - skipped")
                continue
            }

            entry := Map(
                "run",         runItem,
                "runId",       currentRunId,
                "totalMs",     runItem.Has("totalMs") ? Integer(runItem["totalMs"]) : 0,
                "conflict",    "new",
                "finalRunId",  currentRunId
            )

            existing := ""
            try existing := this._runHistory.Load(currentRunId)

            existsOnDisk := IsObject(existing)
            duplicateInFile := seenFinalIds.Has(currentRunId)

            if (existsOnDisk && RunImportService._RunsAreIdentical(runItem, existing))
            {
                ; Conteudo identico ao do disco -> skip silencioso (idempotente).
                ; NAO adiciona a seenFinalIds pois nao sera escrito.
                entry["conflict"] := "identical"
            }
            else if (existsOnDisk || duplicateInFile)
            {
                ; Conflito real: ou com disco (conteudo diferente) ou com
                ; outro entry do mesmo arquivo (mesmo runId).
                renamed := this._GenerateRenamedId(currentRunId, seenFinalIds)
                if (renamed = "")
                {
                    result["warnings"].Push("Could not allocate unique renamed ID for "
                        . currentRunId " - will be skipped")
                    continue
                }
                entry["conflict"] := "rename"
                entry["finalRunId"] := renamed
                seenFinalIds[renamed] := true
            }
            else
            {
                ; Genuinamente novo (sem conflito de disco nem de arquivo).
                seenFinalIds[currentRunId] := true
            }

            result["toImport"].Push(entry)
        }

        ; --- Summary ---
        for _, entry in result["toImport"]
        {
            result["summary"]["total"] += 1
            key := entry["conflict"]
            result["summary"][key] := result["summary"][key] + 1
        }

        if (result["toImport"].Length = 0)
            result["warnings"].Push("No runs to import after validation")

        result["success"] := true
        return result
    }

    ; ============================================================
    ; Execute(preview, pbStrategy) -> ImportResult
    ;
    ; Aplica as mudancas a partir de um preview previamente computado.
    ; NAO re-le o arquivo \u2014 usa os buildResults capturados em memoria
    ; pelo preview (resistente a mudancas mid-operation).
    ;
    ; pbStrategy in {"keep", "rebuild", "replace"}. Invalido = erro.
    ; ============================================================
    Execute(preview, pbStrategy := "keep")
    {
        result := Map(
            "success",  false,
            "imported", 0,
            "renamed",  0,
            "skipped",  0,
            "errors",   [],
            "pbAction", "none"
        )

        if !IsObject(preview) || !preview.Has("success") || !preview["success"]
        {
            result["errors"].Push("Invalid or unsuccessful preview")
            return result
        }
        if !RegExMatch(pbStrategy, "^(keep|rebuild|replace)$")
        {
            result["errors"].Push("Invalid pbStrategy: '" pbStrategy "' (expected keep|rebuild|replace)")
            return result
        }

        ; --- Apply imports ---
        for _, entry in preview["toImport"]
        {
            conflict := entry["conflict"]

            if (conflict = "identical")
            {
                result["skipped"] += 1
                continue
            }

            ; "new" ou "rename" - escreve com finalRunId
            runItem := entry["run"]
            runItem["runId"] := entry["finalRunId"]

            saved := false
            try saved := this._runHistory.Save(runItem)
            catch as ex
            {
                result["errors"].Push("Save failed for " entry["finalRunId"] ": " ex.Message)
                continue
            }

            if saved
            {
                result["imported"] += 1
                if (conflict = "rename")
                    result["renamed"] += 1
            }
            else
            {
                result["errors"].Push("Save returned false for runId=" entry["finalRunId"]
                    . " (totalMs=" entry["totalMs"] ")")
            }
        }

        ; --- Apply PB strategy ---
        if (pbStrategy = "keep")
        {
            result["pbAction"] := "kept current (no change)"
        }
        else if (pbStrategy = "rebuild")
        {
            if !IsObject(this._personalBest)
            {
                result["pbAction"] := "rebuild skipped (no PB service)"
            }
            else
            {
                try
                {
                    allRuns := []
                    for _, rid in this._runHistory.ListRunIds()
                    {
                        br := this._runHistory.Load(rid)
                        if IsObject(br)
                            allRuns.Push(br)
                    }
                    this._personalBest.RebuildFromHistory(allRuns)
                    result["pbAction"] := "rebuilt from " allRuns.Length " runs in history"
                }
                catch as ex
                {
                    result["errors"].Push("PB rebuild failed: " ex.Message)
                    result["pbAction"] := "rebuild failed"
                }
            }
        }
        else if (pbStrategy = "replace")
        {
            if !IsObject(preview["importedPbs"])
            {
                result["errors"].Push("No PBs in import file to replace with")
                result["pbAction"] := "replace failed (no source data)"
            }
            else if !IsObject(this._personalBest)
            {
                result["pbAction"] := "replace skipped (no PB service)"
            }
            else
            {
                try
                {
                    this._personalBest.LoadFromExternal(preview["importedPbs"])
                    result["pbAction"] := "replaced with imported PBs"
                }
                catch as ex
                {
                    result["errors"].Push("PB replace failed: " ex.Message)
                    result["pbAction"] := "replace failed"
                }
            }
        }

        ; --- Publish event ---
        try this._bus.Publish(Events.RunsImported, Map(
            "path",     preview["path"],
            "imported", result["imported"],
            "renamed",  result["renamed"],
            "skipped",  result["skipped"]
        ))

        ; Success se nao houve erro OU se ao menos importou alguma coisa.
        ; Erros parciais nao bloqueiam mas sao reportados.
        result["success"] := (result["errors"].Length = 0) || (result["imported"] > 0)
        return result
    }

    ; ============================================================
    ; Helpers privados
    ; ============================================================

    ; Compara duas buildResults por signature minima.
    ; Suficiente pra detectar "isso eh a mesma run" sem ser fragil
    ; a diferencas triviais (categoryLabel re-derivado, etc).
    static _RunsAreIdentical(runA, runB)
    {
        if !IsObject(runA) || !IsObject(runB)
            return false
        if (String(runA["runId"]) != String(runB["runId"]))
            return false

        aMs := runA.Has("totalMs") ? Integer(runA["totalMs"]) : 0
        bMs := runB.Has("totalMs") ? Integer(runB["totalMs"]) : 0
        if (aMs != bMs)
            return false

        aDeaths := runA.Has("deathCount") ? Integer(runA["deathCount"]) : 0
        bDeaths := runB.Has("deathCount") ? Integer(runB["deathCount"]) : 0
        if (aDeaths != bDeaths)
            return false

        aMax := runA.Has("maxActReached") ? Integer(runA["maxActReached"]) : 0
        bMax := runB.Has("maxActReached") ? Integer(runB["maxActReached"]) : 0
        if (aMax != bMax)
            return false

        aDetailsLen := (runA.Has("details") && IsObject(runA["details"]))
            ? runA["details"].Length : 0
        bDetailsLen := (runB.Has("details") && IsObject(runB["details"]))
            ? runB["details"].Length : 0
        if (aDetailsLen != bDetailsLen)
            return false

        return true
    }

    ; Aloca um runId unico baseado em "<original>_imported".
    ; Se ja existir (em disco OU no set `alreadyClaimed`), tenta
    ; "_imported_2", "_imported_3"... ate MAX_RENAME_ATTEMPTS.
    ; Retorna "" se nao conseguir (acidente improvavel).
    ;
    ; alreadyClaimed: Map<runId, true> opcional. Usado pelo Preview
    ; pra evitar colisao com runs DENTRO do mesmo arquivo (duplicatas).
    _GenerateRenamedId(originalId, alreadyClaimed := "")
    {
        claimed := IsObject(alreadyClaimed) ? alreadyClaimed : Map()

        candidate := originalId "_imported"
        if !this._IsRunIdInUse(candidate, claimed)
            return candidate

        i := 2
        while (i <= RunImportService.MAX_RENAME_ATTEMPTS)
        {
            candidate := originalId "_imported_" i
            if !this._IsRunIdInUse(candidate, claimed)
                return candidate
            i += 1
        }
        return ""
    }

    ; Helper: runId esta "em uso" se ja existe em disco OU se foi
    ; pre-reservado pelo Preview (set claimedIds).
    _IsRunIdInUse(id, claimedIds)
    {
        if IsObject(claimedIds) && claimedIds.Has(id)
            return true
        existing := ""
        try existing := this._runHistory.Load(id)
        return IsObject(existing)
    }
}
