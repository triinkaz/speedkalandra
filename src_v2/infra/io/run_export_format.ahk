; ============================================================
; RunExportFormat - schema de export/import de runs (v0.1.0)
; ============================================================
;
; Classe pura sem I/O. Converte entre:
;   - buildResult interno (Map produzido por RunStatsPlotBuilder.Build)
;   - estrutura JSON-ready (Map normalizado p/ JsonFile.Stringify)
;
; FILOSOFIA:
;   - Serialize/Deserialize sao inversos (roundtrip preserva dados)
;   - ValidateSchema eh estrito: rejeita input ambiguo ao inves de
;     adivinhar (preferimos um erro claro do que silenciar corrupcao)
;   - schemaVersion existe pra que mudancas futuras sejam detectaveis
;
; SCHEMA v1:
;   {
;     "schemaVersion": 1,
;     "exportedAt": "ISO timestamp",
;     "exportedBy": "SpeedKalandra vX.Y.Z",
;     "anonymized": true|false,
;     "runs": [
;       {
;         "runId": "20260515_103045_873",
;         "profile": "Default" (ou "Anonymous" se anonimizado),
;         "patch": "Unknown",
;         "firstTs": "2026-05-15 10:30:45",
;         "totalMs": 7665873,
;         "deathCount": 3,
;         "maxActReached": 5,
;         "totals": { "mapa": 5800000, ... },
;         "actCheckpoints": { "1": 1200000, "2": 2600000, ... },
;         "details": [
;           { "category": "mapa", "label": "Mud Burrow", "ms": 184321,
;             "note": "Act 1", "timestamp": "" },
;           ...
;         ]
;       },
;       ...
;     ],
;     "personalBests": {     // opcional, presente se options.includePbs
;       "runPbMs": 7100000,
;       "runPbRunId": "20260512_142345_012",
;       "runPbByAct": { "1": 1100000, ... },
;       "zonePbs": { "Mud Burrow": 175000, ... }
;     }
;   }
;
; CAVEATS:
;   - JSON object keys sao sempre strings, entao Map<int, int> de
;     actCheckpoints/runPbByAct/zonePbs eh serializado como
;     Map<string, int>. Deserialize converte de volta.
;   - "categoryLabel" de details NAO eh exportado (eh derivado).
;     Re-derivado no Deserialize via RunStatsPlotBuilder.CategoryLabel.
;
; USO:
;   payload := RunExportFormat.Serialize([buildResult1, buildResult2],
;                                        pbData, Map("anonymized", true))
;   jsonStr := JsonFile.Stringify(payload)
;
;   ; ... na importacao:
;   parsed := JsonFile.Parse(jsonStr)
;   validation := RunExportFormat.ValidateSchema(parsed)
;   if !validation["valid"]
;       throw Error(validation["errors"][1])
;   decoded := RunExportFormat.Deserialize(parsed)
;   ; decoded["runs"] = Array<buildResult>
;   ; decoded["personalBests"] = Map ou ""
;   ; decoded["meta"] = Map<exportedAt, exportedBy, anonymized>


class RunExportFormat
{
    static SCHEMA_VERSION := 1
    static ANON_PROFILE := "Anonymous"
    static EXPORTER_NAME := "SpeedKalandra"

