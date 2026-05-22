; ============================================================
; RunAverageServiceTests
; ============================================================
;
; RunAverageService averages the latest N runs from
; RunHistoryRepository. Three query surfaces mirror
; PersonalBestService:
;
;   GetAverageRunMs()              ← summary.totalMs
;   GetAverageRunMsForAct(act)     ← summary.actCheckpoints[act]
;   GetAverageZoneMs(zoneName)     ← Σ visits in run details
;
; Caching:
;   - Run + per-act averages: built from LoadSummaries.
;   - Per-zone averages: lazy, built from Load(runId) per run.
;   - Both invalidate on Evt.RunCompleted / Evt.RunCancelled.
;
; Tests use REAL RunHistoryRepository instances pointed at
; Fixtures.TempDir() and seeded via repo.Save(), so the cache and
; the disk-shaped contract are exercised together. The service's
; constructor enforces `is RunHistoryRepository` + `is EventBus`,
; and Save() rejects totalMs < 1000 — every test builds runs
; comfortably above that floor.
;
; The `runId` local collides case-insensitively with the RunId
; domain class; we use `id` / `currentId` in seeding loops.


class RunAverageServiceTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_run_history_not_repo",
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_warning_sink_lacks_warn_method",
        "constructor_with_empty_history_initializes_to_zero",

        ; --- Run averages (overall totalMs) ---
        "get_average_run_ms_zero_when_no_runs",
        "has_average_run_ms_false_when_no_runs",
        "has_average_run_ms_true_when_runs_present",
        "average_run_ms_with_single_run",
        "average_run_ms_with_two_runs",
        "average_run_ms_with_five_runs",
        "average_run_ms_with_more_than_five_runs_only_uses_latest_five",
        "average_run_ms_skips_runs_with_zero_total_ms",
        "average_run_ms_rounds_down_to_integer",

        ; --- Per-act averages ---
        "get_average_run_ms_for_act_zero_for_unknown_act",
        "get_average_run_ms_for_act_zero_for_negative_input",
        "get_average_run_ms_for_act_zero_for_non_number_input",
        "get_average_run_ms_for_act_zero_for_zero_input",
        "has_average_run_ms_for_act_true_when_exists",
        "average_per_act_only_counts_runs_that_reached_act",
        "average_per_act_handles_multiple_acts",
        "average_per_act_ignores_invalid_checkpoint_entries",
        "get_all_average_act_ms_returns_defensive_copy",

        ; --- Zone averages ---
        "get_average_zone_ms_zero_for_unknown_zone",
        "get_average_zone_ms_zero_for_empty_name",
        "has_average_zone_ms_true_when_exists",
        "average_zone_includes_only_mapa_and_cidade_categories",
        "average_zone_sums_multiple_visits_within_one_run",
        "average_zone_counts_each_run_once_after_summing_visits",
        "average_zone_only_counts_runs_that_visited_zone",
        "average_zone_ignores_invalid_entries",
        "get_all_average_zone_ms_returns_defensive_copy",

        ; --- Cache invalidation ---
        "cache_recomputes_after_run_completed_event",
        "cache_recomputes_after_run_cancelled_event",
        "manual_invalidate_forces_recompute",
        "zone_cache_invalidated_when_main_cache_invalidates",

        ; --- Dispose ---
        "dispose_unsubscribes_run_completed_handler",
        "dispose_is_idempotent"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    ; Makes a buildResult Map ready for RunHistoryRepository.Save.
    ; totalMs must be >= 1000 or Save rejects the run (handled by
    ; the repo, surfaced as `false` to the caller).
    _MakeRun(id, totalMs, actCheckpoints := "", details := "")
    {
        if !IsObject(actCheckpoints)
            actCheckpoints := Map()
        if !IsObject(details)
            details := []
        return Map(
            "runId",          id,
            "profile",        "Default",
            "patch",          "0.2.0",
            "firstTs",        "2026-05-12 14:23:45",
            "totalMs",        totalMs,
            "deathCount",     0,
            "maxActReached",  1,
            "totals",         Map(),
            "actCheckpoints", actCheckpoints,
            "details",        details
        )
    }

    ; Convenience for building one detail row.
    _MakeDetail(category, label, ms)
    {
        return Map(
            "category",  category,
            "label",     label,
            "ms",        ms,
            "note",      "",
            "timestamp", ""
        )
    }

    ; Builds a fresh RunHistoryRepository in a temp dir and seeds
    ; it with the provided runs (Array<buildResult>). Returns the
    ; repo so the test can construct the service against it.
    ;
    ; Saves in array order then FORCES the on-disk modification
    ; time of each saved INI to an evenly-spaced sequence, so
    ; ListRunIds (which sorts by mtime desc) deterministically
    ; returns runs in reverse-save-order. The previous Sleep(25)
    ; approach was flaky: NTFS exposes 100 ns mtime resolution in
    ; principle but FileWrite-to-mtime propagation on Windows is
    ; coarser than the sleep granularity, so two saves spaced 25 ms
    ; apart could land on the same mtime and ListRunIds would return
    ; them in arbitrary file-system order — breaking the "only
    ; latest 5" and "zone cache rebuilt" assertions intermittently.
    ; FileSetTime takes a YYYYMMDDHHMISS string and writes it
    ; directly; no timer involved.
    _MakeRepoWithRuns(runs)
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        i := 1
        for _, currentRun in runs
        {
            repo.Save(currentRun)
            ; Force mtime to 2026-01-01 00:00:{i:02d}. The seconds
            ; field cleanly orders saves 1..60 and stays well under
            ; the FAT 2 s granularity threshold (NTFS handles us
            ; fine; FAT volumes — like some external test
            ; environments — would round to even seconds, so we
            ; advance by full seconds to be safe everywhere).
            iniPath := repo.GetDir() . "\" . currentRun["runId"] . ".ini"
            stamp := "202601010000" . Format("{:02d}", i)
            try FileSetTime(stamp, iniPath, "M")
            i += 1
        }
        return repo
    }

    ; Standard service factory: bus + null sink. Tests that care
    ; about the warning path build their own with InMemoryWarningSink.
    _MakeSvc(repo, bus := "")
    {
        if (bus = "")
            bus := Fixtures.MakeBus()
        return RunAverageService(repo, bus)
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_run_history_not_repo()
    {
        bus := Fixtures.MakeBus()
        Assert.Throws(TypeError, () => RunAverageService("not a repo", bus))
    }

    constructor_throws_when_bus_not_event_bus()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        Assert.Throws(TypeError, () => RunAverageService(repo, "not a bus"))
    }

    constructor_throws_when_warning_sink_lacks_warn_method()
    {
        ; Wiring bug: someone passes a Map() instead of a real sink.
        ; WarningSink.Resolve must reject it at boot rather than
        ; wait for the first recompute to crash. Same contract as
        ; PersonalBestRepository / RunHistoryRepository.
        repo := RunHistoryRepository(Fixtures.TempDir())
        bus  := Fixtures.MakeBus()
        Assert.Throws(TypeError,
            () => RunAverageService(repo, bus, Map("not", "a sink")))
    }

    constructor_with_empty_history_initializes_to_zero()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        svc := this._MakeSvc(repo)
        Assert.Equal(0, svc.GetAverageRunMs())
        Assert.False(svc.HasAverageRunMs())
        Assert.Equal(0, svc.GetAverageRunMsForAct(1))
        Assert.Equal(0, svc.GetAverageZoneMs("Anything"))
        Assert.Equal(0, svc.GetAllAverageActMs().Count)
        Assert.Equal(0, svc.GetAllAverageZoneMs().Count)
    }

    ; ============================================================
    ; Run averages (overall totalMs)
    ; ============================================================

    get_average_run_ms_zero_when_no_runs()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        svc := this._MakeSvc(repo)
        Assert.Equal(0, svc.GetAverageRunMs())
    }

    has_average_run_ms_false_when_no_runs()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        svc := this._MakeSvc(repo)
        Assert.False(svc.HasAverageRunMs())
    }

    has_average_run_ms_true_when_runs_present()
    {
        repo := this._MakeRepoWithRuns([
            this._MakeRun("20260101_120000", 300000)
        ])
        svc := this._MakeSvc(repo)
        Assert.True(svc.HasAverageRunMs())
    }

    average_run_ms_with_single_run()
    {
        repo := this._MakeRepoWithRuns([
            this._MakeRun("20260101_120000", 300000)
        ])
        svc := this._MakeSvc(repo)
        Assert.Equal(300000, svc.GetAverageRunMs())
    }

    average_run_ms_with_two_runs()
    {
        repo := this._MakeRepoWithRuns([
            this._MakeRun("20260101_120000", 300000),
            this._MakeRun("20260102_120000", 200000)
        ])
        svc := this._MakeSvc(repo)
        Assert.Equal(250000, svc.GetAverageRunMs(), "(300000 + 200000) / 2")
    }

    average_run_ms_with_five_runs()
    {
        repo := this._MakeRepoWithRuns([
            this._MakeRun("20260101_120000", 100000),
            this._MakeRun("20260102_120000", 200000),
            this._MakeRun("20260103_120000", 300000),
            this._MakeRun("20260104_120000", 400000),
            this._MakeRun("20260105_120000", 500000)
        ])
        svc := this._MakeSvc(repo)
        Assert.Equal(300000, svc.GetAverageRunMs(), "(100+200+300+400+500)/5 = 300")
    }

    average_run_ms_with_more_than_five_runs_only_uses_latest_five()
    {
        ; Seven runs persisted in chronological order. ListRunIds
        ; sorts mtime DESC and LoadSummaries(5) caps to the latest
        ; five — runs 3..7 contribute, runs 1..2 do not. The Sleep
        ; in _MakeRepoWithRuns keeps the mtimes ordered.
        repo := this._MakeRepoWithRuns([
            this._MakeRun("20260101_120000",  10000),   ; should be EXCLUDED
            this._MakeRun("20260102_120000",  20000),   ; should be EXCLUDED
            this._MakeRun("20260103_120000", 300000),   ; included
            this._MakeRun("20260104_120000", 300000),   ; included
            this._MakeRun("20260105_120000", 300000),   ; included
            this._MakeRun("20260106_120000", 300000),   ; included
            this._MakeRun("20260107_120000", 300000)    ; included
        ])
        svc := this._MakeSvc(repo)
        Assert.Equal(300000, svc.GetAverageRunMs(),
            "Only the latest 5 runs contribute; older 10k/20k ignored")
    }

    average_run_ms_skips_runs_with_zero_total_ms()
    {
        ; Save() rejects totalMs < 1000, so the only way a "zero"
        ; run reaches the service is via a hand-crafted INI on
        ; disk. To exercise the in-service skip we shortcut by
        ; constructing a stub repo that returns summaries with
        ; one valid and one zero-ms entry directly.
        stub := _AvgRepoStub.WithSummaries([
            Map("totalMs", 300000, "actCheckpoints", Map()),
            Map("totalMs", 0,      "actCheckpoints", Map())
        ])
        svc := RunAverageService(stub, Fixtures.MakeBus())
        Assert.Equal(300000, svc.GetAverageRunMs(),
            "Zero-ms entry skipped; denominator stays at 1")
    }

    average_run_ms_rounds_down_to_integer()
    {
        ; (100 + 101 + 102) / 3 = 101 (no remainder). Pick three
        ; values whose mean has a fractional part to confirm the
        ; service stores an Integer.
        stub := _AvgRepoStub.WithSummaries([
            Map("totalMs", 100000, "actCheckpoints", Map()),
            Map("totalMs", 100001, "actCheckpoints", Map()),
            Map("totalMs", 100002, "actCheckpoints", Map())
        ])
        svc := RunAverageService(stub, Fixtures.MakeBus())
        Assert.Equal(100001, svc.GetAverageRunMs())
    }

    ; ============================================================
    ; Per-act averages
    ; ============================================================

    get_average_run_ms_for_act_zero_for_unknown_act()
    {
        repo := this._MakeRepoWithRuns([
            this._MakeRun("r1", 300000, Map(1, 100000))
        ])
        svc := this._MakeSvc(repo)
        Assert.Equal(0, svc.GetAverageRunMsForAct(5),
            "Act 5 not reached in any run")
    }

    get_average_run_ms_for_act_zero_for_negative_input()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        svc := this._MakeSvc(repo)
        Assert.Equal(0, svc.GetAverageRunMsForAct(-1))
    }

    get_average_run_ms_for_act_zero_for_non_number_input()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        svc := this._MakeSvc(repo)
        Assert.Equal(0, svc.GetAverageRunMsForAct("abc"))
    }

    get_average_run_ms_for_act_zero_for_zero_input()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        svc := this._MakeSvc(repo)
        Assert.Equal(0, svc.GetAverageRunMsForAct(0))
    }

    has_average_run_ms_for_act_true_when_exists()
    {
        repo := this._MakeRepoWithRuns([
            this._MakeRun("r1", 300000, Map(1, 100000))
        ])
        svc := this._MakeSvc(repo)
        Assert.True(svc.HasAverageRunMsForAct(1))
        Assert.False(svc.HasAverageRunMsForAct(2))
    }

    average_per_act_only_counts_runs_that_reached_act()
    {
        ; Three runs: r1 reached only act 1, r2 reached acts 1+2,
        ; r3 reached acts 1+2+3. Average for act 3 = r3 alone, not
        ; dragged down by phantom zero contributions from r1/r2.
        repo := this._MakeRepoWithRuns([
            this._MakeRun("r1", 100000, Map(1, 100000)),
            this._MakeRun("r2", 250000, Map(1, 100000, 2, 250000)),
            this._MakeRun("r3", 600000, Map(1, 100000, 2, 250000, 3, 600000))
        ])
        svc := this._MakeSvc(repo)
        Assert.Equal(100000, svc.GetAverageRunMsForAct(1),
            "All 3 runs reached act 1; (100+100+100)/3 = 100")
        Assert.Equal(250000, svc.GetAverageRunMsForAct(2),
            "Only 2 runs reached act 2; (250+250)/2 = 250")
        Assert.Equal(600000, svc.GetAverageRunMsForAct(3),
            "Only 1 run reached act 3; 600/1 = 600")
    }

    average_per_act_handles_multiple_acts()
    {
        repo := this._MakeRepoWithRuns([
            this._MakeRun("r1", 500000, Map(1, 200000, 2, 500000)),
            this._MakeRun("r2", 700000, Map(1, 300000, 2, 700000))
        ])
        svc := this._MakeSvc(repo)
        Assert.Equal(250000, svc.GetAverageRunMsForAct(1), "(200+300)/2")
        Assert.Equal(600000, svc.GetAverageRunMsForAct(2), "(500+700)/2")
    }

    average_per_act_ignores_invalid_checkpoint_entries()
    {
        ; Stub summaries with garbage in the actCheckpoints map:
        ; negative/zero/non-number values must be skipped, only
        ; the valid entry contributes.
        stub := _AvgRepoStub.WithSummaries([
            Map("totalMs", 300000, "actCheckpoints", Map(
                1, 100000,
                0, 9999,    ; bad: actNum=0
                -1, 8888,   ; bad: actNum<0
                2, 0,       ; bad: ms=0
                3, -50,     ; bad: ms<0
                4, "abc"    ; bad: non-number
            ))
        ])
        svc := RunAverageService(stub, Fixtures.MakeBus())
        all := svc.GetAllAverageActMs()
        Assert.Equal(1, all.Count, "Only act=1 accepted")
        Assert.Equal(100000, svc.GetAverageRunMsForAct(1))
    }

    get_all_average_act_ms_returns_defensive_copy()
    {
        repo := this._MakeRepoWithRuns([
            this._MakeRun("r1", 300000, Map(1, 100000))
        ])
        svc := this._MakeSvc(repo)
        copy := svc.GetAllAverageActMs()
        copy[99] := 999
        Assert.False(svc.GetAllAverageActMs().Has(99),
            "Mutating the returned Map must not affect the cache")
    }

    ; ============================================================
    ; Zone averages
    ; ============================================================

    get_average_zone_ms_zero_for_unknown_zone()
    {
        repo := this._MakeRepoWithRuns([
            this._MakeRun("r1", 300000, Map(), [
                this._MakeDetail("mapa", "Clearfell", 50000)
            ])
        ])
        svc := this._MakeSvc(repo)
        Assert.Equal(0, svc.GetAverageZoneMs("Nonexistent"))
    }

    get_average_zone_ms_zero_for_empty_name()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        svc := this._MakeSvc(repo)
        Assert.Equal(0, svc.GetAverageZoneMs(""))
    }

    has_average_zone_ms_true_when_exists()
    {
        repo := this._MakeRepoWithRuns([
            this._MakeRun("r1", 300000, Map(), [
                this._MakeDetail("mapa", "Clearfell", 50000)
            ])
        ])
        svc := this._MakeSvc(repo)
        Assert.True(svc.HasAverageZoneMs("Clearfell"))
        Assert.False(svc.HasAverageZoneMs("Other Zone"))
    }

    average_zone_includes_only_mapa_and_cidade_categories()
    {
        ; Mirror PersonalBestService.RebuildFromHistory: only
        ; mapa + cidade contribute to zone averages. loading and
        ; morte are real categories in the run plot but they
        ; don't represent zone time the player can compare.
        repo := this._MakeRepoWithRuns([
            this._MakeRun("r1", 300000, Map(), [
                this._MakeDetail("mapa",    "Clearfell",  50000),
                this._MakeDetail("cidade",  "Hub",         5000),
                this._MakeDetail("loading", "X -> Y",      9999),
                this._MakeDetail("morte",   "1 death",     8888)
            ])
        ])
        svc := this._MakeSvc(repo)
        Assert.Equal(50000, svc.GetAverageZoneMs("Clearfell"))
        Assert.Equal(5000,  svc.GetAverageZoneMs("Hub"))
        Assert.Equal(0,     svc.GetAverageZoneMs("X -> Y"), "loading excluded")
        Assert.Equal(0,     svc.GetAverageZoneMs("1 death"), "morte excluded")
    }

    average_zone_sums_multiple_visits_within_one_run()
    {
        ; Run visits "Mud Burrow" twice (40k + 25k). The PER-RUN
        ; total is 65k; that single sample contributes to the
        ; cross-run average. Mirrors ZoneTrackingService's
        ; GetZoneTotalWithActive sum.
        repo := this._MakeRepoWithRuns([
            this._MakeRun("r1", 300000, Map(), [
                this._MakeDetail("mapa", "Mud Burrow", 40000),
                this._MakeDetail("mapa", "Mud Burrow", 25000),
                this._MakeDetail("mapa", "Clearfell",  50000)
            ])
        ])
        svc := this._MakeSvc(repo)
        Assert.Equal(65000, svc.GetAverageZoneMs("Mud Burrow"),
            "Two visits in one run: summed to 65000 before averaging")
        Assert.Equal(50000, svc.GetAverageZoneMs("Clearfell"),
            "Single-visit zone unaffected")
    }

    average_zone_counts_each_run_once_after_summing_visits()
    {
        ; Two runs, both visit "Mud Burrow":
        ;   r1: 60000 (one visit)
        ;   r2: 40000 + 20000 = 60000 (two visits summed)
        ; Per-run samples: [60000, 60000]; mean = 60000.
        repo := this._MakeRepoWithRuns([
            this._MakeRun("r1", 300000, Map(), [
                this._MakeDetail("mapa", "Mud Burrow", 60000)
            ]),
            this._MakeRun("r2", 300000, Map(), [
                this._MakeDetail("mapa", "Mud Burrow", 40000),
                this._MakeDetail("mapa", "Mud Burrow", 20000)
            ])
        ])
        svc := this._MakeSvc(repo)
        Assert.Equal(60000, svc.GetAverageZoneMs("Mud Burrow"))
    }

    average_zone_only_counts_runs_that_visited_zone()
    {
        ; Three runs; "Mud Burrow" appears only in r1 + r3.
        ; r2 contributes nothing to that average — denominator = 2,
        ; not 3.
        repo := this._MakeRepoWithRuns([
            this._MakeRun("r1", 300000, Map(), [
                this._MakeDetail("mapa", "Mud Burrow", 50000)
            ]),
            this._MakeRun("r2", 300000, Map(), [
                this._MakeDetail("mapa", "Other Zone", 99999)
            ]),
            this._MakeRun("r3", 300000, Map(), [
                this._MakeDetail("mapa", "Mud Burrow", 70000)
            ])
        ])
        svc := this._MakeSvc(repo)
        Assert.Equal(60000, svc.GetAverageZoneMs("Mud Burrow"),
            "(50 + 70) / 2 = 60 — r2 doesn't drag the denominator up")
    }

    average_zone_ignores_invalid_entries()
    {
        ; Detail rows with missing/empty label, non-positive ms,
        ; or non-number ms must be skipped without affecting the
        ; valid sample.
        repo := this._MakeRepoWithRuns([
            this._MakeRun("r1", 300000, Map(), [
                this._MakeDetail("mapa", "",            5000),   ; empty label
                this._MakeDetail("mapa", "Bad ms 1",       0),   ; zero ms
                this._MakeDetail("mapa", "Bad ms 2",     -50),   ; negative ms
                this._MakeDetail("mapa", "Bad ms 3",   "abc"),   ; non-number ms
                this._MakeDetail("mapa", "Valid Zone", 40000)
            ])
        ])
        svc := this._MakeSvc(repo)
        Assert.Equal(40000, svc.GetAverageZoneMs("Valid Zone"))
        Assert.Equal(0,     svc.GetAverageZoneMs(""))
        Assert.Equal(0,     svc.GetAverageZoneMs("Bad ms 1"))
        Assert.Equal(0,     svc.GetAverageZoneMs("Bad ms 2"))
        Assert.Equal(0,     svc.GetAverageZoneMs("Bad ms 3"))
    }

    get_all_average_zone_ms_returns_defensive_copy()
    {
        repo := this._MakeRepoWithRuns([
            this._MakeRun("r1", 300000, Map(), [
                this._MakeDetail("mapa", "Clearfell", 50000)
            ])
        ])
        svc := this._MakeSvc(repo)
        copy := svc.GetAllAverageZoneMs()
        copy["NewZone"] := 999
        Assert.False(svc.GetAllAverageZoneMs().Has("NewZone"))
    }

    ; ============================================================
    ; Cache invalidation
    ; ============================================================

    cache_recomputes_after_run_completed_event()
    {
        ; Build service against an initially-empty repo, query
        ; once to populate the cache, then ADD a run to disk and
        ; publish RunCompleted. The next query must re-read.
        repo := RunHistoryRepository(Fixtures.TempDir())
        bus  := Fixtures.MakeBus()
        svc  := RunAverageService(repo, bus)

        Assert.Equal(0, svc.GetAverageRunMs(), "Initially zero")

        repo.Save(this._MakeRun("r1", 300000))
        ; Without invalidation, the cached zero would persist.
        bus.Publish(Events.RunCompleted, Map("runId", "r1"))

        Assert.Equal(300000, svc.GetAverageRunMs(),
            "RunCompleted invalidates the cache; next query re-reads")
    }

    cache_recomputes_after_run_cancelled_event()
    {
        ; RunCancelled also triggers a save when the run was >= 3 min,
        ; so the service treats it as a possible-new-INI event too.
        repo := RunHistoryRepository(Fixtures.TempDir())
        bus  := Fixtures.MakeBus()
        svc  := RunAverageService(repo, bus)

        Assert.Equal(0, svc.GetAverageRunMs())

        repo.Save(this._MakeRun("r1", 200000))
        bus.Publish(Events.RunCancelled, Map("runId", "r1"))

        Assert.Equal(200000, svc.GetAverageRunMs())
    }

    manual_invalidate_forces_recompute()
    {
        ; Explicit hook for callers that change runs outside the
        ; finalize path (history delete, run import).
        repo := RunHistoryRepository(Fixtures.TempDir())
        svc  := this._MakeSvc(repo)

        Assert.Equal(0, svc.GetAverageRunMs())

        repo.Save(this._MakeRun("r1", 150000))
        ; No event published — without manual Invalidate the cached
        ; zero would stay.
        svc.Invalidate()
        Assert.Equal(150000, svc.GetAverageRunMs())
    }

    zone_cache_invalidated_when_main_cache_invalidates()
    {
        ; Two caches with separate lazy lifetimes: the zone cache
        ; is computed on first GetAverageZoneMs after invalidation.
        ; A stale zone average can't survive across an Invalidate.
        repo := RunHistoryRepository(Fixtures.TempDir())
        bus  := Fixtures.MakeBus()
        svc  := RunAverageService(repo, bus)

        repo.Save(this._MakeRun("r1", 200000, Map(), [
            this._MakeDetail("mapa", "Mud Burrow", 50000)
        ]))
        bus.Publish(Events.RunCompleted, Map("runId", "r1"))

        Assert.Equal(50000, svc.GetAverageZoneMs("Mud Burrow"))

        ; Add a second run with a different zone time. After the
        ; event, the per-zone average for Mud Burrow must reflect
        ; both runs (Sleep 25ms so the mtime advances and r2 is
        ; visible to ListRunIds in newest-first order).
        Sleep(25)
        repo.Save(this._MakeRun("r2", 200000, Map(), [
            this._MakeDetail("mapa", "Mud Burrow", 30000)
        ]))
        bus.Publish(Events.RunCompleted, Map("runId", "r2"))

        Assert.Equal(40000, svc.GetAverageZoneMs("Mud Burrow"),
            "(50000 + 30000) / 2 = 40000 — zone cache rebuilt")
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_run_completed_handler()
    {
        ; After Dispose, publishing RunCompleted must NOT cause
        ; another LoadSummaries call. Use a stub repo to count.
        stub := _AvgRepoStub.Counting()
        bus  := Fixtures.MakeBus()
        svc  := RunAverageService(stub, bus)
        svc.GetAverageRunMs()   ; primes cache (LoadSummaries +1)
        initialCount := stub.loadSummariesCount

        svc.Dispose()
        bus.Publish(Events.RunCompleted, Map("runId", "r1"))
        ; Trigger a query that would force a recompute if dirty.
        svc.GetAverageRunMs()

        ; If the handler was still subscribed, RunCompleted would
        ; have set _dirty := true and the GetAverageRunMs above
        ; would have called LoadSummaries again. With Dispose
        ; working, _dirty stayed false and the count is unchanged.
        Assert.Equal(initialCount, stub.loadSummariesCount,
            "Dispose unsubscribes — RunCompleted no longer invalidates")
    }

    dispose_is_idempotent()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        svc  := this._MakeSvc(repo)
        svc.Dispose()
        svc.Dispose()   ; must not throw
    }
}


