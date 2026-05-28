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

    _runPbMs            := 0
    _runPbRunId         := ""
    _runPbByActStage    := ""    ; Map<"act|stage", ms> — B1 Layer B
    _zonePbs            := ""    ; Map<zoneName, ms>

    __New(repo, sinkOrEmpty := "")
    {
        if !(repo is PersonalBestRepository)
            throw TypeError("PersonalBestService: 'repo' must be PersonalBestRepository")
        this._repo             := repo
        this._runPbByActStage  := Map()
        this._zonePbs          := Map()
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
    ;
    ; Two views:
    ;   - Stage-aware (B1 Layer B): keyed by "act|stage" composite
    ;     where stage is "normal" or "interlude". Each (act, stage)
    ;     bucket is an independent PB.
    ;   - Legacy: integer-keyed projection of the normal-stage
    ;     entries only. Pre-B1 "Act N PB" referred to the normal
    ;     campaign Act N — interlude data didn't exist as a
    ;     separate concept — so the projection drops interlude
    ;     entries by default.

    GetRunPbForAct(actNum) => this.GetRunPbForActStage(actNum, "normal")

    HasRunPbForAct(actNum) => this.GetRunPbForAct(actNum) > 0

    ; B1 Layer B stage-aware queries.
    GetRunPbForActStage(actNum, stage)
    {
        if !IsNumber(actNum) || actNum <= 0
            return 0
        if (stage != "normal" && stage != "interlude")
            return 0
        compositeKey := Integer(actNum) . "|" . stage
        return this._runPbByActStage.Has(compositeKey) ? this._runPbByActStage[compositeKey] : 0
    }

    HasRunPbForActStage(actNum, stage) => this.GetRunPbForActStage(actNum, stage) > 0

    ; Legacy view: integer-keyed, normal-stage only. Use
    ; GetAllRunPbsByActStage for the full stage-aware picture.
    GetAllRunPbsByAct()
    {
        out := Map()
        for compositeKey, ms in this._runPbByActStage
        {
            if !RegExMatch(String(compositeKey), "i)^(\d+)\|normal$", &mk)
                continue
            out[Integer(mk[1] + 0)] := ms
        }
        return out
    }

    ; B1 Layer B: composite-keyed defensive copy. Keys look like
    ; "1|normal", "4|interlude".
    GetAllRunPbsByActStage()
    {
        out := Map()
        for k, v in this._runPbByActStage
            out[k] := v
        return out
    }

    ; Counts how many (act, stage) buckets have a saved PB. Useful
    ; for the reset UI. Pre-B1 this counted distinct acts (max 4);
    ; post-B1 each act has up to two buckets (normal + interlude)
    ; so the count can reach 8.
    CountActPbs()
    {
        n := 0
        for k, v in this._runPbByActStage
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
    ;   actCheckpointsMap  — ActCheckpointTracker.GetCheckpointsByStage()
    ;                        (composite keys "act|stage"). For
    ;                        backward compatibility, the legacy
    ;                        integer-keyed map is also accepted; each
    ;                        integer key is treated as the normal stage.
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

        ; Per-(act, stage) PB.
        if IsObject(actCheckpointsMap)
        {
            for k, actMs in actCheckpointsMap
            {
                if !IsNumber(actMs) || actMs <= 0
                    continue
                compositeKey := PersonalBestService._NormalizeCheckpointKey(k)
                if (compositeKey = "")
                    continue
                actMsInt := Integer(actMs)
                cur := this._runPbByActStage.Has(compositeKey) ? this._runPbByActStage[compositeKey] : 0
                if (cur = 0 || actMsInt < cur)
                {
                    this._runPbByActStage[compositeKey] := actMsInt
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
        this._runPbMs           := 0
        this._runPbRunId        := ""
        this._runPbByActStage   := Map()
        this._zonePbs           := Map()
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
        this._runPbMs           := 0
        this._runPbRunId        := ""
        this._runPbByActStage   := Map()
        this._zonePbs           := Map()

        if pbData.Has("runPbMs") && IsNumber(pbData["runPbMs"])
        {
            v := Integer(pbData["runPbMs"])
            if (v >= 0)
                this._runPbMs := v
        }
        if pbData.Has("runPbRunId")
            this._runPbRunId := String(pbData["runPbRunId"])
        ; Per-(act, stage) PB. Stage-aware shape is canonical; legacy
        ; integer-keyed shape is also accepted (treated as normal).
        if pbData.Has("runPbByActStage") && IsObject(pbData["runPbByActStage"])
        {
            for k, v in pbData["runPbByActStage"]
            {
                if !IsNumber(v) || Integer(v) <= 0
                    continue
                compositeKey := PersonalBestService._NormalizeCheckpointKey(k)
                if (compositeKey = "")
                    continue
                this._runPbByActStage[compositeKey] := Integer(v)
            }
        }
        if pbData.Has("runPbByAct") && IsObject(pbData["runPbByAct"])
        {
            for k, v in pbData["runPbByAct"]
            {
                if !IsNumber(k) || Integer(k) <= 0
                    continue
                if !IsNumber(v) || Integer(v) <= 0
                    continue
                legacyKey := Integer(k) . "|normal"
                if !this._runPbByActStage.Has(legacyKey)
                    this._runPbByActStage[legacyKey] := Integer(v)
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

        ; --- runPbByActStage (if checkpoints available) ---
        if IsObject(actCheckpoints)
        {
            newByActStage := Map()
            for k, ms in actCheckpoints
            {
                if !IsNumber(ms) || ms <= 0
                    continue
                compositeKey := PersonalBestService._NormalizeCheckpointKey(k)
                if (compositeKey = "")
                    continue
                newByActStage[compositeKey] := Integer(ms)
            }
            if (newByActStage.Count > 0)
            {
                ; Compare serialized to detect a real change
                if (PersonalBestService._MapToDebugStr(this._runPbByActStage)
                    != PersonalBestService._MapToDebugStr(newByActStage))
                {
                    this._runPbByActStage := newByActStage
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
        prevByActStr := PersonalBestService._MapToDebugStr(this._runPbByActStage)
        prevZoneStr  := PersonalBestService._MapToDebugStr(this._zonePbs)

        ; Reset in memory (does NOT persist yet)
        this._runPbMs           := 0
        this._runPbRunId        := ""
        this._runPbByActStage   := Map()
        this._zonePbs           := Map()

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

            ; Per-(act, stage) PB.
            if runItem.Has("actCheckpoints") && IsObject(runItem["actCheckpoints"])
            {
                for k, actMs in runItem["actCheckpoints"]
                {
                    if !IsNumber(actMs) || actMs <= 0
                        continue
                    compositeKey := PersonalBestService._NormalizeCheckpointKey(k)
                    if (compositeKey = "")
                        continue
                    val := Integer(actMs)
                    cur := this._runPbByActStage.Has(compositeKey) ? this._runPbByActStage[compositeKey] : 0
                    if (cur = 0 || val < cur)
                        this._runPbByActStage[compositeKey] := val
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
        newByActStr := PersonalBestService._MapToDebugStr(this._runPbByActStage)
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
            if data.Has("runPbByActStage") && IsObject(data["runPbByActStage"])
            {
                this._runPbByActStage := Map()
                for k, v in data["runPbByActStage"]
                {
                    if !IsNumber(v) || Integer(v) <= 0
                        continue
                    compositeKey := PersonalBestService._NormalizeCheckpointKey(k)
                    if (compositeKey = "")
                        continue
                    this._runPbByActStage[compositeKey] := Integer(v)
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
            "runPbMs",          this._runPbMs,
            "runPbRunId",       this._runPbRunId,
            "runPbByActStage",  this._runPbByActStage,
            "zonePbs",          this._zonePbs
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

    ; ---- Static helpers ----

    ; Accepts checkpoint-map keys in two shapes and returns the
    ; canonical composite "<act>|<stage>" string, or "" when the
    ; input doesn't fit either shape (caller skips).
    ;
    ; Shapes accepted:
    ;   1. Integer or numeric-string key  (legacy ActCheckpointTracker.
    ;      GetCheckpoints integer keys)     → "<act>|normal"
    ;   2. "<act>|<stage>" composite       (B1 Layer B,
    ;      ActCheckpointTracker.GetCheckpointsByStage)
    ;                                       → returned as-is
    ;
    ; Why dual-shape: existing callers (RunSnapshotSaver, tests,
    ; LoadFromExternal, RebuildFromHistory reading legacy history
    ; INIs) still pass integer-keyed maps. This helper centralizes
    ; the conversion so the rest of the service speaks the composite
    ; shape exclusively.
    static _NormalizeCheckpointKey(rawKey)
    {
        if IsNumber(rawKey) && rawKey > 0
            return Integer(rawKey) . "|normal"
        keyStr := String(rawKey)
        if RegExMatch(keyStr, "i)^(\d+)\|(normal|interlude)$", &m)
        {
            actNum := Integer(m[1] + 0)
            if (actNum > 0)
                return actNum . "|" . StrLower(m[2])
        }
        ; Numeric string ("1") that wasn't a composite: treat as legacy.
        if RegExMatch(keyStr, "^\d+$")
        {
            actNum := Integer(keyStr + 0)
            if (actNum > 0)
                return actNum . "|normal"
        }
        return ""
    }
}
