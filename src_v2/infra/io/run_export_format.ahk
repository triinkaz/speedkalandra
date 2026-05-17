; ============================================================
; RunExportFormat - run export/import schema (v0.1.0)
; ============================================================
;
; Pure class with no I/O. Converts between:
;   - internal buildResult (Map produced by RunStatsPlotBuilder.Build)
;   - JSON-ready structure (Map normalized for JsonFile.Stringify)
;
; PHILOSOPHY:
;   - Serialize/Deserialize are inverses (roundtrip preserves data)
;   - ValidateSchema is strict: rejects ambiguous input instead of
;     guessing (we prefer a clear error over silently corrupt data)
;   - schemaVersion exists so that future changes are detectable
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
;         "profile": "Default" (or "Anonymous" if anonymized),
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
;     "personalBests": {     // optional, present if options.includePbs
;       "runPbMs": 7100000,
;       "runPbRunId": "20260512_142345_012",
;       "runPbByAct": { "1": 1100000, ... },
;       "zonePbs": { "Mud Burrow": 175000, ... }
;     }
;   }
;
; CAVEATS:
;   - JSON object keys are always strings, so Map<int, int> for
;     actCheckpoints/runPbByAct/zonePbs is serialized as
;     Map<string, int>. Deserialize converts back.
;   - "categoryLabel" of details is NOT exported (it's derived).
;     Re-derived in Deserialize via RunStatsPlotBuilder.CategoryLabel.
;
; USAGE:
;   payload := RunExportFormat.Serialize([buildResult1, buildResult2],
;                                        pbData, Map("anonymized", true))
;   jsonStr := JsonFile.Stringify(payload)
;
;   ; ... on import:
;   parsed := JsonFile.Parse(jsonStr)
;   validation := RunExportFormat.ValidateSchema(parsed)
;   if !validation["valid"]
;       throw Error(validation["errors"][1])
;   decoded := RunExportFormat.Deserialize(parsed)
;   ; decoded["runs"] = Array<buildResult>
;   ; decoded["personalBests"] = Map or ""
;   ; decoded["meta"] = Map<exportedAt, exportedBy, anonymized>


class RunExportFormat
{
    static SCHEMA_VERSION := 1
    static ANON_PROFILE := "Anonymous"
    static EXPORTER_NAME := "SpeedKalandra"

    ; ============================================================
    ; Serialize(runs, pbData, options) -> JSON-ready Map
    ;
    ;   runs    : Array<buildResult> (Maps in the builder's format)
    ;   pbData  : Map with runPbMs/runPbRunId/runPbByAct/zonePbs,
    ;             or "" to omit
    ;   options : Map with:
    ;     "anonymized" : bool (default false) - if true, blank profile
    ;     "exporterVersion" : string (e.g. "v0.1.0") optional
    ;
    ; Throws TypeError on invalid input (runs not array, etc.).
    ; ============================================================
    static Serialize(runs, pbData := "", options := "")
    {
        if !IsObject(runs) || !(runs is Array)
            throw TypeError("RunExportFormat.Serialize: 'runs' must be an Array")

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
        ; v0.1.0: renamed from `run` to `runItem` (case-insensitive
        ; collision with the builtin function `Run` was triggering #Warn).
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
    ; Checks the parsed JSON structure BEFORE attempting to
    ; deserialize. Serious errors block import. Warnings are
    ; informational.
    ; ============================================================
    static ValidateSchema(parsed)
    {
        errors := []
        warnings := []

        if !IsObject(parsed) || !(parsed is Map)
        {
            errors.Push("Root is not a JSON object")
            return Map("valid", false, "errors", errors, "warnings", warnings)
        }

        ; schemaVersion (required)
        if !parsed.Has("schemaVersion")
        {
            errors.Push("'schemaVersion' field missing — not a valid SpeedKalandra export")
        }
        else
        {
            v := parsed["schemaVersion"]
            if !IsNumber(v)
            {
                errors.Push("schemaVersion must be a number, got: " v)
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

        ; runs (required)
        if !parsed.Has("runs")
        {
            errors.Push("'runs' field missing")
        }
        else if !IsObject(parsed["runs"]) || !(parsed["runs"] is Array)
        {
            errors.Push("'runs' field must be an array")
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

        ; personalBests (optional)
        if parsed.Has("personalBests")
        {
            pbErrors := RunExportFormat._ValidatePbs(parsed["personalBests"])
            for _, e in pbErrors
                errors.Push(e)
        }

        ; Warnings (do not block but inform)
        if !parsed.Has("exportedAt")
            warnings.Push("'exportedAt' field missing (informational)")
        if !parsed.Has("exportedBy")
            warnings.Push("'exportedBy' field missing (informational)")

        valid := errors.Length = 0
        return Map("valid", valid, "errors", errors, "warnings", warnings)
    }

    ; ============================================================
    ; Deserialize(parsed) -> Map{runs, personalBests, meta}
    ;
    ; Converts parsed JSON into the internal structure. ASSUMES that
    ; it has already passed ValidateSchema with valid=true. If it did
    ; not, it may throw an exception.
    ; ============================================================
    static Deserialize(parsed)
    {
        if !IsObject(parsed) || !(parsed is Map)
            throw TypeError("RunExportFormat.Deserialize: input must be a Map")

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
    ; Roundtrip test: build a fake buildResult -> Serialize -> JSON
    ; -> Parse -> ValidateSchema -> Deserialize -> compare.
    ;
    ; Returns details for a debug MsgBox.
    ; ============================================================
    static SelfTest()
    {
        details := []
        try
        {
            ; --- Create test buildResult ---
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

            ; --- Serialize ---
            payload := RunExportFormat.Serialize([originalRun], originalPbs,
                Map("anonymized", false, "exporterVersion", "v0.1.0-test"))
            details.Push("Serialize OK")

            ; --- Stringify to JSON ---
            jsonStr := JsonFile.Stringify(payload, 0)   ; minified for test
            details.Push("Stringify OK (" StrLen(jsonStr) " chars)")

            ; --- Parse back ---
            parsed := JsonFile.Parse(jsonStr)
            details.Push("Parse OK")

            ; --- Validate ---
            validation := RunExportFormat.ValidateSchema(parsed)
            if !validation["valid"]
            {
                msg := "ValidateSchema FAILED:"
                for _, e in validation["errors"]
                    msg .= "`n  - " e
                return Map("passed", false, "message", msg, "details", details)
            }
            details.Push("ValidateSchema OK (errors=0, warnings=" validation["warnings"].Length ")")

            ; --- Deserialize ---
            decoded := RunExportFormat.Deserialize(parsed)
            details.Push("Deserialize OK")

            ; --- Compare run fields ---
            if (decoded["runs"].Length != 1)
                return Map("passed", false,
                    "message", "Expected 1 run, got " decoded["runs"].Length,
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
                        "message", "Field '" field "': expected='" expected
                                 . "' actual='" actual "'",
                        "details", details)
                }
            }
            details.Push("Basic fields: 7/7 OK")

            ; --- Compare totals ---
            for k, v in originalRun["totals"]
            {
                if !decodedRun["totals"].Has(k) || decodedRun["totals"][k] != v
                {
                    return Map("passed", false,
                        "message", "totals['" k "']: expected=" v
                                 . " actual=" (decodedRun["totals"].Has(k)
                                            ? decodedRun["totals"][k] : "missing"),
                        "details", details)
                }
            }
            details.Push("Totals: " originalRun["totals"].Count "/"
                . originalRun["totals"].Count " OK")

            ; --- Compare actCheckpoints ---
            for k, v in originalRun["actCheckpoints"]
            {
                if !decodedRun["actCheckpoints"].Has(k) || decodedRun["actCheckpoints"][k] != v
                {
                    return Map("passed", false,
                        "message", "actCheckpoints[" k "]: expected=" v
                                 . " actual=" (decodedRun["actCheckpoints"].Has(k)
                                            ? decodedRun["actCheckpoints"][k] : "missing"),
                        "details", details)
                }
            }
            details.Push("ActCheckpoints: " originalRun["actCheckpoints"].Count "/"
                . originalRun["actCheckpoints"].Count " OK")

            ; --- Compare details (array) ---
            if (decodedRun["details"].Length != originalRun["details"].Length)
            {
                return Map("passed", false,
                    "message", "details.Length: expected=" originalRun["details"].Length
                             . " actual=" decodedRun["details"].Length,
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
                            "message", "details[" i "]." field ": expected='"
                                     . expectedDetail[field] "' actual='"
                                     . actualDetail[field] "'",
                            "details", details)
                    }
                }
            }
            details.Push("Details: " originalRun["details"].Length " rows, all fields OK")

            ; --- Compare PBs ---
            decodedPbs := decoded["personalBests"]
            if (decodedPbs["runPbMs"] != originalPbs["runPbMs"])
            {
                return Map("passed", false,
                    "message", "PB runPbMs: expected=" originalPbs["runPbMs"]
                             . " actual=" decodedPbs["runPbMs"],
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
            details.Push("PBs: 4 categories OK")

            ; --- Anonymize test ---
            anonPayload := RunExportFormat.Serialize([originalRun], "",
                Map("anonymized", true))
            anonRun := anonPayload["runs"][1]
            if (anonRun["profile"] != RunExportFormat.ANON_PROFILE)
            {
                return Map("passed", false,
                    "message", "Anonymize: profile should be '"
                             . RunExportFormat.ANON_PROFILE
                             . "', became '" anonRun["profile"] "'",
                    "details", details)
            }
            details.Push("Anonymize: OK")

            ; --- All passed ---
            return Map(
                "passed", true,
                "message", "All " details.Length " sub-tests passed",
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
    ; Private helpers
    ; ============================================================

    static _NowIso()
    {
        ; "YYYY-MM-DD HH:MM:SS" (ISO-like, no Z because it's local time)
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

        ; actCheckpoints: Map<int, int> -> Map<str, int> (JSON keys are strings)
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

        ; zonePbs: Map<str, int> -> same format
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
            errors.Push("runs[" idx "]: is not an object")
            return errors
        }
        if !run.Has("runId") || String(run["runId"]) = ""
            errors.Push("runs[" idx "]: 'runId' missing or empty")
        if !run.Has("totalMs")
            errors.Push("runs[" idx "]: 'totalMs' missing")
        else if !IsNumber(run["totalMs"]) || Integer(run["totalMs"]) <= 0
            errors.Push("runs[" idx "]: 'totalMs' must be a positive integer")

        ; Optional fields: type-check if present
        if run.Has("totals") && (!IsObject(run["totals"]) || !(run["totals"] is Map))
            errors.Push("runs[" idx "]: 'totals' must be an object")
        if run.Has("actCheckpoints") && (!IsObject(run["actCheckpoints"]) || !(run["actCheckpoints"] is Map))
            errors.Push("runs[" idx "]: 'actCheckpoints' must be an object")
        if run.Has("details") && (!IsObject(run["details"]) || !(run["details"] is Array))
            errors.Push("runs[" idx "]: 'details' must be an array")

        return errors
    }

    static _ValidatePbs(pbs)
    {
        errors := []
        if !IsObject(pbs) || !(pbs is Map)
        {
            errors.Push("personalBests: is not an object")
            return errors
        }
        if pbs.Has("runPbMs") && (!IsNumber(pbs["runPbMs"]) || Integer(pbs["runPbMs"]) < 0)
            errors.Push("personalBests.runPbMs: must be an integer >= 0")
        if pbs.Has("runPbByAct") && (!IsObject(pbs["runPbByAct"]) || !(pbs["runPbByAct"] is Map))
            errors.Push("personalBests.runPbByAct: must be an object")
        if pbs.Has("zonePbs") && (!IsObject(pbs["zonePbs"]) || !(pbs["zonePbs"] is Map))
            errors.Push("personalBests.zonePbs: must be an object")
        return errors
    }

    ; Derives categoryLabel without needing to instantiate RunStatsPlotBuilder.
    ; Replicates the RunStatsPlotBuilder.CategoryLabel logic but defensively
    ; (if the builder changes the mapping, update here too).
    ;
    ; v0.1.0: dynamic lookup via %"..."% to avoid #Warn when the
    ; builder is not in scope (e.g. isolated RunExportFormat tests
    ; without including the builder). The outer try/catch covers the
    ; case where the lookup fails (UnsetError) or the builder changed
    ; its signature.
    static _SafeCategoryLabel(cat)
    {
        try
        {
            builderClass := %"RunStatsPlotBuilder"%
            return builderClass.CategoryLabel(cat)
        }
        catch
        {
            ; Fallback if RunStatsPlotBuilder is not available
            ; (e.g. SelfTest running before the builder, or in
            ; isolated tests without the builder on the #Include path).
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
