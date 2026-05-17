; ============================================================
; RunServiceTests
; ============================================================
;
; RunService orchestrates the run lifecycle:
;   NewRun       -> status=running, timer.Start, publishes RunStarted
;   FinalizeRun  -> status=completed, timer.Stop, publishes RunCompleted
;   CancelRun    -> status=cancelled, timer.Stop, publishes RunCancelled
;   ResetRun     -> RunState.Empty, timer.Reset, publishes RunReset
;   Hydrate      -> restores state + timer; publishes RunStarted{hydrated:true}
;                   if state.IsActive
;
; Subscribes to 4 Commands:
;   Cmd.NewRunRequested      -> NewRun()
;   Cmd.FinalizeRunRequested -> FinalizeRun()
;   Cmd.CancelRunRequested   -> CancelRun()
;   Cmd.ResetRunRequested    -> ResetRun()
;
; Persistence: state saved in RunStateRepository (UTF-16 INI).
; PersistTimer saves only runBaseMs (optimization for periodic tick).
;
; Real deps used: TimerService + RunStateRepository (typecheck via `is`).


class RunServiceTests extends TestCase
{
    bus       := ""
    stubClock := ""
    timerSvc  := ""
    iniInst   := ""
    stateRepo := ""
    repoPath  := ""
    svc       := ""

    Setup()
    {
        this.bus       := Fixtures.MakeBus()
        this.stubClock := Fixtures.MakeFakeClock(10000)
        this.timerSvc  := TimerService(this.stubClock, this.bus)
        this.repoPath  := Fixtures.TempPath("ini")
        this.iniInst   := IniFile(this.repoPath)
        this.stateRepo := RunStateRepository(this.iniInst)
        this.svc       := RunService(this.stubClock, this.bus, this.timerSvc, this.stateRepo)
    }

