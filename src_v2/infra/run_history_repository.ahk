; RunHistoryRepository — persists finalized runs to disk, one INI
; per run at data/runs/{runId}.ini. The content stored is the
; buildResult produced by RunStatsPlotBuilder.Build (already
; aggregated into totals + details), so the history dialog can open
; an old run without re-running the builder.
;
; Per-run INI layout:
;
;   [meta]
;   runId=20260513_051547_873
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
;   [checkpoints]
;   Act1Ms=1725000
;   Act2Ms=3719000
;
;   [details]
;   count=15
;   0=mapa|Cemetery of the Eternals|220000|Act 1|
;   1=mapa|Clearfell|156000|Act 1|
;   2=cidade|The Ardura Caravan|95000|Act 2|
;
; Details are serialized as "category|label|ms|note|timestamp". Pipe
; is the separator; backslash escapes a literal pipe or backslash.
; A custom format avoids the cost of bundling a JSON parser — the
; project already has a battle-tested IniFile reader.
;
; Old runs saved before the [checkpoints] section was added simply
; come back with an empty actCheckpoints Map on Load. Old runs may
; also carry category=boss in totals/details; the builder no longer
; declares that category but the loader passes it through.
;
; API:
;   ListRunIds(maxN := -1)    → Array<string>, mtime desc
;   Load(runId)               → Map | ""
;   LoadSummaries(maxN := -1) → Array<Map> with empty details (fast)
;   Save(buildResult)         → bool
;   Delete(runId)             → bool
;   GetDir()                  → string


class RunHistoryRepository
{
    _dir  := ""
    _warn := ""   ; WarningSink (Null by default; LogServiceWarningSink in production)

    static DETAIL_SEP := "|"

    __New(dir, sinkOrEmpty := "")
    {
        if (Trim(String(dir)) = "")
            throw ValueError("RunHistoryRepository: 'dir' is required")
        this._dir := dir
        ; No-op sink by default; production wires LogServiceWarningSink
        ; tagged with "RunHistory". The Ensure-dir call below uses the
        ; sink already, so the constructor wires it BEFORE _EnsureDir.
        ; Resolve throws on an object that doesn't implement Warn.
        ; Parameter is `sinkOrEmpty` (not `warningSink`) to avoid the
        ; case-insensitive shadow of the WarningSink class — see
        ; ARCHITECTURE.md § 15.
        this._warn := WarningSink.Resolve(sinkOrEmpty)
        this._EnsureDir()
    }

    GetDir() => this._dir

    ; Persists buildResult to data/runs/{runId}.ini. Runs without a
    ; runId or shorter than 1 s are rejected as garbage. buildResult
    ; shape: { runId, profile, patch, firstTs, totals, details,
    ; deathCount, totalMs, maxActReached, actCheckpoints }.
    ;
    ; Atomicity: the entire INI is serialized in memory then written
    ; through AtomicWriter (.tmp + FileMove). Earlier versions made
    ; ~N direct IniWrite calls against the destination file; a crash
    ; in the middle of those left a partially-written run on disk
    ; (e.g. [meta] complete, [totals] missing, [details] inconsistent
    ; with count). With the in-memory build the destination only
    ; receives a fully-formed file or nothing at all. Same encoding
    ; (UTF-16 LE BOM) that IniWrite produces, so existing runs and
    ; the Load path stay byte-compatible.
    Save(buildResult)
    {
        if !IsObject(buildResult)
            return false

        ; Local `runId` collides case-insensitively with the `RunId`
        ; domain class; rename here.
        currentRunId := buildResult.Has("runId") ? String(buildResult["runId"]) : ""
        if (currentRunId = "")
            return false

        totalMs := buildResult.Has("totalMs") ? buildResult["totalMs"] : 0
        if (totalMs < 1000)
            return false

        path := this._PathForRunId(currentRunId)

        try
        {
            ; Build the INI text inside the try so any ValueError
            ; from _AssertNoIniBreakingChars (a textual field with
            ; \r\n[] in it) is caught and surfaced through the same
            ; WarningSink that handles AtomicWriter failures — same
            ; "Save failed for runId ..." path either way.
            content := this._SerializeBuildResultToIni(buildResult, currentRunId, totalMs)
            AtomicWriter.WriteAll(path, content, "UTF-16")
            return true
        }
        catch as ex
        {
            ; Disk full, permission denied, locked destination, or
            ; a field with INI-breaking characters from upstream.
            ; Surface via the injected sink so finalize-time save
            ; failures don't disappear silently into the bus handler.
            this._warn.Warn("Save failed for runId " . currentRunId, ex)
            return false
        }
    }

