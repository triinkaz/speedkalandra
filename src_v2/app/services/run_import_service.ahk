; RunImportService — imports runs from a JSON exported earlier by
; RunExportService.
;
; Preview/Execute pattern: the caller invokes Preview to see what
; WILL happen (no mutation), inspects the result, then calls Execute
; with the chosen PB strategy. Execute does not re-read the file —
; it uses the buildResults captured in memory by Preview, so changes
; on disk between the two calls don't surprise the user.
;
; Conflict resolution per run:
;   runId absent locally               → "new" (write directly)
;   runId present + content identical  → "identical" (skip, idempotent)
;   runId present + content different  → "rename" (write as
;                                       "_imported", "_imported_2"...)
;
; Identity signature: runId + totalMs + deathCount + maxActReached
; + details.Length. Enough to detect "this is the same run" without
; comparing field-by-field, which would give false negatives over
; trivial differences like a re-derived categoryLabel.
;
; PB strategies (chosen at Execute time):
;   "keep"    — don't touch local PBs (default, non-destructive).
;   "rebuild" — call PersonalBestService.RebuildFromHistory with the
;               current history (which now includes freshly imported
;               runs).
;   "replace" — replace local PBs with those from the import file.
;               Destructive; the user must have chosen consciously.
;
; Dependencies:
;   bus          — EventBus, publishes Evt.RunsImported on Execute
;   runHistory   — RunHistoryRepository, for Load (conflict check)
;                  and Save
;   personalBest — PersonalBestService, optional (only consulted for
;                  rebuild/replace strategies)
;
; ImportPreview shape:
;   Map{ success, path, errors[], warnings[], meta,
;        toImport: Array<{run, runId, totalMs, conflict, finalRunId}>,
;        importedPbs: Map | "",
;        summary: {total, new, identical, rename} }
;
; ImportResult shape:
;   Map{ success, imported, renamed, skipped, errors[], pbAction }


class RunImportService
{
    static MAX_RENAME_ATTEMPTS := 10

    _bus          := ""
    _runHistory   := ""
    _personalBest := ""

    __New(bus, runHistory, personalBest := "")
    {
        if !(bus is EventBus)
            throw TypeError("RunImportService: 'bus' must be EventBus")
        if !(runHistory is RunHistoryRepository)
            throw TypeError("RunImportService: 'runHistory' must be RunHistoryRepository")
        if (personalBest != "" && !(personalBest is PersonalBestService))
            throw TypeError("RunImportService: 'personalBest' must be PersonalBestService or empty")

        this._bus          := bus
        this._runHistory   := runHistory
        this._personalBest := personalBest
    }

    ; Reads the file, validates the schema, deserializes, and works
    ; out the per-run conflict resolution. Does NOT touch disk — the
    ; result is consumed by Execute (or thrown away if the user cancels).
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

        ; Read.
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

        ; Parse.
        parsed := ""
        try
            parsed := JsonFile.Parse(jsonStr)
        catch as ex
        {
            result["errors"].Push("JSON parse error: " ex.Message)
            return result
        }

        ; Validate schema.
        validation := RunExportFormat.ValidateSchema(parsed)
        if !validation["valid"]
        {
            for _, e in validation["errors"]
                result["errors"].Push(e)
            return result
        }
        for _, w in validation["warnings"]
            result["warnings"].Push(w)

        ; Deserialize.
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

        ; Per-run conflict resolution.
        ; Track every finalRunId we've reserved during this pass so
        ; duplicates WITHIN the same file (hand-edited file with two
        ; runs of the same runId, or a buggy export) don't end up
        ; overwriting each other on Save.
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
                ; Content identical to disk -> silent skip (idempotent).
                ; Does NOT add to seenFinalIds because it won't be written.
                entry["conflict"] := "identical"
            }
            else if (existsOnDisk || duplicateInFile)
            {
                ; Real conflict: either with disk (different content) or
                ; with another entry in the same file (same runId).
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
                ; Genuinely new (no disk conflict, no file conflict).
                seenFinalIds[currentRunId] := true
            }

            result["toImport"].Push(entry)
        }

        ; Summary.
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

    ; Applies the changes from a previously computed preview. Uses
    ; the buildResults captured in memory by Preview — does NOT re-read
    ; the file, so concurrent changes between Preview and Execute
    ; don't surprise the user.
    ;
    ; pbStrategy must be one of "keep", "rebuild", "replace".
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

        ; Apply each imported run.
        for _, entry in preview["toImport"]
        {
            conflict := entry["conflict"]

            if (conflict = "identical")
            {
                result["skipped"] += 1
                continue
            }

            ; "new" or "rename" — write with finalRunId.
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

        ; Apply PB strategy.
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

        ; Publish event.
        try this._bus.Publish(Events.RunsImported, Map(
            "path",     preview["path"],
            "imported", result["imported"],
            "renamed",  result["renamed"],
            "skipped",  result["skipped"]
        ))

        ; Success when there were no errors OR at least something
        ; was imported. Partial failures don't block; they are
        ; reported in `errors`.
        result["success"] := (result["errors"].Length = 0) || (result["imported"] > 0)
        return result
    }

    ; ---- Private helpers ----

    ; Compares two buildResults by a minimal signature — enough to
    ; detect "this is the same run" without being fragile to trivial
    ; differences like a re-derived categoryLabel.
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

    ; Allocates a unique runId based on "<original>_imported". If
    ; it's already taken (on disk OR in the alreadyClaimed set), tries
    ; "_imported_2", "_imported_3", ... up to MAX_RENAME_ATTEMPTS.
    ; Returns "" if nothing fits in that range — an unlikely accident.
    ;
    ; alreadyClaimed lets Preview reserve finalRunIds during its pass
    ; so two runs in the same file with the same runId can't collide
    ; with each other.
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

    ; A runId is "in use" when it already exists on disk OR was
    ; pre-reserved during the current Preview pass.
    _IsRunIdInUse(id, claimedIds)
    {
        if IsObject(claimedIds) && claimedIds.Has(id)
            return true
        existing := ""
        try existing := this._runHistory.Load(id)
        return IsObject(existing)
    }
}
