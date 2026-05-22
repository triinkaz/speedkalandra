; RunAverageService — the "average of the latest N runs" alternative
; to PersonalBestService for the PB display modes (see
; cfg.pbDisplayMode in AppSettings).
;
; Pull-based, mirroring PersonalBestService. Three query surfaces,
; one per PB category the live widgets consult:
;
;   GetAverageRunMs()              ←→ PersonalBestService.GetRunPbMs
;   GetAverageRunMsForAct(actNum)  ←→ PersonalBestService.GetRunPbForAct
;   GetAverageZoneMs(zoneName)     ←→ PersonalBestService.GetZonePbMs
;
; Source data: RunHistoryRepository. The latest N runs (sorted by
; mtime desc inside ListRunIds) are averaged. N is the static
; N_RECENT constant; not exposed in the UI yet (the user asked for
; "average of the last 5", so 5 is hard-wired here and named so
; tests + future UI surfacing have a single edit point).
;
; ARITHMETIC:
;
;   GetAverageRunMs:
;     mean of buildResult["totalMs"] across runs where totalMs > 0.
;
;   GetAverageRunMsForAct(N):
;     mean of buildResult["actCheckpoints"][N] across runs that
;     REACHED act N (i.e., have a positive checkpoint for that act).
;     Legacy runs persisted before [checkpoints] existed land with
;     an empty Map and contribute nothing — they don't drag the
;     average down with phantom zeroes.
;
;   GetAverageZoneMs(name):
;     mean of (sum of all visits to that zone within one run) across
;     runs where the zone appears in details with category=mapa or
;     cidade. Same exclusion the PB service applies (loading / morte
;     are excluded). Multiple visits in one run are summed before
;     the run is counted once.
;
; CACHING:
;
;   Two caches with separate invalidation:
;     - run/per-act averages: built from LoadSummaries (fast — meta
;       + totals + checkpoints, no details). Invalidated on dirty.
;     - per-zone averages: built from Load(runId) per run (slow —
;       requires the details section). Lazy-built on first zone
;       query after a dirty flip; subsequent queries hit the cache.
;
;   Dirty flag is raised by Evt.RunCompleted and Evt.RunCancelled.
;   Both events can result in a new INI on disk (RunCancelled saves
;   when the run lasted at least 3 minutes — see RunSnapshotSaver).
;   Re-loading on both is the safe superset; there is no
;   correctness loss in re-loading when nothing changed.
;
; TOS COMPLIANCE (GSG §18):
;   This service interacts ONLY with data\runs\*.ini, written by
;   this same tracker. No reading of Client.txt, no input
;   simulation, no GGG API or website access. No risk under PoE2
;   Terms of Use.


class RunAverageService
{
    ; Window size for the average. The user asked for "last 5"; the
    ; constant exists so a future UI surface or a knob in
    ; AppSettings has a single edit point.
    static N_RECENT := 5

    _runHistory := ""
    _bus        := ""
    _warn       := ""

    _dirty           := true     ; true means re-read summaries on the next query
    _avgRunMs        := 0
    _avgByAct        := ""       ; Map<actNum, ms>
    _zoneCacheReady  := false    ; true after _RecomputeZones; cleared by _Invalidate
    _avgByZone       := ""       ; Map<zoneName, ms>

    ; Handler refs — same pattern as the other services. Dispose
    ; needs the exact closure reference Subscribe was called with.
    _handlerCompleted := ""
    _handlerCancelled := ""

    __New(runHistory, bus, sinkOrEmpty := "")
    {
        if !(runHistory is RunHistoryRepository)
            throw TypeError("RunAverageService: 'runHistory' must be RunHistoryRepository")
        if !(bus is EventBus)
            throw TypeError("RunAverageService: 'bus' must be EventBus")
        this._runHistory := runHistory
        this._bus        := bus
        ; Parameter `sinkOrEmpty` (not `warningSink`) avoids the
        ; AHK v2 case-insensitive shadow of WarningSink — same
        ; convention as PersonalBestService / RunHistoryRepository.
        this._warn       := WarningSink.Resolve(sinkOrEmpty)
        this._avgByAct   := Map()
        this._avgByZone  := Map()

        this._handlerCompleted := (data) => this._Invalidate()
        this._handlerCancelled := (data) => this._Invalidate()
        bus.Subscribe(Events.RunCompleted, this._handlerCompleted)
        bus.Subscribe(Events.RunCancelled, this._handlerCancelled)
    }

