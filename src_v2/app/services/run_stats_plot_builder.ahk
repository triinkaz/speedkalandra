; RunStatsPlotBuilder — aggregates a run snapshot into a renderable
; Map. The composition root passes data via Build(snapshot); no
; persistence happens here (the result is consumed by the plot
; renderer and optionally fed to RunHistoryRepository).
;
; Snapshot shape:
;   Map(
;     "runId":         "20260512_1423",
;     "profile":       "Default",
;     "patch":         "0.4",
;     "firstTs":       "2026-05-12 14:23:45",
;     "runDurationMs": 5040000,
;     "zoneTotals":    Map<zoneName, totalMs>,
;     "zoneFirstEnteredAt": Map<zoneName, ts>,    (optional)
;     "loadingEvents": Array<Map{fromZone, toZone, durationMs, ts}>,
;     "deathCount":    int
;   )
;
; Categories:
;   mapa     — zones with isTown=false
;   cidade   — zones with isTown=true
;   loading  — sum of all loadingEvents.durationMs
;   morte    — deathCount * cfg.deathPenaltyMs (gated by
;              cfg.deathPenaltyEnabled)
;
; Output Map:
;   runId / profile / patch / firstTs       (strings)
;   totals        (Map<key, ms>)
;   details       (Array<Map>) with {category, categoryLabel, label,
;                                    ms, note, timestamp}
;   deathCount / totalMs / maxActReached    (ints)
;
; AHK v2 gotcha: variable lookup is case-insensitive, so a parameter
; named `zonesCatalog` would collide with the `ZonesCatalog` class on
; the right side of `is` ("Expected a Class but got a ZonesCatalog").
; The constructor uses `catalog` to stay case-insensitive-distinct.


class RunStatsPlotBuilder
{
    _zonesCatalog := ""    ; ZonesCatalog or ""
    _settings     := ""    ; AppSettings

    static SEGMENT_KEYS := ["mapa", "cidade", "loading", "morte"]

    __New(catalog, cfg)
    {
        if (catalog != "" && !(catalog is ZonesCatalog))
            throw TypeError("RunStatsPlotBuilder: 'catalog' must be ZonesCatalog or empty")
        if !(cfg is AppSettings)
            throw TypeError("RunStatsPlotBuilder: 'cfg' must be AppSettings")
        this._zonesCatalog := catalog
        this._settings     := cfg
    }

    ; ---- Category definitions ----

    static SegmentDefinitions()
    {
        return [
            Map("key", "mapa",    "label", "Map",     "color", "38BDF8"),
            Map("key", "cidade",  "label", "Town",    "color", "A78BFA"),
            Map("key", "loading", "label", "Loading", "color", "FACC15"),
            Map("key", "morte",   "label", "Deaths",  "color", "EF4444")
        ]
    }

    static CategoryLabel(category)
    {
        for _, seg in RunStatsPlotBuilder.SegmentDefinitions()
            if (seg["key"] = category)
                return seg["label"]
        return "All"
    }

    static CategoryColor(category)
    {
        for _, seg in RunStatsPlotBuilder.SegmentDefinitions()
            if (seg["key"] = category)
                return seg["color"]
        return ""
    }

    ; ---- Build ----

    Build(snapshot)
    {
        data := this._InitData(snapshot)
        if !IsObject(snapshot)
            return data

        this._AddZoneDetails(data, snapshot)
        this._AddLoadingDetails(data, snapshot)
        this._AddDeathDetails(data, snapshot)

        ; Sort details chronologically by timestamp. Entries without
        ; a timestamp (legacy snapshots, aggregated deaths) are
        ; pushed to the end so the ordered ones stay grouped at the
        ; top of the list.
        RunStatsPlotBuilder._SortDetailsByTimestamp(data["details"])

        data["totalMs"] := RunStatsPlotBuilder._TotalFromTotals(data["totals"])
        data["maxActReached"] := RunStatsPlotBuilder._DeriveMaxAct(data["details"])
        return data
    }

