; ============================================================
; RunStateRepository - RunState <-> INI + TXT file (Wave 6)
; ============================================================
;
; Persists run state for crash recovery and resume between sessions.
;
; ON-DISK LAYOUT:
;   speedkalandra.ini:
;     [RunState]
;       RunId=20260512_142345
;       StartedAt=2026-05-12 14:23:45
;       Status=running
;       RunBaseMs=187432
;       LoadingTotalMs=24500
;
;   speedkalandra_zones.txt (separate file):
;     The Riverbank=125000
;     Clearfell=234000
;     The Grelwood=456000
;
; WHY 2 FILES:
;   IniWrite on Windows needs to parse the entire file on each call.
;   For N=20 zones, that was N+1 IniWrites = 5-10s of main-thread
;   blocking every 5s. It froze pause-detection.
;
;   Switching zone totals to a plain text file with AtomicWriter
;   (a single FileWrite + atomic FileMove), the operation drops to
;   ~20-50ms. Solves the lag completely.
;
;   RunState stays as INI because it has only 5 small fields — IniWrite
;   there is acceptable (~50ms each).
;
; OPERATIONS:
;   Load()              -> RunState (Empty if none)
;   Save(state)         -> writes 4 canonical fields to [RunState]
;   SaveRunBaseMs(ms)   -> writes only RunBaseMs (1 IniWrite, fast)
;   Clear()             -> removes [RunState]
;
;   LoadLoadingTotal()  -> Int
;   SaveLoadingTotal(ms)
;
;   LoadZoneTotals()    -> Map<zoneName, ms> (reads from .txt)
;   SaveZoneTotals(map) -> overwrites .txt atomically
;   ClearZoneTotals()   -> deletes .txt


class RunStateRepository
{
    static SECTION := "RunState"

    _ini             := ""
    _zoneTotalsPath  := ""

    __New(iniFileObj)
    {
        if !(iniFileObj is IniFile)
            throw TypeError("RunStateRepository: 'iniFileObj' must be IniFile")
        this._ini := iniFileObj

        ; Derives the zone totals file path from the INI path
        ; e.g. "C:\...\speedkalandra.ini" -> "C:\...\speedkalandra_zones.txt"
        iniPath := iniFileObj.GetPath()
        SplitPath(iniPath, , &dir, , &nameNoExt)
        this._zoneTotalsPath := (dir != "" ? dir "\" : "") nameNoExt "_zones.txt"
    }

    Load()
    {
        ini := this._ini
        ; v0.1.0: renamed from `runId` to `currentRunId` (case-insensitive
        ; collision with the domain class `RunId` was triggering #Warn).
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

    ; ============================================================
    ; SaveRunBaseMs - persists ONLY runBaseMs (1 IniWrite)
    ; ============================================================
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

    ; ============================================================
    ; LoadZoneTotals - reads plain TXT file (key=value per line)
    ;
    ; Format:
    ;   The Riverbank=125000
    ;   Clearfell=234000
    ;
    ; Returns an empty Map() if the file does not exist or is empty.
    ; Malformed lines are ignored (defensive).
    ; ============================================================
    LoadZoneTotals()
    {
        out := Map()
        path := this._zoneTotalsPath
        if !FileExist(path)
            return out

        content := ""
        try
            content := FileRead(path, "UTF-8")
        catch
            return out

        if (content = "")
            return out

        ; Normalize CRLF and split into lines
        content := StrReplace(content, "`r`n", "`n")
        for _, line in StrSplit(content, "`n")
        {
            line := Trim(line)
            if (line = "")
                continue
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
        return out
    }

    ; ============================================================
    ; SaveZoneTotals - writes TXT atomically
    ;
    ; Single FileWrite via AtomicWriter (.tmp + FileMove on NTFS).
    ; Typical ~20-50ms regardless of Map size. Much faster than
    ; IniWrite which was ~80ms PER ZONE.
    ;
    ; If totalsMap is empty, writes an empty file (preserves existence
    ; for consistency, but LoadZoneTotals returns an empty Map).
    ; ============================================================
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
        try AtomicWriter.WriteAll(this._zoneTotalsPath, content, "UTF-8")
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
            ; v17.15 (Bug #8): records failure instead of silently swallowing.
            ; Without an injected logger, uses OutputDebug.
            OutputDebug("RunStateRepository.ClearZoneTotals failed: " ex.Message)
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
