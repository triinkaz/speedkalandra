; PersonalBestRepository — persists PBs to data/personal_bests.ini.
; Updated by PersonalBestService after each RunCompleted (cancelled
; runs do not become PBs).
;
; INI format (post-B1):
;
;   [Run]
;   BestMs=410000
;   BestRunId=20260512_142345
;
;   [RunByAct]
;   Act1NormalMs=1725000
;   Act1InterludeMs=8200000
;   Act2NormalMs=3900000
;   ...
;
;   [Zones]
;   Mud Burrow=215000
;   Clearfell=180000
;   ...
;
; [RunByAct] keys are `Act<N><Stage>Ms` where Stage is `Normal` or
; `Interlude`. Pre-B1 INIs used `Act<N>Ms` (no stage); those are
; treated as Normal on Load so PBs from old runs aren't silently
; orphaned. Migration is read-only — the next Save rewrites the
; whole section in the new shape.
;
; Zone names are used as raw INI keys; PoE2 names contain no `=`,
; `]`, or newlines, so they don't need escaping. Any zone with
; problematic characters is sanitized or dropped at serialize time.
;
; API:
;   Load() → Map{ runPbMs, runPbRunId, runPbByActStage, zonePbs }
;     - runPbByActStage: Map<"act|stage", ms> (composite key,
;       same format as ActCheckpointTracker.GetCheckpointsByStage)
;   Save(data) → bool
;     - data["runPbByActStage"] is the canonical input. For
;       backward-compat, data["runPbByAct"] (integer-keyed legacy)
;       is still accepted and treated as all-normal.
;   GetPath() → string


class PersonalBestRepository
{
    _path := ""
    _warn := ""   ; WarningSink (Null by default; LogServiceWarningSink in production)

    __New(path, sinkOrEmpty := "")
    {
        if (Trim(String(path)) = "")
            throw ValueError("PersonalBestRepository: 'path' is required")
        this._path := path
        ; Default to a no-op sink so the repo can still be used in
        ; isolated tests or early-boot paths without an explicit
        ; observability wiring. Production wires LogServiceWarningSink.
        ; Resolve throws if the input is an object that doesn't
        ; implement Warn — fails fast at wiring time.
        ;
        ; The parameter is named `sinkOrEmpty` (not `warningSink`)
        ; because AHK v2 has case-insensitive variable lookup: a
        ; local `warningSink` would shadow the global `WarningSink`
        ; class on the next line. Documented in ARCHITECTURE.md § 15.
        this._warn := WarningSink.Resolve(sinkOrEmpty)
    }

    GetPath() => this._path

    ; Returns a Map with PBs, empty when the file doesn't exist yet.
    ;
    ; Both `runPbByActStage` (canonical, composite-keyed) and
    ; `runPbByAct` (legacy projection, integer-keyed, normal-stage
    ; only) are populated. Callers should prefer the composite
    ; shape; the integer-keyed view exists so pre-B1 consumers and
    ; tests that assert against the legacy field don't break.
    Load()
    {
        result := Map(
            "runPbMs",          0,
            "runPbRunId",       "",
            "runPbByActStage",  Map(),
            "runPbByAct",       Map(),
            "zonePbs",          Map()
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

        ; [RunByAct] — per-(act, stage) PB. Two key shapes accepted:
        ;   New (post-B1):  Act<N>NormalMs, Act<N>InterludeMs
        ;   Legacy (pre-B1): Act<N>Ms  — treated as Normal so old
        ;                    files don't lose data on first Load.
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
                    actNum  := 0
                    stage   := ""
                    if RegExMatch(keyStr, "i)^Act(\d+)(Normal|Interlude)Ms$", &mNew)
                    {
                        actNum := Integer(mNew[1] + 0)
                        stage  := (StrLower(mNew[2]) = "interlude") ? "interlude" : "normal"
                    }
                    else if RegExMatch(keyStr, "i)^Act(\d+)Ms$", &mOld)
                    {
                        actNum := Integer(mOld[1] + 0)
                        stage  := "normal"
                    }
                    else
                        continue
                    if (actNum <= 0)
                        continue
                    try
                    {
                        ms := Integer(v + 0)
                        if (ms > 0)
                        {
                            compositeKey := actNum . "|" . stage
                            result["runPbByActStage"][compositeKey] := ms
                            ; Legacy projection: normal-stage only,
                            ; integer-keyed. Pre-B1 callers and tests
                            ; that read runPbByAct still see the
                            ; right data.
                            if (stage = "normal")
                                result["runPbByAct"][actNum] := ms
                        }
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
    ; Failures are forwarded to the injected WarningSink (LogService-
    ; backed in production), so a disk-full / locked-file / corrupt-
    ; encoding event becomes a visible `[PB]` WARN in the user log
    ; instead of vanishing. The method still returns false on failure
    ; so the caller can decide how to react.
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
            this._warn.Warn("Save failed for " . this._path, ex)
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
        ; Composite-keyed: Map<"act|stage", ms>. Output format:
        ;   Act<N>NormalMs   for stage "normal"
        ;   Act<N>InterludeMs for stage "interlude"
        ; Backward-compat: if the caller passed `runPbByAct` (legacy
        ; integer-keyed), treat all entries as normal stage.
        content .= "[RunByAct]`r`n"
        byActStage := data.Has("runPbByActStage") ? data["runPbByActStage"] : ""
        if !IsObject(byActStage)
            byActStage := Map()
        ; Merge in legacy integer-keyed map (treated as normal stage).
        ; The composite map wins on conflict — if both representations
        ; are passed, the explicit stage is authoritative.
        if data.Has("runPbByAct") && IsObject(data["runPbByAct"])
        {
            for actNum, ms in data["runPbByAct"]
            {
                if !IsNumber(actNum) || actNum <= 0
                    continue
                if !IsNumber(ms) || ms <= 0
                    continue
                legacyKey := Integer(actNum) . "|normal"
                if !byActStage.Has(legacyKey)
                    byActStage[legacyKey] := Integer(ms)
            }
        }
        for compositeKey, ms in byActStage
        {
            if !IsNumber(ms) || ms <= 0
                continue
            ; Parse "<act>|<stage>" — emit only well-formed entries.
            if !RegExMatch(String(compositeKey), "i)^(\d+)\|(normal|interlude)$", &mk)
                continue
            actNum := Integer(mk[1] + 0)
            if (actNum <= 0)
                continue
            stageCap := (StrLower(mk[2]) = "interlude") ? "Interlude" : "Normal"
            content .= "Act" . actNum . stageCap . "Ms=" . Integer(ms) . "`r`n"
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