    ; Stable insertion sort on the details array by timestamp.
    ; Empty timestamps are treated as +infinity (sentinel "~" sorts
    ; after every "YYYY-MM-DD HH:MM:SS" because '~' > '9'). Stable
    ; ordering preserves insertion order on ties (two events in the
    ; same second). Insertion sort is fine — details typically run
    ; under 50 entries.
    static _SortDetailsByTimestamp(details)
    {
        if !IsObject(details) || details.Length < 2
            return
        n := details.Length
        i := 2
        while (i <= n)
        {
            j := i
            while (j > 1)
            {
                tsA := RunStatsPlotBuilder._TimestampSortKey(details[j])
                tsB := RunStatsPlotBuilder._TimestampSortKey(details[j - 1])
                ; tsA < tsB means details[j] should come BEFORE details[j-1].
                ; StrCompare returns negative when a < b.
                if (StrCompare(tsA, tsB) >= 0)
                    break
                tmp := details[j]
                details[j] := details[j - 1]
                details[j - 1] := tmp
                j -= 1
            }
            i += 1
        }
    }

    ; Sort key for a detail. Empty timestamps get the sentinel "~"
    ; so they sort after every real "YYYY-MM-DD HH:MM:SS" value.
    static _TimestampSortKey(detail)
    {
        if !IsObject(detail) || !detail.Has("timestamp")
            return "~"
        ts := detail["timestamp"]
        if (ts = "")
            return "~"
        return String(ts)
    }

    ; Highest act number visited in the run, derived from the `note`
    ; field of each detail. Supports both "Act N" (current) and
    ; "Ato N" (older saves in Portuguese) for back-compat. Used by
    ; the history dialog's "Min Act" filter to compare like-with-like.
    static _DeriveMaxAct(details)
    {
        if !IsObject(details)
            return 0
        maxAct := 0
        for _, d in details
        {
            if !IsObject(d)
                continue
            note := d.Has("note") ? d["note"] : ""
            if !RegExMatch(note, "(?:Ato|Act)\s+(\d+)", &m)
                continue
            n := Integer(m[1] + 0)
            if (n > maxAct)
                maxAct := n
        }
        return maxAct
    }

    ; ---- Init ----