    ; ---- Queries ----

    GetAverageRunMs()
    {
        this._RecomputeIfDirty()
        return this._avgRunMs
    }

    HasAverageRunMs() => this.GetAverageRunMs() > 0

    GetAverageRunMsForAct(actNum)
    {
        if !IsNumber(actNum) || actNum <= 0
            return 0
        this._RecomputeIfDirty()
        key := Integer(actNum)
        return this._avgByAct.Has(key) ? this._avgByAct[key] : 0
    }

    HasAverageRunMsForAct(actNum) => this.GetAverageRunMsForAct(actNum) > 0

    GetAverageZoneMs(zoneName)
    {
        zStr := String(zoneName)
        if (zStr = "")
            return 0
        this._RecomputeIfDirty()
        if !this._zoneCacheReady
            this._RecomputeZones()
        return this._avgByZone.Has(zStr) ? this._avgByZone[zStr] : 0
    }

    HasAverageZoneMs(zoneName) => this.GetAverageZoneMs(zoneName) > 0

    ; Test / diagnostics surface. Returns a defensive copy so
    ; mutation of the returned Map can't taint the cache.
    GetAllAverageActMs()
    {
        this._RecomputeIfDirty()
        out := Map()
        for k, v in this._avgByAct
            out[k] := v
        return out
    }

    GetAllAverageZoneMs()
    {
        this._RecomputeIfDirty()
        if !this._zoneCacheReady
            this._RecomputeZones()
        out := Map()
        for k, v in this._avgByZone
            out[k] := v
        return out
    }

    ; Manual invalidation hook for callers that change the on-disk
    ; runs outside the RunCompleted / RunCancelled path (run-history
    ; delete, run-import). The bus subscriptions cover the live
    ; finalize paths; this method is the explicit knob for the
    ; offline manipulation paths.
    Invalidate() => this._Invalidate()

    ; ---- Internals ----

    _Invalidate()
    {
        this._dirty := true
        ; Zone cache stays invalid until the next zone query — both
        ; halves of the recompute reset together so a stale
        ; per-zone average can't sneak through after a new run lands.
        this._zoneCacheReady := false
    }

    _RecomputeIfDirty()
    {
        if !this._dirty
            return
        this._dirty := false

        ; Reset caches before re-populating. Without this, a delete
        ; that drops every run would leave the previous averages
        ; visible (the recompute below would short-circuit on an
        ; empty result and never zero them).
        this._avgRunMs := 0
        this._avgByAct := Map()
        this._zoneCacheReady := false   ; zones recomputed lazily on demand

        try
        {
            summaries := this._runHistory.LoadSummaries(RunAverageService.N_RECENT)
        }
        catch as ex
        {
            this._warn.Warn("LoadSummaries failed during average recompute", ex)
            return
        }
        if !IsObject(summaries) || summaries.Length = 0
            return

        ; --- Average totalMs across the N most recent runs ---
        ; Skip runs with non-positive totalMs (defensive — Save
        ; rejects totalMs < 1000 upstream, but a corrupt INI could
        ; still load with 0/missing). The denominator counts only
        ; runs that contributed, so the average isn't dragged down
        ; by phantom zero-length runs.
        sumTotal   := 0
        countTotal := 0
        for _, summary in summaries
        {
            if !IsObject(summary)
                continue
            ms := summary.Has("totalMs") ? summary["totalMs"] : 0
            if !IsNumber(ms) || ms <= 0
                continue
            sumTotal   += Integer(ms)
            countTotal += 1
        }
        if (countTotal > 0)
            this._avgRunMs := Integer(sumTotal / countTotal)

        ; --- Average per-act checkpoint ---
        ; Per-act denominator counts only runs that REACHED that
        ; act. A run that ended in Act 2 doesn't have a checkpoint
        ; for Act 3, so it doesn't contribute to the Act 3 average.
        actAccum := Map()    ; Map<actNum, Map{sum, count}>
        for _, summary in summaries
        {
            if !IsObject(summary)
                continue
            ckpts := summary.Has("actCheckpoints") ? summary["actCheckpoints"] : ""
            if !IsObject(ckpts)
                continue
            for actNum, actMs in ckpts
            {
                if !IsNumber(actNum) || actNum <= 0
                    continue
                if !IsNumber(actMs) || actMs <= 0
                    continue
                key := Integer(actNum)
                if !actAccum.Has(key)
                    actAccum[key] := Map("sum", 0, "count", 0)
                actAccum[key]["sum"]   += Integer(actMs)
                actAccum[key]["count"] += 1
            }
        }
        for actNum, agg in actAccum
        {
            if (agg["count"] > 0)
                this._avgByAct[actNum] := Integer(agg["sum"] / agg["count"])
        }
    }

