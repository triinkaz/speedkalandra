; ============================================================
; RunHistoryRepository - persists finalized runs to disk
; ============================================================
;
; SCOPE (v17.6):
;   Each finalized run is saved as `data/runs/{runId}.ini`. The
;   content is the "buildResult" produced by RunStatsPlotBuilder.Build
;   — i.e. already aggregated into totals + details — so that the
;   dialog can open historical runs without having to re-run the builder.
;
; FORMAT (1 INI file per run):
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
;   0=mapa|Cemetery of the Eternals|220000|Act 1|
;   1=mapa|Clearfell|156000|Act 1|
;   2=cidade|The Ardura Caravan|95000|Act 2|
;   ...
;
; NOTE: runs saved in old versions may have `category=boss` in
; details/totals. The loader reads without complaining; the current
; builder no longer has the boss category in SegmentDefinitions, so
; the plot ignores it.
;
; DETAILS SERIALIZATION:
;   Each detail becomes a line "category|label|ms|note|timestamp".
;   Pipe `|` is the separator (should not appear in PoE2 zone names;
;   if it does, escaped as `\|`).
;
;   Decision: no JSON to avoid a custom parser. INI already has a
;   stable reader in the project and the format is enough for runs.
;
; QUERY API:
;   ListRunIds(maxN := -1)         -> Array<string> sorted desc by mtime
;   Load(runId)                    -> Map (same format as builder) | ""
;   LoadSummaries(maxN := -1)      -> Array<Map> with only meta+totals (fast)
;   Save(buildResult)              -> bool
;   Delete(runId)                  -> bool
;   GetDir()                       -> string
;
; CONSTRUCTION:
;   repo := RunHistoryRepository(A_ScriptDir "\data\runs")


class RunHistoryRepository
{
    _dir := ""

    static DETAIL_SEP := "|"

    __New(dir)
    {
        if (Trim(String(dir)) = "")
            throw ValueError("RunHistoryRepository: 'dir' is required")
        this._dir := dir
        this._EnsureDir()
    }

    GetDir() => this._dir