    Teardown()
    {
        if IsObject(this.svc)
            this.svc.Dispose()
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_clock_missing_now_ms",
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_timer_svc_not_timer_service",
        "constructor_throws_when_state_repo_not_run_state_repository",
        "constructor_subscribes_to_all_4_commands",

        ; --- Initial state ---
        "run_id_empty_initially",
        "status_idle_initially",
        "is_active_false_initially",

        ; --- NewRun ---
        "new_run_returns_true",
        "new_run_generates_run_id_in_yyyyMMdd_HHmmss_nnn_format",
        "new_run_sets_started_at_iso_format",
        "new_run_sets_status_to_running",
        "new_run_starts_timer",
        "new_run_publishes_run_started_event",
        "new_run_event_includes_run_id",
        "new_run_event_includes_started_at",
        "new_run_event_includes_profile_id_when_provided",
        "new_run_with_active_run_resets_first",
        "new_run_persists_to_state_repo",

        ; --- FinalizeRun ---
        "finalize_returns_false_when_not_active",
        "finalize_returns_true_when_active",
        "finalize_sets_status_to_completed",
        "finalize_stops_timer",
        "finalize_publishes_run_completed_event",
        "finalize_event_includes_run_id",
        "finalize_event_includes_duration_ms",
        "finalize_persists_status_to_repo",

        ; --- CancelRun ---
        "cancel_returns_false_when_not_active",
        "cancel_returns_true_when_active",
        "cancel_sets_status_to_cancelled",
        "cancel_stops_timer",
        "cancel_publishes_run_cancelled_event",
        "cancel_event_includes_run_id",
        "cancel_persists_status_to_repo",

        ; --- ResetRun ---
        "reset_clears_run_id",
        "reset_resets_timer",
        "reset_clears_state_repo",
        "reset_publishes_run_reset_event",
        "reset_event_includes_previous_run_id",
        "reset_when_no_active_run_still_works",

        ; --- Hydrate ---
        "hydrate_throws_on_non_run_state",
        "hydrate_restores_state",
        "hydrate_with_running_status_resumes_timer_running",
        "hydrate_with_paused_status_keeps_timer_paused",
        "hydrate_with_stopped_status_keeps_timer_stopped",
        "hydrate_active_state_publishes_run_started",
        "hydrate_event_has_hydrated_true_flag",
        "hydrate_inactive_state_does_not_publish_run_started",

        ; --- PersistTimer ---
        "persist_timer_no_op_when_not_active",
        "persist_timer_updates_run_base_ms_when_active",
        "persist_tick_alias_calls_persist_timer",

        ; --- Subscribers (Commands) ---
        "new_run_requested_command_triggers_new_run",
        "finalize_run_requested_triggers_finalize",
        "cancel_run_requested_triggers_cancel",
        "reset_run_requested_triggers_reset",

        ; --- Dispose ---
        "dispose_unsubscribes_all_commands",
        "dispose_is_idempotent"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _CaptureEvents(eventName)
    {
        capturedEvents := []
        this.bus.Subscribe(eventName, (data) => capturedEvents.Push(data))
        return capturedEvents
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_clock_missing_now_ms()
    {
        b := this.bus
        t := this.timerSvc
        r := this.stateRepo
        emptyObj := { foo: () => 0 }
        Assert.Throws(TypeError, () => RunService(emptyObj, b, t, r))
    }

    constructor_throws_when_bus_not_event_bus()
    {
        clk := this.stubClock
        t := this.timerSvc
        r := this.stateRepo
        Assert.Throws(TypeError, () => RunService(clk, "not bus", t, r))
    }

    constructor_throws_when_timer_svc_not_timer_service()
    {
        clk := this.stubClock
        b := this.bus
        r := this.stateRepo
        Assert.Throws(TypeError, () => RunService(clk, b, "not timer", r))
    }

    constructor_throws_when_state_repo_not_run_state_repository()
    {
        clk := this.stubClock
        b := this.bus
        t := this.timerSvc
        Assert.Throws(TypeError, () => RunService(clk, b, t, "not repo"))
    }

    constructor_subscribes_to_all_4_commands()
    {
        Assert.Equal(1, this.bus.Subscribers(Commands.NewRunRequested))
        Assert.Equal(1, this.bus.Subscribers(Commands.FinalizeRunRequested))
        Assert.Equal(1, this.bus.Subscribers(Commands.CancelRunRequested))
        Assert.Equal(1, this.bus.Subscribers(Commands.ResetRunRequested))
    }

    ; ============================================================
    ; Initial state
    ; ============================================================

    run_id_empty_initially()    => Assert.Equal("", this.svc.GetRunId())
    status_idle_initially()     => Assert.Equal("idle", this.svc.GetStatus())
    is_active_false_initially() => Assert.False(this.svc.IsActive())

    ; ============================================================
    ; NewRun
    ; ============================================================

    new_run_returns_true()
    {
        Assert.True(this.svc.NewRun())
    }

    new_run_generates_run_id_in_yyyyMMdd_HHmmss_nnn_format()
    {
        this.svc.NewRun()
        producedId := this.svc.GetRunId()
        ; Format: "20260515_103045_873" = 19 chars (8 + _ + 6 + _ + 3)
        Assert.Equal(19, StrLen(producedId))
        ; Underscores at positions 9 and 16
        Assert.Equal("_", SubStr(producedId, 9,  1))
        Assert.Equal("_", SubStr(producedId, 16, 1))
    }

    new_run_sets_started_at_iso_format()
    {
        this.svc.NewRun()
        ts := this.svc.GetStartedAt()
        ; "yyyy-MM-dd HH:mm:ss" = 19 chars
        Assert.Equal(19, StrLen(ts))
        Assert.Equal("-", SubStr(ts, 5,  1))
        Assert.Equal("-", SubStr(ts, 8,  1))
        Assert.Equal(" ", SubStr(ts, 11, 1))
        Assert.Equal(":", SubStr(ts, 14, 1))
    }

    new_run_sets_status_to_running()
    {
        this.svc.NewRun()
        Assert.Equal("running", this.svc.GetStatus())
        Assert.True(this.svc.IsActive())
        Assert.True(this.svc.IsRunning())
    }

    new_run_starts_timer()
    {
        this.svc.NewRun()
        Assert.True(this.timerSvc.IsActive())
        Assert.True(this.timerSvc.IsRunning())
    }

    new_run_publishes_run_started_event()
    {
        capturedEvents := this._CaptureEvents(Events.RunStarted)
        this.svc.NewRun()
        Assert.Equal(1, capturedEvents.Length)
    }

    new_run_event_includes_run_id()
    {
        capturedEvents := this._CaptureEvents(Events.RunStarted)
        this.svc.NewRun()
        Assert.Equal(this.svc.GetRunId(), capturedEvents[1]["runId"])
    }

    new_run_event_includes_started_at()
    {
        capturedEvents := this._CaptureEvents(Events.RunStarted)
        this.svc.NewRun()
        Assert.Equal(this.svc.GetStartedAt(), capturedEvents[1]["startedAt"])
    }

    new_run_event_includes_profile_id_when_provided()
    {
        capturedEvents := this._CaptureEvents(Events.RunStarted)
        this.svc.NewRun("speedrun_profile")
        Assert.Equal("speedrun_profile", capturedEvents[1]["profileId"])
    }

    new_run_with_active_run_resets_first()
    {
        ; v17.14: NewRun with an active run calls ResetRun (discards
        ; without saving). Before that, CancelRun was called and saved
        ; if runMs >= 3min.
        this.svc.NewRun()
        firstId := this.svc.GetRunId()

        ; Does it publish RunReset?
        resetEvents := this._CaptureEvents(Events.RunReset)
        this.svc.NewRun()
        Assert.True(resetEvents.Length >= 1, "ResetRun was called before NewRun")
        Assert.Equal(firstId, resetEvents[1]["runId"],
            "Reset published with the previous run's runId")
    }

    new_run_persists_to_state_repo()
    {
        this.svc.NewRun()
        ; Verifies via fresh read from the repo
        freshRepo := RunStateRepository(IniFile(this.repoPath))
        loaded := freshRepo.Load()
        Assert.Equal(this.svc.GetRunId(), loaded.runId)
        Assert.Equal("running", loaded.status)
    }

    ; ============================================================
    ; FinalizeRun
    ; ============================================================

    finalize_returns_false_when_not_active()
    {
        Assert.False(this.svc.FinalizeRun())
    }

    finalize_returns_true_when_active()
    {
        this.svc.NewRun()
        Assert.True(this.svc.FinalizeRun())
    }

    finalize_sets_status_to_completed()
    {
        this.svc.NewRun()
        this.svc.FinalizeRun()
        Assert.Equal("completed", this.svc.GetStatus())
        Assert.False(this.svc.IsActive())
    }

    finalize_stops_timer()
    {
        this.svc.NewRun()
        this.svc.FinalizeRun()
        Assert.False(this.timerSvc.IsActive())
    }

    finalize_publishes_run_completed_event()
    {
        this.svc.NewRun()
        capturedEvents := this._CaptureEvents(Events.RunCompleted)
        this.svc.FinalizeRun()
        Assert.Equal(1, capturedEvents.Length)
    }

    finalize_event_includes_run_id()
    {
        this.svc.NewRun()
        producedId := this.svc.GetRunId()
        capturedEvents := this._CaptureEvents(Events.RunCompleted)
        this.svc.FinalizeRun()
        Assert.Equal(producedId, capturedEvents[1]["runId"])
    }

    finalize_event_includes_duration_ms()
    {
        this.svc.NewRun()
        this.stubClock.AdvanceMs(5000)
        capturedEvents := this._CaptureEvents(Events.RunCompleted)
        this.svc.FinalizeRun()
        Assert.Equal(5000, capturedEvents[1]["durationMs"])
    }

    finalize_persists_status_to_repo()
    {
        this.svc.NewRun()
        this.svc.FinalizeRun()
        freshRepo := RunStateRepository(IniFile(this.repoPath))
        loaded := freshRepo.Load()
        Assert.Equal("completed", loaded.status)
    }

    ; ============================================================
    ; CancelRun
    ; ============================================================

    cancel_returns_false_when_not_active()
    {
        Assert.False(this.svc.CancelRun())
    }

    cancel_returns_true_when_active()
    {
        this.svc.NewRun()
        Assert.True(this.svc.CancelRun())
    }

    cancel_sets_status_to_cancelled()
    {
        this.svc.NewRun()
        this.svc.CancelRun()
        Assert.Equal("cancelled", this.svc.GetStatus())
        Assert.False(this.svc.IsActive())
    }

    cancel_stops_timer()
    {
        this.svc.NewRun()
        this.svc.CancelRun()
        Assert.False(this.timerSvc.IsActive())
    }

    cancel_publishes_run_cancelled_event()
    {
        this.svc.NewRun()
        capturedEvents := this._CaptureEvents(Events.RunCancelled)
        this.svc.CancelRun()
        Assert.Equal(1, capturedEvents.Length)
    }

    cancel_event_includes_run_id()
    {
        this.svc.NewRun()
        producedId := this.svc.GetRunId()
        capturedEvents := this._CaptureEvents(Events.RunCancelled)
        this.svc.CancelRun()
        Assert.Equal(producedId, capturedEvents[1]["runId"])
    }

    cancel_persists_status_to_repo()
    {
        this.svc.NewRun()
        this.svc.CancelRun()
        freshRepo := RunStateRepository(IniFile(this.repoPath))
        loaded := freshRepo.Load()
        Assert.Equal("cancelled", loaded.status)
    }

    ; ============================================================
    ; ResetRun
    ; ============================================================

    reset_clears_run_id()
    {
        this.svc.NewRun()
        this.svc.ResetRun()
        Assert.Equal("", this.svc.GetRunId())
        Assert.Equal("idle", this.svc.GetStatus())
    }

    reset_resets_timer()
    {
        this.svc.NewRun()
        this.stubClock.AdvanceMs(5000)
        this.svc.ResetRun()
        Assert.Equal(0, this.timerSvc.GetRunMs())
        Assert.False(this.timerSvc.IsActive())
    }

    reset_clears_state_repo()
    {
        this.svc.NewRun()
        this.svc.ResetRun()
        ; After Reset, the repo must be empty (Load returns RunState.Empty equivalent)
        freshRepo := RunStateRepository(IniFile(this.repoPath))
        loaded := freshRepo.Load()
        Assert.Equal("", loaded.runId, "Repo cleared after Reset")
    }

    reset_publishes_run_reset_event()
    {
        this.svc.NewRun()
        capturedEvents := this._CaptureEvents(Events.RunReset)
        this.svc.ResetRun()
        Assert.Equal(1, capturedEvents.Length)
    }

    reset_event_includes_previous_run_id()
    {
        this.svc.NewRun()
        producedId := this.svc.GetRunId()
        capturedEvents := this._CaptureEvents(Events.RunReset)
        this.svc.ResetRun()
        Assert.Equal(producedId, capturedEvents[1]["runId"])
    }

    reset_when_no_active_run_still_works()
    {
        capturedEvents := this._CaptureEvents(Events.RunReset)
        result := this.svc.ResetRun()
        Assert.True(result, "ResetRun always returns true (idempotent)")
        Assert.Equal(1, capturedEvents.Length)
    }

    ; ============================================================
    ; Hydrate
    ; ============================================================

    hydrate_throws_on_non_run_state()
    {
        s := this.svc
        Assert.Throws(TypeError, () => s.Hydrate("not run state"))
        Assert.Throws(TypeError, () => s.Hydrate(Map()))
    }

    hydrate_restores_state()
    {
        state := RunState.Empty()
        state.runId     := "20260515_103045_873"
        state.startedAt := "2026-05-15 10:30:45"
        state.status    := "running"
        state.runBaseMs := 300000

        this.svc.Hydrate(state)
        Assert.Equal("20260515_103045_873", this.svc.GetRunId())
        Assert.Equal("running",              this.svc.GetStatus())
    }

    hydrate_with_running_status_resumes_timer_running()
    {
        state := RunState.Empty()
        state.runId     := "run_x"
        state.status    := "running"
        state.runBaseMs := 60000

        this.svc.Hydrate(state)
        Assert.True(this.timerSvc.IsActive())
        Assert.True(this.timerSvc.IsRunning())
        ; runBaseMs preserved; new delta adds when clock advances
        this.stubClock.AdvanceMs(5000)
        Assert.Equal(65000, this.timerSvc.GetRunMs(),
            "60000 baseMs + 5000 new delta")
    }

    hydrate_with_paused_status_keeps_timer_paused()
    {
        state := RunState.Empty()
        state.runId     := "run_x"
        state.status    := "paused"
        state.runBaseMs := 60000

        this.svc.Hydrate(state)
        Assert.True(this.timerSvc.IsActive())
        Assert.True(this.timerSvc.IsPaused())
        ; Paused: time doesn't advance
        this.stubClock.AdvanceMs(10000)
        Assert.Equal(60000, this.timerSvc.GetRunMs(), "Paused: base preserved")
    }

    hydrate_with_stopped_status_keeps_timer_stopped()
    {
        state := RunState.Empty()
        state.runId     := "run_x"
        state.status    := "completed"
        state.runBaseMs := 60000

        this.svc.Hydrate(state)
        Assert.False(this.timerSvc.IsActive())
    }

    hydrate_active_state_publishes_run_started()
    {
        state := RunState.Empty()
        state.runId  := "run_x"
        state.status := "running"

        capturedEvents := this._CaptureEvents(Events.RunStarted)
        this.svc.Hydrate(state)
        Assert.Equal(1, capturedEvents.Length)
    }

    hydrate_event_has_hydrated_true_flag()
    {
        state := RunState.Empty()
        state.runId  := "run_x"
        state.status := "running"

        capturedEvents := this._CaptureEvents(Events.RunStarted)
        this.svc.Hydrate(state)
        Assert.True(capturedEvents[1]["hydrated"],
            "Hydrate publishes RunStarted with hydrated=true to distinguish from NewRun")
    }

    hydrate_inactive_state_does_not_publish_run_started()
    {
        state := RunState.Empty()
        state.runId  := "run_x"
        state.status := "completed"

        capturedEvents := this._CaptureEvents(Events.RunStarted)
        this.svc.Hydrate(state)
        Assert.Equal(0, capturedEvents.Length,
            "Inactive status: doesn't publish RunStarted")
    }

    ; ============================================================
    ; PersistTimer
    ; ============================================================

    persist_timer_no_op_when_not_active()
    {
        ; Idle: nothing happens, nothing breaks
        this.svc.PersistTimer()
        ; No errors, no state changes
        Assert.Equal("", this.svc.GetRunId())
    }

    persist_timer_updates_run_base_ms_when_active()
    {
        this.svc.NewRun()
        this.stubClock.AdvanceMs(7500)
        this.svc.PersistTimer()
        ; Verifies via disk read
        freshRepo := RunStateRepository(IniFile(this.repoPath))
        loaded := freshRepo.Load()
        Assert.Equal(7500, loaded.runBaseMs)
    }

    persist_tick_alias_calls_persist_timer()
    {
        ; PersistTick is an alias for PersistTimer
        this.svc.NewRun()
        this.stubClock.AdvanceMs(3000)
        this.svc.PersistTick()
        freshRepo := RunStateRepository(IniFile(this.repoPath))
        loaded := freshRepo.Load()
        Assert.Equal(3000, loaded.runBaseMs)
    }

    ; ============================================================
    ; Subscribers (Commands)
    ; ============================================================

    new_run_requested_command_triggers_new_run()
    {
        this.bus.Publish(Commands.NewRunRequested, Map())
        Assert.True(this.svc.IsActive())
        Assert.Equal("running", this.svc.GetStatus())
    }

    finalize_run_requested_triggers_finalize()
    {
        this.svc.NewRun()
        this.bus.Publish(Commands.FinalizeRunRequested, Map())
        Assert.Equal("completed", this.svc.GetStatus())
    }

    cancel_run_requested_triggers_cancel()
    {
        this.svc.NewRun()
        this.bus.Publish(Commands.CancelRunRequested, Map())
        Assert.Equal("cancelled", this.svc.GetStatus())
    }

    reset_run_requested_triggers_reset()
    {
        this.svc.NewRun()
        this.bus.Publish(Commands.ResetRunRequested, Map())
        Assert.Equal("", this.svc.GetRunId())
        Assert.Equal("idle", this.svc.GetStatus())
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_all_commands()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Commands.NewRunRequested))
        Assert.Equal(0, this.bus.Subscribers(Commands.FinalizeRunRequested))
        Assert.Equal(0, this.bus.Subscribers(Commands.CancelRunRequested))
        Assert.Equal(0, this.bus.Subscribers(Commands.ResetRunRequested))
    }

    dispose_is_idempotent()
    {
        this.svc.Dispose()
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Commands.NewRunRequested))
    }
}

TestRegistry.Register(RunServiceTests)
