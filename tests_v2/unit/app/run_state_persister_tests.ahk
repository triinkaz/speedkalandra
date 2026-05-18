; ============================================================
; RunStatePersisterTests
; ============================================================
;
; RunStatePersister owns the 5-second persistence tick + the final
; flush from Stop(). Validates:
;   - Constructor argument types
;   - Tick skip-cache via _lastSavedLoadingTotal / _lastSavedZoneTotalsHash
;   - Flush always writes (no skip)
;   - Flush uses GetTotalsForSnapshot (not GetTotals)
;   - PersistSettings delegates to the repo
;   - Prime* methods seed the cache so the first Tick doesn't
;     rewrite hydrated values
;   - ResetCache clears the dirty-cache so the next run writes
;     immediately
;   - ComputeTotalsHash is deterministic and defensive against
;     non-Map input
;
; Test strategy: lightweight stubs for every collaborator. The
; persister has no clock / bus / SetTimer dependency, so tests
; exercise Tick/Flush directly with no time advancement.


class _PersisterStubRunService
{
    persistTickCount := 0
    active           := true

    PersistTick()
    {
        this.persistTickCount += 1
    }

    IsActive() => !!this.active
}


class _PersisterStubRunState
{
    savedLoadingTotal := -1
    savedZoneTotals   := ""
    saveLoadingCount  := 0
    saveZoneCount     := 0

    SaveLoadingTotal(ms)
    {
        this.savedLoadingTotal := ms
        this.saveLoadingCount += 1
    }

    SaveZoneTotals(totals)
    {
        this.savedZoneTotals := totals
        this.saveZoneCount += 1
    }
}


class _PersisterStubLoadingTotals
{
    totalMs := 0

    GetTotalMs() => this.totalMs
}


class _PersisterStubZoneTracker
{
    runActive       := false
    totals          := ""
    snapshotTotals  := ""

    IsRunActive() => !!this.runActive

    GetTotals() => this.totals

    GetTotalsForSnapshot()
    {
        ; Falls back to GetTotals when not overridden, mirroring real
        ; ZoneTrackingService behaviour where the snapshot variant is
        ; only meaningfully different mid-finalize.
        return IsObject(this.snapshotTotals) ? this.snapshotTotals : this.totals
    }
}


class _PersisterStubSettingsRepo
{
    saveCount    := 0
    savedCfg     := ""

    Save(cfg)
    {
        this.savedCfg  := cfg
        this.saveCount += 1
    }
}


class RunStatePersisterTests extends TestCase
{
    static Tests := [
        ; --- Constructor validations ---
        "constructor_throws_on_missing_run_service",
        "constructor_throws_on_missing_run_state",
        "constructor_throws_on_missing_loading_totals",
        "constructor_throws_on_missing_zone_tracker",
        "constructor_throws_on_missing_settings_repo",
        "constructor_throws_on_missing_cfg",
        "constructor_throws_on_missing_log",

        ; --- Tick: skip-cache ---
        "tick_persists_loading_total_when_changed",
        "tick_skips_loading_total_when_unchanged",
        "tick_skips_loading_total_when_run_inactive",
        "tick_persists_zone_totals_when_hash_changes",
        "tick_skips_zone_totals_when_hash_unchanged",
        "tick_skips_zone_totals_when_run_inactive",
        "tick_calls_persist_tick_on_run_service",

        ; --- Flush ---
        "flush_writes_loading_total_even_when_unchanged",
        "flush_uses_totals_for_snapshot_for_zone_totals",
        "flush_skips_loading_total_when_run_inactive",
        "flush_skips_zone_totals_when_run_inactive",
        "flush_calls_persist_tick_on_run_service",

        ; --- PersistSettings ---
        "persist_settings_delegates_to_repo",
        "persist_settings_passes_cfg_object",

        ; --- Cache priming + reset ---
        "prime_loading_total_cache_sets_value",
        "prime_loading_total_cache_ignores_negative",
        "prime_loading_total_cache_ignores_non_number",
        "prime_zone_totals_cache_hashes_map",
        "prime_zone_totals_cache_ignores_non_object",
        "reset_cache_clears_loading_total",
        "reset_cache_clears_zone_totals_hash",

        ; --- Static ComputeTotalsHash ---
        "compute_totals_hash_empty_map_returns_empty_string",
        "compute_totals_hash_non_object_returns_empty_string",
        "compute_totals_hash_serialises_key_value_pairs",
        "compute_totals_hash_is_deterministic_for_same_input",
    ]

