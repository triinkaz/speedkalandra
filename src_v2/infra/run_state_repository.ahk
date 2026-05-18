; RunStateRepository — persists RunState across sessions for
; crash recovery and resume. The state is split across two files
; on purpose.
;
; speedkalandra.ini:
;   [RunState]
;     RunId=20260512_142345
;     StartedAt=2026-05-12 14:23:45
;     Status=running
;     RunBaseMs=187432
;     LoadingTotalMs=24500
;
; speedkalandra_zones.txt:
;   The Riverbank=125000
;   Clearfell=234000
;   The Grelwood=456000
;
; Why two files: IniWrite on Windows reparses the entire file on
; every call. With ~20 zones, writing them out was N+1 IniWrites and
; ran 5–10 seconds, blocking the main thread every 5 s tick — the
; pause detection actually froze. Moving the zone totals to a plain
; text file written through AtomicWriter (one FileWrite + atomic
; FileMove on NTFS) drops the operation to ~20–50 ms regardless of
; the map size. RunState itself stays as INI because it has only a
; handful of small fields, so IniWrite there is ~50 ms total and
; fine.
;
; Operations:
;   Load()              →  RunState (Empty if none on disk)
;   Save(state)         →  writes the 4 canonical fields to [RunState]
;   SaveRunBaseMs(ms)   →  writes only RunBaseMs (one IniWrite, fast)
;   Clear()             →  removes [RunState]
;   LoadLoadingTotal()  →  Int
;   SaveLoadingTotal(ms)
;   LoadZoneTotals()    →  Map<zoneName, ms> (reads the .txt)
;   SaveZoneTotals(map) →  atomically overwrites the .txt
;   ClearZoneTotals()   →  deletes the .txt


class RunStateRepository
{
    static SECTION := "RunState"

    _ini             := ""
    _zoneTotalsPath  := ""
    _warn            := ""   ; WarningSink (Null by default; LogServiceWarningSink in production)

