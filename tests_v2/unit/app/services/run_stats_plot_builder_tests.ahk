; ============================================================
; RunStatsPlotBuilderTests
; ============================================================
;
; RunStatsPlotBuilder aggregates a run snapshot into a renderable Map.
; Deps:
;   catalog : ZonesCatalog or "" (to categorize map/town)
;   cfg     : AppSettings (deathPenaltyEnabled, deathPenaltyMs,
;             profileName, gamePatch)
;
; Categories (SEGMENT_KEYS): mapa / cidade / loading / morte
;
; Coverage:
;   - Constructor (type validation)
;   - Static methods (Definitions, CategoryLabel, CategoryColor, FormatMs)
;   - Build: output shape, fallbacks
;   - _AddZoneDetails (categorizes via catalog)
;   - _AddLoadingDetails (label "from -> to", firstTs)
;   - _AddDeathDetails (respects penaltyEnabled, count*penalty)
;   - maxActReached (regex in _DeriveMaxAct)
;   - totals + totalMs


class RunStatsPlotBuilderTests extends TestCase
{
    cfg         := ""
    catalog     := ""
    catalogPath := ""
    builder     := ""

    Setup()
    {
        this.cfg := AppSettings.Defaults()
        this.catalogPath := Fixtures.TempPath("csv")
        this._SeedCatalog([
            "name;internal_id;act;is_town",
            "Clearfell Encampment;G1_town;1;1",
            "Mud Burrow;G1_2;1;0",
            "The Ardura Caravan;G2_town;2;1",
            "Vastiri Outskirts;G2_1;2;0",
            "Sandswept Marsh;G3_1;3;0"
        ])
        this.catalog := ZonesCatalog(this.catalogPath)
        this.builder := RunStatsPlotBuilder(this.catalog, this.cfg)
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_catalog_is_random_object",
        "constructor_throws_when_cfg_not_app_settings",
        "constructor_accepts_empty_catalog",
        "constructor_accepts_zones_catalog",

        ; --- Static: SegmentDefinitions ---
        "segment_definitions_returns_4_categories",
        "segment_definitions_includes_mapa_cidade_loading_morte",

        ; --- Static: CategoryLabel ---
        "category_label_mapa_is_Map",
        "category_label_cidade_is_Town",
        "category_label_loading_is_Loading",
        "category_label_morte_is_Deaths",
        "category_label_unknown_falls_back_to_All",

        ; --- Static: CategoryColor ---
        "category_color_returns_hex_for_known_category",
        "category_color_returns_empty_for_unknown",

        ; --- Static: FormatMs ---
        "format_ms_zero_is_00_00",
        "format_ms_below_one_second_is_00_00",
        "format_ms_one_second_is_00_01",
        "format_ms_one_minute_is_01_00",
        "format_ms_one_hour_is_1_00_00",
        "format_ms_negative_clamps_to_zero",

        ; --- Build: output shape ---
        "build_with_non_object_snapshot_returns_data_with_zeros",
        "build_returns_map_with_all_required_keys",
        "build_uses_run_id_from_snapshot",
        "build_uses_profile_from_snapshot",
        "build_uses_patch_from_snapshot",
        "build_uses_first_ts_from_snapshot",
        "build_uses_death_count_from_snapshot",
        "build_falls_back_to_settings_profile_when_snapshot_empty",
        "build_falls_back_to_settings_patch_when_snapshot_empty",

        ; --- _AddZoneDetails ---
        "zone_known_as_normal_categorizes_as_mapa",
        "zone_known_as_town_categorizes_as_cidade",
        "zone_unknown_falls_back_to_mapa_with_no_note",
        "zone_with_zero_ms_skipped",
        "zone_with_negative_ms_skipped",
        "zone_note_includes_act_number_when_known",
        "zone_ms_accumulates_to_category_totals",

        ; --- _AddLoadingDetails ---
        "loading_event_pushed_with_from_to_label",
        "loading_event_uses_question_mark_when_from_missing",
        "loading_event_uses_question_mark_when_to_missing",
        "loading_event_label_is_just_Loading_when_both_missing",
        "loading_event_with_zero_ms_skipped",
        "loading_event_accumulates_to_loading_total",
        "loading_event_note_includes_act_from_to_zone",
        "loading_event_note_empty_when_to_zone_unknown",
        "loading_event_note_empty_when_to_zone_missing",

        ; --- _AddDeathDetails ---
        "death_count_zero_produces_no_detail",
        "death_count_with_penalty_enabled_adds_detail",
        "death_count_with_penalty_disabled_skips_detail",
        "death_detail_total_equals_count_times_penalty",
        "death_detail_label_includes_count",

        ; --- maxActReached ---
        "max_act_zero_when_no_notes",
        "max_act_extracts_from_act_note",
        "max_act_extracts_from_ato_note_for_legacy_runs",
        "max_act_picks_highest_among_notes",

        ; --- totals + totalMs ---
        "totals_initialized_with_all_four_keys_at_zero",
        "total_ms_is_sum_of_all_category_totals",

        ; --- Defensive: large run histories ---
        "build_aggregates_100_plus_zone_entries_without_overflow",
        "build_aggregates_100_plus_loading_events_without_overflow",

        ; --- FilterByAct (static) ---
        "filter_by_act_zero_is_no_op",
        "filter_by_act_negative_is_no_op",
        "filter_by_act_keeps_only_exact_match",
        "filter_by_act_drops_lower_acts_under_specific_filter",
        "filter_by_act_keeps_deaths_regardless_of_act",
        "filter_by_act_drops_details_without_parsed_act",
        "filter_by_act_keeps_loading_with_matching_act",
        "filter_by_act_drops_loading_with_non_matching_act",
        "filter_by_act_recomputes_totals",
        "filter_by_act_recomputes_total_ms",
        "filter_by_act_preserves_max_act_reached",
        "filter_by_act_preserves_metadata_fields",
        "filter_by_act_does_not_mutate_input",
        "filter_by_act_interlude_drops_normal_stage_details",
        "filter_by_act_interlude_keeps_only_interlude_stage",
        "filter_by_act_per_act_drops_interlude_stage",
        "filter_by_act_interlude_keeps_deaths_through_bypass",
        "filter_by_act_interlude_empty_when_no_cruel_data",

        ; --- B1 Layer B: stage propagation through Build() ---
        "build_emits_stage_normal_by_default_on_zone_details",
        "build_consumes_zone_totals_by_stage_when_present",
        "build_prefers_zone_totals_by_stage_over_legacy_zone_totals",
        "build_drops_unparseable_composite_zone_keys",
        "loading_event_emits_stage_normal_by_default",
        "loading_event_emits_stage_from_field",
        "loading_event_invalid_stage_falls_back_to_normal",
        "death_detail_carries_empty_stage"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _SeedCatalog(lines)
    {
        content := ""
        for _, csvLine in lines
            content .= csvLine "`n"
        FileAppend(content, this.catalogPath, "UTF-8")
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_catalog_is_random_object()
    {
        c := this.cfg
        Assert.Throws(TypeError, () => RunStatsPlotBuilder({not: "a catalog"}, c))
    }

    constructor_throws_when_cfg_not_app_settings()
    {
        cat := this.catalog
        Assert.Throws(TypeError, () => RunStatsPlotBuilder(cat, "not settings"))
    }

    constructor_accepts_empty_catalog()
    {
        ; "" is allowed (in case the catalog wasn't loaded)
        b := RunStatsPlotBuilder("", this.cfg)
        Assert.True(IsObject(b))
    }

    constructor_accepts_zones_catalog()
    {
        Assert.True(IsObject(this.builder))
    }

    ; ============================================================
    ; Static: SegmentDefinitions
    ; ============================================================

    segment_definitions_returns_4_categories()
    {
        defs := RunStatsPlotBuilder.SegmentDefinitions()
        Assert.Equal(4, defs.Length)
    }

    segment_definitions_includes_mapa_cidade_loading_morte()
    {
        defs := RunStatsPlotBuilder.SegmentDefinitions()
        seen := Map()
        for _, seg in defs
            seen[seg["key"]] := true
        Assert.True(seen.Has("mapa"))
        Assert.True(seen.Has("cidade"))
        Assert.True(seen.Has("loading"))
        Assert.True(seen.Has("morte"))
    }

    ; ============================================================
    ; Static: CategoryLabel
    ; ============================================================

    category_label_mapa_is_Map()
    {
        Assert.Equal("Map", RunStatsPlotBuilder.CategoryLabel("mapa"))
    }

    category_label_cidade_is_Town()
    {
        Assert.Equal("Town", RunStatsPlotBuilder.CategoryLabel("cidade"))
    }

    category_label_loading_is_Loading()
    {
        Assert.Equal("Loading", RunStatsPlotBuilder.CategoryLabel("loading"))
    }

    category_label_morte_is_Deaths()
    {
        Assert.Equal("Deaths", RunStatsPlotBuilder.CategoryLabel("morte"))
    }

    category_label_unknown_falls_back_to_All()
    {
        Assert.Equal("All", RunStatsPlotBuilder.CategoryLabel("nonexistent"))
    }

    ; ============================================================
    ; Static: CategoryColor
    ; ============================================================

    category_color_returns_hex_for_known_category()
    {
        Assert.Equal("38BDF8", RunStatsPlotBuilder.CategoryColor("mapa"))
        Assert.Equal("A78BFA", RunStatsPlotBuilder.CategoryColor("cidade"))
        Assert.Equal("FACC15", RunStatsPlotBuilder.CategoryColor("loading"))
        Assert.Equal("EF4444", RunStatsPlotBuilder.CategoryColor("morte"))
    }

    category_color_returns_empty_for_unknown()
    {
        Assert.Equal("", RunStatsPlotBuilder.CategoryColor("nonexistent"))
    }

    ; ============================================================
    ; Static: FormatMs
    ; ============================================================

    format_ms_zero_is_00_00()
    {
        Assert.Equal("00:00", RunStatsPlotBuilder.FormatMs(0))
    }

    format_ms_below_one_second_is_00_00()
    {
        Assert.Equal("00:00", RunStatsPlotBuilder.FormatMs(500))
    }

    format_ms_one_second_is_00_01()
    {
        Assert.Equal("00:01", RunStatsPlotBuilder.FormatMs(1000))
    }

    format_ms_one_minute_is_01_00()
    {
        Assert.Equal("01:00", RunStatsPlotBuilder.FormatMs(60000))
    }

    format_ms_one_hour_is_1_00_00()
    {
        Assert.Equal("1:00:00", RunStatsPlotBuilder.FormatMs(3600000))
    }

    format_ms_negative_clamps_to_zero()
    {
        Assert.Equal("00:00", RunStatsPlotBuilder.FormatMs(-1000))
    }

    ; ============================================================
    ; Build: output shape
    ; ============================================================

    build_with_non_object_snapshot_returns_data_with_zeros()
    {
        data := this.builder.Build("not an object")
        Assert.Equal(0, data["totalMs"])
        Assert.Equal(0, data["details"].Length)
    }

    build_returns_map_with_all_required_keys()
    {
        data := this.builder.Build(Map())
        for _, k in ["runId", "profile", "patch", "firstTs",
                     "totals", "details", "deathCount", "totalMs", "maxActReached"]
        {
            Assert.True(data.Has(k), "Missing key: " k)
        }
    }

    build_uses_run_id_from_snapshot()
    {
        data := this.builder.Build(Map("runId", "20260512_142345"))
        Assert.Equal("20260512_142345", data["runId"])
    }

    build_uses_profile_from_snapshot()
    {
        data := this.builder.Build(Map("profile", "Speedrunner"))
        Assert.Equal("Speedrunner", data["profile"])
    }

    build_uses_patch_from_snapshot()
    {
        data := this.builder.Build(Map("patch", "0.4"))
        Assert.Equal("0.4", data["patch"])
    }

    build_uses_first_ts_from_snapshot()
    {
        data := this.builder.Build(Map("firstTs", "2026-05-12 14:23:45"))
        Assert.Equal("2026-05-12 14:23:45", data["firstTs"])
    }

    build_uses_death_count_from_snapshot()
    {
        data := this.builder.Build(Map("deathCount", 3))
        Assert.Equal(3, data["deathCount"])
    }

    build_falls_back_to_settings_profile_when_snapshot_empty()
    {
        ; AppSettings.Defaults() has profileName="Default"
        data := this.builder.Build(Map())
        Assert.Equal("Default", data["profile"])
    }

    build_falls_back_to_settings_patch_when_snapshot_empty()
    {
        ; AppSettings.Defaults() has gamePatch="Unknown" (capital U)
        data := this.builder.Build(Map())
        Assert.Equal("Unknown", data["patch"])
    }

    ; ============================================================
    ; _AddZoneDetails
    ; ============================================================

    zone_known_as_normal_categorizes_as_mapa()
    {
        ; Mud Burrow: act=1, isTown=false
        data := this.builder.Build(Map("zoneTotals", Map("Mud Burrow", 60000)))
        Assert.Equal(60000, data["totals"]["mapa"])
        Assert.Equal(0,     data["totals"]["cidade"])
    }

    zone_known_as_town_categorizes_as_cidade()
    {
        ; Clearfell Encampment: act=1, isTown=true
        data := this.builder.Build(Map("zoneTotals", Map("Clearfell Encampment", 15000)))
        Assert.Equal(15000, data["totals"]["cidade"])
        Assert.Equal(0,     data["totals"]["mapa"])
    }

    zone_unknown_falls_back_to_mapa_with_no_note()
    {
        ; Zone not in the catalog
        data := this.builder.Build(Map("zoneTotals", Map("Unknown Zone", 50000)))
        Assert.Equal(50000, data["totals"]["mapa"])
        ; Detail has note="" (act=0, no "Act N")
        Assert.Equal("", data["details"][1]["note"])
    }

    zone_with_zero_ms_skipped()
    {
        data := this.builder.Build(Map("zoneTotals", Map("Mud Burrow", 0)))
        Assert.Equal(0, data["totals"]["mapa"])
        Assert.Equal(0, data["details"].Length)
    }

    zone_with_negative_ms_skipped()
    {
        data := this.builder.Build(Map("zoneTotals", Map("Mud Burrow", -100)))
        Assert.Equal(0, data["totals"]["mapa"])
    }

    zone_note_includes_act_number_when_known()
    {
        ; Vastiri Outskirts: act=2
        data := this.builder.Build(Map("zoneTotals", Map("Vastiri Outskirts", 100000)))
        Assert.Equal("Act 2", data["details"][1]["note"])
    }

    zone_ms_accumulates_to_category_totals()
    {
        data := this.builder.Build(Map("zoneTotals", Map(
            "Mud Burrow",       60000,
            "Vastiri Outskirts", 40000
        )))
        Assert.Equal(100000, data["totals"]["mapa"], "60000 + 40000")
    }

    ; ============================================================
    ; _AddLoadingDetails
    ; ============================================================

    loading_event_pushed_with_from_to_label()
    {
        data := this.builder.Build(Map("loadingEvents", [
            Map("durationMs", 4500, "fromZone", "Clearfell", "toZone", "Mud Burrow")
        ]))
        Assert.Equal(1, data["details"].Length)
        Assert.Equal("Clearfell -> Mud Burrow", data["details"][1]["label"])
        Assert.Equal("loading", data["details"][1]["category"])
    }

    loading_event_uses_question_mark_when_from_missing()
    {
        data := this.builder.Build(Map("loadingEvents", [
            Map("durationMs", 4500, "toZone", "Mud Burrow")
        ]))
        Assert.Equal("? -> Mud Burrow", data["details"][1]["label"])
    }

    loading_event_uses_question_mark_when_to_missing()
    {
        data := this.builder.Build(Map("loadingEvents", [
            Map("durationMs", 4500, "fromZone", "Clearfell")
        ]))
        Assert.Equal("Clearfell -> ?", data["details"][1]["label"])
    }

    loading_event_label_is_just_Loading_when_both_missing()
    {
        data := this.builder.Build(Map("loadingEvents", [
            Map("durationMs", 4500)
        ]))
        Assert.Equal("Loading", data["details"][1]["label"])
    }

    loading_event_with_zero_ms_skipped()
    {
        data := this.builder.Build(Map("loadingEvents", [
            Map("durationMs", 0, "toZone", "X")
        ]))
        Assert.Equal(0, data["totals"]["loading"])
        Assert.Equal(0, data["details"].Length)
    }

    loading_event_accumulates_to_loading_total()
    {
        data := this.builder.Build(Map("loadingEvents", [
            Map("durationMs", 1000, "toZone", "A"),
            Map("durationMs", 2500, "toZone", "B"),
            Map("durationMs",  500, "toZone", "C")
        ]))
        Assert.Equal(4000, data["totals"]["loading"])
    }

    loading_event_note_includes_act_from_to_zone()
    {
        ; Loadings into act-1 zones survive an actFilter=1 cut
        ; because their note is "Act 1" (derived from toZone).
        ; Loading note empty when toZone is unknown.
        data := this.builder.Build(Map("loadingEvents", [
            Map("durationMs", 3000, "fromZone", "Mud Burrow", "toZone", "Vastiri Outskirts")
        ]))
        Assert.Equal("Act 2", data["details"][1]["note"])
    }

    loading_event_note_empty_when_to_zone_unknown()
    {
        ; Catalog doesn't recognize "Mystery Place" → note stays
        ; empty. Under exact-match filtering an empty-note loading
        ; is dropped (no act attribution → can't match any
        ; specific act).
        data := this.builder.Build(Map("loadingEvents", [
            Map("durationMs", 2000, "fromZone", "Mud Burrow", "toZone", "Mystery Place")
        ]))
        Assert.Equal("", data["details"][1]["note"])
    }

    loading_event_note_empty_when_to_zone_missing()
    {
        ; No toZone field at all (e.g. a final-area loading before
        ; logout). Note stays empty, no false attribution to act 0.
        data := this.builder.Build(Map("loadingEvents", [
            Map("durationMs", 2000, "fromZone", "Mud Burrow")
        ]))
        Assert.Equal("", data["details"][1]["note"])
    }

    ; ============================================================
    ; _AddDeathDetails
    ; ============================================================

    death_count_zero_produces_no_detail()
    {
        data := this.builder.Build(Map("deathCount", 0))
        Assert.Equal(0, data["totals"]["morte"])
    }

    death_count_with_penalty_enabled_adds_detail()
    {
        ; Builder defaults have deathPenaltyEnabled=false (opt-in flag);
        ; this test exercises the enabled path explicitly so the
        ; assertion below is meaningful regardless of the default.
        cfg := AppSettings.Defaults()
        cfg.deathPenaltyEnabled := true
        builder := RunStatsPlotBuilder(this.catalog, cfg)
        data := builder.Build(Map("deathCount", 2))
        Assert.True(data["totals"]["morte"] > 0,
            "With penalty enabled and deathCount=2, total morte must be > 0")
    }

    death_count_with_penalty_disabled_skips_detail()
    {
        ; Create cfg with penalty disabled
        cfgDisabled := AppSettings.Defaults()
        cfgDisabled.deathPenaltyEnabled := false
        builder2 := RunStatsPlotBuilder(this.catalog, cfgDisabled)
        data := builder2.Build(Map("deathCount", 3))
        Assert.Equal(0, data["totals"]["morte"])
    }

    death_detail_total_equals_count_times_penalty()
    {
        cfgFixed := AppSettings.Defaults()
        cfgFixed.deathPenaltyEnabled := true
        cfgFixed.deathPenaltyMs      := 10000
        builder2 := RunStatsPlotBuilder(this.catalog, cfgFixed)
        data := builder2.Build(Map("deathCount", 3))
        Assert.Equal(30000, data["totals"]["morte"], "3 deaths * 10s = 30000ms")
    }

    death_detail_label_includes_count()
    {
        ; Builder defaults have deathPenaltyEnabled=false; flip on
        ; explicitly so the death detail is emitted and the label
        ; assertion below has something to match against.
        cfg := AppSettings.Defaults()
        cfg.deathPenaltyEnabled := true
        builder := RunStatsPlotBuilder(this.catalog, cfg)
        data := builder.Build(Map("deathCount", 5))
        ; Find the death detail
        for _, d in data["details"]
        {
            if (d["category"] = "morte")
            {
                Assert.Contains("5", d["label"])
                return
            }
        }
        Assert.Fail("Expected detail with category=morte")
    }

    ; ============================================================
    ; maxActReached
    ; ============================================================

    max_act_zero_when_no_notes()
    {
        data := this.builder.Build(Map())
        Assert.Equal(0, data["maxActReached"])
    }

    max_act_extracts_from_act_note()
    {
        ; Zone in act 2 -> note "Act 2"
        data := this.builder.Build(Map("zoneTotals", Map("Vastiri Outskirts", 1000)))
        Assert.Equal(2, data["maxActReached"])
    }

    max_act_extracts_from_ato_note_for_legacy_runs()
    {
        ; The regex also accepts "Ato N" (legacy PT-BR runs).
        ; We simulate by passing a snapshot whose detail
        ; already contains "Ato N" in the note. We can't force that
        ; via zone (which generates "Act N"); we need to test
        ; _DeriveMaxAct directly.
        details := [
            Map("category", "mapa", "label", "X", "ms", 100, "note", "Ato 5", "timestamp", "")
        ]
        Assert.Equal(5, RunStatsPlotBuilder._DeriveMaxAct(details))
    }

    max_act_picks_highest_among_notes()
    {
        ; Multiple zones in different acts -> max
        data := this.builder.Build(Map("zoneTotals", Map(
            "Mud Burrow",       100,   ; act 1
            "Vastiri Outskirts", 200,   ; act 2
            "Sandswept Marsh",   300    ; act 3
        )))
        Assert.Equal(3, data["maxActReached"])
    }

    ; ============================================================
    ; totals + totalMs
    ; ============================================================

    totals_initialized_with_all_four_keys_at_zero()
    {
        data := this.builder.Build(Map())
        for _, k in ["mapa", "cidade", "loading", "morte"]
        {
            Assert.True(data["totals"].Has(k))
            Assert.Equal(0, data["totals"][k])
        }
    }

    total_ms_is_sum_of_all_category_totals()
    {
        cfgFixed := AppSettings.Defaults()
        cfgFixed.deathPenaltyEnabled := true
        cfgFixed.deathPenaltyMs      := 5000
        builder2 := RunStatsPlotBuilder(this.catalog, cfgFixed)

        data := builder2.Build(Map(
            "zoneTotals", Map("Mud Burrow", 60000, "Clearfell Encampment", 15000),
            "loadingEvents", [Map("durationMs", 4000, "toZone", "X")],
            "deathCount", 2
        ))
        ; mapa=60000 + cidade=15000 + loading=4000 + morte=(2*5000)=10000 = 89000
        Assert.Equal(89000, data["totalMs"])
    }

    ; ============================================================
    ; Defensive: large run histories
    ; ============================================================
    ;
    ; The plot dialog feeds Build() either the current in-memory
    ; snapshot (RunStatsRecorder.GetSnapshot) or a snapshot
    ; reconstructed from a saved run. The latter is bounded by the
    ; import schema (MAX_DETAILS_PER_RUN = 1000), but the in-memory
    ; path has no equivalent cap — a long marathon run that traverses
    ; every zone several times will produce a large zoneTotals map
    ; and a long loadingEvents array. The builder must aggregate
    ; these in linear time without integer overflow or detail loss.
    ;
    ; 100 entries is the realistic worst case for a single run; the
    ; test uses 120 to exercise the path with margin.

    build_aggregates_100_plus_zone_entries_without_overflow()
    {
        ; 120 unknown zones (not in the catalog) at 60s each. Unknown
        ; zones categorize as `mapa` with an empty note, exercising
        ; the same code path a stress run with many novel zones
        ; would hit. Total: 120 * 60000 = 7,200,000 ms (2h). Well
        ; below INT_MAX (2^31-1 = ~2.1 billion), but high enough that
        ; a 16-bit accumulator would silently wrap to a small positive.
        zoneTotals := Map()
        loop 120
            zoneTotals["Zone_" A_Index] := 60000

        data := this.builder.Build(Map(
            "zoneTotals", zoneTotals,
            "deathCount", 0
        ))

        Assert.Equal(120, data["details"].Length,
            "every zone entry produced exactly one detail row")
        Assert.Equal(7200000, data["totals"]["mapa"],
            "sum is exact: 120 × 60000 ms, no overflow or rounding")
        Assert.Equal(7200000, data["totalMs"],
            "totalMs equals the sole non-zero category total")
    }

    build_aggregates_100_plus_loading_events_without_overflow()
    {
        ; 150 loading transitions at 5s each. Total: 750,000 ms
        ; (12.5 min of loading), which is plausible for a long
        ; play session with many zone changes. Each event becomes
        ; one detail row labeled "from -> to".
        loadingEvents := []
        loop 150
        {
            loadingEvents.Push(Map(
                "durationMs", 5000,
                "fromZone",   "Zone_" A_Index,
                "toZone",     "Zone_" (A_Index + 1)
            ))
        }

        data := this.builder.Build(Map(
            "loadingEvents", loadingEvents,
            "deathCount",    0
        ))

        Assert.Equal(150, data["details"].Length,
            "every loading event produced exactly one detail row")
        Assert.Equal(750000, data["totals"]["loading"],
            "sum is exact: 150 × 5000 ms")
        Assert.Equal(750000, data["totalMs"])
    }

    ; ============================================================
    ; FilterByAct (static)
    ; ============================================================
    ;
    ; The filter is applied by RunStatsPlotDialog on every dropdown
    ; change to the cached unfiltered build result, so it has to be
    ; idempotent, non-mutating, and cheap. Semantics is exact-match:
    ; an Act 2 filter shows ONLY Act 2 details (not Act 1+2). See
    ; the FilterByAct header in run_stats_plot_builder.ahk for the
    ; full policy on deaths, unparseable notes, and the Interlude
    ; placeholder.

    filter_by_act_zero_is_no_op()
    {
        ; actFilter = 0 means "All". Returns a shallow copy of
        ; data with the same details, totals, totalMs — nothing
        ; dropped.
        data := this.builder.Build(Map("zoneTotals", Map(
            "Mud Burrow",        60000,   ; act 1
            "Vastiri Outskirts", 40000    ; act 2
        )))
        filtered := RunStatsPlotBuilder.FilterByAct(data, 0)
        Assert.Equal(data["details"].Length, filtered["details"].Length)
        Assert.Equal(data["totalMs"],        filtered["totalMs"])
        Assert.Equal(data["totals"]["mapa"], filtered["totals"]["mapa"])
    }

    filter_by_act_negative_is_no_op()
    {
        ; Defensive: negative or non-numeric actFilter lands on
        ; the same no-op path as 0 (rather than throw, which would
        ; crash the dialog mid-render).
        data := this.builder.Build(Map("zoneTotals", Map("Mud Burrow", 60000)))
        filtered := RunStatsPlotBuilder.FilterByAct(data, -1)
        Assert.Equal(1, filtered["details"].Length)
        Assert.Equal(60000, filtered["totalMs"])
    }

    filter_by_act_keeps_only_exact_match()
    {
        ; Exact match: actFilter = 1 keeps only the act-1 detail,
        ; not act-2. The semantics flipped from "<= maxAct" to
        ; "== actFilter" — see commit history and the FilterByAct
        ; header for the rationale (user wanted "see only the
        ; selected act", not "include up to N").
        data := this.builder.Build(Map("zoneTotals", Map(
            "Mud Burrow",        60000,   ; act 1
            "Vastiri Outskirts", 40000    ; act 2
        )))
        filtered := RunStatsPlotBuilder.FilterByAct(data, 1)
        Assert.Equal(1, filtered["details"].Length,
            "only the act-1 zone survives an actFilter=1 exact match")
        Assert.Equal("Mud Burrow", filtered["details"][1]["label"])
    }

    filter_by_act_drops_lower_acts_under_specific_filter()
    {
        ; New invariant under exact-match: an act-1 detail is
        ; dropped under an actFilter=2 cut. Under the old cut-above
        ; semantics it would have survived (act 1 <= maxAct 2),
        ; which produced the cumulative view that misled users
        ; into thinking the chart was hiding their maps. This test
        ; explicitly pins the change so a future refactor can't
        ; silently regress to cumulative behavior.
        data := this.builder.Build(Map("zoneTotals", Map(
            "Mud Burrow",        10000,   ; act 1 (must be dropped)
            "Vastiri Outskirts", 20000,   ; act 2 (must survive)
            "Sandswept Marsh",   30000    ; act 3 (must be dropped)
        )))
        filtered := RunStatsPlotBuilder.FilterByAct(data, 2)
        Assert.Equal(1, filtered["details"].Length,
            "only the act-2 zone survives — lower AND higher acts both dropped")
        Assert.Equal("Vastiri Outskirts", filtered["details"][1]["label"])
        Assert.Equal(20000, filtered["totals"]["mapa"])
    }

    filter_by_act_keeps_deaths_regardless_of_act()
    {
        ; Deaths (category=morte) carry no act in the current
        ; snapshot schema (BACKLOG B2 traces the path that would
        ; add per-zone deaths). They must pass the filter unchanged
        ; — dropping them silently under a specific actFilter would
        ; under-report the run's death cost in the KPIs. The user
        ; sees "this is how the act went, with N deaths" rather
        ; than "this act had 0 deaths (because we can't attribute
        ; them)".
        cfg := AppSettings.Defaults()
        cfg.deathPenaltyEnabled := true
        cfg.deathPenaltyMs := 60000
        b := RunStatsPlotBuilder(this.catalog, cfg)
        data := b.Build(Map(
            "zoneTotals", Map("Vastiri Outskirts", 10000),    ; act 2
            "deathCount", 2
        ))
        filtered := RunStatsPlotBuilder.FilterByAct(data, 1)
        ; act-2 zone dropped under actFilter=1, but the morte
        ; detail survives.
        deathDetailFound := false
        for _, d in filtered["details"]
        {
            if (d["category"] = "morte")
            {
                deathDetailFound := true
                break
            }
        }
        Assert.True(deathDetailFound,
            "morte details bypass the act filter")
        Assert.Equal(120000, filtered["totals"]["morte"],
            "morte total survives intact: 2 deaths * 60s")
    }

    filter_by_act_drops_details_without_parsed_act()
    {
        ; Inverted from the old cut-above semantics: an
        ; uncatalogued zone with empty note used to be over-
        ; included (kept regardless of maxAct). Under exact-match,
        ; an unattributable entry is noise rather than missing
        ; data — dropped under any active filter. The unfiltered
        ; (actFilter=0) and Interlude-sentinel (actFilter>=999)
        ; paths short-circuit at the top of FilterByAct, so
        ; "Mystery Place" still survives both of those.
        data := this.builder.Build(Map("zoneTotals", Map(
            "Vastiri Outskirts", 20000,    ; act 2 -> note "Act 2"
            "Mystery Place",     30000     ; not in catalog -> note ""
        )))
        filtered := RunStatsPlotBuilder.FilterByAct(data, 2)
        ; Vastiri Outskirts kept (act 2 == actFilter 2).
        ; Mystery Place DROPPED (no parsed act → noise).
        Assert.Equal(1, filtered["details"].Length)
        Assert.Equal("Vastiri Outskirts", filtered["details"][1]["label"])
    }

    filter_by_act_keeps_loading_with_matching_act()
    {
        ; Loadings into act-1 zones survive an actFilter=1 cut
        ; because their note is "Act 1" (derived from toZone).
        data := this.builder.Build(Map("loadingEvents", [
            Map("durationMs", 3000, "fromZone", "Clearfell Encampment", "toZone", "Mud Burrow")
        ]))
        filtered := RunStatsPlotBuilder.FilterByAct(data, 1)
        Assert.Equal(1, filtered["details"].Length)
        Assert.Equal(3000, filtered["totals"]["loading"])
    }

    filter_by_act_drops_loading_with_non_matching_act()
    {
        ; Loadings into act-2 zones are dropped by actFilter=1
        ; because their note ("Act 2") doesn't match the filter
        ; exactly. This is the whole point of attributing loadings
        ; to toZone in _AddLoadingDetails — without it, every
        ; loading would either be over- or under-included.
        data := this.builder.Build(Map("loadingEvents", [
            Map("durationMs", 3000, "fromZone", "Mud Burrow", "toZone", "Vastiri Outskirts")
        ]))
        filtered := RunStatsPlotBuilder.FilterByAct(data, 1)
        Assert.Equal(0, filtered["details"].Length,
            "loading into act 2 is dropped under actFilter=1")
        Assert.Equal(0, filtered["totals"]["loading"])
    }

    filter_by_act_recomputes_totals()
    {
        ; Totals must reflect the FILTERED details, not the
        ; original. Without recomputation, the KPIs would still
        ; show pre-filter values — defeating the whole purpose of
        ; the filter.
        data := this.builder.Build(Map("zoneTotals", Map(
            "Mud Burrow",        60000,   ; act 1
            "Vastiri Outskirts", 40000    ; act 2
        )))
        Assert.Equal(100000, data["totals"]["mapa"],
            "sanity: unfiltered total is 60k + 40k")

        filtered := RunStatsPlotBuilder.FilterByAct(data, 1)
        Assert.Equal(60000, filtered["totals"]["mapa"],
            "filtered total reflects only act-1 contribution")
    }

    filter_by_act_recomputes_total_ms()
    {
        ; totalMs is recomputed as the sum of all category totals
        ; under the filter. Tests the same invariant as the totals
        ; test above, but for the top-level totalMs field that the
        ; dialog header surfaces.
        data := this.builder.Build(Map(
            "zoneTotals", Map(
                "Mud Burrow",        60000,    ; act 1, mapa
                "Vastiri Outskirts", 40000     ; act 2, mapa
            ),
            "loadingEvents", [
                Map("durationMs", 1000, "toZone", "Mud Burrow"),       ; act 1
                Map("durationMs", 2000, "toZone", "Vastiri Outskirts") ; act 2
            ]
        ))
        ; Unfiltered: 60k + 40k + 1k + 2k = 103000
        Assert.Equal(103000, data["totalMs"])

        filtered := RunStatsPlotBuilder.FilterByAct(data, 1)
        ; Filtered: 60k (act 1 zone) + 1k (act 1 loading) = 61000
        Assert.Equal(61000, filtered["totalMs"])
    }

    filter_by_act_preserves_max_act_reached()
    {
        ; maxActReached describes the underlying run — the highest
        ; act the player visited. It must NOT shift with the view
        ; filter; a player who reached act 3 in a run still has
        ; maxActReached=3 even when looking at the run under an
        ; actFilter=1 view.
        data := this.builder.Build(Map("zoneTotals", Map(
            "Mud Burrow",        60000,   ; act 1
            "Sandswept Marsh",   30000    ; act 3
        )))
        Assert.Equal(3, data["maxActReached"], "sanity")

        filtered := RunStatsPlotBuilder.FilterByAct(data, 1)
        Assert.Equal(3, filtered["maxActReached"],
            "maxActReached survives the filter — descriptive, not gated")
    }

    filter_by_act_preserves_metadata_fields()
    {
        ; runId, profile, patch, firstTs, deathCount survive in
        ; the shallow clone. The dialog reads them for the header,
        ; so a missing field after the filter would blank the
        ; header.
        snapshot := Map(
            "runId",      "20260523_104500_test",
            "profile",    "Speedrunner",
            "patch",      "0.4",
            "firstTs",    "2026-05-23 10:45:00",
            "deathCount", 2,
            "zoneTotals", Map("Mud Burrow", 60000)
        )
        data := this.builder.Build(snapshot)
        filtered := RunStatsPlotBuilder.FilterByAct(data, 1)
        Assert.Equal("20260523_104500_test", filtered["runId"])
        Assert.Equal("Speedrunner",          filtered["profile"])
        Assert.Equal("0.4",                  filtered["patch"])
        Assert.Equal("2026-05-23 10:45:00",  filtered["firstTs"])
        Assert.Equal(2,                      filtered["deathCount"])
    }

    filter_by_act_does_not_mutate_input()
    {
        ; Critical invariant: the caller (RunStatsPlotDialog)
        ; caches the original data in _currentData and reapplies
        ; the filter on every dropdown change. If FilterByAct
        ; mutated the input, the second call would filter an
        ; already-filtered cache and progressively shrink the data
        ; — a silent bug that would only surface on the third+
        ; dropdown change.
        data := this.builder.Build(Map("zoneTotals", Map(
            "Mud Burrow",        60000,   ; act 1
            "Vastiri Outskirts", 40000    ; act 2
        )))
        originalDetailsLen := data["details"].Length
        originalMapaTotal  := data["totals"]["mapa"]
        originalTotalMs    := data["totalMs"]

        RunStatsPlotBuilder.FilterByAct(data, 1)

        Assert.Equal(originalDetailsLen, data["details"].Length,
            "input details array was not mutated")
        Assert.Equal(originalMapaTotal, data["totals"]["mapa"],
            "input totals map was not mutated")
        Assert.Equal(originalTotalMs, data["totalMs"],
            "input totalMs scalar was not mutated")
    }

    filter_by_act_interlude_drops_normal_stage_details()
    {
        ; Pre-B1 the dialog mapped "Interlude" to sentinel 999 and
        ; FilterByAct short-circuited it as a no-op. Post-B1 the
        ; sentinel actually filters: only stage="interlude" details
        ; survive (deaths also bypass; see
        ; filter_by_act_interlude_keeps_deaths_through_bypass). A
        ; run with no cruel data — every detail defaults to
        ; stage="normal" via _AddDetail — returns an empty plot.
        ; This is the honest result, not data loss: legacy runs
        ; never tracked cruel separately.
        data := this.builder.Build(Map("zoneTotals", Map(
            "Mud Burrow",        60000,
            "Vastiri Outskirts", 40000,
            "Sandswept Marsh",   30000
        )))
        filtered := RunStatsPlotBuilder.FilterByAct(data, 999)
        Assert.Equal(0, filtered["details"].Length,
            "all-normal run yields empty Interlude view")
        Assert.Equal(0, filtered["totalMs"])
    }

    filter_by_act_interlude_keeps_only_interlude_stage()
    {
        ; Mixed-stage run: zoneTotalsByStage carries both normal
        ; and interlude entries for the same act. Interlude filter
        ; keeps the interlude entry only.
        data := this.builder.Build(Map("zoneTotalsByStage", Map(
            "Mud Burrow|normal",        60000,
            "Mud Burrow|interlude",     90000,
            "Vastiri Outskirts|normal", 40000
        )))
        filtered := RunStatsPlotBuilder.FilterByAct(data, 999)
        Assert.Equal(1, filtered["details"].Length,
            "only the interlude entry survives the Interlude filter")
        Assert.Equal("Mud Burrow", filtered["details"][1]["label"])
        Assert.Equal("interlude",  filtered["details"][1]["stage"])
        Assert.Equal(90000, filtered["totalMs"])
    }

    filter_by_act_per_act_drops_interlude_stage()
    {
        ; The per-act filter (1..4) keeps stage="normal" entries
        ; only. Even if a cruel Act 1 entry exists with the same
        ; "Act 1" note string, the per-act filter rejects it — the
        ; user picked the campaign act, not the cruel ladder.
        data := this.builder.Build(Map("zoneTotalsByStage", Map(
            "Mud Burrow|normal",    60000,
            "Mud Burrow|interlude", 90000
        )))
        filtered := RunStatsPlotBuilder.FilterByAct(data, 1)
        Assert.Equal(1, filtered["details"].Length,
            "only the normal-stage Act 1 entry survives an Act 1 filter")
        Assert.Equal("normal", filtered["details"][1]["stage"])
        Assert.Equal(60000,    filtered["totalMs"])
    }

    filter_by_act_interlude_keeps_deaths_through_bypass()
    {
        ; Deaths carry no stage (single aggregated row). They
        ; bypass every filter, matching the per-act exemption.
        ; A user picking "Interlude" still sees the run's death
        ; KPI — dropping it silently would under-report the run.
        cfg := AppSettings.Defaults()
        cfg.deathPenaltyEnabled := true
        cfg.deathPenaltyMs := 60000
        b := RunStatsPlotBuilder(this.catalog, cfg)
        data := b.Build(Map(
            "zoneTotals", Map("Mud Burrow", 60000),    ; normal-only
            "deathCount", 2
        ))
        filtered := RunStatsPlotBuilder.FilterByAct(data, 999)
        deathDetailFound := false
        for _, d in filtered["details"]
        {
            if (d["category"] = "morte")
            {
                deathDetailFound := true
                break
            }
        }
        Assert.True(deathDetailFound,
            "morte detail survives the Interlude filter via the category bypass")
        Assert.Equal(120000, filtered["totals"]["morte"])
    }

    filter_by_act_interlude_empty_when_no_cruel_data()
    {
        ; Same scenario as the dialog's first open on a pre-B1 run
        ; library: nothing in zoneTotalsByStage, every detail
        ; defaults to stage="normal". Interlude filter returns
        ; zero zone details (deaths still bypass when enabled,
        ; but this scenario has none).
        data := this.builder.Build(Map("zoneTotals", Map(
            "Mud Burrow",      60000,
            "Sandswept Marsh", 30000
        )))
        filtered := RunStatsPlotBuilder.FilterByAct(data, 999)
        Assert.Equal(0, filtered["details"].Length)
        Assert.Equal(0, filtered["totals"]["mapa"])
        Assert.Equal(0, filtered["totalMs"])
    }

    ; ============================================================
    ; B1 Layer B: stage propagation through Build()
    ; ============================================================
    ;
    ; The builder is forward-compatible with stage info flowing
    ; through the snapshot. These tests pin the canonical shapes:
    ;   - zoneTotalsByStage (composite "name|stage") takes
    ;     precedence over zoneTotals when both are present.
    ;   - Loading events carry an optional `stage` field that
    ;     defaults to "normal" when absent.
    ;   - Deaths carry stage="" because the aggregated row spans
    ;     both stages by definition.

    build_emits_stage_normal_by_default_on_zone_details()
    {
        ; Legacy snapshot path: only zoneTotals present. Every
        ; emitted detail gets stage="normal" — the per-act filter
        ; still works on legacy runs without needing them to
        ; migrate to the composite shape.
        data := this.builder.Build(Map("zoneTotals", Map(
            "Mud Burrow", 60000
        )))
        Assert.Equal("normal", data["details"][1]["stage"])
    }

    build_consumes_zone_totals_by_stage_when_present()
    {
        ; Canonical B1 input shape: composite keys "name|stage".
        ; Each entry round-trips into a detail with the matching
        ; stage flag, label = base zone name, ms = entry value.
        data := this.builder.Build(Map("zoneTotalsByStage", Map(
            "Mud Burrow|normal",    60000,
            "Mud Burrow|interlude", 90000
        )))
        Assert.Equal(2, data["details"].Length)
        stages := Map()
        for _, d in data["details"]
        {
            if (d["label"] = "Mud Burrow")
                stages[d["stage"]] := d["ms"]
        }
        Assert.Equal(60000, stages["normal"])
        Assert.Equal(90000, stages["interlude"])
    }

    build_prefers_zone_totals_by_stage_over_legacy_zone_totals()
    {
        ; When both shapes are present, the composite map wins.
        ; This protects against the transitional state where the
        ; recorder emits both shapes during migration — the
        ; downstream builder should consume the canonical one
        ; rather than double-counting.
        data := this.builder.Build(Map(
            "zoneTotalsByStage", Map("Mud Burrow|normal", 60000),
            "zoneTotals",        Map("Mud Burrow", 999999)   ; ignored
        ))
        Assert.Equal(1, data["details"].Length,
            "only the composite entry is emitted; legacy ignored")
        Assert.Equal(60000, data["details"][1]["ms"])
        Assert.Equal("normal", data["details"][1]["stage"])
    }

    build_drops_unparseable_composite_zone_keys()
    {
        ; Defensive: a malformed composite key (no pipe, bad
        ; stage, empty zone) is dropped silently. The builder
        ; can't infer stage from arbitrary keys without risking
        ; misattribution.
        data := this.builder.Build(Map("zoneTotalsByStage", Map(
            "NoPipeHere",        10000,    ; dropped
            "Zone|cruel",        20000,    ; dropped (unknown stage)
            "|normal",           30000,    ; dropped (empty zone)
            "Mud Burrow|normal", 60000     ; kept
        )))
        Assert.Equal(1, data["details"].Length,
            "only the well-formed entry survives")
        Assert.Equal("Mud Burrow", data["details"][1]["label"])
    }

    loading_event_emits_stage_normal_by_default()
    {
        ; No `stage` field on the event — defaults to "normal".
        ; This is the legacy-snapshot path and the path for any
        ; upstream that hasn't been wired through yet.
        data := this.builder.Build(Map("loadingEvents", [
            Map("durationMs", 3000, "fromZone", "A", "toZone", "B")
        ]))
        Assert.Equal("normal", data["details"][1]["stage"])
    }

    loading_event_emits_stage_from_field()
    {
        ; Cruel loading: event carries stage="interlude". The
        ; detail surfaces it so FilterByAct(999) can keep it.
        data := this.builder.Build(Map("loadingEvents", [
            Map("durationMs", 3000, "fromZone", "A", "toZone", "B", "stage", "interlude")
        ]))
        Assert.Equal("interlude", data["details"][1]["stage"])
    }

    loading_event_invalid_stage_falls_back_to_normal()
    {
        ; Defensive: garbage stage value (e.g. an unknown future
        ; stage like "cruel-plus") falls back to "normal" rather
        ; than crashing the filter on an unexpected value. The
        ; Interlude filter compares to "interlude" exactly, so
        ; an unknown stage staying "normal" keeps the per-act
        ; filter accepting it.
        data := this.builder.Build(Map("loadingEvents", [
            Map("durationMs", 3000, "fromZone", "A", "toZone", "B", "stage", "cruel-plus")
        ]))
        Assert.Equal("normal", data["details"][1]["stage"])
    }

    death_detail_carries_empty_stage()
    {
        ; Deaths span both stages by definition (single aggregated
        ; row). Stage="" signals "no stage attribution"; the
        ; filters use category="morte" to bypass them, not the
        ; stage flag.
        cfg := AppSettings.Defaults()
        cfg.deathPenaltyEnabled := true
        cfg.deathPenaltyMs := 10000
        b := RunStatsPlotBuilder(this.catalog, cfg)
        data := b.Build(Map("deathCount", 2))
        for _, d in data["details"]
        {
            if (d["category"] = "morte")
            {
                Assert.Equal("", d["stage"],
                    "deaths carry empty stage; category bypass handles the filter")
                return
            }
        }
        Assert.Fail("Expected detail with category=morte")
    }
}

TestRegistry.Register(RunStatsPlotBuilderTests)
