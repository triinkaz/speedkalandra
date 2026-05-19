; PersonalBestService — PBs in memory, updated when the
; composition root finalizes a run. Loads from disk on construction;
; UpdateFromRun() is called from inside RunSnapshotSaver.Save with
; the aggregated data, so the service stays pull-based and never has
; to race subscribers that clear state on RunCompleted.
;
; Three PB categories:
;   Run PB (legacy)   — lowest runDurationMs across completed runs.
;                       Kept for back-compat; the overlay no longer
;                       reads it directly.
;   Per-act run PB    — total run time at each act transition.
;                       Independent per act, so an Act-1-only run
;                       and a full campaign can still be compared
;                       fairly on Act 1.
;   Zone PB           — lowest zoneTotalMs in a completed run
;                       (total = sum of all visits in that run).
;
; Cancelled runs never become PBs — only an explicit FinalizeRun
; (Ctrl+Alt+F) triggers UpdateFromRun.


class PersonalBestService
{
    _repo := ""
    _warn := ""   ; WarningSink (Null by default; LogServiceWarningSink in production)

    _runPbMs    := 0
    _runPbRunId := ""
    _runPbByAct := ""    ; Map<actNum, ms>
    _zonePbs    := ""    ; Map<zoneName, ms>

    __New(repo, sinkOrEmpty := "")
    {
        if !(repo is PersonalBestRepository)
            throw TypeError("PersonalBestService: 'repo' must be PersonalBestRepository")
        this._repo       := repo
        this._runPbByAct := Map()
        this._zonePbs    := Map()
        ; No-op sink by default so existing tests that construct the
        ; service with just `(repo)` keep passing. Production wires
        ; LogServiceWarningSink so persist failures show up in the
        ; user log under the "PB" tag instead of being silently
        ; swallowed by the finalize flow. Resolve throws on an object
        ; that doesn't implement Warn (fail-fast at wiring).
        ; Parameter is `sinkOrEmpty` (not `warningSink`) to avoid the
        ; case-insensitive shadow of the WarningSink class — see
        ; ARCHITECTURE.md § 15.
        this._warn       := WarningSink.Resolve(sinkOrEmpty)
        this._LoadFromRepo()
    }

    ; ---- Queries ----

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

    ; ---- Per-act PB ----

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

    ; Called by the composition root after a completed run.
    ;   runMs              — final runDurationMs (TimerService.GetRunMs)
    ;   runId              — id of the completed run
    ;   zoneTotalsMap      — ZoneTrackingService.GetTotalsForSnapshot()
    ;   actCheckpointsMap  — ActCheckpointTracker.GetCheckpoints()
    ; Returns true if any PB was updated. Persists immediately on
    ; change; I/O failure is swallowed so the finalize flow isn't
    ; broken.
    UpdateFromRun(runMs, runId := "", zoneTotalsMap := "", actCheckpointsMap := "")
    {
        changed := false

        ; Global run PB (legacy, preserved).
        if (IsNumber(runMs) && runMs > 0)
        {
            if (this._runPbMs = 0 || runMs < this._runPbMs)
            {
                this._runPbMs    := Integer(runMs)
                this._runPbRunId := String(runId)
                changed := true
            }
        }

        ; Per-act run PB.
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

        ; Zone PBs.
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
            this._TryPersistOrWarn("after UpdateFromRun")
        return changed
    }

    ; Wipes every PB in memory and on disk. Called via the tray
    ; menu "Reset PBs".
    Reset()
    {
        this._runPbMs    := 0
        this._runPbRunId := ""
        this._runPbByAct := Map()
        this._zonePbs    := Map()
        this._TryPersistOrWarn("after Reset")
    }

    ; Replaces all local PBs with external data, used by
    ; RunImportService when the user picks pbStrategy="replace".
    ; Destructive on purpose — the user made the choice consciously.
    ;
    ; pbData accepts (all optional, missing keys default to 0/""/empty):
    ;   runPbMs (int >= 0), runPbRunId (string),
    ;   runPbByAct (Map<int,int>), zonePbs (Map<str,int>)
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

