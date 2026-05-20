; ============================================================
; DeathStatsService - aggregates DeathLogRepository entries
; ============================================================
;
; Consumed by DeathStatsDialog. Reads every recorded death from
; DeathLogRepository, optionally filters by patch/profile, drops
; town zones via ZonesCatalog, and returns counts per zone sorted
; descending plus the lists of patches/profiles seen in the log
; (those populate the dropdowns in the UI).
;
; No cache: Aggregate() re-reads the CSV every call. The log is
; append-only and grows by a handful of bytes per death, so the
; full read is cheap even at 10k+ entries; caching would buy
; little and introduce an invalidation problem (the upstream
; handler appends from a separate code path).
;
; Filtering semantics:
;   - empty filter Map         -> no filter applied
;   - filter has "patch" key   -> only rows where row.patch matches
;   - filter has "profile" key -> only rows where row.profile matches
;   - both keys                -> both must match (AND)
;
; "Available" lists (patches, profiles) are extracted from the
; ENTIRE dataset, NOT from the filtered subset. The UI uses them
; to populate dropdowns that the user picks from to set the
; filter -- limiting them to the current filter would hide
; selectable options after the first pick.
;
; Town zones: filtered out by ZonesCatalog.IsTownName when a
; catalog is provided. Without a catalog (test setups, missing
; CSV) every zone passes -- defensive, matches the same fallback
; that RunStatsPlotBuilder uses. Unknown zones (not in catalog)
; also pass: a fresh game patch with new zones still surfaces in
; the stats instead of vanishing.
;
; AHK v2 gotcha: parameter is `catalog`, not `zonesCatalog` --
; AHK variable lookup is case-insensitive, and `is ZonesCatalog`
; would collide with a `zonesCatalog` local. Same convention as
; ZoneTrackingService / RunStatsPlotBuilder.


class DeathStatsService
{
    _deathLog := ""
    _catalog  := ""

    __New(deathLog, catalog := "")
    {
        if !(deathLog is DeathLogRepository)
            throw TypeError("DeathStatsService: 'deathLog' must be DeathLogRepository")
        if (catalog != "" && !(catalog is ZonesCatalog))
            throw TypeError("DeathStatsService: 'catalog' must be ZonesCatalog or empty")
        this._deathLog := deathLog
        this._catalog  := catalog
    }

    ; Aggregate(filter := "") -> Map
    ;
    ; filter: Map (or "") with optional keys "patch" and "profile".
    ;         Missing/empty keys mean "no filter on that dimension".
    ;
    ; Returns:
    ;   Map(
    ;     "totalDeaths"       : Integer,  count after filter+town drop
    ;     "perZone"           : Array<Map{zoneName, count}>, desc by count
    ;     "availablePatches"  : Array<string>, unique + sorted (alpha)
    ;     "availableProfiles" : Array<string>, unique + sorted (alpha)
    ;   )
    Aggregate(filter := "")
    {
        rows := this._deathLog.LoadAll()

        patchFilter   := DeathStatsService._GetFilterValue(filter, "patch")
        profileFilter := DeathStatsService._GetFilterValue(filter, "profile")

        ; Map used as a set: presence-of-key is what matters.
        patchSet    := Map()
        profileSet  := Map()
        countByZone := Map()
        totalDeaths := 0

        for _, row in rows
        {
            if !IsObject(row)
                continue

            ; "Available" lists reflect the WHOLE log, not the filter.
            ; Collected before the filter check so the dropdowns always
            ; offer every option the user has ever recorded.
            patch := row.Has("patch") ? String(row["patch"]) : ""
            if (patch != "")
                patchSet[patch] := true

            profile := row.Has("profile") ? String(row["profile"]) : ""
            if (profile != "")
                profileSet[profile] := true

            ; Apply filter
            if (patchFilter != "" && patch != patchFilter)
                continue
            if (profileFilter != "" && profile != profileFilter)
                continue

            ; Defensive: corrupted rows with empty zoneName should
            ; not become a phantom bar in the chart.
            zoneName := row.Has("zoneName") ? String(row["zoneName"]) : ""
            if (zoneName = "")
                continue

            ; Skip towns when a catalog is wired. Unknown zones (not
            ; in the catalog) are NOT skipped -- IsTownName returns
            ; false for them, which is the desired behavior (new
            ; zones from a future patch still get counted).
            if IsObject(this._catalog) && this._catalog.IsTownName(zoneName)
                continue

            countByZone[zoneName] := (countByZone.Has(zoneName)
                ? countByZone[zoneName] : 0) + 1
            totalDeaths += 1
        }

        ; Build perZone Array<Map> + sort desc by count. Insertion sort
        ; is fine; even on a year of play this is < 100 unique zones.
        perZone := []
        for zoneName, count in countByZone
            perZone.Push(Map("zoneName", zoneName, "count", count))
        DeathStatsService._SortByCountDesc(perZone)

        return Map(
            "totalDeaths",       totalDeaths,
            "perZone",           perZone,
            "availablePatches",  DeathStatsService._MapKeysSorted(patchSet),
            "availableProfiles", DeathStatsService._MapKeysSorted(profileSet)
        )
    }

    ; ============================================================
    ; Private helpers
    ; ============================================================

    ; Reads `filter[key]` defensively. Returns "" for any of:
    ; filter is not a Map, key missing, value empty/whitespace.
    ; Centralising the check keeps Aggregate readable and gives a
    ; single place to evolve the filter contract.
    static _GetFilterValue(filter, key)
    {
        if !IsObject(filter)
            return ""
        if !(filter is Map)
            return ""
        if !filter.Has(key)
            return ""
        v := String(filter[key])
        return Trim(v) = "" ? "" : v
    }

    ; In-place insertion sort: descending by "count". Stable order
    ; (equal counts preserve insertion order, which mirrors the
    ; for-loop order over countByZone -- AHK's Map preserves
    ; insertion order). Ties are visually unimportant for the bar
    ; chart but stability avoids flicker on re-open with same data.
    static _SortByCountDesc(arr)
    {
        if !IsObject(arr) || arr.Length < 2
            return
        n := arr.Length
        i := 2
        while (i <= n)
        {
            j := i
            while (j > 1 && arr[j]["count"] > arr[j - 1]["count"])
            {
                tmp := arr[j]
                arr[j] := arr[j - 1]
                arr[j - 1] := tmp
                j -= 1
            }
            i += 1
        }
    }

    ; Returns the keys of `setMap` as an Array, sorted alphabetically
    ; case-insensitively. Case-insensitive because the user picks
    ; from a dropdown -- "Default" and "default" sorting next to
    ; each other is more useful than ASCII order ("D" before "d").
    static _MapKeysSorted(setMap)
    {
        out := []
        for k, _ in setMap
            out.Push(String(k))
        ; Insertion sort, ascending. Same shape as _SortByCountDesc
        ; above but compares strings via StrCompare(..., 1) which
        ; is case-insensitive.
        n := out.Length
        i := 2
        while (i <= n)
        {
            j := i
            while (j > 1 && StrCompare(out[j], out[j - 1], 1) < 0)
            {
                tmp := out[j]
                out[j] := out[j - 1]
                out[j - 1] := tmp
                j -= 1
            }
            i += 1
        }
        return out
    }
}
