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
    ; Toggle for SaveZoneTotals to return false instead of true,
    ; simulating an AtomicWriter exception inside the real
    ; RunStateRepository.SaveZoneTotals (which catches + warns +
    ; returns false). Tests that exercise the persister's retry
    ; loop flip this to false; default true so the existing tests
    ; that don't care continue to pass.
    saveZoneSucceeds  := true

    savedLoadingEvents          := ""
    saveLoadingEventsCount      := 0
    saveLoadingEventsSucceeds   := true

    savedDeathCount             := -1
    saveDeathCountCalls         := 0

    SaveLoadingTotal(ms)
    {
        this.savedLoadingTotal := ms
        this.saveLoadingCount += 1
    }

    SaveZoneTotals(totals)
    {
        this.savedZoneTotals := totals
        this.saveZoneCount += 1
        return this.saveZoneSucceeds
    }

    SaveLoadingEvents(arr)
    {
        this.savedLoadingEvents := arr
        this.saveLoadingEventsCount += 1
        return this.saveLoadingEventsSucceeds
    }

    SaveDeathCount(n)
    {
        this.savedDeathCount := n
        this.saveDeathCountCalls += 1
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


; Recorder stub. The persister calls GetLoadingEvents() on it each
; Tick and Flush to drive the dirty-cache + skip logic. `events` is
; deliberately defaulted to "" so the getter handles the not-set
; case gracefully (the real RunStatsRecorder always returns an Array;
; tests that don't care leave it untouched).
class _PersisterStubRecorder
{
    events     := ""
    deathCount := 0

    GetLoadingEvents()
    {
        return IsObject(this.events) ? this.events : []
    }

    GetDeathCount() => this.deathCount
}


class RunStatePersisterTests extends TestCase
{
    static Tests := [
        ; --- Constructor validations ---
        "constructor_throws_on_missing_run_service",
        "constructor_throws_on_missing_run_state",
        "constructor_throws_on_missing_loading_totals",
        "constructor_throws_on_missing_zone_tracker",
        "constructor_throws_on_missing_recorder",
        "constructor_throws_on_missing_settings_repo",
        "constructor_throws_on_missing_cfg",
        "constructor_throws_on_missing_log",

        ; --- Tick: skip-cache ---
        "tick_persists_loading_total_when_changed",
        "tick_skips_loading_total_when_unchanged",
        "tick_skips_loading_total_when_run_inactive",
        "tick_persists_death_count_when_changed",
        "tick_skips_death_count_when_unchanged",
        "tick_skips_death_count_when_run_inactive",
        "tick_persists_zone_totals_when_hash_changes",
        "tick_skips_zone_totals_when_hash_unchanged",
        "tick_skips_zone_totals_when_run_inactive",
        "tick_calls_persist_tick_on_run_service",
        ; Regression: Tick used to call GetTotals() instead of
        ; GetTotalsForSnapshot(), so the active zone's in-flight
        ; elapsed wasn't included in the persisted image — defeating
        ; the whole crash-recovery purpose of the 5 s tick. Flush
        ; was already correct (see flush_uses_totals_for_snapshot_*
        ; below); the new test mirrors it for Tick.
        "tick_uses_totals_for_snapshot_for_zone_totals",
        ; Regression: SaveZoneTotals returns void in the old
        ; implementation, with the catch swallowing exceptions
        ; silently. The persister then advanced its skip-cache
        ; hash on the failed write, so subsequent ticks short-
        ; circuited without retrying until the totals changed.
        ; SaveZoneTotals now returns boolean; the persister only
        ; advances the cache on true.
        "tick_does_not_advance_cache_when_save_zone_totals_returns_false",
        "tick_retries_save_zone_totals_on_next_tick_after_failure",

        ; --- Tick: loading events (same skip-cache pattern as
        ; zone totals, keyed off the array length since events are
        ; append-only during a run — reset-on-end clears via
        ; ResetCache) ---
        "tick_persists_loading_events_when_count_changed",
        "tick_skips_loading_events_when_count_unchanged",
        "tick_skips_loading_events_when_run_inactive",
        "tick_does_not_advance_loading_events_cache_on_failed_save",
        "tick_retries_save_loading_events_on_next_tick_after_failure",

        ; --- Flush ---
        "flush_writes_loading_total_even_when_unchanged",
        "flush_uses_totals_for_snapshot_for_zone_totals",
        "flush_skips_loading_total_when_run_inactive",
        "flush_skips_zone_totals_when_run_inactive",
        "flush_calls_persist_tick_on_run_service",
        "flush_writes_loading_events_even_when_unchanged",
        "flush_skips_loading_events_when_run_inactive",
        "flush_writes_death_count_even_when_unchanged",
        "flush_skips_death_count_when_run_inactive",

        ; --- PersistSettings ---
        "persist_settings_delegates_to_repo",
        "persist_settings_passes_cfg_object",

        ; --- Cache priming + reset ---
        "prime_loading_total_cache_sets_value",
        "prime_loading_total_cache_ignores_negative",
        "prime_loading_total_cache_ignores_non_number",
        "prime_zone_totals_cache_hashes_map",
        "prime_zone_totals_cache_ignores_non_object",
        "prime_loading_events_count_sets_value",
        "prime_loading_events_count_ignores_negative",
        "prime_loading_events_count_ignores_non_number",
        "prime_death_count_cache_sets_value",
        "prime_death_count_cache_ignores_negative",
        "prime_death_count_cache_ignores_non_number",
        "reset_cache_clears_loading_total",
        "reset_cache_clears_zone_totals_hash",
        "reset_cache_clears_loading_events_count",
        "reset_cache_clears_death_count",

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
        recorder    := deps.Has("recorder")    ? deps["recorder"]    : _PersisterStubRecorder()
        repo        := deps.Has("repo")        ? deps["repo"]        : _PersisterStubSettingsRepo()
        cfg         := deps.Has("cfg")         ? deps["cfg"]         : AppSettings()
        log         := deps.Has("log")         ? deps["log"]         : this.log

        return RunStatePersister(runSvc, runState, loading, zoneTracker, recorder, repo, cfg, log)
    }

    ; ------------------------------------------------------------
    ; Constructor validations
    ; ------------------------------------------------------------

    constructor_throws_on_missing_run_service()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            "", _PersisterStubRunState(), _PersisterStubLoadingTotals(),
            _PersisterStubZoneTracker(), _PersisterStubRecorder(),
            _PersisterStubSettingsRepo(), AppSettings(), this.log
        ))
    }

    constructor_throws_on_missing_run_state()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            _PersisterStubRunService(), "", _PersisterStubLoadingTotals(),
            _PersisterStubZoneTracker(), _PersisterStubRecorder(),
            _PersisterStubSettingsRepo(), AppSettings(), this.log
        ))
    }

    constructor_throws_on_missing_loading_totals()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            _PersisterStubRunService(), _PersisterStubRunState(), "",
            _PersisterStubZoneTracker(), _PersisterStubRecorder(),
            _PersisterStubSettingsRepo(), AppSettings(), this.log
        ))
    }

    constructor_throws_on_missing_zone_tracker()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            _PersisterStubRunService(), _PersisterStubRunState(),
            _PersisterStubLoadingTotals(), "", _PersisterStubRecorder(),
            _PersisterStubSettingsRepo(), AppSettings(), this.log
        ))
    }

    constructor_throws_on_missing_recorder()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            _PersisterStubRunService(), _PersisterStubRunState(),
            _PersisterStubLoadingTotals(), _PersisterStubZoneTracker(),
            "", _PersisterStubSettingsRepo(), AppSettings(), this.log
        ))
    }

    constructor_throws_on_missing_settings_repo()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            _PersisterStubRunService(), _PersisterStubRunState(),
            _PersisterStubLoadingTotals(), _PersisterStubZoneTracker(),
            _PersisterStubRecorder(), "", AppSettings(), this.log
        ))
    }

    constructor_throws_on_missing_cfg()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            _PersisterStubRunService(), _PersisterStubRunState(),
            _PersisterStubLoadingTotals(), _PersisterStubZoneTracker(),
            _PersisterStubRecorder(), _PersisterStubSettingsRepo(), "", this.log
        ))
    }

    constructor_throws_on_missing_log()
    {
        Assert.Throws(TypeError, () => RunStatePersister(
            _PersisterStubRunService(), _PersisterStubRunState(),
            _PersisterStubLoadingTotals(), _PersisterStubZoneTracker(),
            _PersisterStubRecorder(), _PersisterStubSettingsRepo(),
            AppSettings(), ""
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

    tick_uses_totals_for_snapshot_for_zone_totals()
    {
        ; Symmetric to flush_uses_totals_for_snapshot_for_zone_totals
        ; below: the 5 s tick exists precisely to preserve in-flight
        ; zone time across crashes, which means it MUST read the
        ; snapshot variant (which folds the active zone's elapsed
        ; into the per-zone map) rather than the bare _totals map
        ; (which only contains transitions already closed).
        ;
        ; The stub deliberately returns DIFFERENT maps from the
        ; two getters — totals carries 1 entry, snapshotTotals
        ; carries 2. If Tick reads from the wrong getter, the
        ; assertion below fails on the Count.
        zoneTracker := _PersisterStubZoneTracker()
        zoneTracker.runActive := true
        zoneTracker.totals         := Map("Riverbank", 60000)
        zoneTracker.snapshotTotals := Map("Riverbank", 60000, "Clearfell", 120000)
        runState    := _PersisterStubRunState()
        persister   := this._Make(Map(
            "zoneTracker", zoneTracker,
            "runState",    runState
        ))

        persister.Tick()

        Assert.True(IsObject(runState.savedZoneTotals))
        Assert.Equal(2, runState.savedZoneTotals.Count,
            "Tick must use GetTotalsForSnapshot (2 entries), not GetTotals (1 entry)")
    }

    tick_does_not_advance_cache_when_save_zone_totals_returns_false()
    {
        ; SaveZoneTotals returns false when the underlying
        ; AtomicWriter throws (disk full, file lock from antivirus,
        ; etc.). The persister must NOT advance _lastSavedZoneTotalsHash
        ; on a false return — doing so would mark the failed write
        ; as "saved" and skip all subsequent ticks until the totals
        ; happen to change again. This test pins the no-cache-update
        ; contract; the follow-up test pins the retry-on-next-tick.
        zoneTracker := _PersisterStubZoneTracker()
        zoneTracker.runActive := true
        zoneTracker.totals := Map("Riverbank", 60000)
        runState    := _PersisterStubRunState()
        runState.saveZoneSucceeds := false    ; simulate write failure
        persister   := this._Make(Map(
            "zoneTracker", zoneTracker,
            "runState",    runState
        ))

        persister.Tick()

        Assert.Equal(1, runState.saveZoneCount,
            "SaveZoneTotals was attempted")
        ; Internal field check: the cache hash must NOT have been
        ; advanced. We can probe by running a second Tick with the
        ; same totals and verifying it ALSO writes (which it would
        ; only do if the cache wasn't advanced).
        persister.Tick()
        Assert.Equal(2, runState.saveZoneCount,
            "the next Tick must retry the failed write, not skip via stale cache")
    }

    tick_retries_save_zone_totals_on_next_tick_after_failure()
    {
        ; End-to-end retry: first Tick fails, second Tick still has
        ; the same totals (no transition happened in between), and
        ; the disk is healthy again. The persister must (a) retry
        ; on the second Tick AND (b) advance the cache once the
        ; retry succeeds, so the third Tick legitimately skips.
        zoneTracker := _PersisterStubZoneTracker()
        zoneTracker.runActive := true
        zoneTracker.totals := Map("Riverbank", 60000)
        runState    := _PersisterStubRunState()
        runState.saveZoneSucceeds := false
        persister   := this._Make(Map(
            "zoneTracker", zoneTracker,
            "runState",    runState
        ))

        persister.Tick()                       ; fails
        Assert.Equal(1, runState.saveZoneCount)

        runState.saveZoneSucceeds := true      ; disk recovers
        persister.Tick()                       ; retries, succeeds
        Assert.Equal(2, runState.saveZoneCount,
            "second Tick must retry the write")

        persister.Tick()                       ; same totals, cache should now skip
        Assert.Equal(2, runState.saveZoneCount,
            "third Tick must skip via cache now that the previous write succeeded")
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

    ; ------------------------------------------------------------
    ; Tick: loading events behavior
    ; ------------------------------------------------------------
    ; The recorder's GetLoadingEvents() is sampled each Tick. The
    ; persister keys its dirty-cache off Length (events are
    ; append-only during a run — ResetCache handles the
    ; end-of-run reset path). Same bool-return contract as
    ; SaveZoneTotals: cache only advances when SaveLoadingEvents
    ; returns true.

    tick_persists_loading_events_when_count_changed()
    {
        recorder := _PersisterStubRecorder()
        recorder.events := [
            Map("durationMs", 1500, "ts", "t1", "source", "", "fromZone", "", "toZone", ""),
            Map("durationMs", 2200, "ts", "t2", "source", "", "fromZone", "", "toZone", "")
        ]
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.Tick()

        Assert.Equal(1, runState.saveLoadingEventsCount)
        Assert.Equal(2, runState.savedLoadingEvents.Length)
    }

    tick_skips_loading_events_when_count_unchanged()
    {
        recorder := _PersisterStubRecorder()
        recorder.events := [
            Map("durationMs", 1500, "ts", "t1", "source", "", "fromZone", "", "toZone", "")
        ]
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.PrimeLoadingEventsCount(1)
        persister.Tick()

        Assert.Equal(0, runState.saveLoadingEventsCount)
    }

    tick_skips_loading_events_when_run_inactive()
    {
        runSvc := _PersisterStubRunService()
        runSvc.active := false
        recorder := _PersisterStubRecorder()
        recorder.events := [Map("durationMs", 1500, "ts", "t1",
            "source", "", "fromZone", "", "toZone", "")]
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "runSvc",   runSvc,
            "recorder", recorder,
            "runState", runState
        ))

        persister.Tick()

        Assert.Equal(0, runState.saveLoadingEventsCount)
    }

    tick_does_not_advance_loading_events_cache_on_failed_save()
    {
        ; Regression mirror of zone-totals: when SaveLoadingEvents
        ; returns false (AtomicWriter threw inside the repo), the
        ; persister must NOT advance _lastSavedLoadingEventsCount,
        ; so the next tick retries the write.
        recorder := _PersisterStubRecorder()
        recorder.events := [Map("durationMs", 1500, "ts", "t1",
            "source", "", "fromZone", "", "toZone", "")]
        runState := _PersisterStubRunState()
        runState.saveLoadingEventsSucceeds := false
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.Tick()
        Assert.Equal(1, runState.saveLoadingEventsCount)
        ; Same array length on next tick — if the cache had advanced,
        ; this call would skip. The retry path must call Save again.
        persister.Tick()
        Assert.Equal(2, runState.saveLoadingEventsCount)
    }

    tick_retries_save_loading_events_on_next_tick_after_failure()
    {
        recorder := _PersisterStubRecorder()
        recorder.events := [Map("durationMs", 1500, "ts", "t1",
            "source", "", "fromZone", "", "toZone", "")]
        runState := _PersisterStubRunState()
        runState.saveLoadingEventsSucceeds := false
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.Tick()   ; first attempt: returns false
        runState.saveLoadingEventsSucceeds := true
        persister.Tick()   ; second attempt: succeeds

        Assert.Equal(2, runState.saveLoadingEventsCount)
        ; Now the cache is primed; another tick with same count skips
        persister.Tick()
        Assert.Equal(2, runState.saveLoadingEventsCount)
    }

    ; ------------------------------------------------------------
    ; Flush: loading events behavior
    ; ------------------------------------------------------------

    flush_writes_loading_events_even_when_unchanged()
    {
        recorder := _PersisterStubRecorder()
        recorder.events := [Map("durationMs", 1500, "ts", "t1",
            "source", "", "fromZone", "", "toZone", "")]
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.PrimeLoadingEventsCount(1)   ; would skip in Tick
        persister.Flush()

        Assert.Equal(1, runState.saveLoadingEventsCount)
    }

    flush_skips_loading_events_when_run_inactive()
    {
        runSvc := _PersisterStubRunService()
        runSvc.active := false
        recorder := _PersisterStubRecorder()
        recorder.events := [Map("durationMs", 1500, "ts", "t1",
            "source", "", "fromZone", "", "toZone", "")]
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "runSvc",   runSvc,
            "recorder", recorder,
            "runState", runState
        ))

        persister.Flush()

        Assert.Equal(0, runState.saveLoadingEventsCount)
    }

    ; ------------------------------------------------------------
    ; Cache priming + reset (loading events)
    ; ------------------------------------------------------------

    prime_loading_events_count_sets_value()
    {
        recorder := _PersisterStubRecorder()
        recorder.events := [
            Map("durationMs", 1500, "ts", "t1", "source", "", "fromZone", "", "toZone", ""),
            Map("durationMs", 2200, "ts", "t2", "source", "", "fromZone", "", "toZone", ""),
            Map("durationMs", 3100, "ts", "t3", "source", "", "fromZone", "", "toZone", "")
        ]
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.PrimeLoadingEventsCount(3)
        persister.Tick()    ; same count — must skip
        Assert.Equal(0, runState.saveLoadingEventsCount)
    }

    prime_loading_events_count_ignores_negative()
    {
        recorder := _PersisterStubRecorder()
        recorder.events := [Map("durationMs", 1500, "ts", "t1",
            "source", "", "fromZone", "", "toZone", "")]
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.PrimeLoadingEventsCount(-5)
        persister.Tick()   ; cache stayed at -1, current count is 1 — must write
        Assert.Equal(1, runState.saveLoadingEventsCount)
    }

    prime_loading_events_count_ignores_non_number()
    {
        recorder := _PersisterStubRecorder()
        recorder.events := [Map("durationMs", 1500, "ts", "t1",
            "source", "", "fromZone", "", "toZone", "")]
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.PrimeLoadingEventsCount("not a number")
        persister.Tick()
        Assert.Equal(1, runState.saveLoadingEventsCount)
    }

    reset_cache_clears_loading_events_count()
    {
        recorder := _PersisterStubRecorder()
        recorder.events := [Map("durationMs", 1500, "ts", "t1",
            "source", "", "fromZone", "", "toZone", "")]
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.PrimeLoadingEventsCount(1)
        persister.Tick()   ; would skip due to prime
        Assert.Equal(0, runState.saveLoadingEventsCount)

        persister.ResetCache()
        persister.Tick()   ; cache cleared — must write again
        Assert.Equal(1, runState.saveLoadingEventsCount)
    }

    ; ------------------------------------------------------------
    ; Tick / Flush / cache: death count
    ; ------------------------------------------------------------
    ; Scalar in [RunState] DeathCount=N, mirror of LoadingTotal.
    ; Without persistence the count resets every reboot and
    ; multi-session finalized runs under-report total deaths.

    tick_persists_death_count_when_changed()
    {
        recorder := _PersisterStubRecorder()
        recorder.deathCount := 4
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.Tick()

        Assert.Equal(1, runState.saveDeathCountCalls)
        Assert.Equal(4, runState.savedDeathCount)
    }

    tick_skips_death_count_when_unchanged()
    {
        recorder := _PersisterStubRecorder()
        recorder.deathCount := 2
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.PrimeDeathCountCache(2)
        persister.Tick()

        Assert.Equal(0, runState.saveDeathCountCalls)
    }

    tick_skips_death_count_when_run_inactive()
    {
        runSvc := _PersisterStubRunService()
        runSvc.active := false
        recorder := _PersisterStubRecorder()
        recorder.deathCount := 3
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "runSvc",   runSvc,
            "recorder", recorder,
            "runState", runState
        ))

        persister.Tick()

        Assert.Equal(0, runState.saveDeathCountCalls)
    }

    flush_writes_death_count_even_when_unchanged()
    {
        recorder := _PersisterStubRecorder()
        recorder.deathCount := 5
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.PrimeDeathCountCache(5)
        persister.Flush()

        Assert.Equal(1, runState.saveDeathCountCalls)
        Assert.Equal(5, runState.savedDeathCount)
    }

    flush_skips_death_count_when_run_inactive()
    {
        runSvc := _PersisterStubRunService()
        runSvc.active := false
        recorder := _PersisterStubRecorder()
        recorder.deathCount := 3
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "runSvc",   runSvc,
            "recorder", recorder,
            "runState", runState
        ))

        persister.Flush()

        Assert.Equal(0, runState.saveDeathCountCalls)
    }

    prime_death_count_cache_sets_value()
    {
        recorder := _PersisterStubRecorder()
        recorder.deathCount := 3
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.PrimeDeathCountCache(3)
        persister.Tick()    ; same count — must skip
        Assert.Equal(0, runState.saveDeathCountCalls)
    }

    prime_death_count_cache_ignores_negative()
    {
        recorder := _PersisterStubRecorder()
        recorder.deathCount := 2
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.PrimeDeathCountCache(-1)
        persister.Tick()
        Assert.Equal(1, runState.saveDeathCountCalls)
    }

    prime_death_count_cache_ignores_non_number()
    {
        recorder := _PersisterStubRecorder()
        recorder.deathCount := 2
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.PrimeDeathCountCache("not a number")
        persister.Tick()
        Assert.Equal(1, runState.saveDeathCountCalls)
    }

    reset_cache_clears_death_count()
    {
        recorder := _PersisterStubRecorder()
        recorder.deathCount := 4
        runState := _PersisterStubRunState()
        persister := this._Make(Map(
            "recorder", recorder,
            "runState", runState
        ))

        persister.PrimeDeathCountCache(4)
        persister.Tick()   ; would skip due to prime
        Assert.Equal(0, runState.saveDeathCountCalls)

        persister.ResetCache()
        persister.Tick()   ; cache cleared — must write again
        Assert.Equal(1, runState.saveDeathCountCalls)
    }
}


TestRegistry.Register(RunStatePersisterTests)