    ; ============================================================
    ; Serialize(runs, pbData, options) -> Map JSON-ready
    ;
    ;   runs    : Array<buildResult> (Maps no formato do builder)
    ;   pbData  : Map com runPbMs/runPbRunId/runPbByAct/zonePbs,
    ;             ou "" pra omitir
    ;   options : Map com:
    ;     "anonymized" : bool (default false) - se true, blank profile
    ;     "exporterVersion" : string (ex: "v0.1.0") opcional
    ;
    ; Throws TypeError em input invalido (runs nao array, etc).
    ; ============================================================
    static Serialize(runs, pbData := "", options := "")
    {
        if !IsObject(runs) || !(runs is Array)
            throw TypeError("RunExportFormat.Serialize: 'runs' deve ser Array")

        opts := IsObject(options) ? options : Map()
        anonymize := opts.Has("anonymized") && opts["anonymized"]
        exporterVersion := opts.Has("exporterVersion") ? String(opts["exporterVersion"]) : "unknown"

        out := Map(
            "schemaVersion", RunExportFormat.SCHEMA_VERSION,
            "exportedAt", RunExportFormat._NowIso(),
            "exportedBy", RunExportFormat.EXPORTER_NAME " " exporterVersion,
            "anonymized", anonymize ? JsonBool(true) : JsonBool(false)
        )

        serializedRuns := []
        ; v0.1.0: renomeado de `run` pra `runItem` (case-insensitive
        ; collision com builtin function `Run` disparava #Warn).
        for _, runItem in runs
        {
            if !IsObject(runItem)
                continue
            serializedRuns.Push(RunExportFormat._SerializeRun(runItem, anonymize))
        }
        out["runs"] := serializedRuns

        if IsObject(pbData)
            out["personalBests"] := RunExportFormat._SerializePbs(pbData)

        return out
    }

    ; ============================================================
    ; ValidateSchema(parsed) -> Map{valid, errors[], warnings[]}
    ;
    ; Verifica estrutura do JSON parseado ANTES de tentar
    ; deserializar. Erros graves bloqueiam import. Warnings sao
    ; informativos.
    ; ============================================================
    static ValidateSchema(parsed)
    {
        errors := []
        warnings := []

        if !IsObject(parsed) || !(parsed is Map)
        {
            errors.Push("Root nao eh um JSON object")
            return Map("valid", false, "errors", errors, "warnings", warnings)
        }

        ; schemaVersion (obrigatorio)
        if !parsed.Has("schemaVersion")
        {
            errors.Push("Campo 'schemaVersion' ausente — not a valid SpeedKalandra export")
        }
        else
        {
            v := parsed["schemaVersion"]
            if !IsNumber(v)
            {
                errors.Push("schemaVersion deve ser numero, achou: " v)
            }
            else
            {
                vInt := Integer(v)
                expected := RunExportFormat.SCHEMA_VERSION
                if (vInt < expected)
                {
                    errors.Push("File schema version " vInt
                        . " is older than supported (expected: " expected
                        . "). This export was created by an older SpeedKalandra version"
                        . " and is not compatible with this one.")
                }
                else if (vInt > expected)
                {
                    errors.Push("File schema version " vInt
                        . " is newer than supported (expected: " expected
                        . "). Please update SpeedKalandra to the latest version.")
                }
            }
        }

        ; runs (obrigatorio)
        if !parsed.Has("runs")
        {
            errors.Push("Campo 'runs' ausente")
        }
        else if !IsObject(parsed["runs"]) || !(parsed["runs"] is Array)
        {
            errors.Push("Campo 'runs' deve ser array")
        }
        else
        {
            for i, runItem in parsed["runs"]
            {
                runErrors := RunExportFormat._ValidateRun(runItem, i)
                for _, e in runErrors
                    errors.Push(e)
            }
        }

        ; personalBests (opcional)
        if parsed.Has("personalBests")
        {
            pbErrors := RunExportFormat._ValidatePbs(parsed["personalBests"])
            for _, e in pbErrors
                errors.Push(e)
        }

        ; Warnings (nao bloqueia mas informa)
        if !parsed.Has("exportedAt")
            warnings.Push("Campo 'exportedAt' ausente (informativo)")
        if !parsed.Has("exportedBy")
            warnings.Push("Campo 'exportedBy' ausente (informativo)")

        valid := errors.Length = 0
        return Map("valid", valid, "errors", errors, "warnings", warnings)
    }

    ; ============================================================
    ; Deserialize(parsed) -> Map{runs, personalBests, meta}
    ;
    ; Converte JSON parseado em estrutura interna. ASSUME que ja
    ; passou por ValidateSchema com valid=true. Se nao passou, pode
    ; lancar exception.
    ; ============================================================
    static Deserialize(parsed)
    {
        if !IsObject(parsed) || !(parsed is Map)
            throw TypeError("RunExportFormat.Deserialize: input deve ser Map")

        runs := []
        if parsed.Has("runs") && IsObject(parsed["runs"])
        {
            for _, raw in parsed["runs"]
            {
                if !IsObject(raw)
                    continue
                runs.Push(RunExportFormat._DeserializeRun(raw))
            }
        }

        pbs := ""
        if parsed.Has("personalBests") && IsObject(parsed["personalBests"])
            pbs := RunExportFormat._DeserializePbs(parsed["personalBests"])

        meta := Map(
            "exportedAt", parsed.Has("exportedAt") ? String(parsed["exportedAt"]) : "",
            "exportedBy", parsed.Has("exportedBy") ? String(parsed["exportedBy"]) : "",
            "anonymized", parsed.Has("anonymized") && parsed["anonymized"] ? true : false
        )

        return Map(
            "runs", runs,
            "personalBests", pbs,
            "meta", meta
        )
    }

    ; ============================================================
    ; SelfTest() -> Map{passed, message, details[]}
    ;
    ; Roundtrip test: monta buildResult fake -> Serialize -> JSON
    ; -> Parse -> ValidateSchema -> Deserialize -> compara.
    ;
    ; Retorna detalhes pra MsgBox de debug.
    ; ============================================================
    static SelfTest()
    {
        details := []
        try
        {
            ; --- Cria buildResult de teste ---
            originalRun := Map(
                "runId", "20260515_103045_873",
                "profile", "TestProfile",
                "patch", "0.2.0",
                "firstTs", "2026-05-15 10:30:45",
                "totalMs", 7665873,
                "deathCount", 3,
                "maxActReached", 5,
                "totals", Map("mapa", 5800000, "loading", 800000, "cidade", 1065873),
                "actCheckpoints", Map(1, 1200000, 2, 2600000, 3, 4200000, 4, 5800000, 5, 7665873),
                "details", [
                    Map("category", "mapa", "label", "Mud Burrow", "ms", 184321,
                        "note", "Act 1", "timestamp", "2026-05-15 10:32:13"),
                    Map("category", "cidade", "label", "The Hooded One",
                        "ms", 23456, "note", "Act 1", "timestamp", "")
                ]
            )
            originalPbs := Map(
                "runPbMs", 7100000,
                "runPbRunId", "20260512_142345_012",
                "runPbByAct", Map(1, 1100000, 5, 7100000),
                "zonePbs", Map("Mud Burrow", 175000, "Clearfell", 220000)
            )

            ; --- Serializa ---
            payload := RunExportFormat.Serialize([originalRun], originalPbs,
                Map("anonymized", false, "exporterVersion", "v0.1.0-test"))
            details.Push("Serialize OK")

            ; --- Stringify pra JSON ---
            jsonStr := JsonFile.Stringify(payload, 0)   ; minified pra teste
            details.Push("Stringify OK (" StrLen(jsonStr) " chars)")

            ; --- Parse de volta ---
            parsed := JsonFile.Parse(jsonStr)
            details.Push("Parse OK")

            ; --- Valida ---
            validation := RunExportFormat.ValidateSchema(parsed)
            if !validation["valid"]
            {
                msg := "ValidateSchema FALHOU:"
                for _, e in validation["errors"]
                    msg .= "`n  - " e
                return Map("passed", false, "message", msg, "details", details)
            }
            details.Push("ValidateSchema OK (errors=0, warnings=" validation["warnings"].Length ")")

            ; --- Deserialize ---
            decoded := RunExportFormat.Deserialize(parsed)
            details.Push("Deserialize OK")

            ; --- Compara campos da run ---
            if (decoded["runs"].Length != 1)
                return Map("passed", false,
                    "message", "Esperava 1 run, achou " decoded["runs"].Length,
                    "details", details)
            decodedRun := decoded["runs"][1]

            checks := [
                ["runId",         originalRun["runId"],         decodedRun["runId"]],
                ["profile",       originalRun["profile"],       decodedRun["profile"]],
                ["patch",         originalRun["patch"],         decodedRun["patch"]],
                ["firstTs",       originalRun["firstTs"],       decodedRun["firstTs"]],
                ["totalMs",       originalRun["totalMs"],       decodedRun["totalMs"]],
                ["deathCount",    originalRun["deathCount"],    decodedRun["deathCount"]],
                ["maxActReached", originalRun["maxActReached"], decodedRun["maxActReached"]]
            ]
            for _, check in checks
            {
                field := check[1], expected := check[2], actual := check[3]
                if (expected != actual)
                {
                    return Map("passed", false,
                        "message", "Campo '" field "': esperado='" expected
                                 . "' atual='" actual "'",
                        "details", details)
                }
            }
            details.Push("Campos basicos: 7/7 OK")

            ; --- Compara totals ---
            for k, v in originalRun["totals"]
            {
                if !decodedRun["totals"].Has(k) || decodedRun["totals"][k] != v
                {
                    return Map("passed", false,
                        "message", "totals['" k "']: esperado=" v
                                 . " atual=" (decodedRun["totals"].Has(k)
                                            ? decodedRun["totals"][k] : "ausente"),
                        "details", details)
                }
            }
            details.Push("Totals: " originalRun["totals"].Count "/"
                . originalRun["totals"].Count " OK")

            ; --- Compara actCheckpoints ---
            for k, v in originalRun["actCheckpoints"]
            {
                if !decodedRun["actCheckpoints"].Has(k) || decodedRun["actCheckpoints"][k] != v
                {
                    return Map("passed", false,
                        "message", "actCheckpoints[" k "]: esperado=" v
                                 . " atual=" (decodedRun["actCheckpoints"].Has(k)
                                            ? decodedRun["actCheckpoints"][k] : "ausente"),
                        "details", details)
                }
            }
            details.Push("ActCheckpoints: " originalRun["actCheckpoints"].Count "/"
                . originalRun["actCheckpoints"].Count " OK")

            ; --- Compara details (array) ---
            if (decodedRun["details"].Length != originalRun["details"].Length)
            {
                return Map("passed", false,
                    "message", "details.Length: esperado=" originalRun["details"].Length
                             . " atual=" decodedRun["details"].Length,
                    "details", details)
            }
            for i, expectedDetail in originalRun["details"]
            {
                actualDetail := decodedRun["details"][i]
                for field in ["category", "label", "ms", "note", "timestamp"]
                {
                    if (expectedDetail[field] != actualDetail[field])
                    {
                        return Map("passed", false,
                            "message", "details[" i "]." field ": esperado='"
                                     . expectedDetail[field] "' atual='"
                                     . actualDetail[field] "'",
                            "details", details)
                    }
                }
            }
            details.Push("Details: " originalRun["details"].Length " rows, todos campos OK")

            ; --- Compara PBs ---
            decodedPbs := decoded["personalBests"]
            if (decodedPbs["runPbMs"] != originalPbs["runPbMs"])
            {
                return Map("passed", false,
                    "message", "PB runPbMs: esperado=" originalPbs["runPbMs"]
                             . " atual=" decodedPbs["runPbMs"],
                    "details", details)
            }
            if (decodedPbs["runPbRunId"] != originalPbs["runPbRunId"])
            {
                return Map("passed", false,
                    "message", "PB runPbRunId mismatch",
                    "details", details)
            }
            for k, v in originalPbs["runPbByAct"]
            {
                if !decodedPbs["runPbByAct"].Has(k) || decodedPbs["runPbByAct"][k] != v
                {
                    return Map("passed", false,
                        "message", "PB runPbByAct[" k "] mismatch",
                        "details", details)
                }
            }
            for k, v in originalPbs["zonePbs"]
            {
                if !decodedPbs["zonePbs"].Has(k) || decodedPbs["zonePbs"][k] != v
                {
                    return Map("passed", false,
                        "message", "PB zonePbs['" k "'] mismatch",
                        "details", details)
                }
            }
            details.Push("PBs: 4 categorias OK")

            ; --- Teste de anonymize ---
            anonPayload := RunExportFormat.Serialize([originalRun], "",
                Map("anonymized", true))
            anonRun := anonPayload["runs"][1]
            if (anonRun["profile"] != RunExportFormat.ANON_PROFILE)
            {
                return Map("passed", false,
                    "message", "Anonymize: profile deveria ser '"
                             . RunExportFormat.ANON_PROFILE
                             . "', virou '" anonRun["profile"] "'",
                    "details", details)
            }
            details.Push("Anonymize: OK")

            ; --- Tudo passou ---
            return Map(
                "passed", true,
                "message", "Todos os " details.Length " sub-testes passaram",
                "details", details
            )
        }
        catch as ex
        {
            return Map(
                "passed", false,
                "message", "Exception: " ex.Message
                         . " (What=" (ex.HasOwnProp("What") ? ex.What : "?")
                         . ", Line=" (ex.HasOwnProp("Line") ? ex.Line : "?") ")",
                "details", details
            )
        }
    }

    ; ============================================================
    ; Helpers privados
    ; ============================================================

    static _NowIso()
    {
        ; "YYYY-MM-DD HH:MM:SS" (ISO-like, sem Z porque eh local time)
        return FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
    }

    static _SerializeRun(run, anonymize)
    {
        out := Map(
            "runId",         run.Has("runId")         ? String(run["runId"])         : "",
            "profile",       anonymize ? RunExportFormat.ANON_PROFILE
                                       : (run.Has("profile") ? String(run["profile"]) : ""),
            "patch",         run.Has("patch")         ? String(run["patch"])         : "",
            "firstTs",       run.Has("firstTs")       ? String(run["firstTs"])       : "",
            "totalMs",       run.Has("totalMs")       ? Integer(run["totalMs"])      : 0,
            "deathCount",    run.Has("deathCount")    ? Integer(run["deathCount"])   : 0,
            "maxActReached", run.Has("maxActReached") ? Integer(run["maxActReached"]): 0
        )

        ; totals: Map<str, int>
        totals := Map()
        if run.Has("totals") && IsObject(run["totals"])
        {
            for k, v in run["totals"]
                totals[String(k)] := IsNumber(v) ? Integer(v) : 0
        }
        out["totals"] := totals

        ; actCheckpoints: Map<int, int> -> Map<str, int> (JSON keys sao str)
        ckpts := Map()
        if run.Has("actCheckpoints") && IsObject(run["actCheckpoints"])
        {
            for k, v in run["actCheckpoints"]
            {
                if !IsNumber(k) || Integer(k) <= 0
                    continue
                if !IsNumber(v) || Integer(v) <= 0
                    continue
                ckpts[String(Integer(k))] := Integer(v)
            }
        }
        out["actCheckpoints"] := ckpts

        ; details: Array<Map>
        outDetails := []
        if run.Has("details") && IsObject(run["details"])
        {
            for _, d in run["details"]
            {
                if !IsObject(d)
                    continue
                outDetails.Push(Map(
                    "category",  d.Has("category")  ? String(d["category"])  : "",
                    "label",     d.Has("label")     ? String(d["label"])     : "",
                    "ms",        d.Has("ms")        ? Integer(d["ms"])       : 0,
                    "note",      d.Has("note")      ? String(d["note"])      : "",
                    "timestamp", d.Has("timestamp") ? String(d["timestamp"]) : ""
                ))
            }
        }
        out["details"] := outDetails

        return out
    }

    static _SerializePbs(pbData)
    {
        out := Map()
        if pbData.Has("runPbMs") && IsNumber(pbData["runPbMs"])
            out["runPbMs"] := Integer(pbData["runPbMs"])
        else
            out["runPbMs"] := 0

        out["runPbRunId"] := pbData.Has("runPbRunId") ? String(pbData["runPbRunId"]) : ""

        ; runPbByAct: Map<int, int> -> Map<str, int>
        ba := Map()
        if pbData.Has("runPbByAct") && IsObject(pbData["runPbByAct"])
        {
            for k, v in pbData["runPbByAct"]
            {
                if !IsNumber(k) || Integer(k) <= 0
                    continue
                if !IsNumber(v) || Integer(v) <= 0
                    continue
                ba[String(Integer(k))] := Integer(v)
            }
        }
        out["runPbByAct"] := ba

        ; zonePbs: Map<str, int> -> mesmo formato
        zp := Map()
        if pbData.Has("zonePbs") && IsObject(pbData["zonePbs"])
        {
            for k, v in pbData["zonePbs"]
            {
                if !IsNumber(v) || Integer(v) <= 0
                    continue
                zp[String(k)] := Integer(v)
            }
        }
        out["zonePbs"] := zp

        return out
    }

    static _DeserializeRun(raw)
    {
        result := Map(
            "runId",         raw.Has("runId")         ? String(raw["runId"])         : "",
            "profile",       raw.Has("profile")       ? String(raw["profile"])       : "",
            "patch",         raw.Has("patch")         ? String(raw["patch"])         : "",
            "firstTs",       raw.Has("firstTs")       ? String(raw["firstTs"])       : "",
            "totalMs",       raw.Has("totalMs")       ? Integer(raw["totalMs"])      : 0,
            "deathCount",    raw.Has("deathCount")    ? Integer(raw["deathCount"])   : 0,
            "maxActReached", raw.Has("maxActReached") ? Integer(raw["maxActReached"]): 0
        )

        ; totals (str -> int)
        totals := Map()
        if raw.Has("totals") && IsObject(raw["totals"])
        {
            for k, v in raw["totals"]
                totals[String(k)] := IsNumber(v) ? Integer(v) : 0
        }
        result["totals"] := totals

        ; actCheckpoints (JSON keys str -> int)
        ckpts := Map()
        if raw.Has("actCheckpoints") && IsObject(raw["actCheckpoints"])
        {
            for k, v in raw["actCheckpoints"]
            {
                actNum := 0
                try actNum := Integer(String(k) + 0)
                if (actNum > 0 && IsNumber(v) && Integer(v) > 0)
                    ckpts[actNum] := Integer(v)
            }
        }
        result["actCheckpoints"] := ckpts

        ; details
        details := []
        if raw.Has("details") && IsObject(raw["details"])
        {
            for _, d in raw["details"]
            {
                if !IsObject(d)
                    continue
                cat := d.Has("category") ? String(d["category"]) : ""
                details.Push(Map(
                    "category",      cat,
                    "categoryLabel", RunExportFormat._SafeCategoryLabel(cat),
                    "label",         d.Has("label")     ? String(d["label"])     : "",
                    "ms",            d.Has("ms")        ? Integer(d["ms"])       : 0,
                    "note",          d.Has("note")      ? String(d["note"])      : "",
                    "timestamp",     d.Has("timestamp") ? String(d["timestamp"]) : ""
                ))
            }
        }
        result["details"] := details

        return result
    }

    static _DeserializePbs(raw)
    {
        result := Map(
            "runPbMs",    raw.Has("runPbMs")    ? Integer(raw["runPbMs"])    : 0,
            "runPbRunId", raw.Has("runPbRunId") ? String(raw["runPbRunId"])  : ""
        )

        ba := Map()
        if raw.Has("runPbByAct") && IsObject(raw["runPbByAct"])
        {
            for k, v in raw["runPbByAct"]
            {
                actNum := 0
                try actNum := Integer(String(k) + 0)
                if (actNum > 0 && IsNumber(v) && Integer(v) > 0)
                    ba[actNum] := Integer(v)
            }
        }
        result["runPbByAct"] := ba

        zp := Map()
        if raw.Has("zonePbs") && IsObject(raw["zonePbs"])
        {
            for k, v in raw["zonePbs"]
            {
                if !IsNumber(v) || Integer(v) <= 0
                    continue
                zp[String(k)] := Integer(v)
            }
        }
        result["zonePbs"] := zp

        return result
    }

    static _ValidateRun(run, idx)
    {
        errors := []
        if !IsObject(run) || !(run is Map)
        {
            errors.Push("runs[" idx "]: nao eh um object")
            return errors
        }
        if !run.Has("runId") || String(run["runId"]) = ""
            errors.Push("runs[" idx "]: 'runId' ausente ou vazio")
        if !run.Has("totalMs")
            errors.Push("runs[" idx "]: 'totalMs' ausente")
        else if !IsNumber(run["totalMs"]) || Integer(run["totalMs"]) <= 0
            errors.Push("runs[" idx "]: 'totalMs' deve ser inteiro positivo")

        ; Optional fields: type-check se presentes
        if run.Has("totals") && (!IsObject(run["totals"]) || !(run["totals"] is Map))
            errors.Push("runs[" idx "]: 'totals' deve ser object")
        if run.Has("actCheckpoints") && (!IsObject(run["actCheckpoints"]) || !(run["actCheckpoints"] is Map))
            errors.Push("runs[" idx "]: 'actCheckpoints' deve ser object")
        if run.Has("details") && (!IsObject(run["details"]) || !(run["details"] is Array))
            errors.Push("runs[" idx "]: 'details' deve ser array")

        return errors
    }

    static _ValidatePbs(pbs)
    {
        errors := []
        if !IsObject(pbs) || !(pbs is Map)
        {
            errors.Push("personalBests: nao eh um object")
            return errors
        }
        if pbs.Has("runPbMs") && (!IsNumber(pbs["runPbMs"]) || Integer(pbs["runPbMs"]) < 0)
            errors.Push("personalBests.runPbMs: deve ser inteiro >= 0")
        if pbs.Has("runPbByAct") && (!IsObject(pbs["runPbByAct"]) || !(pbs["runPbByAct"] is Map))
            errors.Push("personalBests.runPbByAct: deve ser object")
        if pbs.Has("zonePbs") && (!IsObject(pbs["zonePbs"]) || !(pbs["zonePbs"] is Map))
            errors.Push("personalBests.zonePbs: deve ser object")
        return errors
    }

    ; Deriva categoryLabel sem precisar instanciar RunStatsPlotBuilder.
    ; Replica a logica de RunStatsPlotBuilder.CategoryLabel mas defensiva
    ; (se o builder mudar o mapping, atualizar aqui tambem).
    ;
    ; v0.1.0: lookup dinamico via %"..."% pra evitar #Warn quando o
    ; builder nao esta no escopo (ex: testes isolados do RunExportFormat
    ; sem incluir o builder). O try/catch externo cobre o caso em que
    ; o lookup falha (UnsetError) ou o builder mudou de assinatura.
    static _SafeCategoryLabel(cat)
    {
        try
        {
            builderClass := %"RunStatsPlotBuilder"%
            return builderClass.CategoryLabel(cat)
        }
        catch
        {
            ; Fallback se RunStatsPlotBuilder nao estiver disponivel
            ; (ex: SelfTest rodando antes do builder, ou em testes
            ; isolados sem o builder no #Include path).
            switch String(cat)
            {
                case "mapa":    return "Map"
                case "cidade":  return "Town"
                case "loading": return "Loading"
                case "morte":   return "Deaths"
                default:        return String(cat)
            }
        }
    }
}
