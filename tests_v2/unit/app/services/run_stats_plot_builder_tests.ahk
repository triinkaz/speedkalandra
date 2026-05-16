; ============================================================
; RunStatsPlotBuilderTests
; ============================================================
;
; RunStatsPlotBuilder agrega snapshot de run em Map renderizavel.
; Deps:
;   catalog : ZonesCatalog ou "" (pra categorizar mapa/cidade)
;   cfg     : AppSettings (deathPenaltyEnabled, deathPenaltyMs,
;             profileName, gamePatch)
;
; Categorias (SEGMENT_KEYS): mapa / cidade / loading / morte
;
; Cobertura:
;   - Construtor (validacao tipos)
;   - Static methods (Definitions, CategoryLabel, CategoryColor, FormatMs)
;   - Build: shape do output, fallbacks
;   - _AddZoneDetails (categoriza via catalog)
;   - _AddLoadingDetails (label "from -> to", firstTs)
;   - _AddDeathDetails (respeita penaltyEnabled, count*penalty)
;   - maxActReached (regex de _DeriveMaxAct)
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
        ; --- Construtor ---
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

        ; --- Build: shape do output ---
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
        "total_ms_is_sum_of_all_category_totals"
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
    ; Construtor
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
        ; "" eh permitido (caso o catalog nao tenha sido carregado)
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
    ; Build: shape do output
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
            Assert.True(data.Has(k), "Falta key: " k)
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
        ; AppSettings.Defaults() tem profileName="Default"
        data := this.builder.Build(Map())
        Assert.Equal("Default", data["profile"])
    }

    build_falls_back_to_settings_patch_when_snapshot_empty()
    {
        ; AppSettings.Defaults() tem gamePatch="Unknown" (capital U)
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
        ; Zone que nao existe no catalog
        data := this.builder.Build(Map("zoneTotals", Map("Unknown Zone", 50000)))
        Assert.Equal(50000, data["totals"]["mapa"])
        ; Detail tem note="" (act=0, sem "Act N")
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
        ; Defaults: deathPenaltyEnabled=true, deathPenaltyMs=algum default
        data := this.builder.Build(Map("deathCount", 2))
        Assert.True(data["totals"]["morte"] > 0,
            "Com penalty enabled e deathCount=2, total morte deve ser > 0")
    }

    death_count_with_penalty_disabled_skips_detail()
    {
        ; Cria cfg com penalty desabilitada
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
        data := this.builder.Build(Map("deathCount", 5))
        ; Encontra o detail de morte
        for _, d in data["details"]
        {
            if (d["category"] = "morte")
            {
                Assert.Contains("5", d["label"])
                return
            }
        }
        Assert.Fail("Esperava detail com category=morte")
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
        ; Regex tambem aceita "Ato N" (PT-BR antigo - runs salvas em v17.13-)
        ; Simulamos passando snapshot com detail ja contendo "Ato N" no note.
        ; Nao da pra forcar via zone (que gera "Act N"); precisamos
        ; testar _DeriveMaxAct direto.
        details := [
            Map("category", "mapa", "label", "X", "ms", 100, "note", "Ato 5", "timestamp", "")
        ]
        Assert.Equal(5, RunStatsPlotBuilder._DeriveMaxAct(details))
    }

    max_act_picks_highest_among_notes()
    {
        ; Multiple zones em atos diferentes -> max
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
}

TestRegistry.Register(RunStatsPlotBuilderTests)
