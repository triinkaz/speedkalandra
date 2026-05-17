; ============================================================
; RunExportService - orchestrates export of runs to JSON (v0.1.0)
; ============================================================
;
; Single responsibility: given a list of runIds + output path +
; options, load the runs from RunHistoryRepository, build the
; payload via RunExportFormat, and write to disk via JsonFile.
;
; Does NOT do UI — that is ExportOptionsDialog's job. Does NOT pick
; which runs to export — the caller decides.
;
; DEPS:
;   bus          : EventBus (to publish Evt.RunsExported on success)
;   runHistory   : RunHistoryRepository (for Load(runId))
;   personalBest : PersonalBestService (optional, for includePbs)
;
; ExportResult:
;   Map{
;     success      : bool,
;     path         : string (final file path),
;     runsExported : int (how many runs were effectively written),
;     errors       : Array<string> (problems, possibly partial)
;   }
;
; ERROR SEMANTICS:
;   - If ONE run fails to Load, it is recorded in errors and skipped,
;     but the export continues with the others (partial success).
;   - If NO run loads (all failed or empty list), returns
;     success=false without writing the file.
;   - If the write itself fails (disk, permission), returns
;     success=false with a descriptive error.
;
; CONSTRUCTION:
;   svc := RunExportService(bus, runHistory, personalBest)


class RunExportService
{
    static DEFAULT_EXPORT_DIR := A_ScriptDir "\exports"

    _bus          := ""
    _runHistory   := ""
    _personalBest := ""

    __New(bus, runHistory, personalBest := "")
    {
        if !(bus is EventBus)
            throw TypeError("RunExportService: 'bus' must be EventBus")
        if !(runHistory is RunHistoryRepository)
            throw TypeError("RunExportService: 'runHistory' must be RunHistoryRepository")
        if (personalBest != "" && !(personalBest is PersonalBestService))
            throw TypeError("RunExportService: 'personalBest' must be PersonalBestService or empty")

        this._bus          := bus
        this._runHistory   := runHistory
        this._personalBest := personalBest
    }

    ; ============================================================
    ; Export(runIds, outputPath, options) -> ExportResult
    ;
    ; runIds      : Array<string> of runIds to export
    ; outputPath  : absolute path of the .json
    ; options     : Map with:
    ;   "anonymized" : bool (default false) - blank profile name
    ;   "includePbs" : bool (default true)  - includes personalBests block
    ; ============================================================
    Export(runIds, outputPath, options := "")
    {
        errors := []

        ; --- Input validation ---
        if !IsObject(runIds) || !(runIds is Array)
        {
            errors.Push("runIds must be Array")
            return this._FailResult(outputPath, errors)
        }
        if (runIds.Length = 0)
        {
            errors.Push("No runs to export")
            return this._FailResult(outputPath, errors)
        }
        outputPath := String(outputPath)
        if (Trim(outputPath) = "")
        {
            errors.Push("Empty output path")
            return this._FailResult(outputPath, errors)
        }

        opts := IsObject(options) ? options : Map()
        anonymize := opts.Has("anonymized") && opts["anonymized"]
        includePbs := !opts.Has("includePbs") || opts["includePbs"]   ; default true

        ; --- Load each run ---
        runs := []
        for _, rid in runIds
        {
            ridStr := String(rid)
            if (ridStr = "")
            {
                errors.Push("Empty runId in list")
                continue
            }
            try
            {
                ; v0.1.1: local `run` collides with builtin `Run` (case-insensitive).
                ; Use `runItem`.
                runItem := this._runHistory.Load(ridStr)
                if !IsObject(runItem)
                {
                    errors.Push("Run " ridStr ": not found in history")
                    continue
                }
                runs.Push(runItem)
            }
            catch as ex
            {
                errors.Push("Run " ridStr ": " ex.Message)
            }
        }

        if (runs.Length = 0)
        {
            errors.Push("No run loaded successfully")
            return this._FailResult(outputPath, errors)
        }

        ; --- Collect PBs if requested ---
        pbData := ""
        if includePbs && IsObject(this._personalBest)
        {
            try
            {
                pbData := Map(
                    "runPbMs",    this._personalBest.GetRunPbMs(),
                    "runPbRunId", this._personalBest.GetRunPbRunId(),
                    "runPbByAct", this._personalBest.GetAllRunPbsByAct(),
                    "zonePbs",    this._personalBest.GetAllZonePbs()
                )
            }
            catch as ex
            {
                ; Doesn't block the export — just logs and proceeds without PBs
                errors.Push("Failed to collect PBs (export will proceed without them): " ex.Message)
                pbData := ""
            }
        }

        ; --- Ensure output directory ---
        try
        {
            RunExportService._EnsureDirFor(outputPath)
        }
        catch as ex
        {
            errors.Push("Failed to create directory: " ex.Message)
            return this._FailResult(outputPath, errors)
        }

        ; --- Serialize via RunExportFormat ---
        payload := ""
        try
        {
            payload := RunExportFormat.Serialize(runs, pbData, Map(
                "anonymized", anonymize,
                "exporterVersion", Version.STRING
            ))
        }
        catch as ex
        {
            errors.Push("Serialization failed: " ex.Message)
            return this._FailResult(outputPath, errors)
        }

        ; --- Write to disk (via JsonFile which uses AtomicWriter) ---
        try
        {
            jf := JsonFile(outputPath)
            jf.Write(payload, 2)   ; indent=2 (pretty)
        }
        catch as ex
        {
            errors.Push("Failed to write file: " ex.Message)
            return this._FailResult(outputPath, errors)
        }

        ; --- Publish success event ---
        try this._bus.Publish(Events.RunsExported, Map(
            "path", outputPath,
            "count", runs.Length
        ))

        return Map(
            "success",      true,
            "path",         outputPath,
            "runsExported", runs.Length,
            "errors",       errors
        )
    }

    ; ============================================================
    ; GetDefaultExportPath() - generates default path in exports/ dir
    ;
    ; Format: exports/runs-YYYYMMDD_HHMMSS.json
    ; ============================================================
    static GetDefaultExportPath()
    {
        ts := FormatTime(A_Now, "yyyyMMdd_HHmmss")
        return RunExportService.DEFAULT_EXPORT_DIR "\runs-" ts ".json"
    }

    ; ============================================================
    ; EnsureExportDir() - creates default directory if missing
    ; ============================================================
    static EnsureExportDir()
    {
        dir := RunExportService.DEFAULT_EXPORT_DIR
        if !DirExist(dir)
        {
            try DirCreate(dir)
        }
        return dir
    }

    ; ============================================================
    ; Private helpers
    ; ============================================================

    _FailResult(path, errors)
    {
        return Map(
            "success",      false,
            "path",         path,
            "runsExported", 0,
            "errors",       errors
        )
    }

    ; Creates the parent directory of `filePath` if missing.
    static _EnsureDirFor(filePath)
    {
        SplitPath(filePath, , &dir)
        if (dir != "" && !DirExist(dir))
            DirCreate(dir)
    }
}
