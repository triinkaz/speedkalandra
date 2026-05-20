; ============================================================
; DeathLogScannerTests
; ============================================================
;
; Covers the one-shot Client.txt aggregator that drives the
; DeathStatsDialog's "All-time (from log)" view. Pure read-side
; tests — no event bus, no disk writes, no FileOpen state — so
; the suite stays headless-safe.
;
; Fixtures use Fixtures.TempFile to materialize tiny Client.txt
; samples and a zones.csv that mirrors the production catalog
; format ("name;internal_id;act;is_town"). Both Mud Burrow and
; Riverbank appear as regular zones; Clearfell Encampment is the
; town used to exercise IsTownName filtering.


class DeathLogScannerTests extends TestCase
{
    catalogPath := ""
    catalog     := ""
    scanner     := ""

    static CATALOG_CONTENT := "
    (LTrim
        name;internal_id;act;is_town
        Mud Burrow;G1_3;1;0
        The Riverbank;G1_1;1;0
        Cemetery of the Eternals;G1_7;1;0
        Clearfell Encampment;G1_town;1;1
    )"

    Setup()
    {
        this.catalogPath := Fixtures.TempFile(DeathLogScannerTests.CATALOG_CONTENT, "csv")
        this.catalog     := ZonesCatalog(this.catalogPath)
        this.scanner     := DeathLogScanner(this.catalog)
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_catalog_not_zones_catalog",
        "constructor_accepts_empty_catalog",
        "constructor_accepts_real_catalog",

        ; --- Path / file validation ---
        "scan_returns_error_when_path_is_empty",
        "scan_returns_error_when_path_is_whitespace",
        "scan_returns_error_when_file_does_not_exist",

        ; --- Empty / minimal inputs ---
        "scan_returns_zero_deaths_for_empty_file",
        "scan_counts_lines_even_when_no_matches",

        ; --- Basic parsing (scene path) ---
        "scan_counts_single_death_in_current_zone",
        "scan_counts_multiple_deaths_in_same_zone",
        "scan_counts_deaths_across_multiple_zones",
        "scan_zone_changes_via_scene_line_with_human_name",
        "scan_zone_changes_via_scene_line_with_internal_id_resolved",

        ; --- Area-gen path (LT6: campaign + cruel detection) ---
        "scan_area_gen_resolves_normal_zone_via_internal_id",
        "scan_area_gen_takes_precedence_over_following_scene",
        "scan_detects_cruel_via_c_prefix_and_appends_suffix",
        "scan_cruel_and_normal_same_zone_counted_independently",
        "scan_drops_cruel_town_via_c_prefix_on_town_id",
        "scan_drops_hideout_area_code_increments_skipped",
        "scan_drops_endgame_map_area_code_increments_skipped",

        ; --- Character filter ---
        "scan_filters_out_deaths_with_different_character_name",
        "scan_empty_character_filter_counts_every_slain_line",

        ; --- Catalog effects (campaign-only policy) ---
        "scan_drops_town_deaths_via_catalog",
        "scan_drops_unknown_scene_zone_increments_skipped_non_campaign",
        "scan_works_without_catalog_using_raw_scene_text",

        ; --- skippedNonCampaign accounting ---
        "scan_skips_death_before_any_zone_seen",
        "scan_skipped_counter_accumulates",
        "scan_hideout_after_campaign_resets_currentzone",

        ; --- Sort + stability ---
        "scan_perzone_sorted_by_count_desc",
        "scan_perzone_stable_for_ties_preserves_first_appearance",

        ; --- Static parsers ---
        "static_parse_scene_extracts_name",
        "static_parse_scene_returns_empty_for_null_unknown_act_marker_interlude",
        "static_parse_death_extracts_name_with_colon_prefix",
        "static_parse_death_extracts_name_without_colon_prefix",
        "static_parse_area_gen_extracts_normal_code",
        "static_parse_area_gen_extracts_cruel_code_with_prefix",
        "static_parse_area_gen_returns_empty_for_non_matching"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    ; Builds a temp Client.txt with the given lines joined by `n.
    ; UTF-8 because that's how PoE2 writes the real log (and the
    ; production Scan() reads with the UTF-8 hint).
    _ClientTxt(lines)
    {
        body := ""
        for i, line in lines
            body .= line . "`n"
        return Fixtures.TempFile(body, "txt")
    }