    _RecomputeZones()
    {
        ; Zone averages are the slow path: each run needs a full
        ; Load() to surface its details section. Cost is bound to
        ; N_RECENT runs (5 INI reads in practice) and the result is
        ; cached until the next dirty flip.
        this._avgByZone := Map()
        this._zoneCacheReady := true

        try
        {
            ids := this._runHistory.ListRunIds(RunAverageService.N_RECENT)
        }
        catch as ex
        {
            this._warn.Warn("ListRunIds failed during zone-average recompute", ex)
            return
        }
        if !IsObject(ids) || ids.Length = 0
            return

        zoneAccum := Map()   ; Map<zone, Map{sum, count}>
        for _, runId in ids
        {
            try
            {
                buildResult := this._runHistory.Load(runId)
            }
            catch as ex
            {
                this._warn.Warn("Load(" . String(runId)
                    . ") failed during zone-average recompute", ex)
                continue
            }
            if !IsObject(buildResult)
                continue
            details := buildResult.Has("details") ? buildResult["details"] : ""
            if !IsObject(details)
                continue

            ; Aggregate per-zone total IN THIS run. A run may visit
            ; the same zone multiple times (death + portal back);
            ; sum all visits within a run before averaging across
            ; runs, so each run contributes a single sample per
            ; zone — same shape as PersonalBestService's zone PB
            ; comparison basis (GetZoneTotalWithActive sums all
            ; visits).
            perRunZoneSum := Map()
            for _, d in details
            {
                if !IsObject(d)
                    continue
                cat := d.Has("category") ? d["category"] : ""
                ; Only combat-eligible categories enter zone averages.
                ; Mirrors the same filter PersonalBestService applies
                ; via RebuildFromHistory — see that method for the
                ; full rationale (loading + morte don't represent
                ; zone-time the player can compare to a PB).
                if (cat != "mapa" && cat != "cidade")
                    continue
                zone := d.Has("label") ? String(d["label"]) : ""
                if (zone = "")
                    continue
                ms := d.Has("ms") ? d["ms"] : 0
                if !IsNumber(ms) || ms <= 0
                    continue
                perRunZoneSum[zone] := (perRunZoneSum.Has(zone)
                    ? perRunZoneSum[zone] : 0) + Integer(ms)
            }

            for zone, ms in perRunZoneSum
            {
                if !zoneAccum.Has(zone)
                    zoneAccum[zone] := Map("sum", 0, "count", 0)
                zoneAccum[zone]["sum"]   += ms
                zoneAccum[zone]["count"] += 1
            }
        }

        for zone, agg in zoneAccum
        {
            if (agg["count"] > 0)
                this._avgByZone[zone] := Integer(agg["sum"] / agg["count"])
        }
    }

    ; ---- Cleanup ----

    Dispose()
    {
        if (this._handlerCompleted != "")
        {
            try this._bus.Unsubscribe(Events.RunCompleted, this._handlerCompleted)
            this._handlerCompleted := ""
        }
        if (this._handlerCancelled != "")
        {
            try this._bus.Unsubscribe(Events.RunCancelled, this._handlerCancelled)
            this._handlerCancelled := ""
        }
    }
}
