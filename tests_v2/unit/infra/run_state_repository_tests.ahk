; ============================================================
; RunStateRepository tests
; ============================================================
;
; RunState <-> INI + arquivo TXT separado pra zone totals (perf).
;
; SECTION INI: [RunState] com RunId, StartedAt, Status, RunBaseMs,
;              LoadingTotalMs.
; TXT separado: `<iniBaseName>_zones.txt` no mesmo dir, formato
;               key=value por linha, escrito atomicamente.

class RunStateRepositoryTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Construtor ---
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
    ]

    ; ============================================================
    ; Construtor
    ; ============================================================

    constructor_throws_when_ini_not_inifile()
    {
        Assert.Throws(TypeError, () => RunStateRepository("not an ini"))
        Assert.Throws(TypeError, () => RunStateRepository(Map()))
    }

    constructor_derives_zone_totals_path_with_suffix()
    {
        ; Dado um IniFile em "<dir>\name.ini", o zone totals fica em
        ; "<dir>\name_zones.txt"
        tmpDir := Fixtures.TempDir()
        iniPath := tmpDir "\state.ini"
        mainIni := IniFile(iniPath)
        repo := RunStateRepository(mainIni)
        ; Salva algo pra forcar criacao do _zones.txt
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
        ; RunState.Empty() = runId vazio
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
        ; Sem Status escrito, mas com runId pra nao cair em Empty()
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
        ; Linhas: valida, sem `=`, valor nao-numerico, vazia, valida
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
        ; Nome com `=`, `\n`, `\r` — deve ser sanitizado
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
        ; Sem arquivo - nao deve estourar
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
}

TestRegistry.Register(RunStateRepositoryTests)