    __New(iniFileObj, sinkOrEmpty := "")
    {
        if !(iniFileObj is IniFile)
            throw TypeError("RunStateRepository: 'iniFileObj' must be IniFile")
        this._ini := iniFileObj

        ; Derives the zone totals file path from the INI path
        ; e.g. "C:\...\speedkalandra.ini" -> "C:\...\speedkalandra_zones.txt"
        iniPath := iniFileObj.GetPath()
        SplitPath(iniPath, , &dir, , &nameNoExt)
        this._zoneTotalsPath := (dir != "" ? dir "\" : "") nameNoExt "_zones.txt"

        ; No-op sink by default; production wires LogServiceWarningSink
        ; tagged with "RunState" so failures of the zone-totals file
        ; show up as visible WARNs in the user log. Resolve throws on
        ; an object that doesn't implement Warn (fail-fast at wiring).
        ; Parameter is `sinkOrEmpty` (not `warningSink`) to avoid the
        ; case-insensitive shadow of the WarningSink class — see
        ; ARCHITECTURE.md § 15.
        this._warn := WarningSink.Resolve(sinkOrEmpty)
    }

    Load()
    {
        ini := this._ini
        ; Local `runId` collides case-insensitively with the `RunId`
        ; domain class (#Warn LocalSameAsGlobal). Use `currentRunId`,
        ; consistent with every other repo and dialog in the project.
        currentRunId := ini.Read(RunStateRepository.SECTION, "RunId", "")
        startedAt    := ini.Read(RunStateRepository.SECTION, "StartedAt", "")
        status       := ini.Read(RunStateRepository.SECTION, "Status", "idle")
        runBaseMs    := RunStateRepository._ReadInt(ini, RunStateRepository.SECTION, "RunBaseMs", 0)

        if (Trim(currentRunId) = "")
            return RunState.Empty()

        return RunState.FromMap(Map(
            "runId",     currentRunId,
            "startedAt", startedAt,
            "status",    status,
            "runBaseMs", runBaseMs
        ))
    }

    Save(state)
    {
        if !(state is RunState)
            throw TypeError("RunStateRepository.Save: 'state' must be RunState")
        ini := this._ini
        ini.Write(state.runId,     RunStateRepository.SECTION, "RunId")
        ini.Write(state.startedAt, RunStateRepository.SECTION, "StartedAt")
        ini.Write(state.status,    RunStateRepository.SECTION, "Status")
        ini.Write(state.runBaseMs, RunStateRepository.SECTION, "RunBaseMs")
    }

    ; Persists ONLY runBaseMs (single IniWrite). Used by the
    ; recorder's periodic snapshot so we don't rewrite all four
    ; fields every tick.
    SaveRunBaseMs(runBaseMs)
    {
        ms := IsNumber(runBaseMs) ? Integer(runBaseMs) : 0
        if (ms < 0)
            ms := 0
        this._ini.Write(ms, RunStateRepository.SECTION, "RunBaseMs")
    }

    Clear()
    {
        this._ini.Delete(RunStateRepository.SECTION, "")
    }

    LoadLoadingTotal()
    {
        return RunStateRepository._ReadInt(this._ini,
            RunStateRepository.SECTION, "LoadingTotalMs", 0)
    }

    SaveLoadingTotal(totalMs)
    {
        ms := IsNumber(totalMs) ? Integer(totalMs) : 0
        if (ms < 0)
            ms := 0
        this._ini.Write(ms, RunStateRepository.SECTION, "LoadingTotalMs")
    }

    ; Reads the plain-text zone totals file.
    ; Format: one "<zone name>=<ms>" per line.
    ;
    ; Failure taxonomy (deliberately graded, see ARCHITECTURE.md § 14):
    ;   - File missing      → silent return empty (expected new state)
    ;   - FileRead throws   → Warn + return empty (data loss if silent)
    ;   - Line malformed    → skip silently (resilient to manual edits)
    ;   - All lines invalid → Warn (file likely corrupt)
    LoadZoneTotals()
    {
        out := Map()
        path := this._zoneTotalsPath
        if !FileExist(path)
            return out

        content := ""
        try
        {
            content := FileRead(path, "UTF-8")
        }
        catch as ex
        {
            ; File exists but cannot be read (lock, permission, bad
            ; encoding). Without this warn the user loses run-in-
            ; progress zone totals silently.
            this._warn.Warn("Failed to read zone totals file " . path, ex)
            return out
        }

        if (content = "")
            return out

        ; Normalize CRLF and split into lines
        content := StrReplace(content, "`r`n", "`n")
        lines := StrSplit(content, "`n")
        nonEmptyLines := 0
        for _, line in lines
        {
            line := Trim(line)
            if (line = "")
                continue
            nonEmptyLines += 1
            eqPos := InStr(line, "=")
            if (eqPos < 2)
                continue
            zoneName := SubStr(line, 1, eqPos - 1)
            rawMs    := SubStr(line, eqPos + 1)
            if (zoneName = "" || !IsNumber(rawMs))
                continue
            ms := Integer(rawMs + 0)
            if (ms > 0)
                out[zoneName] := ms
        }

        ; All non-empty lines failed to parse — the file is present
        ; and non-empty but produced zero entries. That's a corrupt
        ; file, not a manual-edit skip.
        if (nonEmptyLines > 0 && out.Count = 0)
            this._warn.Warn("Zone totals file appears corrupt; no valid lines parsed (" . path . ")")

        return out
    }

    ; Writes the zone totals file atomically (one FileWrite + a
    ; FileMove via AtomicWriter). Typical ~20–50 ms regardless of
    ; the map size, vs ~80 ms per zone via IniWrite.
    ;
    ; An empty totalsMap writes an empty file (kept for existence
    ; semantics; LoadZoneTotals still returns an empty Map).
    SaveZoneTotals(totalsMap)
    {
        if !(totalsMap is Map)
            throw TypeError("RunStateRepository.SaveZoneTotals: 'totalsMap' must be Map")

        ; Builds content in a single string
        content := ""
        for zoneName, ms in totalsMap
        {
            if (zoneName = "" || ms <= 0)
                continue
            ; Sanitize zoneName: remove any "=" or newlines (defense)
            cleanName := StrReplace(zoneName, "=", "")
            cleanName := StrReplace(cleanName, "`n", "")
            cleanName := StrReplace(cleanName, "`r", "")
            content .= cleanName "=" Integer(ms) "`n"
        }

        ; Single atomic write
        try
        {
            AtomicWriter.WriteAll(this._zoneTotalsPath, content, "UTF-8")
        }
        catch as ex
        {
            ; Data loss path: in-progress run zone time fails to
            ; persist. Forwarded to the injected WarningSink so it
            ; shows up in speedkalandra.log under the "RunState" tag.
            this._warn.Warn("SaveZoneTotals failed for " . this._zoneTotalsPath, ex)
        }
    }

    ClearZoneTotals()
    {
        try
        {
            if FileExist(this._zoneTotalsPath)
                FileDelete(this._zoneTotalsPath)
        }
        catch as ex
        {
            ; Stale file lingering on disk — not strictly data loss
            ; (the next save overwrites it) but still surfaced so an
            ; underlying disk problem is visible.
            this._warn.Warn("ClearZoneTotals failed for " . this._zoneTotalsPath, ex)
        }
    }

    static _ReadInt(ini, section, key, default)
    {
        v := ini.Read(section, key, "")
        if (v = "" || !IsNumber(v))
            return default
        return Integer(v + 0)
    }
}
