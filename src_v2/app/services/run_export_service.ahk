; ============================================================
; RunExportService - orquestra export de runs pra JSON (v0.1.0)
; ============================================================
;
; Responsabilidade unica: dado uma lista de runIds + caminho de
; saida + opcoes, carrega as runs do RunHistoryRepository, monta
; o payload via RunExportFormat, e escreve em disco via JsonFile.
;
; NAO faz UI \u2014 isso eh trabalho do ExportOptionsDialog. NAO escolhe
; quais runs exportar \u2014 caller decide.
;
; DEPS:
;   bus          : EventBus (pra publicar Evt.RunsExported no sucesso)
;   runHistory   : RunHistoryRepository (pra Load(runId))
;   personalBest : PersonalBestService (opcional, pra includePbs)
;
; ExportResult:
;   Map{
;     success      : bool,
;     path         : string (caminho final do arquivo),
;     runsExported : int (quantas runs efetivamente foram escritas),
;     errors       : Array<string> (problemas, possivelmente parciais)
;   }
;
; SEMANTICA DE ERRO:
;   - Se UMA run falha em Load, eh registrada em errors e pulada,
;     mas o export continua com as outras (partial success).
;   - Se NENHUMA run carrega (todas falharam ou lista vazia), retorna
;     success=false sem escrever o arquivo.
;   - Se o write em si falha (disco, permissao), retorna success=false
;     com erro descritivo.
;
; CONSTRUCAO:
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
            throw TypeError("RunExportService: 'bus' deve ser EventBus")
        if !(runHistory is RunHistoryRepository)
            throw TypeError("RunExportService: 'runHistory' deve ser RunHistoryRepository")
        if (personalBest != "" && !(personalBest is PersonalBestService))
            throw TypeError("RunExportService: 'personalBest' deve ser PersonalBestService ou vazio")

        this._bus          := bus
        this._runHistory   := runHistory
        this._personalBest := personalBest
    }

    ; ============================================================
    ; Export(runIds, outputPath, options) -> ExportResult
    ;
    ; runIds      : Array<string> de runIds a exportar
    ; outputPath  : caminho absoluto do .json
    ; options     : Map com:
    ;   "anonymized" : bool (default false) - blank profile name
    ;   "includePbs" : bool (default true)  - inclui bloco personalBests
    ; ============================================================
    Export(runIds, outputPath, options := "")
    {
        errors := []

        ; --- Validacao de input ---
        if !IsObject(runIds) || !(runIds is Array)
        {
            errors.Push("runIds deve ser Array")
            return this._FailResult(outputPath, errors)
        }
        if (runIds.Length = 0)
        {
            errors.Push("Nenhuma run para exportar")
            return this._FailResult(outputPath, errors)
        }
        outputPath := String(outputPath)
        if (Trim(outputPath) = "")
        {
            errors.Push("Caminho de saida vazio")
            return this._FailResult(outputPath, errors)
        }

        opts := IsObject(options) ? options : Map()
        anonymize := opts.Has("anonymized") && opts["anonymized"]
        includePbs := !opts.Has("includePbs") || opts["includePbs"]   ; default true

        ; --- Carrega cada run ---
        runs := []
        for _, rid in runIds
        {
            ridStr := String(rid)
            if (ridStr = "")
            {
                errors.Push("runId vazio na lista")
                continue
            }
            try
            {
                ; v0.1.1: `run` local colide com builtin `Run` (case-insensitive).
                ; Usar `runItem`.
                runItem := this._runHistory.Load(ridStr)
                if !IsObject(runItem)
                {
                    errors.Push("Run " ridStr ": nao encontrada no historico")
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
            errors.Push("Nenhuma run carregou com sucesso")
            return this._FailResult(outputPath, errors)
        }

        ; --- Coleta PBs se requisitado ---
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
                ; Nao bloqueia o export \u2014 so loga e segue sem PBs
                errors.Push("Falha ao coletar PBs (export continuara sem eles): " ex.Message)
                pbData := ""
            }
        }

        ; --- Garante diretorio de saida ---
        try
        {
            RunExportService._EnsureDirFor(outputPath)
        }
        catch as ex
        {
            errors.Push("Falha ao criar diretorio: " ex.Message)
            return this._FailResult(outputPath, errors)
        }

        ; --- Serializa via RunExportFormat ---
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
            errors.Push("Falha na serializacao: " ex.Message)
            return this._FailResult(outputPath, errors)
        }

        ; --- Escreve em disco (via JsonFile que usa AtomicWriter) ---
        try
        {
            jf := JsonFile(outputPath)
            jf.Write(payload, 2)   ; indent=2 (pretty)
        }
        catch as ex
        {
            errors.Push("Falha ao escrever arquivo: " ex.Message)
            return this._FailResult(outputPath, errors)
        }

        ; --- Publica evento de sucesso ---
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
    ; GetDefaultExportPath() - gera path default no exports/ dir
    ;
    ; Formato: exports/runs-YYYYMMDD_HHMMSS.json
    ; ============================================================
    static GetDefaultExportPath()
    {
        ts := FormatTime(A_Now, "yyyyMMdd_HHmmss")
        return RunExportService.DEFAULT_EXPORT_DIR "\runs-" ts ".json"
    }

    ; ============================================================
    ; EnsureExportDir() - cria diretorio default se nao existir
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
    ; Helpers privados
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

    ; Cria diretorio pai de `filePath` se nao existir.
    static _EnsureDirFor(filePath)
    {
        SplitPath(filePath, , &dir)
        if (dir != "" && !DirExist(dir))
            DirCreate(dir)
    }
}