    _InitData(snapshot)
    {
        totals := Map()
        for _, key in RunStatsPlotBuilder.SEGMENT_KEYS
            totals[key] := 0

        ; Local `runId` collides case-insensitively with the `RunId`
        ; domain class (#Warn LocalSameAsGlobal). Same workaround as
        ; in the repositories: use `currentRunId`.
        currentRunId := IsObject(snapshot) && snapshot.Has("runId")      ? snapshot["runId"]      : ""
        profile      := IsObject(snapshot) && snapshot.Has("profile")    ? snapshot["profile"]    : ""
        patch        := IsObject(snapshot) && snapshot.Has("patch")      ? snapshot["patch"]      : ""
        firstTs      := IsObject(snapshot) && snapshot.Has("firstTs")    ? snapshot["firstTs"]    : ""
        deathCount   := IsObject(snapshot) && snapshot.Has("deathCount") ? snapshot["deathCount"] : 0

        ; Setting defaults if not provided in the snapshot
        if (profile = "")
            profile := this._settings.profileName
        if (patch = "")
            patch := this._settings.gamePatch

        return Map(
            "runId",         String(currentRunId),
            "profile",       String(profile),
            "patch",         String(patch),
            "firstTs",       String(firstTs),
            "totals",        totals,
            "details",       [],
            "deathCount",    Integer(deathCount),
            "totalMs",       0,
            "maxActReached", 0
        )
    }

    ; Iterates zoneTotals and categorizes each entry via ZonesCatalog
    ; (isTown → cidade, else → mapa). Falls back to "mapa" when the
    ; catalog is absent or doesn't know the zone. If the snapshot
    ; provides zoneFirstEnteredAt, the per-zone first-entry timestamp
    ; is attached to the detail so chronological sorting works.
    _AddZoneDetails(data, snapshot)
    {
        if !snapshot.Has("zoneTotals") || !IsObject(snapshot["zoneTotals"])
            return
        zoneFirstEnteredAt := snapshot.Has("zoneFirstEnteredAt")
                              && IsObject(snapshot["zoneFirstEnteredAt"])
                              ? snapshot["zoneFirstEnteredAt"]
                              : Map()
        for zoneName, ms in snapshot["zoneTotals"]
        {
            if (ms <= 0)
                continue
            ; Categorize via ZonesCatalog (fallback: treat as mapa)
            category := "mapa"
            act := 0
            if IsObject(this._zonesCatalog)
            {
                entry := this._zonesCatalog.FindByName(zoneName)
                if IsObject(entry)
                {
                    category := entry.isTown ? "cidade" : "mapa"
                    act := entry.act
                }
            }
            note := act > 0 ? "Act " act : ""
            ts := zoneFirstEnteredAt.Has(zoneName) ? zoneFirstEnteredAt[zoneName] : ""
            this._AddDetail(data, category, zoneName, ms, note, ts)
        }
    }

    ; Walks loadingEvents and emits one "loading" detail per event.
    _AddLoadingDetails(data, snapshot)
    {
        if !snapshot.Has("loadingEvents") || !IsObject(snapshot["loadingEvents"])
            return
        for _, ev in snapshot["loadingEvents"]
        {
            if !IsObject(ev)
                continue
            ms := ev.Has("durationMs") ? ev["durationMs"] : 0
            if (ms <= 0)
                continue

            fromZ := ev.Has("fromZone") ? ev["fromZone"] : ""
            toZ   := ev.Has("toZone")   ? ev["toZone"]   : ""
            label := "Loading"
            if (fromZ != "" || toZ != "")
            {
                f := fromZ != "" ? fromZ : "?"
                t := toZ   != "" ? toZ   : "?"
                label := f " -> " t
            }
            ts := ev.Has("ts") ? ev["ts"] : (ev.Has("timestamp") ? ev["timestamp"] : "")
            this._AddDetail(data, "loading", label, ms, "", ts)
            this._RememberMetaTs(data, ts)
        }
    }

    ; Adds an aggregated "morte" entry with (deathCount * penaltyMs).
    ; Gated by cfg.deathPenaltyEnabled: when disabled, deaths still
    ; appear in deathCount but contribute zero to the plot.
    _AddDeathDetails(data, snapshot)
    {
        count := data["deathCount"]
        if (count <= 0)
            return
        if !this._settings.deathPenaltyEnabled
            return
        penalty := this._settings.deathPenaltyMs
        ; Single aggregated entry — per-death entries would clutter
        ; the plot. If we ever want per-death detail, the composition
        ; root can pass deathEvents in the snapshot.
        this._AddDetail(data, "morte", count " deaths",
            count * penalty, "Penalty " RunStatsPlotBuilder._FormatMs(penalty) " each", "")
    }

    ; ---- Detail builder ----

    _AddDetail(data, category, label, ms, note := "", timestamp := "")
    {
        n := RunStatsPlotBuilder._ToInt(ms)
        if (n < 0)
            n := 0
        if !data["totals"].Has(category)
            data["totals"][category] := 0
        data["totals"][category] += n
        data["details"].Push(Map(
            "category",      category,
            "categoryLabel", RunStatsPlotBuilder.CategoryLabel(category),
            "label",         label,
            "ms",            n,
            "note",          note,
            "timestamp",     timestamp
        ))
    }

    _RememberMetaTs(data, ts)
    {
        if (ts = "")
            return
        if (data["firstTs"] = "" || StrCompare(ts, data["firstTs"]) < 0)
            data["firstTs"] := ts
    }

    ; ---- Static helpers ----

    static _ToInt(v)
    {
        n := 0
        try
            n := Integer(v + 0)
        catch
            n := 0
        return n
    }

    static _TotalFromTotals(totals)
    {
        total := 0
        for _, ms in totals
            total += RunStatsPlotBuilder._ToInt(ms)
        return total
    }

    static FormatMs(ms) => Duration.FormatMs(ms)

    ; Internal alias kept so existing call sites in this file
    ; (notably _AddDeathDetails) don't need rewriting.
    static _FormatMs(ms) => Duration.FormatMs(ms)
}
