; ============================================================
; ZonesCatalog + ZoneEntry tests
; ============================================================
;
; ZonesCatalog parses data/zones.csv (format `;` delimited:
;   name;internal_id;act;is_town
; ) and exposes queries by name (case-insensitive) and by
; internal_id (case-sensitive). Skips header, comments (# and ;),
; and lines with fewer than 4 fields.
;
; ZoneEntry is a value object: name, internalId, act, isTown.
;
; Local helper: _WriteCsv(path, lines) creates a CSV file via FileAppend.

class ZonesCatalogTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- ZoneEntry ---
        "zone_entry_stores_constructor_args",

        ; --- ZonesCatalog constructor ---
        "constructor_throws_on_empty_path",
        "constructor_with_missing_file_returns_empty_catalog",

        ; --- Basic parsing ---
        "loads_valid_csv_zones",
        "count_returns_zone_count",
        "all_returns_array_of_zone_entries",
        "get_path_returns_constructor_arg",

        ; --- Skipping ---
        "skips_header_line_with_name_internal_id",
        "skips_comment_lines_starting_with_hash",
        "skips_comment_lines_starting_with_semicolon",
        "skips_empty_lines",
        "skips_lines_with_fewer_than_four_fields",

        ; --- FindByName / FindById ---
        "find_by_name_returns_zone_entry",
        "find_by_name_is_case_insensitive",
        "find_by_name_trims_whitespace",
        "find_by_name_returns_empty_for_missing_zone",
        "find_by_name_returns_empty_for_empty_string",
        "find_by_id_returns_zone_entry",
        "find_by_id_is_case_sensitive",
        "find_by_id_returns_empty_for_missing_id",

        ; --- HasName / HasId ---
        "has_name_returns_true_for_existing_zone",
        "has_name_returns_false_for_missing_zone",
        "has_id_returns_true_for_existing_id",

        ; --- IsTownName / IsTownById ---
        "is_town_name_true_for_town",
        "is_town_name_false_for_normal_zone",
        "is_town_name_false_for_missing_zone",
        "is_town_by_id_true_for_town",

        ; --- GetActOfName / GetActOfId ---
        "get_act_of_name_returns_act_number",
        "get_act_of_name_returns_zero_for_missing_zone",
        "get_act_of_id_returns_act_number",

        ; --- ByAct / Towns ---
        "by_act_filters_zones_by_act_index",
        "towns_returns_only_towns",

        ; --- Reload ---
        "reload_picks_up_changes_to_file",
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _WriteCsv(path, lines)
    {
        ; lines: Array<string>, each becomes a CSV line.
        ; `ln` collides with the builtin function `Ln` (natural log).
        content := ""
        for _, csvLine in lines
            content .= csvLine "`n"
        FileAppend(content, path, "UTF-8")
    }

    _MakeStandardCatalog()
    {
        ; Test catalog with 4 zones (2 towns, 2 normal, across 2 acts)
        path := Fixtures.TempPath("csv")
        this._WriteCsv(path, [
            "name;internal_id;act;is_town",
            "Clearfell Encampment;G1_town;1;1",
            "Mud Burrow;G1_2;1;0",
            "The Ardura Caravan;G2_town;2;1",
            "Vastiri Outskirts;G2_1;2;0"
        ])
        return ZonesCatalog(path)
    }

    ; ============================================================
    ; ZoneEntry
    ; ============================================================

    zone_entry_stores_constructor_args()
    {
        entry := ZoneEntry("Mud Burrow", "G1_2", 1, false)
        Assert.Equal("Mud Burrow", entry.name)
        Assert.Equal("G1_2",       entry.internalId)
        Assert.Equal(1,            entry.act)
        Assert.False(entry.isTown)
    }

    ; ============================================================
    ; ZonesCatalog constructor
    ; ============================================================

    constructor_throws_on_empty_path()
    {
        Assert.Throws(ValueError, () => ZonesCatalog(""))
    }

    constructor_with_missing_file_returns_empty_catalog()
    {
        ; Non-existent file does not throw - returns empty catalog
        catalog := ZonesCatalog("C:\\__nonexistent_zones__.csv")
        Assert.Equal(0, catalog.Count())
    }

    ; ============================================================
    ; Basic parsing
    ; ============================================================

    loads_valid_csv_zones()
    {
        catalog := this._MakeStandardCatalog()
        Assert.Equal(4, catalog.Count())
    }

    count_returns_zone_count()
    {
        catalog := this._MakeStandardCatalog()
        Assert.Equal(4, catalog.Count())
    }

    all_returns_array_of_zone_entries()
    {
        catalog := this._MakeStandardCatalog()
        zones := catalog.All()
        Assert.Equal(4, zones.Length)
        Assert.IsType(ZoneEntry, zones[1])
    }

    get_path_returns_constructor_arg()
    {
        path := Fixtures.TempPath("csv")
        FileAppend("name;internal_id;act;is_town`n", path, "UTF-8")
        catalog := ZonesCatalog(path)
        Assert.Equal(path, catalog.GetPath())
    }

    ; ============================================================
    ; Skipping
    ; ============================================================

    skips_header_line_with_name_internal_id()
    {
        ; The first line "name;internal_id;..." is skipped
        catalog := this._MakeStandardCatalog()
        ; Only counts data rows, not the header
        Assert.False(catalog.HasName("name"))
        Assert.Equal(4, catalog.Count())
    }

    skips_comment_lines_starting_with_hash()
    {
        path := Fixtures.TempPath("csv")
        this._WriteCsv(path, [
            "# Comment 1",
            "Clearfell;G1_town;1;1",
            "# Comment 2",
            "Mud Burrow;G1_2;1;0"
        ])
        catalog := ZonesCatalog(path)
        Assert.Equal(2, catalog.Count())
    }

    skips_comment_lines_starting_with_semicolon()
    {
        path := Fixtures.TempPath("csv")
        this._WriteCsv(path, [
            "; Another comment style",
            "Clearfell;G1_town;1;1"
        ])
        catalog := ZonesCatalog(path)
        Assert.Equal(1, catalog.Count())
    }

    skips_empty_lines()
    {
        path := Fixtures.TempPath("csv")
        this._WriteCsv(path, [
            "Clearfell;G1_town;1;1",
            "",
            "",
            "Mud Burrow;G1_2;1;0"
        ])
        catalog := ZonesCatalog(path)
        Assert.Equal(2, catalog.Count())
    }

    skips_lines_with_fewer_than_four_fields()
    {
        path := Fixtures.TempPath("csv")
        this._WriteCsv(path, [
            "OnlyOne",
            "Two;Fields",
            "Three;Fields;Only",
            "Clearfell;G1_town;1;1"
        ])
        catalog := ZonesCatalog(path)
        Assert.Equal(1, catalog.Count())
    }

    ; ============================================================
    ; FindByName / FindById
    ; ============================================================

    find_by_name_returns_zone_entry()
    {
        catalog := this._MakeStandardCatalog()
        entry := catalog.FindByName("Mud Burrow")
        Assert.IsType(ZoneEntry, entry)
        Assert.Equal("Mud Burrow", entry.name)
        Assert.Equal("G1_2",       entry.internalId)
        Assert.Equal(1,            entry.act)
        Assert.False(entry.isTown)
    }

    find_by_name_is_case_insensitive()
    {
        catalog := this._MakeStandardCatalog()
        Assert.IsType(ZoneEntry, catalog.FindByName("mud burrow"))
        Assert.IsType(ZoneEntry, catalog.FindByName("MUD BURROW"))
        Assert.IsType(ZoneEntry, catalog.FindByName("Mud Burrow"))
    }

    find_by_name_trims_whitespace()
    {
        catalog := this._MakeStandardCatalog()
        Assert.IsType(ZoneEntry, catalog.FindByName("  Mud Burrow  "))
    }

    find_by_name_returns_empty_for_missing_zone()
    {
        catalog := this._MakeStandardCatalog()
        Assert.Equal("", catalog.FindByName("Nonexistent Zone"))
    }

    find_by_name_returns_empty_for_empty_string()
    {
        catalog := this._MakeStandardCatalog()
        Assert.Equal("", catalog.FindByName(""))
    }

    find_by_id_returns_zone_entry()
    {
        catalog := this._MakeStandardCatalog()
        entry := catalog.FindById("G1_2")
        Assert.IsType(ZoneEntry, entry)
        Assert.Equal("Mud Burrow", entry.name)
    }

    find_by_id_is_case_sensitive()
    {
        catalog := this._MakeStandardCatalog()
        Assert.IsType(ZoneEntry, catalog.FindById("G1_2"))
        ; Lowercase doesn't match
        Assert.Equal("", catalog.FindById("g1_2"))
    }

    find_by_id_returns_empty_for_missing_id()
    {
        catalog := this._MakeStandardCatalog()
        Assert.Equal("", catalog.FindById("XXX"))
    }

    ; ============================================================
    ; HasName / HasId
    ; ============================================================

    has_name_returns_true_for_existing_zone()
    {
        catalog := this._MakeStandardCatalog()
        Assert.True(catalog.HasName("Mud Burrow"))
        Assert.True(catalog.HasName("mud burrow"))
    }

    has_name_returns_false_for_missing_zone()
    {
        catalog := this._MakeStandardCatalog()
        Assert.False(catalog.HasName("Bogus"))
    }

    has_id_returns_true_for_existing_id()
    {
        catalog := this._MakeStandardCatalog()
        Assert.True(catalog.HasId("G1_2"))
        Assert.False(catalog.HasId("xxx"))
    }

    ; ============================================================
    ; IsTownName / IsTownById
    ; ============================================================

    is_town_name_true_for_town()
    {
        catalog := this._MakeStandardCatalog()
        Assert.True(catalog.IsTownName("Clearfell Encampment"))
        Assert.True(catalog.IsTownName("The Ardura Caravan"))
    }

    is_town_name_false_for_normal_zone()
    {
        catalog := this._MakeStandardCatalog()
        Assert.False(catalog.IsTownName("Mud Burrow"))
    }

    is_town_name_false_for_missing_zone()
    {
        catalog := this._MakeStandardCatalog()
        Assert.False(catalog.IsTownName("Bogus"))
    }

    is_town_by_id_true_for_town()
    {
        catalog := this._MakeStandardCatalog()
        Assert.True(catalog.IsTownById("G1_town"))
        Assert.False(catalog.IsTownById("G1_2"))
    }

    ; ============================================================
    ; GetActOfName / GetActOfId
    ; ============================================================

    get_act_of_name_returns_act_number()
    {
        catalog := this._MakeStandardCatalog()
        Assert.Equal(1, catalog.GetActOfName("Mud Burrow"))
        Assert.Equal(2, catalog.GetActOfName("Vastiri Outskirts"))
    }

    get_act_of_name_returns_zero_for_missing_zone()
    {
        catalog := this._MakeStandardCatalog()
        Assert.Equal(0, catalog.GetActOfName("Bogus"))
    }

    get_act_of_id_returns_act_number()
    {
        catalog := this._MakeStandardCatalog()
        Assert.Equal(2, catalog.GetActOfId("G2_town"))
    }

    ; ============================================================
    ; ByAct / Towns
    ; ============================================================

    by_act_filters_zones_by_act_index()
    {
        catalog := this._MakeStandardCatalog()
        act1 := catalog.ByAct(1)
        Assert.Equal(2, act1.Length)
        for _, z in act1
            Assert.Equal(1, z.act)
    }

    towns_returns_only_towns()
    {
        catalog := this._MakeStandardCatalog()
        towns := catalog.Towns()
        Assert.Equal(2, towns.Length)
        for _, z in towns
            Assert.True(z.isTown)
    }

    ; ============================================================
    ; Reload
    ; ============================================================

    reload_picks_up_changes_to_file()
    {
        path := Fixtures.TempPath("csv")
        this._WriteCsv(path, ["Clearfell;G1_town;1;1"])
        catalog := ZonesCatalog(path)
        Assert.Equal(1, catalog.Count())

        ; Adds new line and reloads
        FileAppend("Mud Burrow;G1_2;1;0`n", path, "UTF-8")
        catalog.Reload()
        Assert.Equal(2, catalog.Count())
    }
}

TestRegistry.Register(ZonesCatalogTests)
