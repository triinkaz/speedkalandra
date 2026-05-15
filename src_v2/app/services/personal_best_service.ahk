; ============================================================
; PersonalBestService - mantem PBs em memoria, atualiza em runs
; ============================================================
;
; ESCOPO:
;   Service que carrega PBs do disco no startup e expoe queries
;   pra UI ler tempos correntes. Atualizado externamente via
;   UpdateFromRun() quando uma run eh finalizada (chamado pelo
;   composition root dentro de _SaveRunSnapshot, com state intacto).
;
; POR QUE NAO SUBSCRIBE A EVENTOS DIRETAMENTE:
;   Em RunCompleted, o ZoneTrackingService e RunStatsRecorder PODEM
;   zerar seu state interno (ordem FIFO do EventBus). Pra evitar
;   timing-dependent subscribes (que precisaria do pattern do v17.10
;   de inscrever no __New ANTES desses services), o service eh
;   pull-based: o app passa os dados ja agregados via UpdateFromRun.
;
;   Isso tambem mantem o service simples e testavel sem mock de bus.
;
; CRITERIO DE PB:
;   - Run PB (legado): menor runDurationMs entre todas as runs COMPLETED.
;     Run cancelada (Cmd.CancelRunRequested -> NewRun ou Ctrl+Alt+R)
;     NAO conta — atualiza so quando a run eh finalizada explicitamente
;     com Ctrl+Alt+F.
;     **PRESERVADO PRA RETROCOMPAT** mas overlay nao consulta mais.
;
;   - Run PB por ato (v17.13): tempo TOTAL DA RUN no momento que cada
;     ato terminou. Multiplos PBs (um por ato). Permite comparar runs
;     de tamanhos diferentes (Ato 1 only vs campanha completa) de forma
;     justa — cada ato tem seu proprio checkpoint independente.
;
;   - Zone PB: pra cada zona, menor zoneTotalMs em uma run completed.
;     Total = soma de todas visitas a zona naquela run (GetTotalsForSnapshot
;     ja entrega isso).
;
; QUERIES:
;   GetRunPbMs()                  -> int (0 se sem PB)  [LEGADO]
;   GetRunPbRunId()               -> string             [LEGADO]
;   GetRunPbForAct(actNum)        -> int (0 se sem PB pra esse ato) [v17.13]
;   HasRunPbForAct(actNum)        -> bool                            [v17.13]
;   GetAllRunPbsByAct()           -> Map<actNum, ms> (clone)         [v17.13]
;   GetZonePbMs(zoneName)         -> int (0 se sem PB)
;   HasRunPb()                    -> bool
;   HasZonePb(zoneName)           -> bool
;   GetAllZonePbs()               -> Map<zoneName, ms> (clone)
;
; CONSTRUCAO:
;   svc := PersonalBestService(repo)
;   svc.UpdateFromRun(runMs, runId, zoneTotalsMap, actCheckpointsMap)


class PersonalBestService
{
    _repo := ""

    _runPbMs    := 0
    _runPbRunId := ""
    _runPbByAct := ""    ; Map<actNum, ms>  (v17.13)
    _zonePbs    := ""    ; Map<zoneName, ms>

    __New(repo)
    {
        if !(repo is PersonalBestRepository)
            throw TypeError("PersonalBestService: 'repo' deve ser PersonalBestRepository")
        this._repo       := repo
        this._runPbByAct := Map()
        this._zonePbs    := Map()
        this._LoadFromRepo()
    }

    ; ============================================================
    ; Queries
    ; ============================================================

    GetRunPbMs()      => this._runPbMs
    GetRunPbRunId()   => this._runPbRunId
    GetZonePbMs(zoneName)
    {
        if (String(zoneName) = "")
            return 0
        return this._zonePbs.Has(zoneName) ? this._zonePbs[zoneName] : 0
    }

    HasRunPb()                => this._runPbMs > 0
    HasZonePb(zoneName)       => this.GetZonePbMs(zoneName) > 0

    GetAllZonePbs()
    {
        out := Map()
        for k, v in this._zonePbs
            out[k] := v
        return out
    }

    ; ============================================================
    ; PB por ato (v17.13)
    ; ============================================================

    GetRunPbForAct(actNum)
    {
        if !IsNumber(actNum) || actNum <= 0
            return 0
        return this._runPbByAct.Has(Integer(actNum)) ? this._runPbByAct[Integer(actNum)] : 0
    }

