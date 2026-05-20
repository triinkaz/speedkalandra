; ============================================================
; PersonalBestRepository tests
; ============================================================
;
; Persists PBs in an atomic INI:
;   [Run]       BestMs, BestRunId
;   [RunByAct]  Act<N>Ms (regex match)
;   [Zones]     <zoneName>=<ms> (zoneName sanitized)
;
; Load returns Map{runPbMs, runPbRunId, runPbByAct, zonePbs}.
; Save serializes the full INI in memory and writes via AtomicWriter.

class PersonalBestRepositoryTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Regression: encoding for IniRead key-lookup ---
        "iniread_key_lookup_works_in_utf16_le_bom_but_not_utf8_bom",

        ; --- Constructor ---
        "constructor_throws_on_empty_path",
        "constructor_throws_on_whitespace_path",
        "get_path_returns_constructor_arg",

        ; --- Load: missing file ---
        "load_returns_empty_structure_when_file_missing",

        ; --- Load: parsing ---
        "load_parses_run_section",
        "load_parses_run_by_act_section",
        "load_skips_run_by_act_keys_not_matching_pattern",
        "load_skips_run_by_act_with_zero_or_negative_ms",
        "load_parses_zones_section",
        "load_skips_zones_with_zero_or_negative_ms",

        ; --- Save: validation ---
        "save_returns_false_when_data_not_object",
        "save_returns_true_on_success",

        ; --- Save: atomic write ---
        "save_creates_file",
        "save_does_not_leave_tmp_behind",

        ; --- Save: serialization ---
        "save_serializes_run_section",
        "save_serializes_run_by_act",
        "save_serializes_zones",
        "save_sanitizes_zone_names_with_invalid_chars",
        "save_ignores_zones_with_invalid_ms",
        "save_skips_runs_with_invalid_act_keys",

        ; --- Roundtrip ---
        "roundtrip_load_save_preserves_pbs",

        ; --- Constructor sink validation (fail-fast via Resolve) ---
        "constructor_throws_when_warning_sink_lacks_warn_method",
    ]

    ; ============================================================
    ; Helper
    ; ============================================================

    _MakePbData()
    {
        return Map(
            "runPbMs",    410000,
            "runPbRunId", "20260512_142345",
            "runPbByAct", Map(1, 1725000, 2, 3900000, 3, 6900000),
            "zonePbs",    Map("Mud Burrow", 215000, "Clearfell", 180000)
        )
    }

    ; ============================================================
    ; Regression: encoding for IniRead key-lookup
    ; ============================================================
    ;
    ; PITFALL (single regression for an AHK encoding pitfall):
    ; IniRead key-lookup (`IniRead(path, section, key, default)`) in
    ; AHK v2 ONLY works on UTF-16 LE BOM files. On UTF-8 BOM it
    ; always returns the default, regardless of line endings.
    ;
    ; Section-reads (`IniRead(path, section)`, no key) tolerate both
    ; encodings — that's why ReadSectionAsMap works, but Read doesn't.
    ;
    ; Project impact:
    ;   - PersonalBestRepository.Save changed from "UTF-8" -> "UTF-16".
    ;   - This file's tests write INIs via FileAppend "UTF-16".
    ;   - R11 (TextEncoding.MigrateIniToUtf8) is a latent project bug:
    ;     migrates main INIs to UTF-8 BOM, breaking every IniRead
    ;     key-lookup on them. Resolve separately.

    iniread_key_lookup_works_in_utf16_le_bom_but_not_utf8_bom()
    {
        ; UTF-16 LE BOM: works
        utf16Path := Fixtures.TempPath("ini")
        FileAppend("[S]`r`nK=V`r`n", utf16Path, "UTF-16")
        utf16Ini := IniFile(utf16Path)
        Assert.Equal("V", utf16Ini.Read("S", "K", "DEFAULT"),
            "UTF-16 LE BOM must work")

        ; UTF-8 BOM: does NOT work (returns default)
        utf8Path := Fixtures.TempPath("ini")
        FileAppend("[S]`r`nK=V`r`n", utf8Path, "UTF-8")
        utf8Ini := IniFile(utf8Path)
        Assert.Equal("DEFAULT", utf8Ini.Read("S", "K", "DEFAULT"),
            "UTF-8 BOM returns default - this is the documented pitfall")
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_on_empty_path()
    {
        Assert.Throws(ValueError, () => PersonalBestRepository(""))
    }

    constructor_throws_on_whitespace_path()
    {
        Assert.Throws(ValueError, () => PersonalBestRepository("   "))
    }

    get_path_returns_constructor_arg()
    {
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        Assert.Equal(path, repo.GetPath())
    }

    ; ============================================================
    ; Load: missing file
    ; ============================================================

    load_returns_empty_structure_when_file_missing()
    {
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        loaded := repo.Load()

        Assert.Equal(0,  loaded["runPbMs"])
        Assert.Equal("", loaded["runPbRunId"])
        Assert.Equal(0,  loaded["runPbByAct"].Count)
        Assert.Equal(0,  loaded["zonePbs"].Count)
    }

    ; ============================================================
    ; Load: parsing
    ; ============================================================

    load_parses_run_section()
    {
        path := Fixtures.TempPath("ini")
        ; UTF-16 required: IniRead key-lookup doesn't work on UTF-8 BOM.
        FileAppend("[Run]`r`nBestMs=410000`r`nBestRunId=20260512_142345`r`n",
            path, "UTF-16")
        repo := PersonalBestRepository(path)
        loaded := repo.Load()

        Assert.Equal(410000,            loaded["runPbMs"])
        Assert.Equal("20260512_142345", loaded["runPbRunId"])
    }

    load_parses_run_by_act_section()
    {
        path := Fixtures.TempPath("ini")
        FileAppend("[RunByAct]`r`nAct1Ms=1725000`r`nAct2Ms=3900000`r`n",
            path, "UTF-16")
        repo := PersonalBestRepository(path)
        loaded := repo.Load()

        Assert.Equal(1725000, loaded["runPbByAct"][1])
        Assert.Equal(3900000, loaded["runPbByAct"][2])
    }

    load_skips_run_by_act_keys_not_matching_pattern()
    {
        path := Fixtures.TempPath("ini")
        FileAppend("[RunByAct]`r`nAct1Ms=1000`r`nGarbage=999`r`nActMs=888`r`n",
            path, "UTF-16")
        repo := PersonalBestRepository(path)
        loaded := repo.Load()

        Assert.Equal(1, loaded["runPbByAct"].Count, "Only Act1Ms must parse")
        Assert.Equal(1000, loaded["runPbByAct"][1])
    }

    load_skips_run_by_act_with_zero_or_negative_ms()
    {
        path := Fixtures.TempPath("ini")
        FileAppend("[RunByAct]`r`nAct1Ms=0`r`nAct2Ms=-100`r`nAct3Ms=5000`r`n",
            path, "UTF-16")
        repo := PersonalBestRepository(path)
        loaded := repo.Load()

        Assert.Equal(1, loaded["runPbByAct"].Count)
        Assert.Equal(5000, loaded["runPbByAct"][3])
    }

    load_parses_zones_section()
    {
        path := Fixtures.TempPath("ini")
        FileAppend("[Zones]`r`nMud Burrow=215000`r`nClearfell=180000`r`n",
            path, "UTF-16")
        repo := PersonalBestRepository(path)
        loaded := repo.Load()

        Assert.Equal(215000, loaded["zonePbs"]["Mud Burrow"])
        Assert.Equal(180000, loaded["zonePbs"]["Clearfell"])
    }

    load_skips_zones_with_zero_or_negative_ms()
    {
        path := Fixtures.TempPath("ini")
        FileAppend("[Zones]`r`nZoneA=0`r`nZoneB=-50`r`nZoneC=100`r`n",
            path, "UTF-16")
        repo := PersonalBestRepository(path)
        loaded := repo.Load()

        Assert.Equal(1, loaded["zonePbs"].Count)
        Assert.Equal(100, loaded["zonePbs"]["ZoneC"])
    }

    ; ============================================================
    ; Save: validation
    ; ============================================================

    save_returns_false_when_data_not_object()
    {
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        Assert.False(repo.Save("not an object"))
        Assert.False(repo.Save(42))
    }

    save_returns_true_on_success()
    {
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        Assert.True(repo.Save(this._MakePbData()))
    }

    ; ============================================================
    ; Save: atomic write
    ; ============================================================

    save_creates_file()
    {
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        repo.Save(this._MakePbData())
        Assert.True(FileExist(path))
    }

    save_does_not_leave_tmp_behind()
    {
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        repo.Save(this._MakePbData())
        Assert.False(FileExist(path ".tmp"))
    }

    ; ============================================================
    ; Save: serialization
    ; ============================================================

    save_serializes_run_section()
    {
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        repo.Save(this._MakePbData())

        content := Fixtures.FileReadAll(path)
        Assert.Contains("[Run]",                content)
        Assert.Contains("BestMs=410000",        content)
        Assert.Contains("BestRunId=20260512_142345", content)
    }

    save_serializes_run_by_act()
    {
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        repo.Save(this._MakePbData())

        content := Fixtures.FileReadAll(path)
        Assert.Contains("[RunByAct]",     content)
        Assert.Contains("Act1Ms=1725000", content)
        Assert.Contains("Act2Ms=3900000", content)
        Assert.Contains("Act3Ms=6900000", content)
    }

    save_serializes_zones()
    {
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        repo.Save(this._MakePbData())

        content := Fixtures.FileReadAll(path)
        Assert.Contains("[Zones]",            content)
        Assert.Contains("Mud Burrow=215000",  content)
        Assert.Contains("Clearfell=180000",   content)
    }

    save_sanitizes_zone_names_with_invalid_chars()
    {
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        repo.Save(Map(
            "runPbMs",    0,
            "runPbRunId", "",
            "runPbByAct", Map(),
            "zonePbs",    Map("Zone=With=Equals", 100, "Zone[bracket]", 200)
        ))

        content := Fixtures.FileReadAll(path)
        ; Chars `=`, `[`, `]` were removed
        Assert.Contains("ZoneWithEquals=100",  content)
        Assert.Contains("Zonebracket=200",     content)
    }

    save_ignores_zones_with_invalid_ms()
    {
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        repo.Save(Map(
            "runPbMs",    0,
            "runPbRunId", "",
            "runPbByAct", Map(),
            "zonePbs",    Map("ValidZone", 100, "InvalidZone", -50, "ZeroZone", 0)
        ))

        loaded := repo.Load()
        Assert.Equal(1, loaded["zonePbs"].Count)
        Assert.Equal(100, loaded["zonePbs"]["ValidZone"])
    }

    save_skips_runs_with_invalid_act_keys()
    {
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        repo.Save(Map(
            "runPbMs",    0,
            "runPbRunId", "",
            "runPbByAct", Map(1, 1000, 0, 999, -1, 888, 2, 2000),
            "zonePbs",    Map()
        ))

        loaded := repo.Load()
        Assert.Equal(2, loaded["runPbByAct"].Count,
            "Only acts 1 and 2 are valid (0 and -1 are skipped)")
        Assert.True(loaded["runPbByAct"].Has(1))
        Assert.True(loaded["runPbByAct"].Has(2))
    }

    ; ============================================================
    ; Roundtrip
    ; ============================================================

    roundtrip_load_save_preserves_pbs()
    {
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        original := this._MakePbData()

        repo.Save(original)
        loaded := repo.Load()

        Assert.Equal(original["runPbMs"],    loaded["runPbMs"])
        Assert.Equal(original["runPbRunId"], loaded["runPbRunId"])

        Assert.Equal(3, loaded["runPbByAct"].Count)
        Assert.Equal(1725000, loaded["runPbByAct"][1])
        Assert.Equal(3900000, loaded["runPbByAct"][2])
        Assert.Equal(6900000, loaded["runPbByAct"][3])

        Assert.Equal(2, loaded["zonePbs"].Count)
        Assert.Equal(215000, loaded["zonePbs"]["Mud Burrow"])
        Assert.Equal(180000, loaded["zonePbs"]["Clearfell"])
    }

    constructor_throws_when_warning_sink_lacks_warn_method()
    {
        ; Map() is an object, looks plausible in a wiring bug, but
        ; doesn't satisfy the WarningSink duck-typed contract. The
        ; constructor (via WarningSink.Resolve) must reject it.
        Assert.Throws(TypeError, () => PersonalBestRepository("some-path.ini", Map("not", "a sink")))
    }
}

TestRegistry.Register(PersonalBestRepositoryTests)
