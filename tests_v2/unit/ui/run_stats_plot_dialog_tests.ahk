; ============================================================
; RunStatsPlotDialog tests
; ============================================================
;
; RunStatsPlotDialog is the "Run Statistics" window: KPIs, current
; run stacked bar, and a line chart of evolution across saved runs.
; In production it owns a Gui and a GDI-backed line chart canvas;
; for tests we exercise the dialog in `headless=true` mode and the
; pure aggregation/formatting algorithms directly.
;
; What's testable headless:
;   - Constructor type-checking
;   - Static methods (_PaletteAt, _ColorForLabel) — deterministic
;   - Open()/Close() lifecycle through the `headless` short-circuit
;     in _ShowWithData (no Gui constructed)
;   - Aggregation helpers (_GetSegmentsForRun + _Segs* family,
;     _BuildLineChartSeries, _CollectRunsForChart) — read-only over
;     plain Maps, no Gui touched
;   - Filter logic (_GetAvailableProfiles, min-act + profile filters)
;   - Y-axis scaling (_RoundUpYMax)
;   - Formatting (_FormatTimeShort, _ShortDateForLabel)
;   - Hidden-series state (_ToggleSeriesVisibility,
;     _IsSeriesHidden — Map mutation only)
;
; What's NOT testable here (covered by manual / future integration):
;   - GUI rendering itself (_BuildGui creates real Gui controls)
;   - GDI line-chart drawing (LineChartRenderer needs an HDC)
;   - Dropdown event wiring (OnEvent handlers need a real Gui)


class RunStatsPlotDialogTests extends TestCase
{
    bus         := ""
    cfg         := ""
    catalog     := ""
    catalogPath := ""
    builder     := ""
    recorder    := ""
    zoneTracker := ""
    stubClock   := ""
    timer       := ""
    runHistDir  := ""
    runHistory  := ""
    dialog      := ""
    _idCounter  := 0

    Setup()
    {
        this._idCounter := 0
        this.bus       := Fixtures.MakeBus()
        this.stubClock := Fixtures.MakeFakeClock(1000)
        this.cfg       := AppSettings.Defaults()

        ; Catalog with a handful of zones across acts (mirrors the
        ; integration setup so the SegsByAct test has real act labels
        ; to aggregate against).
        this.catalogPath := Fixtures.TempPath("csv")
        FileAppend(
            "name;internal_id;act;is_town`n"
            . "Clearfell Encampment;G1_town;1;1`n"
            . "Mud Burrow;G1_3;1;0`n"
            . "The Karui Shores;G3_town;3;1`n",
            this.catalogPath, "UTF-8")
        this.catalog := ZonesCatalog(this.catalogPath)

        this.builder     := RunStatsPlotBuilder(this.catalog, this.cfg)
        this.recorder    := RunStatsRecorder(this.bus, this.stubClock)
        this.zoneTracker := ZoneTrackingService(this.bus, this.stubClock, this.catalog)
        this.timer       := TimerService(this.stubClock, this.bus)

        this.runHistDir  := Fixtures.TempDir()
        this.runHistory  := RunHistoryRepository(this.runHistDir)

        this.dialog := RunStatsPlotDialog(
            this.bus, this.builder, this.recorder, this.zoneTracker,
            this.timer, this.runHistory, true   ; headless
        )
    }

