; ============================================================
; ZonesCatalog + ZoneEntry tests
; ============================================================
;
; ZonesCatalog parseia data/zones.csv (formato `;` delimitado:
;   name;internal_id;act;is_town
; ) e expoe queries por nome (case-insensitive) e por internal_id
; (case-sensitive). Pula header, comments (# e ;), e linhas com
; menos de 4 campos.
;
; ZoneEntry e' value object: name, internalId, act, isTown.
;
; Helper local: _WriteCsv(path, lines) cria arquivo CSV via FileAppend.

class ZonesCatalogTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- ZoneEntry ---
        "zone_entry_stores_constructor_args",

        ; --- Construtor ZonesCatalog ---
        "constructor_throws_on_empty_path",
        "constructor_with_missing_file_returns_empty_catalog",

        ; --- Parsing basico ---
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
        ; lines: Array<string>, cada uma vira uma linha do CSV.
        ; `ln` colide com builtin function `Ln` (logaritmo natural).
        content := ""
        for _, csvLine in lines
            content .= csvLine "`n"
        FileAppend(content, path, "UTF-8")
    }

    _MakeStandardCatalog()
    {
        ; Catalogo de teste com 4 zonas (2 towns, 2 normais, em 2 atos)
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
    ; Construtor ZonesCatalog
    ; ============================================================

    constructor_throws_on_empty_path()
    {
        Assert.Throws(ValueError, () => ZonesCatalog(""))
    }

    constructor_with_missing_file_returns_empty_catalog()
    {
        ; Arquivo inexistente nao estoura - retorna catalogo vazio
        catalog := ZonesCatalog("C:\\__nonexistent_zones__.csv")
        Assert.Equal(0, catalog.Count())
    }

    ; ============================================================
    ; Parsing basico
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
        ; A primeira linha "name;internal_id;..." e' pulada
        catalog := this._MakeStandardCatalog()
        ; So conta dados, nao o header
        Assert.False(catalog.HasName("name"))
        Assert.Equal(4, catalog.Count())
    }

    skips_comment_lines_starting_with_hash()
    {
        path := Fixtures.TempPath("csv")
        this._WriteCsv(path, [
            "# Comentario 1",
            "Clearfell;G1_town;1;1",
            "# Comentario 2",
            "Mud Burrow;G1_2;1;0"
        ])
        catalog := ZonesCatalog(path)
        Assert.Equal(2, catalog.Count())
    }

    skips_comment_lines_starting_with_semicolon()
    {
        path := Fixtures.TempPath("csv")
        this._WriteCsv(path, [
            "; Outro estilo de comentario",
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
        ; Lowercase nao da match
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

        ; Adiciona nova linha e reload
        FileAppend("Mud Burrow;G1_2;1;0`n", path, "UTF-8")
        catalog.Reload()
        Assert.Equal(2, catalog.Count())
    }
}

TestRegistry.Register(ZonesCatalogTests)