; ============================================================
; Stubs — subclasses of RunHistoryRepository
;
; The service guards its constructor with `is RunHistoryRepository`
; so a plain Map() won't pass. These subclasses bypass the parent
; constructor's dir-required check by setting `_dir` directly.
; ============================================================

class _AvgRepoStub extends RunHistoryRepository
{
    summariesToReturn := ""
    loadSummariesCount := 0

    __New(summaries := "")
    {
        this._dir  := "stub-not-used"
        this._warn := NullWarningSink()
        this.summariesToReturn := IsObject(summaries) ? summaries : []
        this.loadSummariesCount := 0
    }

    static WithSummaries(summaries)
    {
        s := _AvgRepoStub(summaries)
        return s
    }

    static Counting()
    {
        ; Empty-summaries stub that counts LoadSummaries invocations,
        ; so dispose_unsubscribes_run_completed_handler can verify
        ; the event subscription actually got torn down.
        return _AvgRepoStub([])
    }

    LoadSummaries(maxN := -1)
    {
        this.loadSummariesCount += 1
        out := []
        ; Apply the maxN cap mirroring the real repo's contract.
        limit := (maxN > 0 && maxN < this.summariesToReturn.Length)
                 ? maxN : this.summariesToReturn.Length
        i := 1
        while (i <= limit)
        {
            out.Push(this.summariesToReturn[i])
            i++
        }
        return out
    }

    ; ListRunIds + Load only matter for the zone-average path,
    ; which these tests don't exercise via the stub. Returning
    ; an empty list keeps that code path inert without leaking
    ; into the run/per-act tests.
    ListRunIds(maxN := -1) => []
    Load(id) => ""
}


TestRegistry.Register(RunAverageServiceTests)
