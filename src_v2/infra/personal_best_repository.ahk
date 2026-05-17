; ============================================================
; PersonalBestRepository - persists PB times to disk (v17.13)
; ============================================================
;
; SCOPE:
;   Persists 2 categories of Personal Bests:
;     - Full-run PB (best runDurationMs in a completed run)
;     - Per-zone PB (best final zoneTotalMs in a completed run)
;
;   Saves to INI `data/personal_bests.ini`. Updated by
;   PersonalBestService after each RunCompleted (NOT on RunCancelled —
;   cancelled runs do not become PBs).
;
; INI FORMAT:
;
;   [Run]
;   BestMs=410000
;   BestRunId=20260512_142345
;
;   [RunByAct]
;   Act1Ms=1725000
;   Act2Ms=3900000
;   Act3Ms=6900000
;   ...
;
;   [Zones]
;   Mud Burrow=215000
;   Clearfell=180000
;   The Riverbank=95000
;   ...
;
; [RunByAct] (v17.13): PB of the TOTAL RUN TIME at the moment each
; act ended. Key = "Act<N>Ms" where N is the act number (1-10).
; Replaces the global full-run PB (which uselessly mixed Act-1-only
; runs with full-campaign runs).
;
; NOTE ON ZONE AS KEY:
;   PoE2 zone names have no `=`, `]`, or newlines, so they work as
;   INI keys without escaping. Spaces are allowed. If a zone with
;   problematic characters shows up, IniFile.Write will fail and the
;   save is skipped (try silences it).
;
; API:
;   Load() -> Map{ "runPbMs": int, "runPbRunId": string, "zonePbs": Map<zone, ms> }
;   Save(data) -> bool
;   GetPath() -> string
;
; CONSTRUCTION:
;   repo := PersonalBestRepository(A_ScriptDir "\data\personal_bests.ini")


class PersonalBestRepository
{
    _path := ""

    __New(path)
    {
        if (Trim(String(path)) = "")
            throw ValueError("PersonalBestRepository: 'path' is required")
        this._path := path
    }

    GetPath() => this._path

    ; ------------------------------------------------------------
    ; Load - returns Map with PBs (empty if the file does not exist)
    ; ------------------------------------------------------------
    Load()
    {
        result := Map(
            "runPbMs",    0,
            "runPbRunId", "",
            "runPbByAct", Map(),
            "zonePbs",    Map()
        )

        if !FileExist(this._path)
            return result

        ini := IniFile(this._path)

        ; [Run]
        try
            result["runPbMs"] := Integer(ini.Read("Run", "BestMs", "0") + 0)
        catch
            result["runPbMs"] := 0
        try
            result["runPbRunId"] := String(ini.Read("Run", "BestRunId", ""))
        catch
            result["runPbRunId"] := ""

        ; [RunByAct] (v17.13) — per-act PB
        try
        {
            byActMap := ini.ReadSectionAsMap("RunByAct")
            if IsObject(byActMap)
            {
                for k, v in byActMap
                {
                    keyStr := String(k)
                    if (keyStr = "")
                        continue
                    ; Match "Act<N>Ms" -> extract N
                    if !RegExMatch(keyStr, "i)^Act(\d+)Ms$", &m)
                        continue
                    actNum := Integer(m[1] + 0)
                    if (actNum <= 0)
                        continue
                    try
                    {
                        ms := Integer(v + 0)
                        if (ms > 0)
                            result["runPbByAct"][actNum] := ms
                    }
                    catch
                        continue
                }
            }
        }

        ; [Zones]
        try
        {
            zonesMap := ini.ReadSectionAsMap("Zones")
            if IsObject(zonesMap)
            {
                for k, v in zonesMap
                {
                    if (String(k) = "")
                        continue
                    try
                    {
                        ms := Integer(v + 0)
                        if (ms > 0)
                            result["zonePbs"][String(k)] := ms
                    }
                    catch
                        continue
                }
            }
        }

        return result
    }

