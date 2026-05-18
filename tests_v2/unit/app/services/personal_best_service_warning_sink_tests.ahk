; ============================================================
; PersonalBestService warning-sink integration tests
; ============================================================
;
; Covers the persist-failure paths added when WarningSink was
; introduced. Every public mutation in PersonalBestService routes
; through `_TryPersistOrWarn(context)` after touching memory; this
; suite proves that:
;
;   - A repo whose Save returns false produces a WARN with the
;     correct context tag.
;   - A repo whose Save throws produces a WARN that includes the
;     exception message.
;   - A successful Save (default repo, no warning sink injected)
;     produces no WARN \u2014 the happy path stays quiet.
;
; The stubs subclass PersonalBestRepository because the service's
; constructor enforces `is PersonalBestRepository`. Each stub
; bypasses the parent's path-required check so it can be
; constructed without touching the filesystem.


class PersonalBestServiceWarningSinkTests extends TestCase
{
    static Tests := [
        ; --- Repo returns false on Save ---
        "update_from_run_warns_when_repo_save_returns_false",
        "reset_warns_when_repo_save_returns_false",
        "load_from_external_warns_when_repo_save_returns_false",
        "set_as_run_pb_warns_when_repo_save_returns_false",
        "rebuild_from_history_warns_when_repo_save_returns_false",

        ; --- Repo throws on Save ---
        "update_from_run_warns_when_repo_save_throws",
        "rebuild_from_history_warns_when_repo_save_throws",

        ; --- Happy path is silent ---
        "successful_update_emits_no_warning",
        "no_change_update_emits_no_warning",

        ; --- Load path ---
        "load_from_repo_warns_when_repo_load_throws",

        ; --- Constructor sink validation ---
        "constructor_throws_when_warning_sink_lacks_warn_method"
    ]

    Setup()
    {
    }
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    ; ============================================================
    ; Repo returns false on Save
    ; ============================================================

    update_from_run_warns_when_repo_save_returns_false()
    {
        sink := InMemoryWarningSink()
        svc := PersonalBestService(_PbRepoStubReturnsFalse(), sink)

        svc.UpdateFromRun(60000, "rid-1")

        Assert.Equal(1, sink.Count())
        Assert.True(sink.HasMessage("after UpdateFromRun"))
        Assert.True(sink.HasMessage("returned false"))
    }

    reset_warns_when_repo_save_returns_false()
    {
        sink := InMemoryWarningSink()
        svc := PersonalBestService(_PbRepoStubReturnsFalse(), sink)

        svc.Reset()

        Assert.Equal(1, sink.Count())
        Assert.True(sink.HasMessage("after Reset"))
    }

    load_from_external_warns_when_repo_save_returns_false()
    {
        sink := InMemoryWarningSink()
        svc := PersonalBestService(_PbRepoStubReturnsFalse(), sink)

        svc.LoadFromExternal(Map(
            "runPbMs",    50000,
            "runPbRunId", "external-rid",
            "runPbByAct", Map(),
            "zonePbs",    Map()
        ))

        Assert.Equal(1, sink.Count())
        Assert.True(sink.HasMessage("after LoadFromExternal"))
    }

    set_as_run_pb_warns_when_repo_save_returns_false()
    {
        sink := InMemoryWarningSink()
        svc := PersonalBestService(_PbRepoStubReturnsFalse(), sink)

        svc.SetAsRunPb(80000, "manual-rid")

        Assert.Equal(1, sink.Count())
        Assert.True(sink.HasMessage("after SetAsRunPb"))
    }

    rebuild_from_history_warns_when_repo_save_returns_false()
    {
        sink := InMemoryWarningSink()
        svc := PersonalBestService(_PbRepoStubReturnsFalse(), sink)

        svc.RebuildFromHistory([])

        Assert.True(sink.Count() >= 1)
        Assert.True(sink.HasMessage("after RebuildFromHistory"))
    }

    ; ============================================================
    ; Repo throws on Save (programmer error / unexpected state)
    ; ============================================================

