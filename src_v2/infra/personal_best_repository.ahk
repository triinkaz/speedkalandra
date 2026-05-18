; PersonalBestRepository — persists PBs to data/personal_bests.ini.
; Updated by PersonalBestService after each RunCompleted (cancelled
; runs do not become PBs).
;
; INI format:
;
;   [Run]
;   BestMs=410000
;   BestRunId=20260512_142345
;
;   [RunByAct]
;   Act1Ms=1725000
;   Act2Ms=3900000
;   ...
;
;   [Zones]
;   Mud Burrow=215000
;   Clearfell=180000
;   ...
;
; [RunByAct] keys are "Act<N>Ms". Zone names are used as raw INI
; keys; PoE2 names contain no `=`, `]`, or newlines, so they don't
; need escaping. Any zone with problematic characters is sanitized
; or dropped at serialize time.
;
; API:
;   Load() → Map{ runPbMs, runPbRunId, runPbByAct, zonePbs }
;   Save(data) → bool
;   GetPath() → string


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

    ; Returns a Map with PBs, empty when the file doesn't exist yet.
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

        ; [RunByAct] — per-act PB
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

    ; Persists PBs atomically: serializes the full INI in memory,
    ; then writes through AtomicWriter (.tmp + FileMove). A crash
    ; before the FileMove leaves an orphan .tmp but the previous INI
    ; intact. Without this, a crash mid-write (between successive
    ; IniWrite calls, or between a Delete and the following Write)
    ; would lose every PB accumulated up to that point.
    ;
    ; Encoding is UTF-16 LE with BOM. AHK v2 IniRead key-lookup
    ; (`IniRead(path, section, key, default)`) does NOT work on
    ; UTF-8 BOM files — it always returns the default. Only UTF-16
    ; LE BOM works (the native format produced by IniWrite). The
    ; project's TextEncoding migrator enforces the same convention.
    ;
    ; Failures are logged via OutputDebug and the method returns
    ; false; the caller (PersonalBestService) currently silences
    ; them but at least has the signal.
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

    ; Builds the full INI content as a string, ready for AtomicWriter.
    ; Output is parseable by IniRead (used by Load above).
    ;
    ; Line endings are CRLF, not LF. IniRead calls Win32's
    ; GetPrivateProfileString under the hood; on UTF-16 BOM files,
    ; key lookups (`IniRead(file, section, key, default)`) refuse to
    ; recognize entries separated by pure LF and silently return the
    ; default. Section-wide reads (`IniRead(file, section)`) tolerate
    ; LF, which is what made this trap hard to spot.
    static _Serialize(data)
    {
        ; --- [Run] ---
        runMs := (data.Has("runPbMs") && IsNumber(data["runPbMs"]))
                 ? Integer(data["runPbMs"]) : 0
        ; Local `runId` collides case-insensitively with the `RunId`
        ; domain class and trips #Warn; rename here.
        currentRunId := data.Has("runPbRunId") ? String(data["runPbRunId"]) : ""
        ; Paranoia: strip newlines that would corrupt the INI.
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
                ; Strip characters that would break the INI structure.
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
