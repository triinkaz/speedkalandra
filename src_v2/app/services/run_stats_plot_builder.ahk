; ============================================================
; RunStatsPlotBuilder - aggregates a run snapshot into a renderable Map
; ============================================================
;
; POST-DEMOLITION VERSION (Wave 5):
;   - No RunRepository / LoadingRepository (no historical persistence).
;   - Receives data via Map snapshot and aggregates it into totals + details.
;   - Zeroed-up categories: mapa / cidade / loading / morte.
;   - No transitionMs (was step-based, removed).
;   - boss category REMOVED in v17.13 (boss tracking left the app).
;
; DATA SOURCE (snapshot):
;   Map(
;     "runId":         "20260512_1423",
;     "profile":       "Default",
;     "patch":         "0.4",
;     "firstTs":       "2026-05-12 14:23:45",
;     "runDurationMs": 5040000,
;     "zoneTotals":    Map<zoneName, totalMs>,        ; ZoneTrackingService.GetTotals()
;     "loadingEvents": Array< Map{fromZone,toZone,durationMs,ts} >,
;     "deathCount":    int
;   )
;
; CATEGORIES:
;   mapa     - aggregated time of zones with isTown=false
;   cidade   - aggregated time of zones with isTown=true
;   loading  - sum of durationMs across all loadingEvents
;   morte    - deathCount * deathPenaltyMs (cfg)
;
; OUTPUT (Map):
;   runId         (string)
;   profile       (string)
;   patch         (string)
;   firstTs       (string)
;   totals        (Map<key, ms>)
;   details       (Array<Map>)    {category, categoryLabel, label, ms, note, timestamp}
;   deathCount    (int)
;   totalMs       (int)
;   maxActReached (int)            ; v17.13 — highest act number visited in the run
;                                  ; (derived from the `note` of details). Used by
;                                  ; the "Min Act" filter in the plot dialog.
;
; CONSTRUCTION:
;   builder := RunStatsPlotBuilder(catalog, cfg)
;   data := builder.Build(snapshot)
;
; NOTE ON PARAMETER NAME:
;   AHK v2 does case-insensitive variable lookup. Param `zonesCatalog`
;   would collide with the `ZonesCatalog` class on the right side of
;   `is` (fails with "Expected a Class but got a ZonesCatalog"). Hence
;   `catalog` — case-insensitive-distinct.


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

    ; ============================================================
    ; Category definitions (visual parity with legacy)
    ; ============================================================
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

    ; ============================================================
    ; Build(snapshot) -> Map
    ; ============================================================
    Build(snapshot)
    {
        data := this._InitData(snapshot)
        if !IsObject(snapshot)
            return data

        this._AddZoneDetails(data, snapshot)
        this._AddLoadingDetails(data, snapshot)
        this._AddDeathDetails(data, snapshot)

        data["totalMs"] := RunStatsPlotBuilder._TotalFromTotals(data["totals"])
        data["maxActReached"] := RunStatsPlotBuilder._DeriveMaxAct(data["details"])
        return data
    }

    ; Derives the MAX act reached from the details. Iterates notes
    ; looking for "Ato N" or "Act N" patterns (compat with runs saved
    ; in v17.13 or earlier which used "Ato") and returns the highest
    ; N. 0 if not found.
    ;
    ; v17.13: used by the dialog to filter comparable runs in the chart.
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

    ; ============================================================
    ; Init
    ; ============================================================
    _InitData(snapshot)
    {
        totals := Map()
        for _, key in RunStatsPlotBuilder.SEGMENT_KEYS
            totals[key] := 0

        ; v0.1.0: local `runId` collides case-insensitively with the `RunId`
        ; class (#Warn LocalSameAsGlobal). Same resolution adopted elsewhere
        ; in the project: use `currentRunId`.
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

    ; ============================================================
    ; _AddZoneDetails - iterates zoneTotals; categorizes by isTown
    ; ============================================================
    _AddZoneDetails(data, snapshot)
    {
        if !snapshot.Has("zoneTotals") || !IsObject(snapshot["zoneTotals"])
            return
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
            this._AddDetail(data, category, zoneName, ms, note, "")
        }
    }

    ; ============================================================
    ; _AddLoadingDetails - iterates loadingEvents
    ; ============================================================
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

    ; ============================================================
    ; _AddDeathDetails - uses snapshot.deathCount * cfg.deathPenaltyMs
    ;
    ; v17.15.1: respects cfg.deathPenaltyEnabled. If disabled, deaths
    ; appear in deathCount but do not add a bar to the plot.
    ; ============================================================
    _AddDeathDetails(data, snapshot)
    {
        count := data["deathCount"]
        if (count <= 0)
            return
        if !this._settings.deathPenaltyEnabled
            return
        penalty := this._settings.deathPenaltyMs
        ; Sum as a single aggregated entry -- per-death details stay out
        ; of the simplified plot. The composition root can add more
        ; detail by passing deathEvents in the snapshot in the future.
        this._AddDetail(data, "morte", count " deaths",
            count * penalty, "Penalty " RunStatsPlotBuilder._FormatMs(penalty) " each", "")
    }

    ; ============================================================
    ; _AddDetail
    ; ============================================================
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

    ; ============================================================
    ; Static helpers
    ; ============================================================
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

    ; v0.1.2 (audit #19): _FormatMs consolidated into Duration.FormatMs.
    ; Kept as an internal static alias for back-compat with this file's
    ; call sites (including _AddDeathDetails which passes the penalty).
    static _FormatMs(ms) => Duration.FormatMs(ms)
}
