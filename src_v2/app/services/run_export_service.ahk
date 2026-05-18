; RunExportService — orchestrates exporting runs to JSON. Given a
; list of runIds, an output path, and options, it loads each run
; through RunHistoryRepository, serializes via RunExportFormat, and
; writes through JsonFile (which itself uses AtomicWriter).
;
; The service has no UI; ExportOptionsDialog drives the picker.
; The service has no policy on which runs to export; the caller
; decides.
;
; Dependencies:
;   bus          — EventBus, used to publish Evt.RunsExported on success
;   runHistory   — RunHistoryRepository, for Load(runId)
;   personalBest — PersonalBestService, optional (only consulted when
;                  options.includePbs is true)
;
; ExportResult shape:
;   Map{ success: bool, path: string, runsExported: int,
;        errors: Array<string> }
;
; Error semantics:
;   - One run fails to Load → recorded in errors and skipped; the
;     export continues with the others (partial success path).
;   - Zero runs load successfully → success=false and no file written.
;   - Write itself fails → success=false with a descriptive error.


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

    ; Loads each run, optionally collects PBs, serializes, writes.
    ; options accepts:
    ;   "anonymized" (default false) — blank profile name in payload
    ;   "includePbs" (default true)  — include personalBests block
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

        ; Load each run.
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
                ; Local `run` collides case-insensitively with the
                ; built-in `Run` function; use `runItem`.
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

        ; Collect PBs if requested.
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
                ; Doesn't block the export — logs and proceeds without PBs.
                errors.Push("Failed to collect PBs (export will proceed without them): " ex.Message)
                pbData := ""
            }
        }

        ; Ensure output directory.
        try
        {
            RunExportService._EnsureDirFor(outputPath)
        }
        catch as ex
        {
            errors.Push("Failed to create directory: " ex.Message)
            return this._FailResult(outputPath, errors)
        }

        ; Serialize.
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

        ; Write through JsonFile (which uses AtomicWriter).
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

        ; Publish success.
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

    ; Default output path: exports/runs-YYYYMMDD_HHMMSS.json
    static GetDefaultExportPath()
    {
        ts := FormatTime(A_Now, "yyyyMMdd_HHmmss")
        return RunExportService.DEFAULT_EXPORT_DIR "\runs-" ts ".json"
    }

    ; Creates the default exports/ directory if missing.
    static EnsureExportDir()
    {
        dir := RunExportService.DEFAULT_EXPORT_DIR
        if !DirExist(dir)
        {
            try DirCreate(dir)
        }
        return dir
    }

    ; ---- Private helpers ----

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
