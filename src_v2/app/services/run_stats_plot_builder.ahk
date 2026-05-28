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
;     "zoneTotals":    Map<zoneName, totalMs>,                  (legacy)
;     "zoneTotalsByStage": Map<"zoneName|stage", totalMs>,      (B1, optional)
;     "zoneFirstEnteredAt": Map<zoneName, ts>,                  (optional)
;     "loadingEvents": Array<Map{fromZone, toZone, durationMs, ts, stage?}>,
;     "deathCount":    int
;   )
;
; Stage handling (B1 Layer B):
;   The builder is forward-compatible with cruel/interlude stage
;   data flowing through the snapshot. When `zoneTotalsByStage` is
;   present, each composite "<zoneName>|<stage>" entry emits its
;   own detail row with the matching stage flag. Otherwise the
;   legacy `zoneTotals` Map is consumed and every entry defaults
;   to stage="normal". Loading events carry their own optional
;   `stage` field, defaulting to "normal" when absent. Deaths
;   currently carry no stage (single aggregated row); the
;   Interlude filter ignores them, matching the act filter's
;   exemption for the same reason.
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
;                                    ms, note, stage, timestamp}
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
        zoneFirstEnteredAt := snapshot.Has("zoneFirstEnteredAt")
                              && IsObject(snapshot["zoneFirstEnteredAt"])
                              ? snapshot["zoneFirstEnteredAt"]
                              : Map()

        ; Prefer the stage-aware totals when the snapshot carries
        ; them — that's the post-B1 canonical shape. Fall back to
        ; the legacy `zoneTotals` Map (treated as all-normal) for
        ; pre-B1 snapshots and for any upstream that hasn't been
        ; wired through yet.
        if snapshot.Has("zoneTotalsByStage") && IsObject(snapshot["zoneTotalsByStage"])
        {
            for compositeKey, ms in snapshot["zoneTotalsByStage"]
            {
                if (ms <= 0)
                    continue
                ; Composite shape: "<zoneName>|<stage>". Unparseable
                ; entries are dropped (defensive — caller might
                ; have leaked a legacy integer-keyed map by mistake).
                if !RegExMatch(String(compositeKey), "^(.+)\|(normal|interlude)$", &m)
                    continue
                zoneName := m[1]
                stage    := m[2]
                if (zoneName = "")
                    continue
                this._EmitZoneDetail(data, zoneName, ms, stage, zoneFirstEnteredAt)
            }
            return
        }

        if !snapshot.Has("zoneTotals") || !IsObject(snapshot["zoneTotals"])
            return
        for zoneName, ms in snapshot["zoneTotals"]
        {
            if (ms <= 0)
                continue
            this._EmitZoneDetail(data, zoneName, ms, "normal", zoneFirstEnteredAt)
        }
    }

    ; Shared zone-detail emitter. Resolves category/act via the
    ; catalog (same fallbacks as before B1) and stamps the stage
    ; flag on the detail row.
    _EmitZoneDetail(data, zoneName, ms, stage, zoneFirstEnteredAt)
    {
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
        this._AddDetail(data, category, zoneName, ms, note, ts, stage)
    }

    ; Walks loadingEvents and emits one "loading" detail per event.
    ; Each event's `note` is derived from the destination zone's act
    ; via the catalog ("Act N"), so the act filter can drop
    ; loading rows that cross into other acts. Loadings whose
    ; toZone is unknown to the catalog get an empty note and are
    ; dropped under any active filter (exact-match semantics:
    ; unattributable entries are noise, not missing data).
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
            ; Derive note from the destination zone's act when the
            ; catalog knows it. The destination is the act the
            ; player is ABOUT TO play in, which is the right
            ; attribution for the act filter (a loading into
            ; Act 2 belongs to Act 2's budget, not Act 1's).
            note := ""
            if (toZ != "" && IsObject(this._zonesCatalog))
            {
                entry := this._zonesCatalog.FindByName(toZ)
                if IsObject(entry) && entry.act > 0
                    note := "Act " entry.act
            }
            ts := ev.Has("ts") ? ev["ts"] : (ev.Has("timestamp") ? ev["timestamp"] : "")
            ; Stage is optional on loading events; defaults to
            ; "normal" so legacy snapshots and upstreams that
            ; haven't been wired through yet behave correctly under
            ; the act filter (which keeps stage="normal" by default).
            stage := ev.Has("stage") ? String(ev["stage"]) : "normal"
            if (stage != "normal" && stage != "interlude")
                stage := "normal"
            this._AddDetail(data, "loading", label, ms, note, ts, stage)
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
        ; Deaths carry no stage (single aggregated row across both
        ; stages). The Interlude filter ignores them so the death
        ; count surfaces in the KPIs regardless of stage filter,
        ; matching the act-filter exemption for the same reason.
        this._AddDetail(data, "morte", count " deaths",
            count * penalty, "Penalty " RunStatsPlotBuilder._FormatMs(penalty) " each", "", "")
    }

    ; ---- Detail builder ----

    ; `stage` is one of "normal" or "interlude". Pre-B1 callers can
    ; omit it (defaults to "normal") so the snapshot pipeline can
    ; opt into stage tagging incrementally without breaking the
    ; rest of the build. Deaths pass "" because the aggregated row
    ; spans both stages by definition (single sum); see
    ; _AddDeathDetails. The Interlude filter ignores stage="" the
    ; same way it ignores deaths.
    _AddDetail(data, category, label, ms, note := "", timestamp := "", stage := "normal")
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
            "stage",         stage,
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

    ; ============================================================
    ; FilterByAct(data, actFilter)
    ; ============================================================
    ;
    ; Returns a NEW data Map filtered to include only details whose
    ; `note` references the EXACT act selected by the user, with
    ; `totals` and `totalMs` recomputed over the retained details.
    ; The input Map is NOT mutated — callers like RunStatsPlotDialog
    ; rebuild the view by reapplying the filter to the current
    ; source data on every dropdown change.
    ;
    ; Filter semantics:
    ;   actFilter = 0    -> no-op, returns a shallow copy of `data`.
    ;                       Used for "All" (idx 1).
    ;   actFilter >= 999 -> Interlude (cruel) filter. Keeps any
    ;                       detail whose stage == "interlude",
    ;                       regardless of act. Deaths bypass (no
    ;                       stage info; same rationale as the
    ;                       per-act exemption). Pre-B1 details that
    ;                       carry no stage default to "normal" via
    ;                       _AddDetail, so the Interlude filter
    ;                       returns an empty plot on legacy runs
    ;                       that never tracked cruel data — honest
    ;                       result, not data loss.
    ;   actFilter >= 1   -> keep details with parsed act EXACTLY
    ;                       equal to actFilter AND stage == "normal"
    ;                       (Act N in the campaign, not in cruel).
    ;                       Exact-match avoids the old "cut-above"
    ;                       semantics that gave the cumulative view
    ;                       and misled users into thinking the
    ;                       chart was hiding their maps. Deaths
    ;                       (category=morte) bypass the filter
    ;                       because they carry no timing/act/stage
    ;                       in the current snapshot schema (BACKLOG
    ;                       B2 traces the path that would add
    ;                       per-zone deaths); the full death count
    ;                       surfaces in the KPIs even when a
    ;                       specific act is selected. Details whose
    ;                       `note` doesn't parse to any act (legacy
    ;                       data, uncatalogued zones, loadings into
    ;                       uncatalogued destinations) are DROPPED
    ;                       under an active filter — under
    ;                       exact-match semantics, an
    ;                       unattributable entry adds noise rather
    ;                       than missing data.
    ;
    ; The act is extracted from `note` via the same regex used by
    ; `_DeriveMaxAct` and `_SegsByAct`, accepting both "Act N"
    ; (current) and "Ato N" (legacy Portuguese saves).
    ;
    ; `maxActReached` carries through unchanged — it describes the
    ; underlying run, not the filtered view.
    static FilterByAct(data, actFilter)
    {
        if !IsObject(data)
            return data
        if !IsNumber(actFilter) || actFilter <= 0
            return RunStatsPlotBuilder._ShallowCloneData(data)

        srcDetails := data.Has("details") && IsObject(data["details"])
            ? data["details"]
            : []

        out := RunStatsPlotBuilder._ShallowCloneData(data)
        filteredDetails := []
        newTotals := Map()
        for _, key in RunStatsPlotBuilder.SEGMENT_KEYS
            newTotals[key] := 0

        for _, d in srcDetails
        {
            if !IsObject(d)
                continue
            if !RunStatsPlotBuilder._DetailPassesAct(d, actFilter)
                continue
            filteredDetails.Push(d)
            cat := d.Has("category") ? d["category"] : ""
            ms  := d.Has("ms")       ? d["ms"]       : 0
            if (cat = "" || ms <= 0)
                continue
            if !newTotals.Has(cat)
                newTotals[cat] := 0
            newTotals[cat] += ms
        }

        out["details"] := filteredDetails
        out["totals"]  := newTotals
        out["totalMs"] := RunStatsPlotBuilder._TotalFromTotals(newTotals)
        ; maxActReached + runId + profile + patch + firstTs +
        ; deathCount survive from the shallow clone; they describe
        ; the underlying run, not the filtered view.
        return out
    }

    ; Returns true if the detail should be retained under the
    ; act filter. See FilterByAct header for the policy.
    static _DetailPassesAct(detail, actFilter)
    {
        ; Deaths bypass every filter (no timing/stage info).
        cat := detail.Has("category") ? detail["category"] : ""
        if (cat = "morte")
            return true

        ; Interlude filter (999) — keep only stage="interlude".
        stage := detail.Has("stage") ? String(detail["stage"]) : "normal"
        if (actFilter >= 999)
            return stage = "interlude"

        ; Per-act filter (1..4) — require stage="normal" AND the
        ; exact act number in the note. Interlude entries with the
        ; same "Act N" note string are excluded because the user
        ; picked the campaign act, not the cruel ladder.
        if (stage != "normal")
            return false

        note := detail.Has("note") ? detail["note"] : ""
        ; No parsed act -> drop under an active filter (exact-match
        ; semantics: unattributable entries are noise, not missing
        ; data). The unfiltered no-op path in FilterByAct already
        ; short-circuits actFilter=0 before reaching here, so this
        ; branch is only hit when the user picked a specific act.
        if !RegExMatch(note, "(?:Ato|Act)\s+(\d+)", &m)
            return false

        act := Integer(m[1] + 0)
        if (act <= 0)
            return false
        return act = actFilter
    }

    ; Returns a shallow clone of the data Map so the caller can
    ; mutate `details` / `totals` / `totalMs` without affecting
    ; the source. Other fields (Strings, Ints) don't need cloning.
    static _ShallowCloneData(data)
    {
        out := Map()
        for k, v in data
            out[k] := v
        return out
    }
}