    ; Builds the complete INI text for a run. Pure function over
    ; buildResult — no I/O, no side effects, no exceptions for any
    ; well-formed input. The output mirrors exactly what the previous
    ; sequence of IniWrite calls produced, so Load() needs no change.
    ; Sections always appear in the same order (meta → totals →
    ; checkpoints → details) and use CRLF line endings so a user
    ; opening the file in Notepad sees the conventional layout.
    ;
    ; Defensive char check: any textual field containing `\r`, `\n`,
    ; `[` or `]` is rejected with ValueError. These would corrupt
    ; the INI structurally (newlines merge sections; brackets fake
    ; section headers). Normal save paths can't hit this (profile
    ; and patch come from the user's INI, firstTs from FormatTime,
    ; zone names from the catalog), so reaching this throw means
    ; some upstream parser produced unexpected text — better to
    ; refuse the save and surface the failure through the sink than
    ; to silently corrupt the run file. The mirror check at import
    ; time lives in RunExportFormat._ValidateRun.
    _SerializeBuildResultToIni(buildResult, currentRunId, totalMs)
    {
        sb := ""

        ; ---- [meta] ----
        sb .= "[meta]`r`n"
        RunHistoryRepository._AssertNoIniBreakingChars(currentRunId, "runId")
        sb .= "runId=" . currentRunId . "`r`n"
        profile := buildResult.Has("profile") ? String(buildResult["profile"]) : ""
        RunHistoryRepository._AssertNoIniBreakingChars(profile, "profile")
        sb .= "profile=" . profile . "`r`n"
        patch := buildResult.Has("patch") ? String(buildResult["patch"]) : ""
        RunHistoryRepository._AssertNoIniBreakingChars(patch, "patch")
        sb .= "patch=" . patch . "`r`n"
        firstTs := buildResult.Has("firstTs") ? String(buildResult["firstTs"]) : ""
        RunHistoryRepository._AssertNoIniBreakingChars(firstTs, "firstTs")
        sb .= "firstTs=" . firstTs . "`r`n"
        sb .= "totalMs=" . Integer(totalMs)                                                                . "`r`n"
        sb .= "deathCount="    . Integer(buildResult.Has("deathCount")    ? buildResult["deathCount"]    : 0) . "`r`n"
        sb .= "maxActReached=" . Integer(buildResult.Has("maxActReached") ? buildResult["maxActReached"] : 0) . "`r`n"
        ; Interrupted-by-hotkey visit: the zone active at FinalizeRun
        ; and the elapsed of that single visit (not the zone's total
        ; for the run). RebuildFromHistory discounts this from PB-
        ; eligible zone totals so Undo / history Delete land on the
        ; same PB as UpdateFromRun. Legacy runs (saved before this
        ; field existed) get "" / 0 on Load -- no discount, matching
        ; the data they were saved with.
        interruptedZoneName := buildResult.Has("interruptedZoneName") ? String(buildResult["interruptedZoneName"]) : ""
        RunHistoryRepository._AssertNoIniBreakingChars(interruptedZoneName, "interruptedZoneName")
        sb .= "interruptedZoneName=" . interruptedZoneName . "`r`n"
        interruptedZoneVisitMs := buildResult.Has("interruptedZoneVisitMs") ? buildResult["interruptedZoneVisitMs"] : 0
        if !IsNumber(interruptedZoneVisitMs) || interruptedZoneVisitMs < 0
            interruptedZoneVisitMs := 0
        sb .= "interruptedZoneVisitMs=" . Integer(interruptedZoneVisitMs) . "`r`n"
        sb .= "`r`n"

        ; ---- [totals] ----
        sb .= "[totals]`r`n"
        totals := buildResult.Has("totals") ? buildResult["totals"] : Map()
        if IsObject(totals)
        {
            for key, ms in totals
            {
                keyStr := String(key)
                RunHistoryRepository._AssertNoIniBreakingChars(keyStr, "totals key")
                sb .= keyStr . "=" . String(ms) . "`r`n"
            }
        }
        sb .= "`r`n"

        ; ---- [checkpoints] ----
        ; Map<actNum, ms>. Same validation as the old IniWrite path:
        ; skip non-numeric / non-positive entries. Old runs saved
        ; before this section existed Load with an empty Map.
        sb .= "[checkpoints]`r`n"
        ckpts := buildResult.Has("actCheckpoints") ? buildResult["actCheckpoints"] : Map()
        if IsObject(ckpts)
        {
            for actNum, ms in ckpts
            {
                if !IsNumber(actNum) || actNum <= 0
                    continue
                if !IsNumber(ms) || ms <= 0
                    continue
                sb .= "Act" . Integer(actNum) . "Ms=" . Integer(ms) . "`r`n"
            }
        }
        sb .= "`r`n"

        ; ---- [details] ----
        ; `count` is written last so it always matches the number of
        ; rows above it, even when rows were filtered out for being
        ; non-objects.
        ;
        ; Each row is serialized via _SerializeDetail which already
        ; escapes the `|` separator ("\\|") and literal backslash
        ; ("\\\\"). Beyond that, the underlying text fields still
        ; need the INI-breaking char guard — a `\n` in `label` would
        ; split the row into two INI lines and the `count` value
        ; would be wrong on load.
        sb .= "[details]`r`n"
        details := buildResult.Has("details") ? buildResult["details"] : []
        n := 0
        if IsObject(details)
        {
            for _, row in details
            {
                if !IsObject(row)
                    continue
                for _, fieldName in ["category", "label", "note", "timestamp"]
                {
                    if row.Has(fieldName)
                        RunHistoryRepository._AssertNoIniBreakingChars(
                            String(row[fieldName]), "details." . fieldName)
                }
                line := RunHistoryRepository._SerializeDetail(row)
                sb .= String(n) . "=" . line . "`r`n"
                n += 1
            }
        }
        sb .= "count=" . n . "`r`n"

        return sb
    }

    ; Throws ValueError if `s` contains any of the characters that
    ; would corrupt the INI structure (\r, \n, [, ]). The caller's
    ; try/catch in Save routes the failure through the WarningSink.
    ; Same set of characters that RunExportFormat._FindIniBreakingChar
    ; rejects at import time — keep the two in sync.
    static _AssertNoIniBreakingChars(s, fieldName)
    {
        if (InStr(s, "`r") > 0)
            throw ValueError("RunHistoryRepository: " . fieldName
                . " contains INI-breaking character (\r); cannot serialize")
        if (InStr(s, "`n") > 0)
            throw ValueError("RunHistoryRepository: " . fieldName
                . " contains INI-breaking character (\n); cannot serialize")
        if (InStr(s, "[") > 0)
            throw ValueError("RunHistoryRepository: " . fieldName
                . " contains INI-breaking character ([); cannot serialize")
        if (InStr(s, "]") > 0)
            throw ValueError("RunHistoryRepository: " . fieldName
                . " contains INI-breaking character (]); cannot serialize")
    }

    ; Lists run IDs available on disk, sorted by modification time
    ; descending (newest first). maxN > 0 caps the result length.
    ;
    ; SplitPath is used instead of SubStr-based extension stripping;
    ; SubStr(name, -3) returns "ini" (no dot), which compared !=
    ; ".ini" (4 chars) and effectively never matched — the runId
    ; ended up keeping ".ini" in the string, which _PathForRunId
    ; then sanitized to "_", looking up a nonexistent file like
    ; "data\runs\NAME_ini.ini". LoadSummaries returned an empty list.
    ListRunIds(maxN := -1)
    {
        result := []
        if !DirExist(this._dir)
            return result

        ; Collect {runId, mtime} for the sort pass.
        candidates := []
        loop files this._dir "\*.ini", "F"
        {
            ; ByRef out `runId` collides with the `RunId` domain class.
            SplitPath(A_LoopFileName, , , , &currentRunId)
            if (currentRunId = "")
                continue
            ; A_LoopFileTimeModified comes in as "YYYYMMDDHHMMSS".
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

    ; Reconstructs the saved buildResult. Returns "" when the file
    ; doesn't exist.
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
            "maxActReached", Integer(ini.Read("meta", "maxActReached", "0") + 0),
            ; Empty / zero defaults preserve legacy-run behavior:
            ; RebuildFromHistory sees no discount and processes the
            ; details exactly like before the field was added.
            "interruptedZoneName",    ini.Read("meta", "interruptedZoneName", ""),
            "interruptedZoneVisitMs", Integer(ini.Read("meta", "interruptedZoneVisitMs", "0") + 0)
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

        ; --- checkpoints ---
        ; Map<actNum, ms> from the [checkpoints] section. Old runs
        ; without the section just return an empty Map.
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

    ; Like Load but skips the details section — fast path for the
    ; history dialog list and comparison plot. Each entry has the
    ; same shape as Load but with details := [].
    LoadSummaries(maxN := -1)
    {
        result := []
        ids := this.ListRunIds(maxN)
        ; Loop var `runId` collides with the `RunId` domain class.
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

            ; actCheckpoints — Map<actNum, ms> from the [checkpoints]
            ; section. Same regex + filtering as Load() so the
            ; summary path stays consistent with the full read.
            ; Cheap to parse (handful of integer entries per run) and
            ; required by RunAverageService.GetAverageRunMsForAct,
            ; which is the natural consumer of the summary surface.
            ; Old runs persisted before [checkpoints] existed Load
            ; with an empty Map.
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
            summary["actCheckpoints"] := checkpoints

            result.Push(summary)
        }
        return result
    }

    ; Deletes the run's INI. Returns false on any failure (missing
    ; file, locked, etc.).
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
            ; Surface the failure via the injected WarningSink so
            ; locked / permission-denied deletes are visible to the
            ; user instead of silent.
            this._warn.Warn("Delete failed for runId " . String(runId), ex)
            return false
        }
    }

    ; ---- Private helpers ----

    _PathForRunId(runId)
    {
        ; Sanitize runId into a safe filename. Should already be a
        ; "YYYYMMDD_HHMMSS_mmm" timestamp; this is defensive.
        safe := RegExReplace(String(runId), "[^A-Za-z0-9_\-]", "_")
        return this._dir "\" safe ".ini"
    }

    _EnsureDir()
    {
        if (this._dir != "" && !DirExist(this._dir))
        {
            try
            {
                DirCreate(this._dir)
            }
            catch as ex
            {
                ; Without the directory, nothing in this repo can be
                ; persisted — every subsequent Save will fail. The
                ; warn surfaces this once at construction so the user
                ; doesn't see N silent save failures later.
                this._warn.Warn("Failed to create run history directory " . this._dir, ex)
            }
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

    ; Explicit lookup in SegmentDefinitions instead of delegating to
    ; CategoryLabel — the latter returns "All" for unknowns, which
    ; would turn legacy categories like `boss` into "All" in the UI.
    ; Here unknown categories pass through verbatim so a saved
    ; category=boss still reads as "boss" instead of "All".
    ;
    ; Uses the dynamic %"..."% lookup so an isolated test of this
    ; repository (without including the builder) still works via the
    ; hardcoded fallback below.
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
