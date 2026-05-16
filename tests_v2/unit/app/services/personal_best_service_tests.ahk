; ============================================================
; PersonalBestServiceTests
; ============================================================
;
; PersonalBestService eh o service mais complexo da Wave 5a.
; Mantem em memoria 4 PBs (run global, run-por-ato, zone PBs),
; carrega do disco no construtor e persiste sempre que muda.
;
; Como o construtor faz `if !(repo is PersonalBestRepository)`, usamos
; repos reais com tempfile (UTF-16 BOM por causa do issue documentado
; em Wave 4: IniRead key-lookup nao funciona em UTF-8 BOM).
;
; Cobertura:
;   - Construtor + _LoadFromRepo automatico
;   - Queries (legacy + por ato + zone PBs)
;   - UpdateFromRun (pull-based, persiste se mudou)
;   - Reset (apaga tudo + persiste)
;   - LoadFromExternal (substituicao total p/ import)
;   - SetAsRunPb (pina uma run, NAO toca zonePbs)
;   - RebuildFromHistory (reconstroi apos delete de run)


class PersonalBestServiceTests extends TestCase
{
    path := ""
    repo := ""
    svc  := ""

    Setup()
    {
        this.path := Fixtures.TempPath("ini")
        this.repo := PersonalBestRepository(this.path)
        this.svc  := PersonalBestService(this.repo)
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Construtor + _LoadFromRepo ---
        "constructor_throws_when_repo_not_personal_best_repository",
        "constructor_with_empty_repo_initializes_to_zeros",
        "constructor_loads_run_pb_from_repo",
        "constructor_loads_run_pb_run_id_from_repo",
        "constructor_loads_run_pbs_by_act_from_repo",
        "constructor_loads_zone_pbs_from_repo",

        ; --- Queries legacy ---
        "get_run_pb_ms_zero_initially",
        "get_run_pb_run_id_empty_initially",
        "has_run_pb_false_initially",
        "has_run_pb_true_when_ms_positive",
        "get_zone_pb_ms_zero_for_unknown_zone",
        "get_zone_pb_ms_zero_for_empty_name",
        "has_zone_pb_false_for_unknown",
        "has_zone_pb_true_when_exists",
        "get_all_zone_pbs_returns_defensive_copy",

        ; --- Queries PB por ato ---
        "get_run_pb_for_act_zero_for_unknown",
        "get_run_pb_for_act_zero_for_negative",
        "get_run_pb_for_act_zero_for_non_number",
        "has_run_pb_for_act_true_when_exists",
        "has_run_pb_for_act_false_when_zero",
        "get_all_run_pbs_by_act_returns_defensive_copy",
        "count_act_pbs_zero_initially",
        "count_act_pbs_returns_correct_count",

        ; --- UpdateFromRun: run global ---
        "update_records_first_run_pb",
        "update_improves_run_pb_when_faster",
        "update_does_not_overwrite_run_pb_when_slower",
        "update_returns_true_when_pb_improved",
        "update_returns_false_when_nothing_improved",
        "update_with_zero_run_ms_skipped",
        "update_with_negative_run_ms_skipped",
        "update_with_non_number_run_ms_skipped",
        "update_persists_change_to_repo",

        ; --- UpdateFromRun: PB por ato ---
        "update_records_act_checkpoints",
        "update_improves_act_pb_when_faster",
        "update_does_not_overwrite_act_pb_when_slower",
        "update_ignores_invalid_act_keys",
        "update_ignores_invalid_act_ms_values",

        ; --- UpdateFromRun: zone PBs ---
        "update_records_zone_pbs",
        "update_improves_zone_pb_when_faster",
        "update_does_not_overwrite_zone_pb_when_slower",
        "update_ignores_invalid_zone_names",
        "update_ignores_invalid_zone_ms_values",

        ; --- Reset ---
        "reset_clears_run_pb",
        "reset_clears_act_pbs",
        "reset_clears_zone_pbs",
        "reset_persists_zeroed_state_to_repo",

        ; --- LoadFromExternal ---
        "load_from_external_throws_on_non_object",
        "load_from_external_replaces_run_pb",
        "load_from_external_replaces_act_pbs",
        "load_from_external_replaces_zone_pbs",
        "load_from_external_missing_fields_default_to_empty",
        "load_from_external_persists_to_repo",
        "load_from_external_ignores_invalid_act_entries",

        ; --- SetAsRunPb ---
        "set_as_run_pb_sets_run_ms_and_run_id",
        "set_as_run_pb_returns_true_on_change",
        "set_as_run_pb_returns_false_when_nothing_changes",
        "set_as_run_pb_replaces_act_pbs_when_checkpoints_provided",
        "set_as_run_pb_keeps_act_pbs_when_no_checkpoints",
        "set_as_run_pb_does_not_touch_zone_pbs",
        "set_as_run_pb_rejects_zero_run_ms",
        "set_as_run_pb_rejects_negative_run_ms",
        "set_as_run_pb_persists_change",

        ; --- RebuildFromHistory ---
        "rebuild_from_empty_history_resets_state",
        "rebuild_from_history_picks_best_run_pb",
        "rebuild_from_history_picks_best_per_act",
        "rebuild_from_history_picks_best_zone_pbs_from_details",
        "rebuild_from_history_ignores_runs_without_total_ms",
        "rebuild_from_history_persists_to_repo"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    ; Cria um repo no path e retorna um service novo com state carregado.
    ; Util pra testar _LoadFromRepo sem depender do Setup geral.
    _MakeServiceWithPreSeededRepo(pbData)
    {
        path := Fixtures.TempPath("ini")
        seedRepo := PersonalBestRepository(path)
        seedRepo.Save(pbData)
        return PersonalBestService(seedRepo)
    }

    ; Le repo de disco e retorna data (pra checar persistencia)
    _ReadRepoFromDisk()
    {
        freshRepo := PersonalBestRepository(this.path)
        return freshRepo.Load()
    }

    ; ============================================================
    ; Construtor + _LoadFromRepo
    ; ============================================================

    constructor_throws_when_repo_not_personal_best_repository()
    {
        Assert.Throws(TypeError, () => PersonalBestService("not a repo"))
    }

    constructor_with_empty_repo_initializes_to_zeros()
    {
        ; Setup ja cria com repo apontando pra arquivo nao existente.
        ; Service deve estar zerado.
        Assert.Equal(0,  this.svc.GetRunPbMs())
        Assert.Equal("", this.svc.GetRunPbRunId())
        Assert.Equal(0,  this.svc.CountActPbs())
        Assert.Equal(0,  this.svc.GetAllZonePbs().Count)
    }

    constructor_loads_run_pb_from_repo()
    {
        svc := this._MakeServiceWithPreSeededRepo(Map(
            "runPbMs",    300000,
            "runPbRunId", "run_x",
            "runPbByAct", Map(),
            "zonePbs",    Map()
        ))
        Assert.Equal(300000, svc.GetRunPbMs())
    }

    constructor_loads_run_pb_run_id_from_repo()
    {
        svc := this._MakeServiceWithPreSeededRepo(Map(
            "runPbMs",    300000,
            "runPbRunId", "20260101_120000",
            "runPbByAct", Map(),
            "zonePbs",    Map()
        ))
        Assert.Equal("20260101_120000", svc.GetRunPbRunId())
    }

    constructor_loads_run_pbs_by_act_from_repo()
    {
        svc := this._MakeServiceWithPreSeededRepo(Map(
            "runPbMs",    0,
            "runPbRunId", "",
            "runPbByAct", Map(1, 100000, 2, 200000, 3, 300000),
            "zonePbs",    Map()
        ))
        Assert.Equal(100000, svc.GetRunPbForAct(1))
        Assert.Equal(200000, svc.GetRunPbForAct(2))
        Assert.Equal(300000, svc.GetRunPbForAct(3))
    }

    constructor_loads_zone_pbs_from_repo()
    {
        svc := this._MakeServiceWithPreSeededRepo(Map(
            "runPbMs",    0,
            "runPbRunId", "",
            "runPbByAct", Map(),
            "zonePbs",    Map("Clearfell", 50000, "Mud Burrow", 30000)
        ))
        Assert.Equal(50000, svc.GetZonePbMs("Clearfell"))
        Assert.Equal(30000, svc.GetZonePbMs("Mud Burrow"))
    }

    ; ============================================================
    ; Queries legacy
    ; ============================================================

    get_run_pb_ms_zero_initially()   => Assert.Equal(0, this.svc.GetRunPbMs())
    get_run_pb_run_id_empty_initially() => Assert.Equal("", this.svc.GetRunPbRunId())
    has_run_pb_false_initially()     => Assert.False(this.svc.HasRunPb())

    has_run_pb_true_when_ms_positive()
    {
        this.svc.UpdateFromRun(300000, "run_x")
        Assert.True(this.svc.HasRunPb())
    }

    get_zone_pb_ms_zero_for_unknown_zone()
    {
        Assert.Equal(0, this.svc.GetZonePbMs("Nonexistent Zone"))
    }

    get_zone_pb_ms_zero_for_empty_name()
    {
        Assert.Equal(0, this.svc.GetZonePbMs(""))
    }

    has_zone_pb_false_for_unknown()
    {
        Assert.False(this.svc.HasZonePb("Unknown"))
    }

    has_zone_pb_true_when_exists()
    {
        this.svc.UpdateFromRun(300000, "run_x", Map("Clearfell", 50000))
        Assert.True(this.svc.HasZonePb("Clearfell"))
    }

    get_all_zone_pbs_returns_defensive_copy()
    {
        this.svc.UpdateFromRun(0, "", Map("Clearfell", 50000))
        copy := this.svc.GetAllZonePbs()
        copy["NewZone"] := 999
        Assert.False(this.svc.GetAllZonePbs().Has("NewZone"))
    }

    ; ============================================================
    ; Queries PB por ato
    ; ============================================================

    get_run_pb_for_act_zero_for_unknown()
    {
        Assert.Equal(0, this.svc.GetRunPbForAct(5))
    }

    get_run_pb_for_act_zero_for_negative()
    {
        Assert.Equal(0, this.svc.GetRunPbForAct(-1))
    }

    get_run_pb_for_act_zero_for_non_number()
    {
        Assert.Equal(0, this.svc.GetRunPbForAct("abc"))
    }

    has_run_pb_for_act_true_when_exists()
    {
        this.svc.UpdateFromRun(0, "", "", Map(1, 100000))
        Assert.True(this.svc.HasRunPbForAct(1))
    }

    has_run_pb_for_act_false_when_zero()
    {
        Assert.False(this.svc.HasRunPbForAct(1))
    }

    get_all_run_pbs_by_act_returns_defensive_copy()
    {
        this.svc.UpdateFromRun(0, "", "", Map(1, 100000))
        copy := this.svc.GetAllRunPbsByAct()
        copy[99] := 999
        Assert.False(this.svc.GetAllRunPbsByAct().Has(99))
    }

    count_act_pbs_zero_initially()
    {
        Assert.Equal(0, this.svc.CountActPbs())
    }

    count_act_pbs_returns_correct_count()
    {
        this.svc.UpdateFromRun(0, "", "", Map(1, 100000, 2, 200000, 3, 300000))
        Assert.Equal(3, this.svc.CountActPbs())
    }

    ; ============================================================
    ; UpdateFromRun: run global
    ; ============================================================

    update_records_first_run_pb()
    {
        this.svc.UpdateFromRun(300000, "run_x")
        Assert.Equal(300000, this.svc.GetRunPbMs())
        Assert.Equal("run_x", this.svc.GetRunPbRunId())
    }

    update_improves_run_pb_when_faster()
    {
        this.svc.UpdateFromRun(300000, "slow")
        this.svc.UpdateFromRun(250000, "fast")
        Assert.Equal(250000, this.svc.GetRunPbMs())
        Assert.Equal("fast", this.svc.GetRunPbRunId())
    }

    update_does_not_overwrite_run_pb_when_slower()
    {
        this.svc.UpdateFromRun(250000, "fast")
        this.svc.UpdateFromRun(300000, "slow")
        Assert.Equal(250000, this.svc.GetRunPbMs())
        Assert.Equal("fast", this.svc.GetRunPbRunId())
    }

    update_returns_true_when_pb_improved()
    {
        Assert.True(this.svc.UpdateFromRun(300000, "first"))
    }

    update_returns_false_when_nothing_improved()
    {
        this.svc.UpdateFromRun(250000, "fast")
        Assert.False(this.svc.UpdateFromRun(300000, "slower"))
    }

    update_with_zero_run_ms_skipped()
    {
        this.svc.UpdateFromRun(0, "anything")
        Assert.False(this.svc.HasRunPb())
    }

    update_with_negative_run_ms_skipped()
    {
        this.svc.UpdateFromRun(-100, "anything")
        Assert.False(this.svc.HasRunPb())
    }

    update_with_non_number_run_ms_skipped()
    {
        this.svc.UpdateFromRun("abc", "anything")
        Assert.False(this.svc.HasRunPb())
    }

    update_persists_change_to_repo()
    {
        this.svc.UpdateFromRun(300000, "run_x")
        data := this._ReadRepoFromDisk()
        Assert.Equal(300000, data["runPbMs"])
        Assert.Equal("run_x", data["runPbRunId"])
    }

    ; ============================================================
    ; UpdateFromRun: PB por ato
    ; ============================================================

    update_records_act_checkpoints()
    {
        this.svc.UpdateFromRun(0, "", "", Map(1, 100000, 2, 200000))
        Assert.Equal(100000, this.svc.GetRunPbForAct(1))
        Assert.Equal(200000, this.svc.GetRunPbForAct(2))
    }

    update_improves_act_pb_when_faster()
    {
        this.svc.UpdateFromRun(0, "", "", Map(1, 100000))
        this.svc.UpdateFromRun(0, "", "", Map(1,  80000))
        Assert.Equal(80000, this.svc.GetRunPbForAct(1))
    }

    update_does_not_overwrite_act_pb_when_slower()
    {
        this.svc.UpdateFromRun(0, "", "", Map(1,  80000))
        this.svc.UpdateFromRun(0, "", "", Map(1, 100000))
        Assert.Equal(80000, this.svc.GetRunPbForAct(1))
    }

    update_ignores_invalid_act_keys()
    {
        this.svc.UpdateFromRun(0, "", "", Map(1, 100000, 0, 99, -1, 88, "abc", 77))
        Assert.Equal(1, this.svc.CountActPbs(), "Apenas act=1 deve ser aceito")
    }

    update_ignores_invalid_act_ms_values()
    {
        this.svc.UpdateFromRun(0, "", "", Map(1, 0, 2, -50, 3, "abc", 4, 100000))
        Assert.Equal(1, this.svc.CountActPbs(), "Apenas act=4 com ms valido")
        Assert.Equal(100000, this.svc.GetRunPbForAct(4))
    }

    ; ============================================================
    ; UpdateFromRun: zone PBs
    ; ============================================================

    update_records_zone_pbs()
    {
        this.svc.UpdateFromRun(0, "", Map("Clearfell", 50000, "Mud Burrow", 30000))
        Assert.Equal(50000, this.svc.GetZonePbMs("Clearfell"))
        Assert.Equal(30000, this.svc.GetZonePbMs("Mud Burrow"))
    }

    update_improves_zone_pb_when_faster()
    {
        this.svc.UpdateFromRun(0, "", Map("Clearfell", 50000))
        this.svc.UpdateFromRun(0, "", Map("Clearfell", 40000))
        Assert.Equal(40000, this.svc.GetZonePbMs("Clearfell"))
    }

    update_does_not_overwrite_zone_pb_when_slower()
    {
        this.svc.UpdateFromRun(0, "", Map("Clearfell", 40000))
        this.svc.UpdateFromRun(0, "", Map("Clearfell", 50000))
        Assert.Equal(40000, this.svc.GetZonePbMs("Clearfell"))
    }

    update_ignores_invalid_zone_names()
    {
        this.svc.UpdateFromRun(0, "", Map("", 100, "Valid", 200))
        Assert.Equal(1, this.svc.GetAllZonePbs().Count)
        Assert.Equal(200, this.svc.GetZonePbMs("Valid"))
    }

    update_ignores_invalid_zone_ms_values()
    {
        this.svc.UpdateFromRun(0, "", Map("Z1", 0, "Z2", -50, "Z3", "abc", "Z4", 100))
        Assert.Equal(1, this.svc.GetAllZonePbs().Count)
        Assert.Equal(100, this.svc.GetZonePbMs("Z4"))
    }

    ; ============================================================
    ; Reset
    ; ============================================================

    reset_clears_run_pb()
    {
        this.svc.UpdateFromRun(300000, "run_x")
        this.svc.Reset()
        Assert.False(this.svc.HasRunPb())
        Assert.Equal("", this.svc.GetRunPbRunId())
    }

    reset_clears_act_pbs()
    {
        this.svc.UpdateFromRun(0, "", "", Map(1, 100, 2, 200))
        this.svc.Reset()
        Assert.Equal(0, this.svc.CountActPbs())
    }

    reset_clears_zone_pbs()
    {
        this.svc.UpdateFromRun(0, "", Map("Z1", 100))
        this.svc.Reset()
        Assert.Equal(0, this.svc.GetAllZonePbs().Count)
    }

    reset_persists_zeroed_state_to_repo()
    {
        this.svc.UpdateFromRun(300000, "run_x", Map("Z", 100), Map(1, 1000))
        this.svc.Reset()
        data := this._ReadRepoFromDisk()
        Assert.Equal(0, data["runPbMs"])
        Assert.Equal(0, data["runPbByAct"].Count)
        Assert.Equal(0, data["zonePbs"].Count)
    }

    ; ============================================================
    ; LoadFromExternal
    ; ============================================================

    load_from_external_throws_on_non_object()
    {
        s := this.svc
        Assert.Throws(TypeError, () => s.LoadFromExternal("not a map"))
    }

    load_from_external_replaces_run_pb()
    {
        this.svc.UpdateFromRun(500000, "old")
        this.svc.LoadFromExternal(Map(
            "runPbMs",    300000,
            "runPbRunId", "imported",
            "runPbByAct", Map(),
            "zonePbs",    Map()
        ))
        Assert.Equal(300000,    this.svc.GetRunPbMs())
        Assert.Equal("imported", this.svc.GetRunPbRunId())
    }

    load_from_external_replaces_act_pbs()
    {
        this.svc.UpdateFromRun(0, "", "", Map(1, 999999))
        this.svc.LoadFromExternal(Map(
            "runPbMs",    0,
            "runPbRunId", "",
            "runPbByAct", Map(1, 100000, 2, 200000),
            "zonePbs",    Map()
        ))
        Assert.Equal(100000, this.svc.GetRunPbForAct(1))
        Assert.Equal(200000, this.svc.GetRunPbForAct(2))
    }

    load_from_external_replaces_zone_pbs()
    {
        this.svc.UpdateFromRun(0, "", Map("OldZone", 999))
        this.svc.LoadFromExternal(Map(
            "runPbMs",    0,
            "runPbRunId", "",
            "runPbByAct", Map(),
            "zonePbs",    Map("NewZone", 50000)
        ))
        Assert.Equal(0,     this.svc.GetZonePbMs("OldZone"), "Old apagado")
        Assert.Equal(50000, this.svc.GetZonePbMs("NewZone"))
    }

    load_from_external_missing_fields_default_to_empty()
    {
        this.svc.UpdateFromRun(500000, "old", Map("Z", 100), Map(1, 1000))
        this.svc.LoadFromExternal(Map())   ; tudo faltando
        Assert.Equal(0, this.svc.GetRunPbMs())
        Assert.Equal("", this.svc.GetRunPbRunId())
        Assert.Equal(0, this.svc.CountActPbs())
        Assert.Equal(0, this.svc.GetAllZonePbs().Count)
    }

    load_from_external_persists_to_repo()
    {
        this.svc.LoadFromExternal(Map(
            "runPbMs",    300000,
            "runPbRunId", "imported",
            "runPbByAct", Map(),
            "zonePbs",    Map()
        ))
        data := this._ReadRepoFromDisk()
        Assert.Equal(300000,     data["runPbMs"])
        Assert.Equal("imported", data["runPbRunId"])
    }

    load_from_external_ignores_invalid_act_entries()
    {
        this.svc.LoadFromExternal(Map(
            "runPbMs",    0,
            "runPbRunId", "",
            "runPbByAct", Map(1, 100, 0, 999, -1, 888, 2, 0, 3, -50, 4, "abc"),
            "zonePbs",    Map()
        ))
        Assert.Equal(1, this.svc.CountActPbs(), "Apenas act=1 valido")
        Assert.Equal(100, this.svc.GetRunPbForAct(1))
    }

    ; ============================================================
    ; SetAsRunPb (pina uma run)
    ; ============================================================

    set_as_run_pb_sets_run_ms_and_run_id()
    {
        this.svc.SetAsRunPb(500000, "pinned_run")
        Assert.Equal(500000,      this.svc.GetRunPbMs())
        Assert.Equal("pinned_run", this.svc.GetRunPbRunId())
    }

    set_as_run_pb_returns_true_on_change()
    {
        Assert.True(this.svc.SetAsRunPb(500000, "run_x"))
    }

    set_as_run_pb_returns_false_when_nothing_changes()
    {
        this.svc.SetAsRunPb(500000, "run_x")
        Assert.False(this.svc.SetAsRunPb(500000, "run_x"),
            "Mesma run + mesmos params: nada muda")
    }

    set_as_run_pb_replaces_act_pbs_when_checkpoints_provided()
    {
        this.svc.UpdateFromRun(0, "", "", Map(1, 999999, 2, 888888))   ; PBs antigos
        this.svc.SetAsRunPb(500000, "pinned", Map(1, 100000, 2, 200000))
        Assert.Equal(100000, this.svc.GetRunPbForAct(1), "Substituido pelo checkpoint da pinned")
        Assert.Equal(200000, this.svc.GetRunPbForAct(2))
    }

    set_as_run_pb_keeps_act_pbs_when_no_checkpoints()
    {
        this.svc.UpdateFromRun(0, "", "", Map(1, 100000))   ; PB antigo intacto
        this.svc.SetAsRunPb(500000, "pinned")                ; sem checkpoints
        Assert.Equal(100000, this.svc.GetRunPbForAct(1),
            "Act PB antigo preservado (checkpoints nao fornecidos)")
    }

    set_as_run_pb_does_not_touch_zone_pbs()
    {
        this.svc.UpdateFromRun(0, "", Map("Clearfell", 50000))
        this.svc.SetAsRunPb(500000, "pinned", Map(1, 100000))
        Assert.Equal(50000, this.svc.GetZonePbMs("Clearfell"),
            "zonePbs NUNCA tocado por SetAsRunPb")
    }

    set_as_run_pb_rejects_zero_run_ms()
    {
        Assert.False(this.svc.SetAsRunPb(0, "run_x"))
    }

    set_as_run_pb_rejects_negative_run_ms()
    {
        Assert.False(this.svc.SetAsRunPb(-100, "run_x"))
    }

    set_as_run_pb_persists_change()
    {
        this.svc.SetAsRunPb(500000, "pinned")
        data := this._ReadRepoFromDisk()
        Assert.Equal(500000,  data["runPbMs"])
        Assert.Equal("pinned", data["runPbRunId"])
    }

    ; ============================================================
    ; RebuildFromHistory
    ; ============================================================

    rebuild_from_empty_history_resets_state()
    {
        this.svc.UpdateFromRun(300000, "old", Map("Z", 100), Map(1, 1000))
        this.svc.RebuildFromHistory([])
        Assert.Equal(0, this.svc.GetRunPbMs())
        Assert.Equal(0, this.svc.CountActPbs())
        Assert.Equal(0, this.svc.GetAllZonePbs().Count)
    }

    rebuild_from_history_picks_best_run_pb()
    {
        runs := [
            Map("runId", "slow", "totalMs", 500000, "actCheckpoints", Map(), "details", []),
            Map("runId", "fast", "totalMs", 250000, "actCheckpoints", Map(), "details", []),
            Map("runId", "mid",  "totalMs", 350000, "actCheckpoints", Map(), "details", [])
        ]
        this.svc.RebuildFromHistory(runs)
        Assert.Equal(250000, this.svc.GetRunPbMs())
        Assert.Equal("fast", this.svc.GetRunPbRunId())
    }

    rebuild_from_history_picks_best_per_act()
    {
        runs := [
            Map("runId", "a", "totalMs", 1000, "actCheckpoints", Map(1, 200, 2, 500),
                "details", []),
            Map("runId", "b", "totalMs", 2000, "actCheckpoints", Map(1, 100, 2, 600),
                "details", [])
        ]
        this.svc.RebuildFromHistory(runs)
        Assert.Equal(100, this.svc.GetRunPbForAct(1), "best act 1 = 100 (run b)")
        Assert.Equal(500, this.svc.GetRunPbForAct(2), "best act 2 = 500 (run a)")
    }

    rebuild_from_history_picks_best_zone_pbs_from_details()
    {
        ; Details com category=mapa|cidade entram em zonePbs
        runs := [
            Map("runId", "a", "totalMs", 1000, "actCheckpoints", Map(), "details", [
                Map("category", "mapa",   "label", "Clearfell",  "ms", 50000),
                Map("category", "cidade", "label", "The Hub",    "ms", 5000),
                Map("category", "loading", "label", "X -> Y",    "ms", 9999),
                Map("category", "morte",  "label", "1 death",    "ms", 8888)
            ]),
            Map("runId", "b", "totalMs", 2000, "actCheckpoints", Map(), "details", [
                Map("category", "mapa", "label", "Clearfell", "ms", 40000)
            ])
        ]
        this.svc.RebuildFromHistory(runs)
        Assert.Equal(40000, this.svc.GetZonePbMs("Clearfell"), "best entre as 2 runs")
        Assert.Equal(5000,  this.svc.GetZonePbMs("The Hub"))
        Assert.Equal(0,     this.svc.GetZonePbMs("X -> Y"), "loading nao entra em zonePbs")
        Assert.Equal(0,     this.svc.GetZonePbMs("1 death"), "morte nao entra em zonePbs")
    }

    rebuild_from_history_ignores_runs_without_total_ms()
    {
        runs := [
            Map("runId", "ok",    "totalMs", 1000, "actCheckpoints", Map(), "details", []),
            Map("runId", "bad",   "totalMs", 0,    "actCheckpoints", Map(), "details", []),
            Map("runId", "worse", "totalMs", -100, "actCheckpoints", Map(), "details", [])
        ]
        this.svc.RebuildFromHistory(runs)
        Assert.Equal(1000, this.svc.GetRunPbMs(), "So a run 'ok' contou")
    }

    rebuild_from_history_persists_to_repo()
    {
        runs := [
            Map("runId", "ok", "totalMs", 1000, "actCheckpoints", Map(1, 500),
                "details", [Map("category", "mapa", "label", "Z", "ms", 200)])
        ]
        this.svc.RebuildFromHistory(runs)
        data := this._ReadRepoFromDisk()
        Assert.Equal(1000, data["runPbMs"])
        Assert.Equal(500,  data["runPbByAct"][1])
        Assert.Equal(200,  data["zonePbs"]["Z"])
    }
}

TestRegistry.Register(PersonalBestServiceTests)