    ; ------------------------------------------------------------
    ; Save - persists buildResult to data/runs/{runId}.ini
    ;
    ; buildResult is the output of RunStatsPlotBuilder.Build (Map with
    ; runId, profile, patch, firstTs, totals, details, deathCount,
    ; totalMs).
    ;
    ; A run with no runId or with totalMs < 1000ms (1s) is ignored —
    ; avoids garbage from runs cancelled immediately after start.
    ; ------------------------------------------------------------
    Save(buildResult)
    {
        if !IsObject(buildResult)
            return false

        ; v0.1.0: renamed from `runId` to `currentRunId` (case-insensitive
        ; collision with the domain class `RunId` was triggering #Warn).
        currentRunId := buildResult.Has("runId") ? String(buildResult["runId"]) : ""
        if (currentRunId = "")
            return false

        totalMs := buildResult.Has("totalMs") ? buildResult["totalMs"] : 0
        if (totalMs < 1000)
            return false

        path := this._PathForRunId(currentRunId)
        ini := IniFile(path)

        ; --- [meta] ---
        ini.Write(currentRunId, "meta", "runId")
        ini.Write(buildResult.Has("profile") ? buildResult["profile"] : "", "meta", "profile")
        ini.Write(buildResult.Has("patch")   ? buildResult["patch"]   : "", "meta", "patch")
        ini.Write(buildResult.Has("firstTs") ? buildResult["firstTs"] : "", "meta", "firstTs")
        ini.Write(totalMs, "meta", "totalMs")
        ini.Write(buildResult.Has("deathCount") ? buildResult["deathCount"] : 0, "meta", "deathCount")
        ini.Write(buildResult.Has("maxActReached") ? buildResult["maxActReached"] : 0, "meta", "maxActReached")

        ; --- [totals] ---
        ; Clear the section first to ensure consistency (in case a
        ; category existed before and not now — unlikely but defensive).
        ini.Delete("totals", "")
        totals := buildResult.Has("totals") ? buildResult["totals"] : Map()
        if IsObject(totals)
        {
            for key, ms in totals
                ini.Write(ms, "totals", key)
        }

        ; --- [checkpoints] (v17.15.1) ---
        ; Total RUN time in ms when each act ended. Map<actNum, ms>.
        ; Persisted here so PersonalBestService.RebuildFromHistory
        ; can rebuild per-act PBs after a run delete. Runs saved
        ; before this field simply come without the section
        ; (Load returns empty Map(), rebuild ignores it).
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
    ; ListRunIds(maxN := -1) - lists available runIds
    ;
    ; Sorted by modification time DESC (most recent first).
    ; If maxN > 0, limits to that count.
    ;
    ; BUGFIX v17.12: Uses SplitPath instead of SubStr(runId, -3) to
    ; strip the extension. The original bug tried to compare
    ; SubStr(name, -3) (= "ini", no dot) to ".ini" (= 4 chars), which
    ; never matched. Result: runId kept ".ini" in the name, and
    ; _PathForRunId sanitized the dot to "_", looking up
    ; "data\runs\NAME_ini.ini" — a non-existent file. LoadSummaries
    ; returned an empty list.
    ; ------------------------------------------------------------
    ListRunIds(maxN := -1)
    {
        result := []
        if !DirExist(this._dir)
            return result

        ; Collect {runId, mtime} to sort later
        candidates := []
        loop files this._dir "\*.ini", "F"
        {
            ; Extract name without extension via SplitPath.
            ; `runId` ByRef out collides with the `RunId` class (#Warn).
            SplitPath(A_LoopFileName, , , , &currentRunId)
            if (currentRunId = "")
                continue
            ; A_LoopFileTimeModified is "YYYYMMDDHHMMSS"
            candidates.Push(Map(
                "runId", currentRunId,
                "mtime", A_LoopFileTimeModified
            ))
        }

        ; Sort desc by mtime (simple insertion sort — N typically < 100)
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

        ; Apply limit
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
    ; Load(runId) - reconstructs saved buildResult
    ; Returns Map (same format as builder) or "" if not found.
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
        ; Rebuilds Map<actNum, ms> from the [checkpoints] section. Old
        ; runs without that section return an empty Map.
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
    ; LoadSummaries(maxN := -1) - loads only meta+totals (no details)
    ;
    ; Faster for listing runs in the history/comparison plot. Each
    ; element is a Map with the same format as the builder, but with
    ; details := [] (empty).
    ; ------------------------------------------------------------
    LoadSummaries(maxN := -1)
    {
        result := []
        ids := this.ListRunIds(maxN)
        ; `runId` loop var collides with the `RunId` class (#Warn).
        for _, currentRunId in ids
        {
            path := this._PathForRunId(currentRunId)
            if !FileExist(path)
                continue
            ini := IniFile(path)

            summary := Map(
                "runId",         ini.Read("meta", "runId", currentRunId),
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
    ; Delete(runId) - deletes the run's file
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
            ; v17.15 (Bug #8): records the failure for diagnostics
            ; instead of silently returning false. No logger injected.
            OutputDebug("RunHistoryRepository.Delete failed (" runId "): " ex.Message)
            return false
        }
    }

    ; ------------------------------------------------------------
    ; Private helpers
    ; ------------------------------------------------------------

    _PathForRunId(runId)
    {
        ; Sanitize runId to a safe path (should be a timestamp in the
        ; "YYYYMMDD_HHMMSS" format, but defensive).
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

    ; Serializes a detail Map into a "category|label|ms|note|timestamp" string
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

    ; Inverse of _SerializeDetail. Returns a Map or "".
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
            "categoryLabel", RunHistoryRepository._SafeCategoryLabel(cat),
            "label",         label,
            "ms",            ms,
            "note",          note,
            "timestamp",     ts
        )
    }

    ; v0.1.0: explicit lookup in SegmentDefinitions instead of delegating
    ; to CategoryLabel (which returns "All" for unknowns, turning legacy
    ; categories like `boss` into "All" in the UI). Here we want passthrough
    ; of the original string for unknown categories — runs saved in old
    ; versions may have category=boss, and the name "boss" is more useful
    ; in the UI than "All".
    ;
    ; Also uses dynamic lookup via %"..."%, keeping the hardcoded fallback
    ; for the case where RunStatsPlotBuilder is not in scope (isolated tests
    ; of this repository without including the builder).
    static _SafeCategoryLabel(cat)
    {
        catStr := String(cat)
        try
        {
            builderClass := %"RunStatsPlotBuilder"%
            for _, seg in builderClass.SegmentDefinitions()
                if (seg["key"] = catStr)
                    return seg["label"]
            ; Unknown category: passthrough
            return catStr
        }
        catch
        {
            switch catStr
            {
                case "mapa":    return "Map"
                case "cidade":  return "Town"
                case "loading": return "Loading"
                case "morte":   return "Deaths"
                default:        return catStr
            }
        }
    }

    ; Escape for serialization: replaces | with \|, and \ with \\
    ; (must be in this order when escaping, reversed when parsing).
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

    ; Split that respects escapes. Breaks on unescaped separators.
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
                ; Escape: take next char literally
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