    HasRunPbForAct(actNum) => this.GetRunPbForAct(actNum) > 0

    GetAllRunPbsByAct()
    {
        out := Map()
        for k, v in this._runPbByAct
            out[k] := v
        return out
    }

    ; Conta quantos atos tem PB salvo. Util pra UI de reset.
    CountActPbs()
    {
        n := 0
        for k, v in this._runPbByAct
        {
            if (v > 0)
                n += 1
        }
        return n
    }

    ; ============================================================
    ; Update - chamado pelo composition root apos run completed
    ;
    ; runMs:              runDurationMs final (TimerService.GetRunMs())
    ; runId:              id da run completada
    ; zoneTotalsMap:      ZoneTrackingService.GetTotalsForSnapshot() — Map<zone, ms>
    ; actCheckpointsMap:  ActCheckpointTracker.GetCheckpoints() — Map<actNum, runMs>
    ;                     (v17.13) tempos TOTAIS DA RUN no momento que cada ato terminou
    ;
    ; Retorna true se algum PB foi atualizado (run global, run-por-ato, e/ou zone).
    ;
    ; Persiste no INI imediatamente se houve mudanca. Falha silenciosa
    ; em I/O (try) pra nao quebrar o fluxo de finalizacao.
    ; ============================================================
    UpdateFromRun(runMs, runId := "", zoneTotalsMap := "", actCheckpointsMap := "")
    {
        changed := false

        ; --- Run PB global (legado, preservado) ---
        if (IsNumber(runMs) && runMs > 0)
        {
            if (this._runPbMs = 0 || runMs < this._runPbMs)
            {
                this._runPbMs    := Integer(runMs)
                this._runPbRunId := String(runId)
                changed := true
            }
        }

        ; --- Run PB por ato (v17.13) ---
        if IsObject(actCheckpointsMap)
        {
            for actNum, actMs in actCheckpointsMap
            {
                if !IsNumber(actNum) || actNum <= 0
                    continue
                if !IsNumber(actMs) || actMs <= 0
                    continue
                actKey := Integer(actNum)
                actMsInt := Integer(actMs)
                cur := this._runPbByAct.Has(actKey) ? this._runPbByAct[actKey] : 0
                if (cur = 0 || actMsInt < cur)
                {
                    this._runPbByAct[actKey] := actMsInt
                    changed := true
                }
            }
        }

        ; --- Zone PBs ---
        if IsObject(zoneTotalsMap)
        {
            for zone, ms in zoneTotalsMap
            {
                zoneStr := String(zone)
                if (zoneStr = "")
                    continue
                if !IsNumber(ms) || ms <= 0
                    continue
                msInt := Integer(ms)
                cur := this._zonePbs.Has(zoneStr) ? this._zonePbs[zoneStr] : 0
                if (cur = 0 || msInt < cur)
                {
                    this._zonePbs[zoneStr] := msInt
                    changed := true
                }
            }
        }

        if changed
            try this._PersistToRepo()
        return changed
    }

    ; ============================================================
    ; Reset - apaga todos os PBs (memoria + INI)
    ;
    ; Chamado externamente quando user pede reset via tray menu.
    ; Ao terminar, GetRunPbMs() e GetZonePbMs() retornam 0 pra tudo.
    ; Persiste no INI — ate uma run completed nao re-cria PBs antigos.
    ; ============================================================
    Reset()
    {
        this._runPbMs    := 0
        this._runPbRunId := ""
        this._runPbByAct := Map()
        this._zonePbs    := Map()
        try this._PersistToRepo()
    }