    update_from_run_warns_when_repo_save_throws()
    {
        sink := InMemoryWarningSink()
        svc := PersonalBestService(_PbRepoStubThrowsOnSave(), sink)

        svc.UpdateFromRun(60000, "rid-1")

        Assert.Equal(1, sink.Count())
        Assert.True(sink.HasMessage("after UpdateFromRun"))
        Assert.True(sink.HasMessage("threw"))
        ; The exception message should be appended by
        ; LogServiceWarningSink in production; the InMemoryWarningSink
        ; here captures the raw message + ex object separately.
        Assert.True(IsObject(sink.entries[1]["ex"]))
    }

    rebuild_from_history_warns_when_repo_save_throws()
    {
        sink := InMemoryWarningSink()
        svc := PersonalBestService(_PbRepoStubThrowsOnSave(), sink)

        svc.RebuildFromHistory([Map(
            "runId",       "rid-1",
            "totalMs",     50000,
            "totals",      Map(),
            "details",     []
        )])

        Assert.True(sink.HasMessage("after RebuildFromHistory"))
    }

    ; ============================================================
    ; Happy path \u2014 NO warning when persist succeeds
    ; ============================================================

    successful_update_emits_no_warning()
    {
        sink := InMemoryWarningSink()
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)   ; real repo, real file
        svc := PersonalBestService(repo, sink)

        svc.UpdateFromRun(60000, "rid-1")

        Assert.Equal(0, sink.Count())
    }

    no_change_update_emits_no_warning()
    {
        ; If UpdateFromRun decides nothing changed (because all values
        ; are zero / non-positive), _TryPersistOrWarn must NOT be
        ; called \u2014 the method early-exits before persisting.
        sink := InMemoryWarningSink()
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        svc := PersonalBestService(repo, sink)

        svc.UpdateFromRun(0, "rid-zero")   ; runMs=0 \u2192 skipped

        Assert.Equal(0, sink.Count())
    }

    ; ============================================================
    ; Load path \u2014 _LoadFromRepo failure produces a WARN
    ; ============================================================

    load_from_repo_warns_when_repo_load_throws()
    {
        sink := InMemoryWarningSink()
        ; Constructor calls _LoadFromRepo \u2014 our stub throws, sink
        ; should capture it.
        svc := PersonalBestService(_PbRepoStubThrowsOnLoad(), sink)

        Assert.Equal(1, sink.Count())
        Assert.True(sink.HasMessage("Failed to load PBs"))
    }

    constructor_throws_when_warning_sink_lacks_warn_method()
    {
        ; Wiring bug: someone passes a Map() instead of an actual
        ; sink. The constructor must reject it loudly at boot rather
        ; than wait for the first persist failure to crash inside
        ; _TryPersistOrWarn. Routed through WarningSink.Resolve.
        path := Fixtures.TempPath("ini")
        repo := PersonalBestRepository(path)
        Assert.Throws(TypeError, () => PersonalBestService(repo, Map("not", "a sink")))
    }
}


; ============================================================
; Stubs \u2014 subclasses of PersonalBestRepository
;
; The service guards its constructor with `is PersonalBestRepository`
; so a plain Map() won't pass. These bypass the parent constructor's
; path-required check by setting `_path` directly.
; ============================================================

class _PbRepoStubReturnsFalse extends PersonalBestRepository
{
    __New()
    {
        this._path := "stub-not-used"
        this._warn := NullWarningSink()
    }
    Load() => Map(
        "runPbMs",    0,
        "runPbRunId", "",
        "runPbByAct", Map(),
        "zonePbs",    Map()
    )
    Save(data) => false
}

class _PbRepoStubThrowsOnSave extends PersonalBestRepository
{
    __New()
    {
        this._path := "stub-not-used"
        this._warn := NullWarningSink()
    }
    Load() => Map(
        "runPbMs",    0,
        "runPbRunId", "",
        "runPbByAct", Map(),
        "zonePbs",    Map()
    )
    Save(data)
    {
        throw OSError("simulated save failure")
    }
}

class _PbRepoStubThrowsOnLoad extends PersonalBestRepository
{
    __New()
    {
        this._path := "stub-not-used"
        this._warn := NullWarningSink()
    }
    Load()
    {
        throw OSError("simulated load failure")
    }
    Save(data) => true
}


TestRegistry.Register(PersonalBestServiceWarningSinkTests)