    log := ""

    Setup()
    {
        this.log := NullLogger()
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    ; ------------------------------------------------------------
    ; Helpers
    ; ------------------------------------------------------------

    _Make(stubs := "")
    {
        deps := IsObject(stubs) ? stubs : Map()
        runSvc      := deps.Has("runSvc")      ? deps["runSvc"]      : _PersisterStubRunService()
        runState    := deps.Has("runState")    ? deps["runState"]    : _PersisterStubRunState()
        loading     := deps.Has("loading")     ? deps["loading"]     : _PersisterStubLoadingTotals()
        zoneTracker := deps.Has("zoneTracker") ? deps["zoneTracker"] : _PersisterStubZoneTracker()
        repo        := deps.Has("repo")        ? deps["repo"]        : _PersisterStubSettingsRepo()
        cfg         := deps.Has("cfg")         ? deps["cfg"]         : AppSettings()
        log         := deps.Has("log")         ? deps["log"]         : this.log

        return RunStatePersister(runSvc, runState, loading, zoneTracker, repo, cfg, log)
    }

    ; ------------------------------------------------------------
    ; Constructor validations
    ; ------------------------------------------------------------

    constructor_throws_on_missing_run_service()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            "", _PersisterStubRunState(), _PersisterStubLoadingTotals(),
            _PersisterStubZoneTracker(), _PersisterStubSettingsRepo(),
            AppSettings(), this.log
        ))
    }

    constructor_throws_on_missing_run_state()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            _PersisterStubRunService(), "", _PersisterStubLoadingTotals(),
            _PersisterStubZoneTracker(), _PersisterStubSettingsRepo(),
            AppSettings(), this.log
        ))
    }

    constructor_throws_on_missing_loading_totals()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            _PersisterStubRunService(), _PersisterStubRunState(), "",
            _PersisterStubZoneTracker(), _PersisterStubSettingsRepo(),
            AppSettings(), this.log
        ))
    }

    constructor_throws_on_missing_zone_tracker()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            _PersisterStubRunService(), _PersisterStubRunState(),
            _PersisterStubLoadingTotals(), "", _PersisterStubSettingsRepo(),
            AppSettings(), this.log
        ))
    }

    constructor_throws_on_missing_settings_repo()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            _PersisterStubRunService(), _PersisterStubRunState(),
            _PersisterStubLoadingTotals(), _PersisterStubZoneTracker(),
            "", AppSettings(), this.log
        ))
    }

    constructor_throws_on_missing_cfg()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            _PersisterStubRunService(), _PersisterStubRunState(),
            _PersisterStubLoadingTotals(), _PersisterStubZoneTracker(),
            _PersisterStubSettingsRepo(), "", this.log
        ))
    }

    constructor_throws_on_missing_log()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            _PersisterStubRunService(), _PersisterStubRunState(),
            _PersisterStubLoadingTotals(), _PersisterStubZoneTracker(),
            _PersisterStubSettingsRepo(), AppSettings(), ""
        ))
    }

    ; ------------------------------------------------------------
    ; Tick: skip-cache behaviour
    ; ------------------------------------------------------------

    tick_persists_loading_total_when_changed()
    {
        loading     := _PersisterStubLoadingTotals()
        loading.totalMs := 12345
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "loading",  loading,
            "runState", runState
        ))

        persister.Tick()

        Assert.Equal(1, runState.saveLoadingCount)
        Assert.Equal(12345, runState.savedLoadingTotal)
    }

    tick_skips_loading_total_when_unchanged()
    {
        loading     := _PersisterStubLoadingTotals()
        loading.totalMs := 7777
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "loading",  loading,
            "runState", runState
        ))

        persister.PrimeLoadingTotalCache(7777)
        persister.Tick()

        Assert.Equal(0, runState.saveLoadingCount, "Tick should skip when loading total matches the primed cache")
    }

    tick_skips_loading_total_when_run_inactive()
    {
        runSvc      := _PersisterStubRunService()
        runSvc.active := false
        loading     := _PersisterStubLoadingTotals()
        loading.totalMs := 9999
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "runSvc",   runSvc,
            "loading",  loading,
            "runState", runState
        ))

        persister.Tick()

        Assert.Equal(0, runState.saveLoadingCount, "Tick should skip loading total persistence when no active run")
    }

    tick_persists_zone_totals_when_hash_changes()
    {
        zoneTracker := _PersisterStubZoneTracker()
        zoneTracker.runActive := true
        zoneTracker.totals    := Map("Riverbank", 60000, "Clearfell", 90000)
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "zoneTracker", zoneTracker,
            "runState",    runState
        ))

        persister.Tick()

        Assert.Equal(1, runState.saveZoneCount)
        Assert.True(IsObject(runState.savedZoneTotals))
    }

    tick_skips_zone_totals_when_hash_unchanged()
    {
        zoneTracker := _PersisterStubZoneTracker()
        zoneTracker.runActive := true
        totals := Map("Riverbank", 60000, "Clearfell", 90000)
        zoneTracker.totals := totals
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "zoneTracker", zoneTracker,
            "runState",    runState
        ))

        persister.PrimeZoneTotalsCache(totals)
        persister.Tick()

        Assert.Equal(0, runState.saveZoneCount, "Tick should skip zone totals when hash matches the primed cache")
    }

    tick_skips_zone_totals_when_run_inactive()
    {
        zoneTracker := _PersisterStubZoneTracker()
        zoneTracker.runActive := false
        zoneTracker.totals    := Map("X", 1)
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "zoneTracker", zoneTracker,
            "runState",    runState
        ))

        persister.Tick()

        Assert.Equal(0, runState.saveZoneCount)
    }

    tick_calls_persist_tick_on_run_service()
    {
        runSvc    := _PersisterStubRunService()
        persister := this._Make(Map("runSvc", runSvc))

        persister.Tick()

        Assert.Equal(1, runSvc.persistTickCount)
    }

    ; ------------------------------------------------------------
    ; Flush: always writes
    ; ------------------------------------------------------------

    flush_writes_loading_total_even_when_unchanged()
    {
        loading     := _PersisterStubLoadingTotals()
        loading.totalMs := 555
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "loading",  loading,
            "runState", runState
        ))

        persister.PrimeLoadingTotalCache(555)
        persister.Flush()

        Assert.Equal(1, runState.saveLoadingCount, "Flush bypasses skip-cache by design")
    }

    flush_uses_totals_for_snapshot_for_zone_totals()
    {
        zoneTracker := _PersisterStubZoneTracker()
        zoneTracker.runActive := true
        zoneTracker.totals         := Map("Riverbank", 60000)
        zoneTracker.snapshotTotals := Map("Riverbank", 60000, "Clearfell", 120000)
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "zoneTracker", zoneTracker,
            "runState",    runState
        ))

        persister.Flush()

        Assert.True(IsObject(runState.savedZoneTotals))
        Assert.Equal(2, runState.savedZoneTotals.Count, "Flush should use GetTotalsForSnapshot, not GetTotals")
    }

    flush_skips_loading_total_when_run_inactive()
    {
        runSvc      := _PersisterStubRunService()
        runSvc.active := false
        loading     := _PersisterStubLoadingTotals()
        loading.totalMs := 555
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "runSvc",   runSvc,
            "loading",  loading,
            "runState", runState
        ))

        persister.Flush()

        Assert.Equal(0, runState.saveLoadingCount)
    }

    flush_skips_zone_totals_when_run_inactive()
    {
        zoneTracker := _PersisterStubZoneTracker()
        zoneTracker.runActive := false
        zoneTracker.totals    := Map("X", 1)
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "zoneTracker", zoneTracker,
            "runState",    runState
        ))

        persister.Flush()

        Assert.Equal(0, runState.saveZoneCount)
    }

    flush_calls_persist_tick_on_run_service()
    {
        runSvc    := _PersisterStubRunService()
        persister := this._Make(Map("runSvc", runSvc))

        persister.Flush()

        Assert.Equal(1, runSvc.persistTickCount)
    }

    ; ------------------------------------------------------------
    ; PersistSettings
    ; ------------------------------------------------------------

    persist_settings_delegates_to_repo()
    {
        repo      := _PersisterStubSettingsRepo()
        persister := this._Make(Map("repo", repo))

        persister.PersistSettings()
        persister.PersistSettings()

        Assert.Equal(2, repo.saveCount)
    }

    persist_settings_passes_cfg_object()
    {
        repo      := _PersisterStubSettingsRepo()
        cfg       := AppSettings()
        persister := this._Make(Map("repo", repo, "cfg", cfg))

        persister.PersistSettings()

        Assert.True(repo.savedCfg is AppSettings, "Save should receive the same AppSettings the persister was constructed with")
    }

    ; ------------------------------------------------------------
    ; Cache priming and reset
    ; ------------------------------------------------------------

    prime_loading_total_cache_sets_value()
    {
        loading     := _PersisterStubLoadingTotals()
        loading.totalMs := 1234
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "loading",  loading,
            "runState", runState
        ))

        persister.PrimeLoadingTotalCache(1234)
        persister.Tick()

        Assert.Equal(0, runState.saveLoadingCount, "After priming with the current value, Tick should skip the write")
    }

    prime_loading_total_cache_ignores_negative()
    {
        loading     := _PersisterStubLoadingTotals()
        loading.totalMs := 0
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "loading",  loading,
            "runState", runState
        ))

        ; Negative values come from "no run was hydrated"; the cache
        ; stays at its initial -1, which is correctly !=0 so the
        ; first Tick writes (would be wrong to silently coerce -5 to
        ; "0 was already saved").
        persister.PrimeLoadingTotalCache(-5)
        persister.Tick()

        Assert.Equal(1, runState.saveLoadingCount)
    }

    prime_loading_total_cache_ignores_non_number()
    {
        loading     := _PersisterStubLoadingTotals()
        loading.totalMs := 0
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "loading",  loading,
            "runState", runState
        ))

        persister.PrimeLoadingTotalCache("not a number")
        persister.Tick()

        Assert.Equal(1, runState.saveLoadingCount, "Non-numeric input must leave the cache at its initial -1")
    }

    prime_zone_totals_cache_hashes_map()
    {
        zoneTracker := _PersisterStubZoneTracker()
        zoneTracker.runActive := true
        totals := Map("A", 100, "B", 200)
        zoneTracker.totals := totals
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "zoneTracker", zoneTracker,
            "runState",    runState
        ))

        persister.PrimeZoneTotalsCache(totals)
        persister.Tick()

        Assert.Equal(0, runState.saveZoneCount, "Priming with the same map must skip the next Tick write")
    }

    prime_zone_totals_cache_ignores_non_object()
    {
        zoneTracker := _PersisterStubZoneTracker()
        zoneTracker.runActive := true
        zoneTracker.totals := Map("A", 100)
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "zoneTracker", zoneTracker,
            "runState",    runState
        ))

        persister.PrimeZoneTotalsCache("")
        persister.Tick()

        Assert.Equal(1, runState.saveZoneCount, "Non-object input must leave the cache empty so the first Tick writes")
    }

    reset_cache_clears_loading_total()
    {
        loading     := _PersisterStubLoadingTotals()
        loading.totalMs := 999
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "loading",  loading,
            "runState", runState
        ))

        persister.PrimeLoadingTotalCache(999)
        persister.ResetCache()
        persister.Tick()

        Assert.Equal(1, runState.saveLoadingCount, "ResetCache must clear the cache so the next Tick writes")
    }

    reset_cache_clears_zone_totals_hash()
    {
        zoneTracker := _PersisterStubZoneTracker()
        zoneTracker.runActive := true
        totals := Map("A", 100)
        zoneTracker.totals := totals
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "zoneTracker", zoneTracker,
            "runState",    runState
        ))

        persister.PrimeZoneTotalsCache(totals)
        persister.ResetCache()
        persister.Tick()

        Assert.Equal(1, runState.saveZoneCount)
    }

    ; ------------------------------------------------------------
    ; Static ComputeTotalsHash
    ; ------------------------------------------------------------

    compute_totals_hash_empty_map_returns_empty_string()
    {
        Assert.Equal("", RunStatePersister.ComputeTotalsHash(Map()))
    }

    compute_totals_hash_non_object_returns_empty_string()
    {
        Assert.Equal("", RunStatePersister.ComputeTotalsHash(""))
        Assert.Equal("", RunStatePersister.ComputeTotalsHash(42))
    }

    compute_totals_hash_serialises_key_value_pairs()
    {
        hash := RunStatePersister.ComputeTotalsHash(Map("Riverbank", 60000))
        Assert.Equal("Riverbank=60000|", hash)
    }

    compute_totals_hash_is_deterministic_for_same_input()
    {
        m := Map("A", 1, "B", 2)
        Assert.Equal(
            RunStatePersister.ComputeTotalsHash(m),
            RunStatePersister.ComputeTotalsHash(m)
        )
    }
}


TestRegistry.Register(RunStatePersisterTests)