    Teardown()
    {
        if IsObject(this.dialog)
            try this.dialog.Close()
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_plot_builder_not_plot_builder",
        "constructor_throws_when_recorder_not_run_stats_recorder",
        "constructor_throws_when_zone_tracker_not_zone_tracking_service",
        "constructor_throws_when_timer_not_timer_service",

        ; --- Static methods ---
        "palette_at_wraps_modulo_palette_length",
        "color_for_label_is_deterministic_for_same_label",
        "color_for_label_handles_empty_string",

        ; --- Headless lifecycle ---
        "headless_open_with_data_marks_is_open_true",
        "close_resets_is_open_to_false",
        "headless_open_does_not_build_gui",

        ; --- Aggregation: _Segs* family ---
        "segs_run_returns_segments_from_totals_skipping_zero",
        "segs_by_act_aggregates_details_by_act_number",
        "segs_by_act_accepts_legacy_ato_notes",
        "segs_by_category_filters_and_aggregates_by_label",

        ; --- Aggregation: _BuildLineChartSeries ---
        "build_line_chart_series_returns_empty_for_no_runs",
        "build_line_chart_series_marks_absent_label_as_not_present",

        ; --- Filters ---
        "collect_runs_for_chart_filters_by_min_act",
        "collect_runs_for_chart_filters_by_profile",
        "get_available_profiles_dedups_and_sorts_alphabetically",

        ; --- Y-axis + formatting ---
        "round_up_y_max_uses_candidate_thresholds",
        "round_up_y_max_falls_back_to_input_for_extreme_values",
        "format_time_short_seconds_minutes_hours",
        "short_date_for_label_extracts_from_first_ts_or_run_id",

        ; --- Hidden series state ---
        "toggle_series_visibility_adds_and_removes_from_hidden_set",
        "hidden_series_state_is_scoped_per_granularity"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _MakeBuildResult(profile := "Default", totalMs := 600000, maxAct := 3, totals := "", details := "", runId := "")
    {
        ; Builds a minimal buildResult Map matching what
        ; RunStatsPlotBuilder.Build emits — enough for the dialog's
        ; aggregation helpers to consume without re-running the
        ; builder pipeline.
        ;
        ; runId defaults to a fresh per-test counter so multiple
        ; calls within the same test produce DIFFERENT runIds. Without
        ; that, two calls to runHistory.Save would write to the same
        ; data/runs/{runId}.ini path and silently overwrite each
        ; other (Save returns true both times), breaking any test
        ; that exercises filtering across multiple saved runs.
        if (runId = "")
        {
            this._idCounter += 1
            runId := "20260101_120000_" . Format("{:03}", this._idCounter)
        }
        if (totals = "")
            totals := Map("mapa", 400000, "cidade", 100000, "loading", 80000, "morte", 20000)
        if (details = "")
            details := []
        return Map(
            "runId",         runId,
            "profile",       profile,
            "patch",         "0.2.0",
            "firstTs",       "2026-01-01 12:00:00",
            "totalMs",       totalMs,
            "deathCount",    0,
            "maxActReached", maxAct,
            "totals",        totals,
            "actCheckpoints", Map(),
            "details",       details
        )
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        b := this.builder, r := this.recorder, z := this.zoneTracker, t := this.timer
        Assert.Throws(TypeError, () => RunStatsPlotDialog("not bus", b, r, z, t))
    }

    constructor_throws_when_plot_builder_not_plot_builder()
    {
        bus := this.bus, r := this.recorder, z := this.zoneTracker, t := this.timer
        Assert.Throws(TypeError, () => RunStatsPlotDialog(bus, "not builder", r, z, t))
    }

    constructor_throws_when_recorder_not_run_stats_recorder()
    {
        bus := this.bus, b := this.builder, z := this.zoneTracker, t := this.timer
        Assert.Throws(TypeError, () => RunStatsPlotDialog(bus, b, "not recorder", z, t))
    }

    constructor_throws_when_zone_tracker_not_zone_tracking_service()
    {
        bus := this.bus, b := this.builder, r := this.recorder, t := this.timer
        Assert.Throws(TypeError, () => RunStatsPlotDialog(bus, b, r, "not zone tracker", t))
    }

    constructor_throws_when_timer_not_timer_service()
    {
        bus := this.bus, b := this.builder, r := this.recorder, z := this.zoneTracker
        Assert.Throws(TypeError, () => RunStatsPlotDialog(bus, b, r, z, "not timer"))
    }

    ; ============================================================
    ; Static methods
    ; ============================================================

    palette_at_wraps_modulo_palette_length()
    {
        ; ROTATING_PALETTE has 15 entries; index 0 and index 15 must
        ; return the same color (wrap-around guarantees the chart
        ; never runs out of colors no matter how many series exist).
        c0  := RunStatsPlotDialog._PaletteAt(0)
        c15 := RunStatsPlotDialog._PaletteAt(15)
        c30 := RunStatsPlotDialog._PaletteAt(30)
        Assert.Equal(c0, c15, "_PaletteAt wraps at the palette length")
        Assert.Equal(c0, c30, "wraps consistently at 2× length")
        ; Length 15 is the contract — if a future change shrinks the
        ; palette this test alerts before the chart starts duplicating
        ; colors in the visible range.
        Assert.True(StrLen(c0) = 6, "palette entries are 6-char RRGGBB hex")
    }

    color_for_label_is_deterministic_for_same_label()
    {
        ; Stable color via hash: the SAME label always gets the same
        ; color across script restarts. That stability is what lets
        ; the user recognize "Mud Burrow is the blue line" between
        ; two opens of the dialog.
        c1 := RunStatsPlotDialog._ColorForLabel("Mud Burrow")
        c2 := RunStatsPlotDialog._ColorForLabel("Mud Burrow")
        Assert.Equal(c1, c2, "same label hashes to same color")

        ; Different labels should hash differently (probabilistic,
        ; not guaranteed — but the project's catalog has well-spread
        ; names where collisions are unlikely).
        c3 := RunStatsPlotDialog._ColorForLabel("Clearfell")
        Assert.True(c1 != c3 || c2 != c3, "different labels usually hash to different colors")
    }

    color_for_label_handles_empty_string()
    {
        ; Edge case: empty label falls back to the first palette
        ; entry. Without the guard, the StrLen=0 loop in the hash
        ; would never run and the modulo would divide by zero on
        ; legacy data with missing labels.
        c := RunStatsPlotDialog._ColorForLabel("")
        Assert.True(StrLen(c) = 6, "empty label returns a valid color")
        Assert.Equal(c, RunStatsPlotDialog._PaletteAt(0),
            "empty label deterministically maps to palette[0]")
    }

    ; ============================================================
    ; Headless lifecycle
    ; ============================================================

    headless_open_with_data_marks_is_open_true()
    {
        Assert.False(this.dialog.IsOpen(), "initially closed")
        result := this.dialog.OpenWithData(this._MakeBuildResult())
        Assert.True(result, "OpenWithData returns true on success")
        Assert.True(this.dialog.IsOpen(), "IsOpen flips after Open in headless")
    }

    close_resets_is_open_to_false()
    {
        this.dialog.OpenWithData(this._MakeBuildResult())
        Assert.True(this.dialog.IsOpen())
        this.dialog.Close()
        Assert.False(this.dialog.IsOpen(), "Close resets the IsOpen flag")
    }

    headless_open_does_not_build_gui()
    {
        ; The whole point of headless mode: _ShowWithData short-circuits
        ; before _BuildGui, so this.dialog._gui stays "". If this
        ; assertion ever fails, the Gui short-circuit in _ShowWithData
        ; was removed and integration tests would start creating real
        ; windows during the suite.
        this.dialog.OpenWithData(this._MakeBuildResult())
        Assert.Equal("", this.dialog._gui,
            "headless mode keeps the Gui field empty (no real window built)")
    }

    ; ============================================================
    ; Aggregation: _Segs* family
    ; ============================================================

    segs_run_returns_segments_from_totals_skipping_zero()
    {
        ; "run" granularity = 4 fixed segments straight from totals,
        ; one per RunStatsPlotBuilder.SegmentDefinitions entry. Entries
        ; with ms <= 0 are skipped so the legend doesn't show empty
        ; categories (e.g. "Deaths" when deathCount = 0 leaves morte=0
        ; in totals and the bar/legend silently omit it).
        runData := this._MakeBuildResult( , , ,
            Map("mapa", 100000, "cidade", 50000, "loading", 0, "morte", 0))
        segs := this.dialog._GetSegmentsForRun(runData, "run")
        ; mapa + cidade should appear; loading + morte are zero and skipped.
        Assert.Equal(2, segs.Length, "zero-ms categories are skipped")
        Assert.Equal("Map",  segs[1]["label"])
        Assert.Equal(100000, segs[1]["ms"])
        Assert.Equal("Town", segs[2]["label"])
    }

    segs_by_act_aggregates_details_by_act_number()
    {
        ; "ato" granularity groups detail rows by the act number
        ; parsed from `note`. Sum is per act across all categories
        ; (map + town + death) — that's the comparison the user
        ; wants when looking for "where did I lose time this act".
        runData := this._MakeBuildResult( , , , ,
            [
                Map("category", "mapa",   "label", "Z1", "ms", 100000, "note", "Act 1", "timestamp", ""),
                Map("category", "mapa",   "label", "Z2", "ms", 50000,  "note", "Act 1", "timestamp", ""),
                Map("category", "cidade", "label", "T1", "ms", 30000,  "note", "Act 2", "timestamp", ""),
                Map("category", "mapa",   "label", "Z3", "ms", 80000,  "note", "Act 2", "timestamp", "")
            ])
        segs := this.dialog._GetSegmentsForRun(runData, "ato")
        Assert.Equal(2, segs.Length, "2 distinct acts produce 2 segments")
        ; Act 1: 100k + 50k = 150k
        Assert.Equal("Act 1",  segs[1]["label"])
        Assert.Equal(150000,   segs[1]["ms"])
        ; Act 2: 30k + 80k = 110k
        Assert.Equal("Act 2",  segs[2]["label"])
        Assert.Equal(110000,   segs[2]["ms"])
    }

    segs_by_act_accepts_legacy_ato_notes()
    {
        ; Legacy saves used Portuguese "Ato N" instead of "Act N".
        ; The regex accepts both so older runs still plot correctly
        ; under "by act" granularity. Without this, every legacy run
        ; would show an empty by-act chart.
        runData := this._MakeBuildResult( , , , ,
            [
                Map("category", "mapa", "label", "Z1", "ms", 50000, "note", "Ato 1", "timestamp", ""),
                Map("category", "mapa", "label", "Z2", "ms", 70000, "note", "Ato 2", "timestamp", "")
            ])
        segs := this.dialog._GetSegmentsForRun(runData, "ato")
        Assert.Equal(2, segs.Length)
        Assert.Equal("Act 1", segs[1]["label"])
        Assert.Equal("Act 2", segs[2]["label"])
    }

    segs_by_category_filters_and_aggregates_by_label()
    {
        ; "mapa" granularity = sum ms per unique label, filtered to
        ; category=mapa only. Duplicates with the same label are
        ; combined (the player can re-enter the same map multiple
        ; times in one run).
        runData := this._MakeBuildResult( , , , ,
            [
                Map("category", "mapa",   "label", "Mud Burrow", "ms", 100000, "note", "", "timestamp", ""),
                Map("category", "mapa",   "label", "Mud Burrow", "ms", 50000,  "note", "", "timestamp", ""),
                Map("category", "mapa",   "label", "Clearfell",  "ms", 80000,  "note", "", "timestamp", ""),
                Map("category", "cidade", "label", "Town",       "ms", 30000,  "note", "", "timestamp", "")
            ])
        segs := this.dialog._GetSegmentsForRun(runData, "mapa")
        Assert.Equal(2, segs.Length, "Mud Burrow + Clearfell, town excluded")
        ; Sorted desc by ms — Mud Burrow (150k) before Clearfell (80k).
        Assert.Equal("Mud Burrow", segs[1]["label"])
        Assert.Equal(150000,       segs[1]["ms"])
        Assert.Equal("Clearfell",  segs[2]["label"])
        Assert.Equal(80000,        segs[2]["ms"])
    }

    ; ============================================================
    ; Aggregation: _BuildLineChartSeries
    ; ============================================================

    build_line_chart_series_returns_empty_for_no_runs()
    {
        result := this.dialog._BuildLineChartSeries([])
        Assert.True(IsObject(result) && result is Array)
        Assert.Equal(0, result.Length, "no runs => no series")
    }

    build_line_chart_series_marks_absent_label_as_not_present()
    {
        ; Under a dynamic granularity (e.g. "mapa"), if a label
        ; appears in some runs but not others, the missing points
        ; get `present: false`. The line renderer breaks the line at
        ; those points instead of drawing a misleading floor at 0.
        ; (Under "run" granularity this is suppressed — ms=0 is real
        ; data there, not absence, see _BuildLineChartSeries's
        ; `useGap` short-circuit.)
        this.dialog._granularity := "mapa"
        runs := [
            this._MakeBuildResult( , , , , [
                Map("category", "mapa", "label", "Mud Burrow", "ms", 50000, "note", "", "timestamp", "")
            ]),
            this._MakeBuildResult( , , , , [
                Map("category", "mapa", "label", "Clearfell", "ms", 70000, "note", "", "timestamp", "")
            ])
        ]
        series := this.dialog._BuildLineChartSeries(runs)
        Assert.True(series.Length >= 1, "at least one series produced")

        ; Find the Mud Burrow series — it has a present point at run
        ; 0 and a NOT-present point at run 1.
        mudBurrowSeries := ""
        for _, s in series
        {
            if (s["label"] = "Mud Burrow")
            {
                mudBurrowSeries := s
                break
            }
        }
        Assert.True(IsObject(mudBurrowSeries), "Mud Burrow series present")
        Assert.Equal(2, mudBurrowSeries["points"].Length, "one point per run")
        Assert.True(mudBurrowSeries["points"][1]["present"],
            "run 1 has Mud Burrow data => point present")
        Assert.False(mudBurrowSeries["points"][2]["present"],
            "run 2 lacks Mud Burrow => point marked NOT present (line breaks)")
    }

    ; ============================================================
    ; Filters
    ; ============================================================

    collect_runs_for_chart_filters_by_min_act()
    {
        ; minActFilter=2 keeps only runs with maxActReached >= 2. The
        ; integration of this filter with the chart is what lets the
        ; user say "only show me runs that reached Act 2+" so a one-
        ; minute Act 1 dry run doesn't pull the y-axis down.
        ;
        ; Setup: 2 saved runs (act 1 and act 3) + current data passed
        ; in. Filter to act 2+ should drop the act-1 saved run.
        this.runHistory.Save(this._MakeBuildResult("P", 200000, 1))   ; act 1
        this.runHistory.Save(this._MakeBuildResult("P", 400000, 3))   ; act 3
        currentData := this._MakeBuildResult("P", 500000, 2)

        this.dialog._minActFilter := 2
        this.dialog._profileFilter := ""    ; ensure profile filter doesn't interfere

        runs := this.dialog._CollectRunsForChart(currentData)
        ; Expect: act-3 saved run + current run (act 2). Act-1 dropped.
        Assert.Equal(2, runs.Length, "act 1 saved run filtered out by min-act=2")
    }

    collect_runs_for_chart_filters_by_profile()
    {
        ; Profile filter isolates the chart to one profile so the
        ; user can compare like-for-like (different builds tend to
        ; live under different profile names).
        this.runHistory.Save(this._MakeBuildResult("Alice", 200000, 3))
        this.runHistory.Save(this._MakeBuildResult("Bob",   300000, 3))
        currentData := this._MakeBuildResult("Alice", 500000, 3)

        this.dialog._profileFilter := "Alice"
        this.dialog._minActFilter  := 0

        runs := this.dialog._CollectRunsForChart(currentData)
        ; Expect: Alice saved + current (also Alice). Bob dropped.
        Assert.Equal(2, runs.Length, "Bob's run filtered out by profile=Alice")
    }

    get_available_profiles_dedups_and_sorts_alphabetically()
    {
        ; Profile dropdown populated from current run + saved runs,
        ; deduped (same profile across multiple runs shows once),
        ; sorted alphabetically so the user finds their build by
        ; scanning down the list.
        this.runHistory.Save(this._MakeBuildResult("Zeta",  100000, 3))
        this.runHistory.Save(this._MakeBuildResult("Alice", 200000, 3))
        this.runHistory.Save(this._MakeBuildResult("Alice", 300000, 3))   ; duplicate
        this.runHistory.Save(this._MakeBuildResult("Bob",   400000, 3))

        currentData := this._MakeBuildResult("Charlie", 500000, 3)

        profiles := this.dialog._GetAvailableProfiles(currentData)
        ; Expect: Alice, Bob, Charlie, Zeta — sorted, no duplicates.
        Assert.Equal(4, profiles.Length, "deduplication leaves 4 unique profiles")
        Assert.Equal("Alice",   profiles[1])
        Assert.Equal("Bob",     profiles[2])
        Assert.Equal("Charlie", profiles[3])
        Assert.Equal("Zeta",    profiles[4])
    }

    ; ============================================================
    ; Y-axis + formatting
    ; ============================================================

    round_up_y_max_uses_candidate_thresholds()
    {
        ; The candidate list (30s, 60s, 2m, 5m, 10m, 15m, 30m, 1h,
        ; 2h, 4h) keeps the chart's y-axis label set to round-feeling
        ; numbers. Each input lands on the SMALLEST candidate that's
        ; >= the input.
        Assert.Equal(30000,   this.dialog._RoundUpYMax(1000),   "1s rounds up to 30s")
        Assert.Equal(30000,   this.dialog._RoundUpYMax(30000),  "30s exactly hits the threshold")
        Assert.Equal(60000,   this.dialog._RoundUpYMax(45000),  "45s rounds up to 1min")
        Assert.Equal(300000,  this.dialog._RoundUpYMax(120001), "just over 2min rounds to 5min")
        Assert.Equal(3600000, this.dialog._RoundUpYMax(1800001),"just over 30min rounds to 1h")
    }

    round_up_y_max_falls_back_to_input_for_extreme_values()
    {
        ; 0 and negative inputs return the default minimum (60s) so
        ; the chart still has a visible y-axis even with no data.
        Assert.Equal(60000, this.dialog._RoundUpYMax(0),     "zero falls back to 60s default")
        Assert.Equal(60000, this.dialog._RoundUpYMax(-1000), "negative falls back to 60s default")
        ; Inputs above the largest candidate (4h = 14_400_000) return
        ; the input itself — the chart adapts to truly extreme runs
        ; rather than capping silently.
        Assert.Equal(20000000, this.dialog._RoundUpYMax(20000000),
            "beyond 4h returns input as-is")
    }

    format_time_short_seconds_minutes_hours()
    {
        ; Compact axis labels: "Ns" under a minute, "Nm" under an hour,
        ; "NhMM" otherwise. Used in y-axis ticks where space is tight.
        Assert.Equal("0",    this.dialog._FormatTimeShort(0),       "zero is just '0'")
        Assert.Equal("45s",  this.dialog._FormatTimeShort(45000),   "45s")
        Assert.Equal("5m",   this.dialog._FormatTimeShort(300000),  "5min")
        Assert.Equal("1h",   this.dialog._FormatTimeShort(3600000), "exact hour drops the minutes")
        Assert.Equal("1h30", this.dialog._FormatTimeShort(5400000), "90min as 1h30")
    }

    short_date_for_label_extracts_from_first_ts_or_run_id()
    {
        ; X-axis label per run on the line chart. Prefers firstTs
        ; ("MM-DD HH:MM") so two runs from the same day are
        ; distinguishable by time of day; falls back to runId
        ; when firstTs is missing (older saves).
        runWithTs := Map("firstTs", "2026-05-15 14:23:45", "runId", "20260515_142345_999")
        Assert.Equal("05-15 14:23", this.dialog._ShortDateForLabel(runWithTs))

        runIdOnly := Map("firstTs", "", "runId", "20260601_093045_000")
        Assert.Equal("06-01 09:30", this.dialog._ShortDateForLabel(runIdOnly))

        runEmpty := Map("firstTs", "", "runId", "")
        Assert.Equal("", this.dialog._ShortDateForLabel(runEmpty))
    }

    ; ============================================================
    ; Hidden series state
    ; ============================================================

    toggle_series_visibility_adds_and_removes_from_hidden_set()
    {
        ; Initial state: nothing hidden.
        Assert.False(this.dialog._IsSeriesHidden("Map"))

        ; Toggle on → hidden.
        ; _ToggleSeriesVisibility also rebuilds the chart from
        ; _currentData if non-empty; with _currentData="" it just
        ; mutates the Map. We exercise the mutation path here.
        this.dialog._granularity := "run"
        this.dialog._currentData := ""
        this.dialog._ToggleSeriesVisibility("Map")
        Assert.True(this.dialog._IsSeriesHidden("Map"),
            "first toggle hides the series")

        ; Toggle again → visible.
        this.dialog._ToggleSeriesVisibility("Map")
        Assert.False(this.dialog._IsSeriesHidden("Map"),
            "second toggle reveals it again")
    }

    hidden_series_state_is_scoped_per_granularity()
    {
        ; A label hidden under "run" granularity must NOT be hidden
        ; when the user switches to "mapa" — labels mean different
        ; things in each mode (Map=category in run, Map=label in
        ; mapa) and applying the hide across modes would lose user
        ; intent. The _HiddenKey embeds the granularity to keep them
        ; isolated.
        this.dialog._currentData := ""

        this.dialog._granularity := "run"
        this.dialog._ToggleSeriesVisibility("Map")
        Assert.True(this.dialog._IsSeriesHidden("Map"),
            "Map hidden under 'run'")

        this.dialog._granularity := "mapa"
        Assert.False(this.dialog._IsSeriesHidden("Map"),
            "the SAME label is NOT hidden under 'mapa' — scope is per granularity")
    }
}

TestRegistry.Register(RunStatsPlotDialogTests)
