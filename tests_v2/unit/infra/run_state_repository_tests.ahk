; ============================================================
; RunStateRepository tests
; ============================================================
;
; RunState <-> INI + separate TXT file for zone totals (perf).
;
; INI SECTION: [RunState] with RunId, StartedAt, Status, RunBaseMs,
;              LoadingTotalMs.
; Separate TXT: `<iniBaseName>_zones.txt` in the same dir, format
;               key=value per line, written atomically.

class RunStateRepositoryTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_ini_not_inifile",
        "constructor_derives_zone_totals_path_with_suffix",

        ; --- Load / Save / Clear ---
        "load_returns_empty_when_run_id_missing",
        "load_parses_all_fields",
        "load_uses_default_status_when_missing",
        "save_throws_when_state_not_run_state",
        "save_writes_canonical_fields",
        "roundtrip_save_load_preserves_run_state",
        "clear_removes_run_state_section",

        ; --- SaveRunBaseMs ---
        "save_run_base_ms_writes_only_run_base_ms",
        "save_run_base_ms_coerces_negative_to_zero",
        "save_run_base_ms_coerces_non_number_to_zero",

        ; --- LoadingTotal ---
        "load_loading_total_returns_zero_default",
        "load_loading_total_parses_existing",
        "save_loading_total_coerces_negative_to_zero",
        "save_loading_total_coerces_non_number_to_zero",

        ; --- DeathCount ---
        "load_death_count_returns_zero_default",
        "load_death_count_parses_existing",
        "save_death_count_coerces_negative_to_zero",
        "save_death_count_coerces_non_number_to_zero",

        ; --- LoadZoneTotals / SaveZoneTotals / Clear ---
        "load_zone_totals_returns_empty_when_file_missing",
        "load_zone_totals_parses_key_equals_value",
        "load_zone_totals_skips_malformed_lines",
        "load_zone_totals_skips_zero_or_negative_ms",
        "save_zone_totals_throws_when_not_map",
        "save_zone_totals_creates_file",
        "save_zone_totals_sanitizes_zone_name",
        "save_zone_totals_ignores_zero_or_negative_ms",
        "clear_zone_totals_deletes_file",
        "clear_zone_totals_no_op_when_missing",
        "roundtrip_save_load_zone_totals",

        ; --- LoadLoadingEvents / SaveLoadingEvents / Clear ---
        "constructor_derives_loading_events_path_with_suffix",
        "load_loading_events_returns_empty_when_file_missing",
        "load_loading_events_parses_tsv_rows",
        "load_loading_events_skips_lines_with_wrong_column_count",
        "load_loading_events_skips_non_number_duration",
        "load_loading_events_skips_zero_or_negative_duration",
        "save_loading_events_throws_when_not_array",
        "save_loading_events_creates_file",
        "save_loading_events_skips_non_map_entries",
        "save_loading_events_skips_invalid_duration_entries",
        "save_loading_events_sanitizes_tab_newline_chars",
        "save_loading_events_writes_empty_file_for_empty_array",
        "save_loading_events_returns_true_on_success",
        "clear_loading_events_deletes_file",
        "clear_loading_events_no_op_when_missing",
        "roundtrip_save_load_loading_events",
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_ini_not_inifile()
    {
        Assert.Throws(TypeError, () => RunStateRepository("not an ini"))
        Assert.Throws(TypeError, () => RunStateRepository(Map()))
    }

    constructor_derives_zone_totals_path_with_suffix()
    {
        ; Given an IniFile at "<dir>\name.ini", the zone totals go to
        ; "<dir>\name_zones.txt"
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        ; Save something to force creation of the _zones.txt
        repo.SaveZoneTotals(Map("Mud Burrow", 1000))
        Assert.True(FileExist(tmpDir "\state_zones.txt"))
    }

    ; ============================================================
    ; Load / Save / Clear
    ; ============================================================

    load_returns_empty_when_run_id_missing()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        state := repo.Load()
        ; RunState.Empty() = empty runId
        Assert.Equal("", state.runId)
    }

    load_parses_all_fields()
    {
        path := Fixtures.TempPath("ini")
        mainIni := IniFile(path)
        mainIni.Write("20260512_142345", "RunState", "RunId")
        mainIni.Write("2026-05-12 14:23:45", "RunState", "StartedAt")
        mainIni.Write("running", "RunState", "Status")
        mainIni.Write(187432, "RunState", "RunBaseMs")

        repo := RunStateRepository(mainIni)
        state := repo.Load()

        Assert.Equal("20260512_142345",     state.runId)
        Assert.Equal("2026-05-12 14:23:45", state.startedAt)
        Assert.Equal("running",             state.status)
        Assert.Equal(187432,                state.runBaseMs)
    }

    load_uses_default_status_when_missing()
    {
        path := Fixtures.TempPath("ini")
        mainIni := IniFile(path)
        ; No Status written, but has runId so we don't fall into Empty()
        mainIni.Write("20260512_142345", "RunState", "RunId")
        repo := RunStateRepository(mainIni)
        state := repo.Load()
        Assert.Equal("idle", state.status)
    }

    save_throws_when_state_not_run_state()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        Assert.Throws(TypeError, () => repo.Save("not a state"))
        Assert.Throws(TypeError, () => repo.Save(Map()))
    }

    save_writes_canonical_fields()
    {
        path := Fixtures.TempPath("ini")
        mainIni := IniFile(path)
        repo := RunStateRepository(mainIni)

        state := RunState.FromMap(Map(
            "runId",     "20260512_142345",
            "startedAt", "2026-05-12 14:23:45",
            "status",    "running",
            "runBaseMs", 187432
        ))
        repo.Save(state)

        Assert.Equal("20260512_142345",     mainIni.Read("RunState", "RunId"))
        Assert.Equal("running",             mainIni.Read("RunState", "Status"))
        Assert.Equal("187432",              mainIni.Read("RunState", "RunBaseMs"))
    }

    roundtrip_save_load_preserves_run_state()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)

        original := RunState.FromMap(Map(
            "runId",     "20260512_142345",
            "startedAt", "2026-05-12 14:23:45",
            "status",    "paused",
            "runBaseMs", 555000
        ))
        repo.Save(original)
        loaded := repo.Load()

        Assert.Equal(original.runId,     loaded.runId)
        Assert.Equal(original.startedAt, loaded.startedAt)
        Assert.Equal(original.status,    loaded.status)
        Assert.Equal(original.runBaseMs, loaded.runBaseMs)
    }

    clear_removes_run_state_section()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        repo.Save(RunState.FromMap(Map(
            "runId",     "20260512_142345",
            "startedAt", "2026-05-12 14:23:45",
            "status",    "running",
            "runBaseMs", 1000
        )))
        Assert.True(mainIni.SectionExists("RunState"))

        repo.Clear()
        Assert.False(mainIni.SectionExists("RunState"))
    }

    ; ============================================================
    ; SaveRunBaseMs
    ; ============================================================

    save_run_base_ms_writes_only_run_base_ms()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        repo.SaveRunBaseMs(98765)
        Assert.Equal("98765", mainIni.Read("RunState", "RunBaseMs"))
    }

    save_run_base_ms_coerces_negative_to_zero()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        repo.SaveRunBaseMs(-500)
        Assert.Equal("0", mainIni.Read("RunState", "RunBaseMs"))
    }

    save_run_base_ms_coerces_non_number_to_zero()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        repo.SaveRunBaseMs("not a number")
        Assert.Equal("0", mainIni.Read("RunState", "RunBaseMs"))
    }

    ; ============================================================
    ; LoadingTotal
    ; ============================================================

    load_loading_total_returns_zero_default()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        Assert.Equal(0, repo.LoadLoadingTotal())
    }

    load_loading_total_parses_existing()
    {
        path := Fixtures.TempPath("ini")
        mainIni := IniFile(path)
        mainIni.Write(24500, "RunState", "LoadingTotalMs")
        repo := RunStateRepository(mainIni)
        Assert.Equal(24500, repo.LoadLoadingTotal())
    }

    save_loading_total_coerces_negative_to_zero()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        repo.SaveLoadingTotal(-100)
        Assert.Equal(0, repo.LoadLoadingTotal())
    }

    save_loading_total_coerces_non_number_to_zero()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        repo.SaveLoadingTotal("not a number")
        Assert.Equal(0, repo.LoadLoadingTotal())
    }

    ; ============================================================
    ; LoadDeathCount / SaveDeathCount
    ; ============================================================
    ; Mirrors LoadingTotal exactly — same scalar shape, same INI
    ; section, same coercion rules. Used by the recorder to
    ; restore _deathCount across reboots of an in-progress run
    ; (without it, multi-session runs would under-report total
    ; deaths in the finalized history dialog).

    load_death_count_returns_zero_default()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        Assert.Equal(0, repo.LoadDeathCount())
    }

    load_death_count_parses_existing()
    {
        path := Fixtures.TempPath("ini")
        mainIni := IniFile(path)
        mainIni.Write(7, "RunState", "DeathCount")
        repo := RunStateRepository(mainIni)
        Assert.Equal(7, repo.LoadDeathCount())
    }

    save_death_count_coerces_negative_to_zero()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        repo.SaveDeathCount(-3)
        Assert.Equal(0, repo.LoadDeathCount())
    }

    save_death_count_coerces_non_number_to_zero()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        repo.SaveDeathCount("not a number")
        Assert.Equal(0, repo.LoadDeathCount())
    }

    ; ============================================================
    ; LoadZoneTotals / SaveZoneTotals
    ; ============================================================

    load_zone_totals_returns_empty_when_file_missing()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        Assert.Equal(0, repo.LoadZoneTotals().Count)
    }

    load_zone_totals_parses_key_equals_value()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        zonesPath := tmpDir "\state_zones.txt"
        FileAppend("The Riverbank=125000`nClearfell=234000`n", zonesPath, "UTF-8")
        Fixtures.RegisterTempPath(zonesPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        loaded := repo.LoadZoneTotals()

        Assert.Equal(2, loaded.Count)
        Assert.Equal(125000, loaded["The Riverbank"])
        Assert.Equal(234000, loaded["Clearfell"])
    }

    load_zone_totals_skips_malformed_lines()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        zonesPath := tmpDir "\state_zones.txt"
        ; Lines: valid, no `=`, non-numeric value, empty, valid
        FileAppend("Zone1=100`nNoEquals`nZoneBad=notanumber`n`nZone2=200`n",
            zonesPath, "UTF-8")
        Fixtures.RegisterTempPath(zonesPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        loaded := repo.LoadZoneTotals()

        Assert.Equal(2, loaded.Count)
        Assert.Equal(100, loaded["Zone1"])
        Assert.Equal(200, loaded["Zone2"])
    }

    load_zone_totals_skips_zero_or_negative_ms()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        zonesPath := tmpDir "\state_zones.txt"
        FileAppend("ZoneA=0`nZoneB=-50`nZoneC=100`n", zonesPath, "UTF-8")
        Fixtures.RegisterTempPath(zonesPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        loaded := repo.LoadZoneTotals()

        Assert.Equal(1, loaded.Count)
        Assert.Equal(100, loaded["ZoneC"])
    }

    save_zone_totals_throws_when_not_map()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        Assert.Throws(TypeError, () => repo.SaveZoneTotals("not a map"))
        Assert.Throws(TypeError, () => repo.SaveZoneTotals([]))
    }

    save_zone_totals_creates_file()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        zonesPath := tmpDir "\state_zones.txt"
        Fixtures.RegisterTempPath(zonesPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        repo.SaveZoneTotals(Map("Mud Burrow", 1500))
        Assert.True(FileExist(zonesPath))
    }

    save_zone_totals_sanitizes_zone_name()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        zonesPath := tmpDir "\state_zones.txt"
        Fixtures.RegisterTempPath(zonesPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        ; Name with `=`, `\n`, `\r` — should be sanitized
        repo.SaveZoneTotals(Map("Bad=Name`nWith`rChars", 500))

        content := Fixtures.FileReadAll(zonesPath)
        Assert.Contains("BadNameWithChars=500", content)
    }

    save_zone_totals_ignores_zero_or_negative_ms()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        zonesPath := tmpDir "\state_zones.txt"
        Fixtures.RegisterTempPath(zonesPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        repo.SaveZoneTotals(Map(
            "ZoneA", 100,
            "ZoneB", 0,
            "ZoneC", -50
        ))
        loaded := repo.LoadZoneTotals()
        Assert.Equal(1, loaded.Count)
        Assert.Equal(100, loaded["ZoneA"])
    }

    clear_zone_totals_deletes_file()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        zonesPath := tmpDir "\state_zones.txt"
        Fixtures.RegisterTempPath(zonesPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        repo.SaveZoneTotals(Map("Mud Burrow", 1500))
        Assert.True(FileExist(zonesPath))

        repo.ClearZoneTotals()
        Assert.False(FileExist(zonesPath))
    }

    clear_zone_totals_no_op_when_missing()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        ; No file - must not throw
        repo.ClearZoneTotals()
        Assert.True(true)
    }

    roundtrip_save_load_zone_totals()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        zonesPath := tmpDir "\state_zones.txt"
        Fixtures.RegisterTempPath(zonesPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        original := Map(
            "Mud Burrow",      125000,
            "Clearfell",       234000,
            "The Grelwood",    456000
        )
        repo.SaveZoneTotals(original)
        loaded := repo.LoadZoneTotals()

        Assert.Equal(3, loaded.Count)
        Assert.Equal(125000, loaded["Mud Burrow"])
        Assert.Equal(234000, loaded["Clearfell"])
        Assert.Equal(456000, loaded["The Grelwood"])
    }

    ; ============================================================
    ; LoadLoadingEvents / SaveLoadingEvents / Clear
    ; ============================================================

    constructor_derives_loading_events_path_with_suffix()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        ; Save something to force creation of the _loading_events.txt
        repo.SaveLoadingEvents([Map("durationMs", 1000, "ts", "",
            "source", "", "fromZone", "", "toZone", "")])
        Assert.True(FileExist(tmpDir "\state_loading_events.txt"))
    }

    load_loading_events_returns_empty_when_file_missing()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        Assert.Equal(0, repo.LoadLoadingEvents().Length)
    }

    load_loading_events_parses_tsv_rows()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        evtsPath := tmpDir "\state_loading_events.txt"
        ; 5 cols: durationMs, ts, source, fromZone, toZone
        FileAppend("1500`t2026-05-27 12:00:00`tpixel`tThe Riverbank`tClearfell`n"
                .  "2200`t2026-05-27 12:05:00`tpixel`tClearfell`tThe Grelwood`n",
            evtsPath, "UTF-8")
        Fixtures.RegisterTempPath(evtsPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        loaded := repo.LoadLoadingEvents()

        Assert.Equal(2, loaded.Length)
        Assert.Equal(1500,                  loaded[1]["durationMs"])
        Assert.Equal("2026-05-27 12:00:00",  loaded[1]["ts"])
        Assert.Equal("pixel",               loaded[1]["source"])
        Assert.Equal("The Riverbank",       loaded[1]["fromZone"])
        Assert.Equal("Clearfell",           loaded[1]["toZone"])
        Assert.Equal(2200,                  loaded[2]["durationMs"])
        Assert.Equal("The Grelwood",        loaded[2]["toZone"])
    }

    load_loading_events_skips_lines_with_wrong_column_count()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        evtsPath := tmpDir "\state_loading_events.txt"
        ; Mix: 4 cols (skip), 3 cols (skip), valid, empty, 5 cols valid
        FileAppend("1500`tts`tsource`tfrom`n"
                .  "oops`n"
                .  "1000`tt1`tpixel`tA`tB`n"
                .  "`n"
                .  "2000`tt2`tpixel`tC`tD`n",
            evtsPath, "UTF-8")
        Fixtures.RegisterTempPath(evtsPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        loaded := repo.LoadLoadingEvents()

        Assert.Equal(2, loaded.Length)
        Assert.Equal(1000, loaded[1]["durationMs"])
        Assert.Equal(2000, loaded[2]["durationMs"])
    }

    load_loading_events_skips_non_number_duration()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        evtsPath := tmpDir "\state_loading_events.txt"
        FileAppend("notanumber`tt`ts`tf`tT`n"
                .  "1500`tt1`tpixel`tA`tB`n",
            evtsPath, "UTF-8")
        Fixtures.RegisterTempPath(evtsPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        loaded := repo.LoadLoadingEvents()

        Assert.Equal(1, loaded.Length)
        Assert.Equal(1500, loaded[1]["durationMs"])
    }

    load_loading_events_skips_zero_or_negative_duration()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        evtsPath := tmpDir "\state_loading_events.txt"
        FileAppend("0`tt0`ts`tA`tB`n"
                .  "-50`tt0`ts`tA`tB`n"
                .  "100`tt0`ts`tA`tB`n",
            evtsPath, "UTF-8")
        Fixtures.RegisterTempPath(evtsPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        loaded := repo.LoadLoadingEvents()

        Assert.Equal(1, loaded.Length)
        Assert.Equal(100, loaded[1]["durationMs"])
    }

    save_loading_events_throws_when_not_array()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        Assert.Throws(TypeError, () => repo.SaveLoadingEvents("not an array"))
        Assert.Throws(TypeError, () => repo.SaveLoadingEvents(Map()))
    }

    save_loading_events_creates_file()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        evtsPath := tmpDir "\state_loading_events.txt"
        Fixtures.RegisterTempPath(evtsPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        repo.SaveLoadingEvents([Map("durationMs", 1500, "ts", "t1",
            "source", "pixel", "fromZone", "A", "toZone", "B")])
        Assert.True(FileExist(evtsPath))
    }

    save_loading_events_skips_non_map_entries()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        evtsPath := tmpDir "\state_loading_events.txt"
        Fixtures.RegisterTempPath(evtsPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        repo.SaveLoadingEvents([
            "not a map",
            42,
            Map("durationMs", 1500, "ts", "t1", "source", "",
                "fromZone", "", "toZone", "")
        ])
        loaded := repo.LoadLoadingEvents()
        Assert.Equal(1, loaded.Length)
        Assert.Equal(1500, loaded[1]["durationMs"])
    }

    save_loading_events_skips_invalid_duration_entries()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        evtsPath := tmpDir "\state_loading_events.txt"
        Fixtures.RegisterTempPath(evtsPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        repo.SaveLoadingEvents([
            Map("durationMs", 0,    "ts", "", "source", "", "fromZone", "", "toZone", ""),
            Map("durationMs", -10,  "ts", "", "source", "", "fromZone", "", "toZone", ""),
            Map("durationMs", "x",  "ts", "", "source", "", "fromZone", "", "toZone", ""),
            Map("durationMs", 1500, "ts", "", "source", "", "fromZone", "", "toZone", "")
        ])
        loaded := repo.LoadLoadingEvents()
        Assert.Equal(1, loaded.Length)
        Assert.Equal(1500, loaded[1]["durationMs"])
    }

    save_loading_events_sanitizes_tab_newline_chars()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        evtsPath := tmpDir "\state_loading_events.txt"
        Fixtures.RegisterTempPath(evtsPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        ; Field values with tab / `n / `r — stripped on write so the
        ; row structure (5 tab-separated columns + newline) is preserved.
        repo.SaveLoadingEvents([Map(
            "durationMs", 1500,
            "ts",         "2026-05-27 12:00:00",
            "source",     "pix`tel",
            "fromZone",   "Bad`nName",
            "toZone",     "Other`rZone"
        )])
        loaded := repo.LoadLoadingEvents()
        Assert.Equal(1, loaded.Length)
        Assert.Equal("pixel",     loaded[1]["source"])
        Assert.Equal("BadName",   loaded[1]["fromZone"])
        Assert.Equal("OtherZone", loaded[1]["toZone"])
    }

    save_loading_events_writes_empty_file_for_empty_array()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        evtsPath := tmpDir "\state_loading_events.txt"
        Fixtures.RegisterTempPath(evtsPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        repo.SaveLoadingEvents([])
        Assert.True(FileExist(evtsPath))
        Assert.Equal(0, repo.LoadLoadingEvents().Length)
    }

    save_loading_events_returns_true_on_success()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        evtsPath := tmpDir "\state_loading_events.txt"
        Fixtures.RegisterTempPath(evtsPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        Assert.True(repo.SaveLoadingEvents([Map("durationMs", 1000, "ts", "",
            "source", "", "fromZone", "", "toZone", "")]))
    }

    clear_loading_events_deletes_file()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        evtsPath := tmpDir "\state_loading_events.txt"
        Fixtures.RegisterTempPath(evtsPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        repo.SaveLoadingEvents([Map("durationMs", 1500, "ts", "",
            "source", "", "fromZone", "", "toZone", "")])
        Assert.True(FileExist(evtsPath))

        repo.ClearLoadingEvents()
        Assert.False(FileExist(evtsPath))
    }

    clear_loading_events_no_op_when_missing()
    {
        mainIni := IniFile(Fixtures.TempPath("ini"))
        repo := RunStateRepository(mainIni)
        repo.ClearLoadingEvents()   ; no file — must not throw
        Assert.True(true)
    }

    roundtrip_save_load_loading_events()
    {
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        evtsPath := tmpDir "\state_loading_events.txt"
        Fixtures.RegisterTempPath(evtsPath)

        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        original := [
            Map("durationMs", 1500, "ts", "2026-05-27 12:00:00",
                "source", "pixel", "fromZone", "The Riverbank",
                "toZone", "Clearfell"),
            Map("durationMs", 2200, "ts", "2026-05-27 12:05:00",
                "source", "pixel", "fromZone", "Clearfell",
                "toZone", "The Grelwood"),
            Map("durationMs", 3100, "ts", "2026-05-27 12:10:00",
                "source", "", "fromZone", "", "toZone", "")
        ]
        repo.SaveLoadingEvents(original)
        loaded := repo.LoadLoadingEvents()

        Assert.Equal(3, loaded.Length)
        Assert.Equal(1500,                  loaded[1]["durationMs"])
        Assert.Equal("The Riverbank",       loaded[1]["fromZone"])
        Assert.Equal("Clearfell",           loaded[1]["toZone"])
        Assert.Equal("2026-05-27 12:05:00",  loaded[2]["ts"])
        Assert.Equal("pixel",               loaded[2]["source"])
        Assert.Equal(3100,                  loaded[3]["durationMs"])
        Assert.Equal("",                    loaded[3]["fromZone"])
        Assert.Equal("",                    loaded[3]["toZone"])
    }
}

TestRegistry.Register(RunStateRepositoryTests)