    ; ------------------------------------------------------------
    ; Save - persists PBs to disk ATOMICALLY (v17.15, Bug #7)
    ;
    ; Before: 6-8 sequential IniWrites with Delete between them. A
    ; crash between Delete("RunByAct") and Write -> PBs accumulated
    ; over weeks were lost.
    ;
    ; Now: serializes the entire INI in memory and writes via
    ; AtomicWriter (.tmp + FileMove). A crash before FileMove leaves
    ; an orphan .tmp but the original INI intact.
    ;
    ; ENCODING (v0.1.0): AtomicWriter uses "UTF-16" instead of "UTF-8".
    ; Discovered in Wave 4 testing: AHK v2 IniRead key-lookup
    ; (`IniRead(path, section, key, default)`) does NOT work on UTF-8
    ; BOM files, always returning the default. Works only on UTF-16
    ; LE BOM (the native IniWrite format). Latent bug in the project's
    ; R11 (TextEncoding.MigrateIniToUtf8) too.
    ;
    ; Failures: logs to OutputDebug and returns false. Caller (service)
    ; decides what to do (currently silences, but at least has the signal).
    ; ------------------------------------------------------------
    Save(data)
    {
        if !IsObject(data)
            return false

        try
        {
            content := PersonalBestRepository._Serialize(data)
            AtomicWriter.WriteAll(this._path, content, "UTF-16")
            return true
        }
        catch as ex
        {
            OutputDebug("PersonalBestRepository.Save failed: " ex.Message)
            return false
        }
    }

    ; ------------------------------------------------------------
    ; _Serialize - builds the complete INI content as a string
    ;
    ; Output compatible with IniRead (which Load uses to parse it).
    ; Defensive: validates types, sanitizes zone keys.
    ;
    ; LINE ENDINGS: uses CRLF (`r`n) because IniRead calls Win32
    ; GetPrivateProfileString, which on UTF-8 BOM files does NOT
    ; recognize key=value separated by pure LF. Section reads
    ; (`IniRead(file, section)`) tolerate LF, but key lookups
    ; (`IniRead(file, section, key, default)`) return the default.
    ; v0.1.0 fix: Windows convention.
    ; ------------------------------------------------------------
    static _Serialize(data)
    {
        ; --- [Run] ---
        runMs := (data.Has("runPbMs") && IsNumber(data["runPbMs"]))
                 ? Integer(data["runPbMs"]) : 0
        ; v0.1.0: renamed from `runId` to `currentRunId` (case-insensitive
        ; collision with the domain class `RunId` was triggering #Warn).
        currentRunId := data.Has("runPbRunId") ? String(data["runPbRunId"]) : ""
        ; Sanitize id (paranoia: should not have invalid characters)
        currentRunId := StrReplace(currentRunId, "`r", "")
        currentRunId := StrReplace(currentRunId, "`n", "")

        content := "[Run]`r`n"
        content .= "BestMs=" runMs "`r`n"
        content .= "BestRunId=" currentRunId "`r`n`r`n"

        ; --- [RunByAct] ---
        content .= "[RunByAct]`r`n"
        byAct := data.Has("runPbByAct") ? data["runPbByAct"] : ""
        if IsObject(byAct)
        {
            for actNum, ms in byAct
            {
                if !IsNumber(actNum) || actNum <= 0
                    continue
                if !IsNumber(ms) || ms <= 0
                    continue
                content .= "Act" Integer(actNum) "Ms=" Integer(ms) "`r`n"
            }
        }
        content .= "`r`n"

        ; --- [Zones] ---
        content .= "[Zones]`r`n"
        zones := data.Has("zonePbs") ? data["zonePbs"] : ""
        if IsObject(zones)
        {
            for zone, ms in zones
            {
                zStr := String(zone)
                if (zStr = "")
                    continue
                if !IsNumber(ms) || ms <= 0
                    continue
                ; Sanitize zone name against chars that would break the INI
                zStr := StrReplace(zStr, "`r", "")
                zStr := StrReplace(zStr, "`n", "")
                zStr := StrReplace(zStr, "=", "")
                zStr := StrReplace(zStr, "[", "")
                zStr := StrReplace(zStr, "]", "")
                if (zStr = "")
                    continue
                content .= zStr "=" Integer(ms) "`r`n"
            }
        }
        return content
    }
}