        this._TryPersistOrWarn("after LoadFromExternal")
    }

    ; Pins a specific run as PB. The use case is a user who
    ; accidentally let a glitched/test/buggy run become PB, or who
    ; prefers a slightly slower but legitimate run as their canonical
    ; mark.
    ;
    ; Scope:
    ;   runPbMs + runPbRunId  — always updated.
    ;   runPbByAct            — REPLACED by the run's checkpoints, but
    ;                           only if the run has at least one valid
    ;                           entry. Old runs without persisted
    ;                           checkpoints don't wipe per-act PBs
    ;                           coming from more recent runs.
    ;   zonePbs               — NOT touched. Per-zone PBs are aggregated
    ;                           across all runs by design; the Reset
    ;                           tray command is the way to clear them.
    ;
    ; Returns true if anything actually changed.
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
            this._TryPersistOrWarn("after SetAsRunPb")
        return changed
    }

    ; Rebuilds PBs from a list of buildResult entries (one per
    ; surviving run after a delete). Used by the run-deletion paths
    ; in RunHistoryDialog and the "Undo last save" tray action; both
    ; share these semantics so a deleted run no longer contributes
    ; to any PB category.
    ;
    ; Each `runs` entry has the buildResult shape produced by
    ; RunHistoryRepository.Load: Map{ runId, totalMs, totals, details,
    ; deathCount, actCheckpoints (may be an empty Map for runs saved
    ; before that section existed), ... }.
    ;
    ; Algorithm: zero all PBs, replay each run through the same
    ; logic as UpdateFromRun, then a single atomic persist at the
    ; end. Old runs without actCheckpoints contribute only to runPbMs
    ; and zonePbs; runPbByAct may end up empty if no surviving run
    ; has checkpoints. Returns true when anything changed.
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
            this._TryPersistOrWarn("after RebuildFromHistory (no runs)")
            return true
        }

        for _, runItem in runs
        {
            if !IsObject(runItem)
                continue

            runMs := runItem.Has("totalMs") ? runItem["totalMs"] : 0
            currentRunId := runItem.Has("runId") ? String(runItem["runId"]) : ""

            ; Global run PB.
            if (IsNumber(runMs) && runMs > 0)
            {
                if (this._runPbMs = 0 || runMs < this._runPbMs)
                {
                    this._runPbMs    := Integer(runMs)
                    this._runPbRunId := currentRunId
                }
            }

            ; Per-act run PB.
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

            ; Zone PBs come from per-run details (category=mapa|cidade).
            if runItem.Has("details") && IsObject(runItem["details"])
            {
                ; Mirror the discount RunSnapshotSaver applied at
                ; save time: subtract the interrupted-visit time
                ; from the matching zone's total before comparing
                ; with the running PB. The two paths -- save and
                ; rebuild -- must agree so Undo (delete + rebuild)
                ; lands on the exact same PB as the original save.
                ; Legacy runs persisted before this field existed
                ; load with "" / 0 (see RunHistoryRepository.Load);
                ; the `interruptedZoneVisitMs > 0` guard skips the
                ; discount cleanly for them.
                interruptedZoneName := runItem.Has("interruptedZoneName") ? String(runItem["interruptedZoneName"]) : ""
                interruptedZoneVisitMs := 0
                if runItem.Has("interruptedZoneVisitMs") && IsNumber(runItem["interruptedZoneVisitMs"])
                {
                    v := Integer(runItem["interruptedZoneVisitMs"])
                    if (v > 0)
                        interruptedZoneVisitMs := v
                }

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
                    if (zone = interruptedZoneName && interruptedZoneVisitMs > 0)
                    {
                        ; Permissive case: zone visited twice (one
                        ; complete + interrupted) keeps the complete-
                        ; visit time as a PB candidate. Single-visit
                        ; (interrupted) falls below 0 and is skipped.
                        msInt -= interruptedZoneVisitMs
                        if (msInt <= 0)
                            continue
                    }
                    cur := this._zonePbs.Has(zone) ? this._zonePbs[zone] : 0
                    if (cur = 0 || msInt < cur)
                        this._zonePbs[zone] := msInt
                }
            }
        }

        ; Always persist (even if nothing changed — simplifies the flow).
        ; The extra I/O cost is negligible.
        this._TryPersistOrWarn("after RebuildFromHistory")

        ; Detect change to return to the caller (debug/UI feedback)
        newByActStr := PersonalBestService._MapToDebugStr(this._runPbByAct)
        newZoneStr  := PersonalBestService._MapToDebugStr(this._zonePbs)
        return (this._runPbMs != prevRunMs)
            || (this._runPbRunId != prevRunId)
            || (newByActStr != prevByActStr)
            || (newZoneStr != prevZoneStr)
    }

    ; Serializes Map<int|string, int> into a canonical comparison
    ; string. Sorts by key so iteration order doesn't matter.
    ;
    ; AHK v2 gotcha: in a Map, `m[1]` (Integer key) and `m["1"]`
    ; (String key) are DIFFERENT keys. _runPbByAct uses integer keys;
    ; coercing them to strings on lookup raises UnsetItemError. Here
    ; we store the value next to the string key on the first pass
    ; instead of looking it back up.
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

    ; ---- Internals ----

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
            ; A silent load failure used to mask corrupt INIs and
            ; I/O problems. Now visible through the WarningSink so
            ; the user sees "PB load failed" instead of silently
            ; starting with zeroed PBs (and overwriting the corrupt
            ; file on the next successful save).
            this._warn.Warn("Failed to load PBs from repo", ex)
        }
    }

    ; Persists current in-memory PBs to the repo. Returns the bool
    ; produced by the repo's Save (true on success, false on failure).
    ; Throws only on programming errors the caller cannot recover from
    ; (the repo's catch already swallows I/O exceptions and turns them
    ; into `false` + a WARN through its own sink).
    _PersistToRepo()
    {
        return this._repo.Save(Map(
            "runPbMs",    this._runPbMs,
            "runPbRunId", this._runPbRunId,
            "runPbByAct", this._runPbByAct,
            "zonePbs",    this._zonePbs
        ))
    }

    ; Calls _PersistToRepo and routes both branches — thrown
    ; exception and returned-false — through the WarningSink.
    ; Keeps the public methods (UpdateFromRun, Reset, etc.) at one
    ; call each instead of repeating the try/catch boilerplate.
    ;
    ; The flow is INTENTIONALLY non-fatal: a failed persist must not
    ; break the finalize flow that called us (the run must still
    ; reach the history file). The WARN replaces the previous silent
    ; swallow.
    _TryPersistOrWarn(context)
    {
        try
        {
            if !this._PersistToRepo()
                this._warn.Warn("PB persist returned false (" . context . ")")
        }
        catch as ex
        {
            this._warn.Warn("PB persist threw (" . context . ")", ex)
        }
    }
}
