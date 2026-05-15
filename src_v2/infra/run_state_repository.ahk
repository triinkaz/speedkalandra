; ============================================================
; RunStateRepository - RunState <-> INI + arquivo TXT (Onda 6)
; ============================================================
;
; Persiste estado de run pra crash recovery e resume entre sessoes.
;
; LAYOUT EM DISCO:
;   speedkalandra.ini:
;     [RunState]
;       RunId=20260512_142345
;       StartedAt=2026-05-12 14:23:45
;       Status=running
;       RunBaseMs=187432
;       LoadingTotalMs=24500
;
;   speedkalandra_zones.txt (arquivo separado):
;     The Riverbank=125000
;     Clearfell=234000
;     The Grelwood=456000
;
; POR QUE 2 ARQUIVOS:
;   IniWrite no Windows precisa parsear o arquivo inteiro a cada
;   chamada. Pra N=20 zonas, eram N+1 IniWrites = 5-10s de bloqueio
;   do thread principal a cada 5s. Isso travava o pause-detection.
;
;   Trocando zone totals pra arquivo texto plano com AtomicWriter
;   (um unico FileWrite + FileMove atomico), a operacao cai pra
;   ~20-50ms. Resolve o lag completamente.
;
;   RunState continua INI porque tem so 5 campos pequenos — IniWrite
;   ali eh aceitavel (~50ms cada).
;
; OPERACOES:
;   Load()              -> RunState (Empty se nao houver)
;   Save(state)         -> escreve 4 campos canonicos em [RunState]
;   SaveRunBaseMs(ms)   -> escreve so RunBaseMs (1 IniWrite, rapido)
;   Clear()             -> remove [RunState]
;
;   LoadLoadingTotal()  -> Int
;   SaveLoadingTotal(ms)
;
;   LoadZoneTotals()    -> Map<zoneName, ms> (le do .txt)
;   SaveZoneTotals(map) -> sobrescreve .txt atomicamente
;   ClearZoneTotals()   -> apaga .txt


class RunStateRepository
{
    static SECTION := "RunState"

    _ini             := ""
    _zoneTotalsPath  := ""

    __New(iniFileObj)
    {
        if !(iniFileObj is IniFile)
            throw TypeError("RunStateRepository: 'iniFileObj' deve ser IniFile")
        this._ini := iniFileObj

        ; Deriva path do arquivo de zone totals a partir do INI path
        ; Ex: "C:\...\speedkalandra.ini" -> "C:\...\speedkalandra_zones.txt"
        iniPath := iniFileObj.GetPath()
        SplitPath(iniPath, , &dir, , &nameNoExt)
        this._zoneTotalsPath := (dir != "" ? dir "\" : "") nameNoExt "_zones.txt"
    }

    Load()
    {
        ini := this._ini
        runId     := ini.Read(RunStateRepository.SECTION, "RunId", "")
        startedAt := ini.Read(RunStateRepository.SECTION, "StartedAt", "")
        status    := ini.Read(RunStateRepository.SECTION, "Status", "idle")
        runBaseMs := RunStateRepository._ReadInt(ini, RunStateRepository.SECTION, "RunBaseMs", 0)

        if (Trim(runId) = "")
            return RunState.Empty()

        return RunState.FromMap(Map(
            "runId",     runId,
            "startedAt", startedAt,
            "status",    status,
            "runBaseMs", runBaseMs
        ))
    }

    Save(state)
    {
        if !(state is RunState)
            throw TypeError("RunStateRepository.Save: 'state' deve ser RunState")
        ini := this._ini
        ini.Write(state.runId,     RunStateRepository.SECTION, "RunId")
        ini.Write(state.startedAt, RunStateRepository.SECTION, "StartedAt")
        ini.Write(state.status,    RunStateRepository.SECTION, "Status")
        ini.Write(state.runBaseMs, RunStateRepository.SECTION, "RunBaseMs")
    }

    ; ============================================================
    ; SaveRunBaseMs - persiste APENAS o runBaseMs (1 IniWrite)
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
    ; LoadZoneTotals - le arquivo TXT plano (key=value por linha)
    ;
    ; Formato:
    ;   The Riverbank=125000
    ;   Clearfell=234000
    ;
    ; Retorna Map() vazio se arquivo nao existir ou estiver vazio.
    ; Linhas malformadas sao ignoradas (defensivo).
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

        ; Normaliza CRLF e separa em linhas
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
    ; SaveZoneTotals - escreve TXT atomicamente
    ;
    ; Single FileWrite via AtomicWriter (.tmp + FileMove no NTFS).
    ; ~20-50ms tipico, independente do tamanho do Map. Muito mais
    ; rapido que IniWrite que era ~80ms POR ZONA.
    ;
    ; Se totalsMap vazio, escreve arquivo vazio (preserva existencia
    ; pra consistencia, mas LoadZoneTotals retorna Map vazio).
    ; ============================================================
    SaveZoneTotals(totalsMap)
    {
        if !(totalsMap is Map)
            throw TypeError("RunStateRepository.SaveZoneTotals: 'totalsMap' deve ser Map")

        ; Gera conteudo em uma string so
        content := ""
        for zoneName, ms in totalsMap
        {
            if (zoneName = "" || ms <= 0)
                continue
            ; Sanitiza zoneName: remove qualquer "=" ou newline (defesa)
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
            ; v17.15 (Bug #8): registra falha em vez de engolir silente.
            ; Sem logger injetado, usa OutputDebug.
            OutputDebug("RunStateRepository.ClearZoneTotals falhou: " ex.Message)
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