    ; ============================================================
    ; SetAsRunPb(runMs, runId, actCheckpoints := "") - pina uma run
    ; como PB (v17.15.1)
    ;
    ; Caso de uso: user fez uma run acidentalmente rapida (bug, glitch,
    ; teste indevido) que virou PB automaticamente. Ou contrario: tem
    ; uma run preferida (legitima) que nao eh o tempo mais baixo mas
    ; representa melhor sua marca pessoal.
    ;
    ; ESCOPO (v17.15.1 fix):
    ;   - runPbMs + runPbRunId: SEMPRE atualizados (legado mas mantido).
    ;   - runPbByAct: SUBSTITUIDO pelos actCheckpoints da run, SE foram
    ;     fornecidos e tem pelo menos 1 entry valido. Caso contrario
    ;     deixa intacto (runs antigas sem checkpoints persistidos nao
    ;     destroem PBs por ato existentes de runs mais recentes).
    ;   - zonePbs: NAO eh tocado. PBs por zona sao naturalmente "melhor
    ;     tempo por zona entre TODAS as runs" — metrica agregada e
    ;     independente da run "oficial". Pra resetar zonas, usar Reset().
    ;
    ; Por que substituir runPbByAct e nao zonePbs?
    ;   O overlay Compact mostra PB por ato ("Lv X | Area Y | XP | PB...")
    ;   como referencia visivel ao jogador. Esse numero precisa refletir
    ;   a run "oficial" escolhida pelo user. Ja PB por zona eh consultado
    ;   pontualmente (highlights de zona individual), faz mais sentido
    ;   ser "o melhor tempo nessa zona, de qualquer run".
    ;
    ; Retorna true se algo mudou, false se nada mudou (ex: ja era esse
    ; runId+ms+checkpoints).
    ; ============================================================
    SetAsRunPb(runMs, runId, actCheckpoints := "")
    {
        if !IsNumber(runMs) || runMs <= 0
            return false
        ridStr := String(runId)
        msInt  := Integer(runMs)
        changed := false

        ; --- runPbMs + runPbRunId ---
        if (this._runPbMs != msInt || this._runPbRunId != ridStr)
        {
            this._runPbMs    := msInt
            this._runPbRunId := ridStr
            changed := true
        }

        ; --- runPbByAct (se checkpoints disponiveis) ---
        if IsObject(actCheckpoints)
        {
            newByAct := Map()
            for actNum, ms in actCheckpoints
            {
                if !IsNumber(actNum) || actNum <= 0
                    continue
                if !IsNumber(ms) || ms <= 0
                    continue
                newByAct[Integer(actNum)] := Integer(ms)
            }
            if (newByAct.Count > 0)
            {
                ; Compara serializado pra detectar mudanca real
                if (PersonalBestService._MapToDebugStr(this._runPbByAct)
                    != PersonalBestService._MapToDebugStr(newByAct))
                {
                    this._runPbByAct := newByAct
                    changed := true
                }
            }
        }

        if changed
            try this._PersistToRepo()
        return changed
    }

    ; ============================================================
    ; RebuildFromHistory(runs) - reconstroi PBs a partir do historico (v17.15.1)
    ;
    ; Usado quando uma run eh apagada do historico: precisamos
    ; descartar contribuicoes da run deletada sem perder PBs de
    ; runs que sobreviveram.
    ;
    ; Cada elemento de `runs` deve ser um buildResult (mesmo formato
    ; que RunHistoryRepository.Load retorna):
    ;   Map{ runId, totalMs, totals, details, deathCount,
    ;        actCheckpoints (Map<actNum, ms>, pode ser Map vazio em
    ;        runs antigas sem essa secao), ... }
    ;
    ; Algoritmo:
    ;   1. Zera todos os PBs em memoria.
    ;   2. Pra cada run, replica a logica do UpdateFromRun:
    ;      - totalMs -> runPbMs (legacy)
    ;      - actCheckpoints -> runPbByAct (v17.13)
    ;      - details com category=mapa|cidade -> zonePbs
    ;   3. Persiste no INI ao final (1 write so, atomico).
    ;
    ; Runs antigas sem actCheckpoints contribuem so pra runPbMs +
    ; zonePbs. runPbByAct pode ficar vazio se nenhuma run tiver
    ; checkpoints persistidos.
    ;
    ; Retorna true se algum PB mudou (memoria ou INI), false se tudo
    ; ficou identico.
    ; ============================================================
    RebuildFromHistory(runs)
    {
        ; Snapshot do estado anterior pra detectar mudanca
        prevRunMs    := this._runPbMs
        prevRunId    := this._runPbRunId
        prevByActStr := PersonalBestService._MapToDebugStr(this._runPbByAct)
        prevZoneStr  := PersonalBestService._MapToDebugStr(this._zonePbs)

        ; Reset em memoria (NAO persiste ainda)
        this._runPbMs    := 0
        this._runPbRunId := ""
        this._runPbByAct := Map()
        this._zonePbs    := Map()

        if !IsObject(runs)
        {
            try this._PersistToRepo()
            return true
        }

        for _, run in runs
        {
            if !IsObject(run)
                continue

            runMs := run.Has("totalMs") ? run["totalMs"] : 0
            runId := run.Has("runId") ? String(run["runId"]) : ""

            ; --- Run PB global ---
            if (IsNumber(runMs) && runMs > 0)
            {
                if (this._runPbMs = 0 || runMs < this._runPbMs)
                {
                    this._runPbMs    := Integer(runMs)
                    this._runPbRunId := runId
                }
            }

            ; --- Run PB por ato ---
            if run.Has("actCheckpoints") && IsObject(run["actCheckpoints"])
            {
                for actNum, actMs in run["actCheckpoints"]
                {
                    if !IsNumber(actNum) || actNum <= 0
                        continue
                    if !IsNumber(actMs) || actMs <= 0
                        continue
                    key := Integer(actNum)
                    val := Integer(actMs)
                    cur := this._runPbByAct.Has(key) ? this._runPbByAct[key] : 0
                    if (cur = 0 || val < cur)
                        this._runPbByAct[key] := val
                }
            }

            ; --- Zone PBs (extraidos de details onde category=mapa|cidade) ---
            if run.Has("details") && IsObject(run["details"])
            {
                for _, d in run["details"]
                {
                    if !IsObject(d)
                        continue
                    cat := d.Has("category") ? d["category"] : ""
                    if (cat != "mapa" && cat != "cidade")
                        continue
                    zone := d.Has("label") ? String(d["label"]) : ""
                    if (zone = "")
                        continue
                    ms := d.Has("ms") ? d["ms"] : 0
                    if !IsNumber(ms) || ms <= 0
                        continue
                    msInt := Integer(ms)
                    cur := this._zonePbs.Has(zone) ? this._zonePbs[zone] : 0
                    if (cur = 0 || msInt < cur)
                        this._zonePbs[zone] := msInt
                }
            }
        }

        ; Persiste sempre (mesmo se nada mudou — simplifica fluxo).
        ; O custo extra de I/O eh negligenciavel.
        try this._PersistToRepo()

        ; Detecta mudanca pra retornar pro caller (debug/UI feedback)
        newByActStr := PersonalBestService._MapToDebugStr(this._runPbByAct)
        newZoneStr  := PersonalBestService._MapToDebugStr(this._zonePbs)
        return (this._runPbMs != prevRunMs)
            || (this._runPbRunId != prevRunId)
            || (newByActStr != prevByActStr)
            || (newZoneStr != prevZoneStr)
    }