    ; Builds the standard PoE2 area-gen line for a given level and
    ; code. The exact format including quotes around the code
    ; matters — the parser regex requires them.
    _AreaGenLine(level, code)
    {
        return '[DEBUG Client 1234] Generating level ' . level . ' area "' . code . '" with seed 42'
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_catalog_not_zones_catalog()
    {
        Assert.Throws(TypeError, () => DeathLogScanner("not a catalog"))
        Assert.Throws(TypeError, () => DeathLogScanner(Map()))
    }

    constructor_accepts_empty_catalog()
    {
        scanner := DeathLogScanner()
        Assert.True(scanner is DeathLogScanner)
    }

    constructor_accepts_real_catalog()
    {
        scanner := DeathLogScanner(this.catalog)
        Assert.True(scanner is DeathLogScanner)
    }

    ; ============================================================
    ; Path / file validation
    ; ============================================================

    scan_returns_error_when_path_is_empty()
    {
        r := this.scanner.Scan("")
        Assert.False(r["success"], "empty path = failure")
        Assert.True(InStr(r["errorMessage"], "empty") > 0, "errorMessage mentions empty: " . r["errorMessage"])
    }

    scan_returns_error_when_path_is_whitespace()
    {
        r := this.scanner.Scan("   ")
        Assert.False(r["success"])
        Assert.True(InStr(r["errorMessage"], "empty") > 0)
    }

    scan_returns_error_when_file_does_not_exist()
    {
        ghostPath := Fixtures.TempPath("txt")
        r := this.scanner.Scan(ghostPath)
        Assert.False(r["success"])
        Assert.True(InStr(r["errorMessage"], "not found") > 0,
            "errorMessage mentions not found: " . r["errorMessage"])
    }

    ; ============================================================
    ; Empty / minimal inputs
    ; ============================================================

    scan_returns_zero_deaths_for_empty_file()
    {
        path := Fixtures.TempFile("", "txt")
        r := this.scanner.Scan(path, "Hero")
        Assert.True(r["success"])
        Assert.Equal(0, r["totalDeaths"])
        Assert.Equal(0, r["perZone"].Length)
        Assert.Equal("", r["errorMessage"])
    }

    scan_counts_lines_even_when_no_matches()
    {
        path := this._ClientTxt([
            "some random log line",
            "[INFO Client] another line",
            "yet another"
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.True(r["success"])
        Assert.Equal(0, r["totalDeaths"])
        Assert.Equal(3, r["linesScanned"], "all 3 lines scanned")
    }

    ; ============================================================
    ; Basic parsing (scene path)
    ; ============================================================

    scan_counts_single_death_in_current_zone()
    {
        path := this._ClientTxt([
            "[INFO Client 1234] [SCENE] Set Source [Mud Burrow]",
            "[INFO Client 1234] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.True(r["success"])
        Assert.Equal(1, r["totalDeaths"])
        Assert.Equal(1, r["perZone"].Length)
        Assert.Equal("Mud Burrow", r["perZone"][1]["zoneName"])
        Assert.Equal(1,            r["perZone"][1]["count"])
    }

    scan_counts_multiple_deaths_in_same_zone()
    {
        path := this._ClientTxt([
            "[INFO Client] [SCENE] Set Source [Mud Burrow]",
            "[INFO Client] : Hero has been slain.",
            "[INFO Client] : Hero has been slain.",
            "[INFO Client] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(3, r["totalDeaths"])
        Assert.Equal(1, r["perZone"].Length)
        Assert.Equal(3, r["perZone"][1]["count"])
    }

    scan_counts_deaths_across_multiple_zones()
    {
        path := this._ClientTxt([
            "[INFO] [SCENE] Set Source [Mud Burrow]",
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain.",
            "[INFO] [SCENE] Set Source [The Riverbank]",
            "[INFO] : Hero has been slain.",
            "[INFO] [SCENE] Set Source [Cemetery of the Eternals]",
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(7, r["totalDeaths"])
        Assert.Equal(3, r["perZone"].Length)
        Assert.Equal("Cemetery of the Eternals", r["perZone"][1]["zoneName"])
        Assert.Equal(4,                          r["perZone"][1]["count"])
        Assert.Equal("Mud Burrow",               r["perZone"][2]["zoneName"])
        Assert.Equal(2,                          r["perZone"][2]["count"])
        Assert.Equal("The Riverbank",            r["perZone"][3]["zoneName"])
        Assert.Equal(1,                          r["perZone"][3]["count"])
    }

    scan_zone_changes_via_scene_line_with_human_name()
    {
        path := this._ClientTxt([
            "[INFO] [SCENE] Set Source [The Riverbank]",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal("The Riverbank", r["perZone"][1]["zoneName"])
    }

    scan_zone_changes_via_scene_line_with_internal_id_resolved()
    {
        ; PoE2 occasionally emits the engine id in [SCENE] as the
        ; raw name. The scanner falls back to FindById to recover
        ; the human name.
        path := this._ClientTxt([
            "[INFO] [SCENE] Set Source [G1_3]",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal("Mud Burrow", r["perZone"][1]["zoneName"],
            "internal id G1_3 resolved to human name via catalog")
    }

    ; ============================================================
    ; Area-gen path (LT6: campaign + cruel detection)
    ; ============================================================

    scan_area_gen_resolves_normal_zone_via_internal_id()
    {
        ; `Generating level X area "G1_3" with seed N` resolves to
        ; the canonical "Mud Burrow" via the catalog's id lookup.
        ; The scanner uses this signal even when no SCENE follows
        ; (e.g. the log was truncated before the SCENE landed).
        path := this._ClientTxt([
            this._AreaGenLine(3, "G1_3"),
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(1, r["totalDeaths"])
        Assert.Equal("Mud Burrow", r["perZone"][1]["zoneName"])
    }

    scan_area_gen_takes_precedence_over_following_scene()
    {
        ; A typical normal-difficulty transition emits the area gen
        ; FIRST, then a SCENE Set Source with the same zone. Both
        ; resolve to the same name, so there's no ambiguity. This
        ; pins the production sequence so a future refactor that
        ; reorders parsing doesn't accidentally drop the area-gen
        ; signal.
        path := this._ClientTxt([
            this._AreaGenLine(3, "G1_3"),
            "[INFO] [SCENE] Set Source [(null)]",
            "[INFO] [SCENE] Set Source [Mud Burrow]",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(1, r["totalDeaths"])
        Assert.Equal("Mud Burrow", r["perZone"][1]["zoneName"])
    }

    scan_detects_cruel_via_c_prefix_and_appends_suffix()
    {
        ; Empirically verified against a real Client.txt: cruel
        ; zones emit `Generating level X area "C_<id>"` but NO
        ; corresponding SCENE Set Source. The scanner detects the
        ; `C_` prefix, strips it, looks up the underlying zone, and
        ; appends " (Cruel)" to the display name so cruel deaths
        ; surface as a separate row.
        path := this._ClientTxt([
            this._AreaGenLine(58, "C_G1_3"),
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(2, r["totalDeaths"])
        Assert.Equal(1, r["perZone"].Length)
        Assert.Equal("Mud Burrow (Cruel)", r["perZone"][1]["zoneName"])
    }

    scan_cruel_and_normal_same_zone_counted_independently()
    {
        ; Player visits Mud Burrow twice in a session: once normal,
        ; once cruel. The two visits must surface as two separate
        ; rows in perZone — coalescing them would lose the
        ; difficulty signal the user explicitly asked for.
        path := this._ClientTxt([
            this._AreaGenLine(3, "G1_3"),
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain.",
            this._AreaGenLine(58, "C_G1_3"),
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(4, r["totalDeaths"])
        Assert.Equal(2, r["perZone"].Length)
        Assert.Equal("Mud Burrow",          r["perZone"][1]["zoneName"])
        Assert.Equal(3,                     r["perZone"][1]["count"])
        Assert.Equal("Mud Burrow (Cruel)",  r["perZone"][2]["zoneName"])
        Assert.Equal(1,                     r["perZone"][2]["count"])
    }

    scan_drops_cruel_town_via_c_prefix_on_town_id()
    {
        ; `C_G1_town` is the cruel Clearfell Encampment. Towns are
        ; dropped regardless of difficulty — same policy as the
        ; live CSV view. Death must increment skippedNonCampaign,
        ; not appear in perZone.
        path := this._ClientTxt([
            this._AreaGenLine(51, "C_G1_town"),
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(0, r["totalDeaths"])
        Assert.Equal(0, r["perZone"].Length)
        Assert.Equal(2, r["skippedNonCampaign"])
    }

    scan_drops_hideout_area_code_increments_skipped()
    {
        ; `HideoutCanal` is not in the campaign catalog. Death is
        ; dropped, the count surfaces in skippedNonCampaign so the
        ; UI can show the filter's effect.
        path := this._ClientTxt([
            this._AreaGenLine(60, "HideoutCanal"),
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(0, r["totalDeaths"])
        Assert.Equal(1, r["skippedNonCampaign"])
    }

    scan_drops_endgame_map_area_code_increments_skipped()
    {
        ; Endgame maps (atlas) use codes like `MapSeepage`,
        ; `MapAugury_NoBoss`, etc. — none in the campaign catalog.
        ; Same drop behaviour as hideouts.
        path := this._ClientTxt([
            this._AreaGenLine(80, "MapSeepage"),
            "[INFO] : Hero has been slain.",
            this._AreaGenLine(80, "MapAugury_NoBoss"),
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(0, r["totalDeaths"])
        Assert.Equal(3, r["skippedNonCampaign"])
    }

    ; ============================================================
    ; Character filter
    ; ============================================================

    scan_filters_out_deaths_with_different_character_name()
    {
        path := this._ClientTxt([
            "[INFO] [SCENE] Set Source [Mud Burrow]",
            "[INFO] : Hero has been slain.",
            "[INFO] : The Devourer has been slain.",
            "[INFO] : Random Mob has been slain.",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(2, r["totalDeaths"], "only Hero's two deaths counted")
    }

    scan_empty_character_filter_counts_every_slain_line()
    {
        path := this._ClientTxt([
            "[INFO] [SCENE] Set Source [Mud Burrow]",
            "[INFO] : Hero has been slain.",
            "[INFO] : The Devourer has been slain.",
            "[INFO] : Random Mob has been slain."
        ])
        r := this.scanner.Scan(path, "")
        Assert.Equal(3, r["totalDeaths"], "every slain line counts when filter is empty")
    }

    ; ============================================================
    ; Catalog effects (campaign-only policy)
    ; ============================================================

    scan_drops_town_deaths_via_catalog()
    {
        path := this._ClientTxt([
            "[INFO] [SCENE] Set Source [Mud Burrow]",
            "[INFO] : Hero has been slain.",
            "[INFO] [SCENE] Set Source [Clearfell Encampment]",
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(1, r["totalDeaths"], "town deaths dropped")
        Assert.Equal(1, r["perZone"].Length)
        Assert.Equal("Mud Burrow", r["perZone"][1]["zoneName"])
        Assert.Equal(2, r["skippedNonCampaign"], "two town deaths in skipped")
    }

    scan_drops_unknown_scene_zone_increments_skipped_non_campaign()
    {
        ; LT6 policy change: zones not in the catalog (a future
        ; patch zone, an atlas map name that happens to appear as a
        ; SCENE, a hideout) are DROPPED rather than passed through.
        ; The death still surfaces via skippedNonCampaign so the
        ; user can see the filter is doing its job. The earlier
        ; behaviour (pass through verbatim) inflated counts with
        ; non-campaign noise.
        path := this._ClientTxt([
            "[INFO] [SCENE] Set Source [Brand New Patch Zone]",
            "[INFO] : Hero has been slain.",
            "[INFO] [SCENE] Set Source [Spider Woods]",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(0, r["totalDeaths"])
        Assert.Equal(0, r["perZone"].Length)
        Assert.Equal(2, r["skippedNonCampaign"])
    }

    scan_works_without_catalog_using_raw_scene_text()
    {
        ; Headless scenarios + integration tests that don't carry a
        ; CSV. Without a catalog the scanner can't know what is or
        ; isn't a campaign zone, so it falls back to the legacy
        ; "pass-through" behaviour for SCENE lines. Area-gen lines
        ; resolve to "" without a catalog (the codes are opaque
        ; engine ids — no point pretending to interpret them).
        catalogless := DeathLogScanner()
        path := this._ClientTxt([
            "[INFO] [SCENE] Set Source [G1_3]",
            "[INFO] : Hero has been slain."
        ])
        r := catalogless.Scan(path, "Hero")
        Assert.Equal(1, r["totalDeaths"])
        Assert.Equal("G1_3", r["perZone"][1]["zoneName"],
            "without catalog, raw scene text passes through")
    }

    ; ============================================================
    ; skippedNonCampaign accounting
    ; ============================================================

    scan_skips_death_before_any_zone_seen()
    {
        ; The file begins mid-game (log rotated, session truncated)
        ; and the first death arrives before any zone signal. The
        ; scanner can't attribute it; counts it under
        ; skippedNonCampaign instead of creating a phantom "" entry.
        path := this._ClientTxt([
            "[INFO] : Hero has been slain.",
            "[INFO] [SCENE] Set Source [Mud Burrow]",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(1, r["totalDeaths"])
        Assert.Equal(1, r["skippedNonCampaign"])
    }

    scan_skipped_counter_accumulates()
    {
        path := this._ClientTxt([
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(0, r["totalDeaths"])
        Assert.Equal(3, r["skippedNonCampaign"])
    }

    scan_hideout_after_campaign_resets_currentzone()
    {
        ; Critical invariant: a SCENE that resolves to "" (hideout,
        ; endgame, unknown) MUST reset currentZone, so a death that
        ; happens in the hideout doesn't get mis-attributed to the
        ; preceding campaign zone. Without the reset, the user
        ; would see phantom deaths in zones they'd already left.
        path := this._ClientTxt([
            "[INFO] [SCENE] Set Source [Mud Burrow]",
            "[INFO] : Hero has been slain.",
            "[INFO] [SCENE] Set Source [Canal Hideout]",
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(1, r["totalDeaths"], "only the Mud Burrow death counts")
        Assert.Equal("Mud Burrow", r["perZone"][1]["zoneName"])
        Assert.Equal(2, r["skippedNonCampaign"],
            "the two hideout deaths are skipped, not attributed to Mud Burrow")
    }

    ; ============================================================
    ; Sort + stability
    ; ============================================================

    scan_perzone_sorted_by_count_desc()
    {
        path := this._ClientTxt([
            "[INFO] [SCENE] Set Source [Mud Burrow]",
            "[INFO] : Hero has been slain.",
            "[INFO] [SCENE] Set Source [The Riverbank]",
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain.",
            "[INFO] [SCENE] Set Source [Cemetery of the Eternals]",
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal("The Riverbank",            r["perZone"][1]["zoneName"])
        Assert.Equal("Cemetery of the Eternals", r["perZone"][2]["zoneName"])
        Assert.Equal("Mud Burrow",               r["perZone"][3]["zoneName"])
    }

    scan_perzone_stable_for_ties_preserves_first_appearance()
    {
        path := this._ClientTxt([
            "[INFO] [SCENE] Set Source [Mud Burrow]",
            "[INFO] : Hero has been slain.",
            "[INFO] [SCENE] Set Source [The Riverbank]",
            "[INFO] : Hero has been slain."
        ])
        r := this.scanner.Scan(path, "Hero")
        Assert.Equal(2, r["perZone"].Length)
        Assert.Equal("Mud Burrow",    r["perZone"][1]["zoneName"])
        Assert.Equal("The Riverbank", r["perZone"][2]["zoneName"])
    }

    ; ============================================================
    ; Static parsers
    ; ============================================================

    static_parse_scene_extracts_name()
    {
        Assert.Equal("Mud Burrow",
            DeathLogScanner._ParseScene("[INFO Client 1234] [SCENE] Set Source [Mud Burrow]"))
        Assert.Equal("G1_3",
            DeathLogScanner._ParseScene("[SCENE] Set Source [G1_3]"))
    }

    static_parse_scene_returns_empty_for_null_unknown_act_marker_interlude()
    {
        Assert.Equal("", DeathLogScanner._ParseScene("[SCENE] Set Source [(null)]"))
        Assert.Equal("", DeathLogScanner._ParseScene("[SCENE] Set Source [(unknown)]"))
        Assert.Equal("", DeathLogScanner._ParseScene("[SCENE] Set Source [Act 1]"))
        Assert.Equal("", DeathLogScanner._ParseScene("[SCENE] Set Source [Act 5]"))
        Assert.Equal("", DeathLogScanner._ParseScene("[SCENE] Set Source [Interlude]"),
            "Interlude is a cruel-transition marker, not a real zone")
        Assert.Equal("", DeathLogScanner._ParseScene("nothing to see here"))
    }

    static_parse_death_extracts_name_with_colon_prefix()
    {
        Assert.Equal("Hero",
            DeathLogScanner._ParseDeath("[INFO Client 1234] : Hero has been slain."))
        Assert.Equal("Olaf the Warrior",
            DeathLogScanner._ParseDeath("2026/05/20 17:32:11 12345 : Olaf the Warrior has been slain."))
    }

    static_parse_death_extracts_name_without_colon_prefix()
    {
        Assert.Equal("The Devourer",
            DeathLogScanner._ParseDeath("The Devourer has been slain."))
        Assert.Equal("",
            DeathLogScanner._ParseDeath("nothing here"))
    }

    static_parse_area_gen_extracts_normal_code()
    {
        ; Standard PoE2 area-gen line: `Generating level <N> area
        ; "<code>" with seed <S>`. The parser returns the code
        ; without quotes — the caller decides what to do with it
        ; (cruel detection, town drop, catalog lookup).
        line := '[DEBUG Client 1234] Generating level 3 area "G1_3" with seed 42'
        Assert.Equal("G1_3", DeathLogScanner._ParseAreaGen(line))
    }

    static_parse_area_gen_extracts_cruel_code_with_prefix()
    {
        ; The `C_` prefix is preserved verbatim — _ResolveAreaCode
        ; is the one that interprets it. The parser is dumb.
        line := '[DEBUG Client 1234] Generating level 58 area "C_G3_3" with seed 1332036627'
        Assert.Equal("C_G3_3", DeathLogScanner._ParseAreaGen(line))
    }

    static_parse_area_gen_returns_empty_for_non_matching()
    {
        Assert.Equal("", DeathLogScanner._ParseAreaGen("nothing here"))
        Assert.Equal("", DeathLogScanner._ParseAreaGen("[SCENE] Set Source [Mud Burrow]"))
        ; Missing "with seed" tail — defensive against a future log
        ; format change that drops the seed value.
        Assert.Equal("", DeathLogScanner._ParseAreaGen('Generating level 3 area "G1_3"'))
    }
}

TestRegistry.Register(DeathLogScannerTests)
