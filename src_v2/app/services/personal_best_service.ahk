; ============================================================
; PersonalBestService - keeps PBs in memory, updates on runs
; ============================================================
;
; SCOPE:
;   Service that loads PBs from disk on startup and exposes queries
;   for the UI to read current times. Externally updated via
;   UpdateFromRun() when a run is finalized (called by the composition
;   root inside _SaveRunSnapshot, with state intact).
;
; WHY IT DOES NOT SUBSCRIBE TO EVENTS DIRECTLY:
;   On RunCompleted, ZoneTrackingService and RunStatsRecorder MAY
;   clear their internal state (EventBus FIFO order). To avoid
;   timing-dependent subscribes (which would require the v17.10
;   pattern of subscribing in __New BEFORE those services), the
;   service is pull-based: the app passes already-aggregated data
;   via UpdateFromRun.
;
;   That also keeps the service simple and testable without mocking
;   the bus.
;
; PB CRITERIA:
;   - Run PB (legacy): lowest runDurationMs among all COMPLETED runs.
;     Cancelled run (Cmd.CancelRunRequested -> NewRun or Ctrl+Alt+R)
;     DOES NOT count — only updates when the run is explicitly
;     finalized with Ctrl+Alt+F.
;     **KEPT FOR BACK-COMPAT** but the overlay no longer consults it.
;
;   - Per-act run PB (v17.13): TOTAL RUN time at the moment each
;     act ended. Multiple PBs (one per act). Allows fair comparison
;     between runs of different sizes (Act 1 only vs full campaign)
;     — each act has its own independent checkpoint.
;
;   - Zone PB: for each zone, lowest zoneTotalMs in a completed run.
;     Total = sum of all visits to the zone in that run
;     (GetTotalsForSnapshot already delivers this).
;
; QUERIES:
;   GetRunPbMs()                  -> int (0 if no PB)        [LEGACY]
;   GetRunPbRunId()               -> string                  [LEGACY]
;   GetRunPbForAct(actNum)        -> int (0 if no PB for that act) [v17.13]
;   HasRunPbForAct(actNum)        -> bool                          [v17.13]
;   GetAllRunPbsByAct()           -> Map<actNum, ms> (clone)       [v17.13]
;   GetZonePbMs(zoneName)         -> int (0 if no PB)
;   HasRunPb()                    -> bool
;   HasZonePb(zoneName)           -> bool
;   GetAllZonePbs()               -> Map<zoneName, ms> (clone)
;
; CONSTRUCTION:
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
            throw TypeError("PersonalBestService: 'repo' must be PersonalBestRepository")
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
    ; Per-act PB (v17.13)
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

    ; Counts how many acts have a saved PB. Useful for the reset UI.
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
    ; Update - called by the composition root after a completed run
    ;
    ; runMs:              final runDurationMs (TimerService.GetRunMs())
    ; runId:              id of the completed run
    ; zoneTotalsMap:      ZoneTrackingService.GetTotalsForSnapshot() — Map<zone, ms>
    ; actCheckpointsMap:  ActCheckpointTracker.GetCheckpoints() — Map<actNum, runMs>
    ;                     (v17.13) TOTAL RUN times at the moment each act ended
    ;
    ; Returns true if any PB was updated (global run, run-per-act,
    ; and/or zone).
    ;
    ; Persists to the INI immediately if something changed. Silent
    ; I/O failure (try) so we don't break the finalization flow.
    ; ============================================================
    UpdateFromRun(runMs, runId := "", zoneTotalsMap := "", actCheckpointsMap := "")
    {
        changed := false

        ; --- Global run PB (legacy, preserved) ---
        if (IsNumber(runMs) && runMs > 0)
        {
            if (this._runPbMs = 0 || runMs < this._runPbMs)
            {
                this._runPbMs    := Integer(runMs)
                this._runPbRunId := String(runId)
                changed := true
            }
        }

        ; --- Per-act run PB (v17.13) ---
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
    ; Reset - deletes all PBs (memory + INI)
    ;
    ; Called externally when the user requests reset via the tray menu.
    ; After finishing, GetRunPbMs() and GetZonePbMs() return 0 for
    ; everything. Persists to the INI — until a completed run, old PBs
    ; are not recreated.
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
    ; LoadFromExternal(pbData) - replaces PBs with external data (v0.1.0)
    ;
    ; Used by RunImportService when the user chooses pbStrategy="replace".
    ; FULLY replaces local PBs with the data from the import file
    ; (destructive action, the user must have chosen consciously).
    ;
    ; pbData: Map with 4 optional fields:
    ;   runPbMs    : int >= 0
    ;   runPbRunId : string
    ;   runPbByAct : Map<int, int>
    ;   zonePbs    : Map<str, int>
    ;
    ; Missing fields become defaults (0/""/empty Map).
    ; Persists to the INI at the end.
    ; ============================================================
    LoadFromExternal(pbData)
    {
        if !IsObject(pbData)
            throw TypeError("PersonalBestService.LoadFromExternal: pbData must be Map")

        ; Reset state first
        this._runPbMs    := 0
        this._runPbRunId := ""
        this._runPbByAct := Map()
        this._zonePbs    := Map()

        if pbData.Has("runPbMs") && IsNumber(pbData["runPbMs"])
        {
            v := Integer(pbData["runPbMs"])
            if (v >= 0)
                this._runPbMs := v
        }
        if pbData.Has("runPbRunId")
            this._runPbRunId := String(pbData["runPbRunId"])
        if pbData.Has("runPbByAct") && IsObject(pbData["runPbByAct"])
        {
            for k, v in pbData["runPbByAct"]
            {
                if !IsNumber(k) || Integer(k) <= 0
                    continue
                if !IsNumber(v) || Integer(v) <= 0
                    continue
                this._runPbByAct[Integer(k)] := Integer(v)
            }
        }
        if pbData.Has("zonePbs") && IsObject(pbData["zonePbs"])
        {
            for k, v in pbData["zonePbs"]
            {
                if !IsNumber(v) || Integer(v) <= 0
                    continue
                this._zonePbs[String(k)] := Integer(v)
            }
        }

        try this._PersistToRepo()
    }

    ; ============================================================
    ; SetAsRunPb(runMs, runId, actCheckpoints := "") - pins a run
    ; as PB (v17.15.1)
    ;
    ; Use case: the user accidentally had a fast run (bug, glitch,
    ; bad test) that became PB automatically. Or the opposite: there
    ; is a preferred (legitimate) run that is not the lowest time but
    ; better represents their personal mark.
    ;
    ; SCOPE (v17.15.1 fix):
    ;   - runPbMs + runPbRunId: ALWAYS updated (legacy but kept).
    ;   - runPbByAct: REPLACED by the run's actCheckpoints, IF provided
    ;     and with at least 1 valid entry. Otherwise left intact (old
    ;     runs without persisted checkpoints do not destroy existing
    ;     per-act PBs from more recent runs).
    ;   - zonePbs: NOT touched. Per-zone PBs are naturally "best time
    ;     per zone across ALL runs" — aggregated metric, independent
    ;     of the "official" run. To reset zones, use Reset().
    ;
    ; Why replace runPbByAct and not zonePbs?
    ;   The Compact overlay shows per-act PB ("Lv X | Area Y | XP | PB...")
    ;   as a reference visible to the player. That number must reflect
    ;   the "official" run chosen by the user. Per-zone PBs, by contrast,
    ;   are queried occasionally (highlights of an individual zone), so
    ;   it makes more sense for them to be "the best time in that zone,
    ;   from any run".
    ;
    ; Returns true if something changed, false if nothing changed
    ; (e.g. was already that runId+ms+checkpoints).
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

        ; --- runPbByAct (if checkpoints available) ---
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
                ; Compare serialized to detect a real change
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
    ; RebuildFromHistory(runs) - rebuilds PBs from history (v17.15.1)
    ;
    ; Used when a run is deleted from history: we need to discard
    ; contributions from the deleted run without losing PBs of runs
    ; that survived.
    ;
    ; Each element of `runs` must be a buildResult (same format as
    ; RunHistoryRepository.Load returns):
    ;   Map{ runId, totalMs, totals, details, deathCount,
    ;        actCheckpoints (Map<actNum, ms>, may be empty Map in
    ;        old runs without that section), ... }
    ;
    ; Algorithm:
    ;   1. Zero all PBs in memory.
    ;   2. For each run, replicate the UpdateFromRun logic:
    ;      - totalMs -> runPbMs (legacy)
    ;      - actCheckpoints -> runPbByAct (v17.13)
    ;      - details with category=mapa|cidade -> zonePbs
    ;   3. Persist to the INI at the end (a single atomic write).
    ;
    ; Old runs without actCheckpoints contribute only to runPbMs +
    ; zonePbs. runPbByAct may end up empty if no run has persisted
    ; checkpoints.
    ;
    ; Returns true if any PB changed (memory or INI), false if
    ; everything stayed identical.
    ; ============================================================
    RebuildFromHistory(runs)
    {
        ; Snapshot of the previous state to detect change
        prevRunMs    := this._runPbMs
        prevRunId    := this._runPbRunId
        prevByActStr := PersonalBestService._MapToDebugStr(this._runPbByAct)
        prevZoneStr  := PersonalBestService._MapToDebugStr(this._zonePbs)

        ; Reset in memory (does NOT persist yet)
        this._runPbMs    := 0
        this._runPbRunId := ""
        this._runPbByAct := Map()
        this._zonePbs    := Map()

        if !IsObject(runs)
        {
            try this._PersistToRepo()
            return true
        }

        for _, runItem in runs
        {
            if !IsObject(runItem)
                continue

            runMs := runItem.Has("totalMs") ? runItem["totalMs"] : 0
            currentRunId := runItem.Has("runId") ? String(runItem["runId"]) : ""

            ; --- Global run PB ---
            if (IsNumber(runMs) && runMs > 0)
            {
                if (this._runPbMs = 0 || runMs < this._runPbMs)
                {
                    this._runPbMs    := Integer(runMs)
                    this._runPbRunId := currentRunId
                }
            }

            ; --- Per-act run PB ---
            if runItem.Has("actCheckpoints") && IsObject(runItem["actCheckpoints"])
            {
                for actNum, actMs in runItem["actCheckpoints"]
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

            ; --- Zone PBs (extracted from details where category=mapa|cidade) ---
            if runItem.Has("details") && IsObject(runItem["details"])
            {
                for _, d in runItem["details"]
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

        ; Always persist (even if nothing changed — simplifies the flow).
        ; The extra I/O cost is negligible.
        try this._PersistToRepo()

        ; Detect change to return to the caller (debug/UI feedback)
        newByActStr := PersonalBestService._MapToDebugStr(this._runPbByAct)
        newZoneStr  := PersonalBestService._MapToDebugStr(this._zonePbs)
        return (this._runPbMs != prevRunMs)
            || (this._runPbRunId != prevRunId)
            || (newByActStr != prevByActStr)
            || (newZoneStr != prevZoneStr)
    }

    ; Serializes Map<int|string, int> into a canonical comparison string.
    ; Does not depend on iteration order (sort by key).
    ;
    ; FIX v0.1.0: previously stored only the key as string and then
    ; re-did `m[k]` at the end, but in AHK v2 `m[1]` (int) and `m["1"]`
    ; (string) are distinct keys in Maps. For runPbByAct (int keys),
    ; the lookup with a string-coerced key triggered UnsetItemError.
    ; Now we store the value alongside the string key during the first
    ; iteration.
    static _MapToDebugStr(m)
    {
        if !IsObject(m)
            return ""
        pairs := []
        for k, v in m
            pairs.Push(Map("k", String(k), "v", v))
        ; Bubble sort by string key (small list)
        n := pairs.Length
        i := 2
        while (i <= n)
        {
            j := i
            while (j > 1 && StrCompare(pairs[j]["k"], pairs[j-1]["k"]) < 0)
            {
                tmp := pairs[j]
                pairs[j] := pairs[j-1]
                pairs[j-1] := tmp
                j--
            }
            i++
        }
        out := ""
        for _, p in pairs
            out .= p["k"] "=" p["v"] "|"
        return out
    }

    ; ============================================================
    ; Internals
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
            ; v17.15 (Bug #8): failure to load PBs used to be silent,
            ; masking a corrupt INI or I/O problems. The service has
            ; no injected logger so it uses OutputDebug.
            OutputDebug("PersonalBestService._LoadFromRepo failed: " ex.Message)
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
