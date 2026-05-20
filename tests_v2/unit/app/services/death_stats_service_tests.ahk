; ============================================================
; DeathStatsServiceTests
; ============================================================
;
; Exercises Aggregate's filter logic, sorting, town-zone skipping,
; and the "available" lists that drive the UI dropdowns.
;
; Uses a real DeathLogRepository (file-backed via Fixtures.TempPath)
; and a real ZonesCatalog (file-backed via Fixtures.TempFile). Avoids
; mocking the collaborators so the test exercises the same CSV/encoding
; path production runs through.


class DeathStatsServiceTests extends TestCase
{
    deathLogPath := ""
    catalogPath  := ""
    deathLog     := ""
    catalog      := ""
    svc          := ""

    ; Catalog fixture: 3 normal zones + 2 towns. Same field order as
    ; production data/zones.csv (name;internal_id;act;is_town).
    static CATALOG_CONTENT := "
    (LTrim
        name;internal_id;act;is_town
        Mud Burrow;G1_1;1;0
        Cemetery of the Eternals;G1_7;1;0
        The Riverbank;G2_5;2;0
        Clearfell Encampment;G1_town;1;1
        The Hooded One;G2_town;2;1
    )"

    Setup()
    {
        this.deathLogPath := Fixtures.TempPath("csv")
        this.deathLog     := DeathLogRepository(this.deathLogPath)

        this.catalogPath  := Fixtures.TempFile(DeathStatsServiceTests.CATALOG_CONTENT, "csv")
        this.catalog      := ZonesCatalog(this.catalogPath)

        this.svc := DeathStatsService(this.deathLog, this.catalog)
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_death_log_not_repository",
        "constructor_accepts_empty_catalog",
        "constructor_throws_when_catalog_is_random_object",

        ; --- Aggregate: empty / minimal ---
        "aggregate_empty_log_returns_zero_total_and_empty_per_zone",
        "aggregate_empty_log_returns_empty_available_lists",
        "aggregate_single_death_counts_one",

        ; --- Aggregate: counting + sorting ---
        "aggregate_multiple_deaths_same_zone_aggregates_count",
        "aggregate_multiple_zones_sorted_descending_by_count",
        "aggregate_ties_preserve_insertion_order",

        ; --- Aggregate: filters ---
        "aggregate_filters_by_patch_only",
        "aggregate_filters_by_profile_only",
        "aggregate_filters_by_patch_and_profile_combined",
        "aggregate_empty_filter_returns_all_data",
        "aggregate_filter_with_no_matches_returns_zero",
        "aggregate_filter_value_whitespace_treated_as_no_filter",

        ; --- Aggregate: town zone handling ---
        "aggregate_skips_town_zones_when_catalog_present",
        "aggregate_includes_all_zones_when_catalog_absent",
        "aggregate_unknown_zone_passes_through_catalog_filter",

        ; --- Available lists ---
        "available_patches_dedupes_and_sorts_case_insensitive",
        "available_profiles_dedupes_and_sorts_case_insensitive",
        "available_lists_extracted_from_full_dataset_ignoring_filter",
        "available_lists_skip_empty_values"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    ; Records a death with a fixed ts so the order on disk matches
    ; the call order. Using an explicit ts also keeps tests
    ; deterministic across clock skews.
    _Record(zoneName, patch := "0.4", profile := "Default", tsSuffix := "00:00:00")
    {
        this.deathLog.Append(zoneName, patch, profile, "2026-05-20 " tsSuffix)
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_death_log_not_repository()
    {
        Assert.Throws(TypeError, () => DeathStatsService("not a repo"))
        Assert.Throws(TypeError, () => DeathStatsService(Map(), this.catalog))
    }

    constructor_accepts_empty_catalog()
    {
        ; No catalog wired -> town filtering is disabled but the rest
        ; of the contract still works. Should not throw.
        svc := DeathStatsService(this.deathLog)
        Assert.True(IsObject(svc))
    }

    constructor_throws_when_catalog_is_random_object()
    {
        Assert.Throws(TypeError, () => DeathStatsService(this.deathLog, Map()))
    }

    ; ============================================================
    ; Aggregate: empty / minimal
    ; ============================================================

    aggregate_empty_log_returns_zero_total_and_empty_per_zone()
    {
        result := this.svc.Aggregate()
        Assert.Equal(0, result["totalDeaths"])
        Assert.Equal(0, result["perZone"].Length)
    }

    aggregate_empty_log_returns_empty_available_lists()
    {
        result := this.svc.Aggregate()
        Assert.Equal(0, result["availablePatches"].Length)
        Assert.Equal(0, result["availableProfiles"].Length)
    }

    aggregate_single_death_counts_one()
    {
        this._Record("Mud Burrow")
        result := this.svc.Aggregate()
        Assert.Equal(1, result["totalDeaths"])
        Assert.Equal(1, result["perZone"].Length)
        Assert.Equal("Mud Burrow", result["perZone"][1]["zoneName"])
        Assert.Equal(1, result["perZone"][1]["count"])
    }

    ; ============================================================
    ; Aggregate: counting + sorting
    ; ============================================================

    aggregate_multiple_deaths_same_zone_aggregates_count()
    {
        this._Record("Mud Burrow", , , "10:00:00")
        this._Record("Mud Burrow", , , "10:05:00")
        this._Record("Mud Burrow", , , "10:10:00")
        result := this.svc.Aggregate()
        Assert.Equal(3, result["totalDeaths"])
        Assert.Equal(1, result["perZone"].Length)
        Assert.Equal(3, result["perZone"][1]["count"])
    }

    aggregate_multiple_zones_sorted_descending_by_count()
    {
        ; 2x Mud Burrow, 5x Riverbank, 1x Cemetery -> expect Riverbank
        ; first, Mud Burrow second, Cemetery last.
        loop 2
            this._Record("Mud Burrow", , , "10:0" A_Index ":00")
        loop 5
            this._Record("The Riverbank", , , "11:0" A_Index ":00")
        this._Record("Cemetery of the Eternals", , , "12:00:00")

        result := this.svc.Aggregate()
        Assert.Equal(8, result["totalDeaths"])
        Assert.Equal(3, result["perZone"].Length)
        Assert.Equal("The Riverbank",            result["perZone"][1]["zoneName"])
        Assert.Equal(5,                          result["perZone"][1]["count"])
        Assert.Equal("Mud Burrow",               result["perZone"][2]["zoneName"])
        Assert.Equal(2,                          result["perZone"][2]["count"])
        Assert.Equal("Cemetery of the Eternals", result["perZone"][3]["zoneName"])
        Assert.Equal(1,                          result["perZone"][3]["count"])
    }

    aggregate_ties_preserve_insertion_order()
    {
        ; Both zones have 1 death. Insertion order (first append) is
        ; "Mud Burrow", then "The Riverbank". Stable sort must keep
        ; that order on equal counts.
        this._Record("Mud Burrow",    , , "10:00:00")
        this._Record("The Riverbank", , , "10:05:00")
        result := this.svc.Aggregate()
        Assert.Equal(2, result["perZone"].Length)
        Assert.Equal("Mud Burrow",    result["perZone"][1]["zoneName"])
        Assert.Equal("The Riverbank", result["perZone"][2]["zoneName"])
    }

    ; ============================================================
    ; Aggregate: filters
    ; ============================================================

    aggregate_filters_by_patch_only()
    {
        this._Record("Mud Burrow",    "0.4", "Default", "10:00:00")
        this._Record("Mud Burrow",    "0.5", "Default", "11:00:00")
        this._Record("The Riverbank", "0.4", "Default", "12:00:00")

        result := this.svc.Aggregate(Map("patch", "0.4"))
        Assert.Equal(2, result["totalDeaths"])
        Assert.Equal(2, result["perZone"].Length)
    }

    aggregate_filters_by_profile_only()
    {
        this._Record("Mud Burrow",    "0.4", "BuildA", "10:00:00")
        this._Record("Mud Burrow",    "0.4", "BuildB", "11:00:00")
        this._Record("The Riverbank", "0.4", "BuildA", "12:00:00")

        result := this.svc.Aggregate(Map("profile", "BuildA"))
        Assert.Equal(2, result["totalDeaths"])
    }

    aggregate_filters_by_patch_and_profile_combined()
    {
        this._Record("Mud Burrow",    "0.4", "BuildA", "10:00:00")  ; match
        this._Record("Mud Burrow",    "0.4", "BuildB", "11:00:00")  ; profile mismatch
        this._Record("Mud Burrow",    "0.5", "BuildA", "12:00:00")  ; patch mismatch
        this._Record("The Riverbank", "0.4", "BuildA", "13:00:00")  ; match

        result := this.svc.Aggregate(Map("patch", "0.4", "profile", "BuildA"))
        Assert.Equal(2, result["totalDeaths"])
    }

    aggregate_empty_filter_returns_all_data()
    {
        this._Record("Mud Burrow",    "0.4", "BuildA", "10:00:00")
        this._Record("The Riverbank", "0.5", "BuildB", "11:00:00")

        ; Empty Map -> no filter applied.
        result := this.svc.Aggregate(Map())
        Assert.Equal(2, result["totalDeaths"])

        ; Empty string ("" default) -> same.
        result := this.svc.Aggregate("")
        Assert.Equal(2, result["totalDeaths"])
    }

    aggregate_filter_with_no_matches_returns_zero()
    {
        this._Record("Mud Burrow", "0.4", "Default")
        result := this.svc.Aggregate(Map("patch", "1.0"))
        Assert.Equal(0, result["totalDeaths"])
        Assert.Equal(0, result["perZone"].Length)
    }

    aggregate_filter_value_whitespace_treated_as_no_filter()
    {
        ; UI may pass "" or "   " for the "All" selection. The service
        ; treats both as "no filter on this dimension".
        this._Record("Mud Burrow",    "0.4", "BuildA")
        this._Record("The Riverbank", "0.5", "BuildB")

        result := this.svc.Aggregate(Map("patch", "   "))
        Assert.Equal(2, result["totalDeaths"])

        result := this.svc.Aggregate(Map("profile", ""))
        Assert.Equal(2, result["totalDeaths"])
    }

    ; ============================================================
    ; Aggregate: town zone handling
    ; ============================================================

    aggregate_skips_town_zones_when_catalog_present()
    {
        ; 2 town deaths + 1 normal -> count should be 1, towns dropped.
        this._Record("Clearfell Encampment", , , "10:00:00")  ; town
        this._Record("The Hooded One",       , , "11:00:00")  ; town
        this._Record("Mud Burrow",           , , "12:00:00")  ; normal

        result := this.svc.Aggregate()
        Assert.Equal(1, result["totalDeaths"])
        Assert.Equal(1, result["perZone"].Length)
        Assert.Equal("Mud Burrow", result["perZone"][1]["zoneName"])
    }

    aggregate_includes_all_zones_when_catalog_absent()
    {
        ; Build a service without catalog: every zone passes (no
        ; way to know what's a town).
        svcNoCatalog := DeathStatsService(this.deathLog)

        this._Record("Clearfell Encampment", , , "10:00:00")
        this._Record("Mud Burrow",           , , "11:00:00")

        result := svcNoCatalog.Aggregate()
        Assert.Equal(2, result["totalDeaths"])
        Assert.Equal(2, result["perZone"].Length)
    }

    aggregate_unknown_zone_passes_through_catalog_filter()
    {
        ; "Future Patch Zone" is NOT in the test catalog. Should be
        ; counted (catalog's IsTownName returns false for unknown).
        this._Record("Mud Burrow",         , , "10:00:00")
        this._Record("Future Patch Zone",  , , "11:00:00")

        result := this.svc.Aggregate()
        Assert.Equal(2, result["totalDeaths"])
    }

    ; ============================================================
    ; Available lists
    ; ============================================================

    available_patches_dedupes_and_sorts_case_insensitive()
    {
        this._Record("Mud Burrow", "0.5",     "Default", "10:00:00")
        this._Record("Mud Burrow", "0.4",     "Default", "11:00:00")
        this._Record("Mud Burrow", "0.5",     "Default", "12:00:00")  ; dup
        this._Record("Mud Burrow", "0.4-beta", "Default", "13:00:00")

        result := this.svc.Aggregate()
        patches := result["availablePatches"]
        Assert.Equal(3, patches.Length)
        Assert.Equal("0.4",      patches[1])
        Assert.Equal("0.4-beta", patches[2])
        Assert.Equal("0.5",      patches[3])
    }

    available_profiles_dedupes_and_sorts_case_insensitive()
    {
        this._Record("Mud Burrow", "0.4", "Zerker",  "10:00:00")
        this._Record("Mud Burrow", "0.4", "Archer",  "11:00:00")
        this._Record("Mud Burrow", "0.4", "zerker",  "12:00:00")  ; case-dup
        this._Record("Mud Burrow", "0.4", "Monk",    "13:00:00")

        result := this.svc.Aggregate()
        profiles := result["availableProfiles"]
        ; "Zerker" and "zerker" are different strings (Map keys are
        ; case-sensitive) but sort next to each other case-insensitively.
        Assert.Equal(4, profiles.Length)
        Assert.Equal("Archer", profiles[1])
        Assert.Equal("Monk",   profiles[2])
        ; Stable case-insensitive sort: "Zerker" appears before "zerker"
        ; if it was inserted first (which it was in this test).
        Assert.True(profiles[3] = "Zerker" || profiles[3] = "zerker")
        Assert.True(profiles[4] = "Zerker" || profiles[4] = "zerker")
    }

    available_lists_extracted_from_full_dataset_ignoring_filter()
    {
        this._Record("Mud Burrow",    "0.4", "BuildA", "10:00:00")
        this._Record("The Riverbank", "0.5", "BuildB", "11:00:00")

        ; Even with a filter that matches one row, both patches and
        ; both profiles should appear in the available lists -- the
        ; UI needs the full picture to populate dropdowns.
        result := this.svc.Aggregate(Map("patch", "0.4"))
        Assert.Equal(1, result["totalDeaths"])
        Assert.Equal(2, result["availablePatches"].Length)
        Assert.Equal(2, result["availableProfiles"].Length)
    }

    available_lists_skip_empty_values()
    {
        ; Append rows that have empty patch / profile. The available
        ; lists should not carry an "" entry (would render as a blank
        ; option in the dropdown).
        this.deathLog.Append("Mud Burrow", "",    "Default", "2026-05-20 10:00:00")
        this.deathLog.Append("Mud Burrow", "0.4", "",        "2026-05-20 11:00:00")

        result := this.svc.Aggregate()
        Assert.Equal(1, result["availablePatches"].Length)
        Assert.Equal("0.4", result["availablePatches"][1])
        Assert.Equal(1, result["availableProfiles"].Length)
        Assert.Equal("Default", result["availableProfiles"][1])
    }
}

TestRegistry.Register(DeathStatsServiceTests)