    ; Serializa Map<int|string, int> em string canonica pra comparacao.
    ; Nao depende de ordem de iteracao (sort por key).
    static _MapToDebugStr(m)
    {
        if !IsObject(m)
            return ""
        keys := []
        for k, _ in m
            keys.Push(String(k))
        ; Bubble sort (lista pequena)
        n := keys.Length
        i := 2
        while (i <= n)
        {
            j := i
            while (j > 1 && StrCompare(keys[j], keys[j-1]) < 0)
            {
                tmp := keys[j]
                keys[j] := keys[j-1]
                keys[j-1] := tmp
                j--
            }
            i++
        }
        out := ""
        for _, k in keys
            out .= k "=" m[k] "|"
        return out
    }

    ; ============================================================
    ; Internos
    ; ============================================================

    _LoadFromRepo()
    {
        try
        {
            data := this._repo.Load()
            if !IsObject(data)
                return
            if data.Has("runPbMs")
                this._runPbMs := Integer(data["runPbMs"])
            if data.Has("runPbRunId")
                this._runPbRunId := String(data["runPbRunId"])
            if data.Has("runPbByAct") && IsObject(data["runPbByAct"])
            {
                this._runPbByAct := Map()
                for k, v in data["runPbByAct"]
                {
                    if IsNumber(k) && IsNumber(v) && v > 0
                        this._runPbByAct[Integer(k)] := Integer(v)
                }
            }
            if data.Has("zonePbs") && IsObject(data["zonePbs"])
            {
                this._zonePbs := Map()
                for k, v in data["zonePbs"]
                    this._zonePbs[String(k)] := Integer(v)
            }
        }
        catch as ex
        {
            ; v17.15 (Bug #8): falha em carregar PBs ficava silenciosa,
            ; mascarando INI corrompido ou problemas de I/O. Service
            ; nao tem logger injetado entao usa OutputDebug.
            OutputDebug("PersonalBestService._LoadFromRepo falhou: " ex.Message)
        }
    }

    _PersistToRepo()
    {
        this._repo.Save(Map(
            "runPbMs",    this._runPbMs,
            "runPbRunId", this._runPbRunId,
            "runPbByAct", this._runPbByAct,
            "zonePbs",    this._zonePbs
        ))
    }
}
