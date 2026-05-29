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

; Test helper: RunStateRepository subclass whose Save throws on
; demand. Used to verify the lifecycle-persist warn path (a
; mid-lifecycle disk failure must surface in the log so the
; silent-data-loss footgun doesn't return).
class _ThrowingRunStateRepository extends RunStateRepository
{
    _throwNext := false

    ThrowOnNextSave()
    {
        this._throwNext := true
    }

    Save(state)
    {
        if this._throwNext
        {
            this._throwNext := false
            throw Error("_ThrowingRunStateRepository: forced Save failure")
        }
        super.Save(state)
    }
}

; Minimal stub for ActCheckpointTracker used by the B2 Ctrl+5
; routing tests. The routing handler only reads
; GetLastCompleteCheckpointMs() — everything else (Reset,
; CaptureCurrentAsCheckpoint, the lifecycle subscriptions) is
; irrelevant to the routing decision, so this stub keeps the
; surface area minimal. Seed via SetCheckpointsByStage with the
; same Map<"act|stage", ms> shape ActCheckpointTracker exposes.
class _RunServiceStubActCheckpoints
{
    _checkpointsByStage := ""

    __New()
    {
        this._checkpointsByStage := Map()
    }

    SetCheckpointsByStage(map)
    {
        this._checkpointsByStage := map
    }

    GetLastCompleteCheckpointMs()
    {
        maxMs := 0
        for _, ms in this._checkpointsByStage
        {
            if (IsNumber(ms) && ms > maxMs)
                maxMs := Integer(ms)
        }
        return maxMs
    }
}

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
        "constructor_accepts_optional_log",

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
        "finalize_invokes_on_before_finalize_before_publishing",
        "finalize_does_not_invoke_hook_when_not_active",
        "finalize_publishes_run_completed_even_when_hook_throws",

        ; --- CancelRun ---
        "cancel_returns_false_when_not_active",
        "cancel_returns_true_when_active",
        "cancel_sets_status_to_cancelled",
        "cancel_stops_timer",
        "cancel_publishes_run_cancelled_event",
        "cancel_event_includes_run_id",
        "cancel_persists_status_to_repo",
        "cancel_invokes_on_before_cancel_before_publishing",
        "cancel_does_not_invoke_hook_when_not_active",
        "cancel_publishes_run_cancelled_even_when_hook_throws",

        ; --- ResetRun ---
        "reset_clears_run_id",
        "reset_resets_timer",
        "reset_clears_state_repo",
        "reset_publishes_run_reset_event",
        "reset_event_includes_previous_run_id",
        "reset_when_no_active_run_still_works",
        "reset_publishes_run_outcome_when_active",
        "reset_outcome_carries_pre_reset_duration",
        "reset_outcome_pb_changed_is_always_false",
        "reset_does_not_publish_outcome_when_idle",
        "reset_outcome_runs_after_run_reset_in_order",

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

        ; --- B2 Ctrl+5 routing ---
        "routing_idle_calls_reset_without_confirm",
        "routing_with_complete_act_calls_cancel",
        "routing_with_complete_act_does_not_invoke_confirm",
        "routing_no_complete_act_yes_confirm_calls_reset",
        "routing_no_complete_act_no_confirm_preserves_run",
        "routing_no_actCheckpoints_dep_falls_through_to_confirm",
        "constructor_default_confirm_fn_returns_yes_for_back_compat",

        ; --- Pre-publish hooks (SetOnBeforeFinalize / SetOnBeforeCancel) ---
        "set_on_before_finalize_throws_when_callback_not_callable",
        "set_on_before_cancel_throws_when_callback_not_callable",
        "set_on_before_finalize_accepts_empty_string_to_clear",
        "hook_throw_is_warned_through_log",

        ; --- Lifecycle persistence failure ---
        "lifecycle_persist_failure_warns_through_log",
        "lifecycle_persist_failure_sets_degraded_flag",
        "lifecycle_persist_success_after_failure_clears_degraded_flag",
        "lifecycle_persist_traytip_rate_limited_to_one_per_60s",
        "lifecycle_persist_publishes_health_event_on_first_failure_only",
        "lifecycle_persist_publishes_health_event_with_degraded_false_on_recovery",
        "lifecycle_persist_success_when_healthy_does_not_publish_health_event",

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

    constructor_accepts_optional_log()
    {
        ; The log parameter is optional (5th, defaults to a NullLogger
        ; built internally). Confirms the construction path with an
        ; explicit logger doesn't break and the service is still wired
        ; correctly. Used by the composition root to route hook-throw
        ; warns into speedkalandra.log.
        freshBus    := Fixtures.MakeBus()
        freshTimer  := TimerService(this.stubClock, freshBus)
        freshRepoP  := Fixtures.TempPath("ini")
        freshRepo   := RunStateRepository(IniFile(freshRepoP))
        memLog      := InMemoryLogger()
        freshSvc    := RunService(this.stubClock, freshBus, freshTimer, freshRepo, memLog)

        Assert.True(IsObject(freshSvc), "constructor with explicit log returns object")
        Assert.Equal(1, freshBus.Subscribers(Commands.NewRunRequested),
            "subscriptions are wired even with explicit log")

        try freshSvc.Dispose()
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
        ; NewRun with an active run calls ResetRun (discards
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

    finalize_invokes_on_before_finalize_before_publishing()
    {
        ; The whole point of the hook: it must run BEFORE Publish(RunCompleted)
        ; so collaborators that subscribe to RunCompleted see the same
        ; in-memory state the hook saw. Verified by recording the call
        ; order: "hook" must come before "publish".
        callOrder := []
        this.svc.SetOnBeforeFinalize(() => callOrder.Push("hook"))
        this.bus.Subscribe(Events.RunCompleted, (data) => callOrder.Push("publish"))

        this.svc.NewRun()
        this.svc.FinalizeRun()

        Assert.Equal(2, callOrder.Length, "both hook and publish ran")
        Assert.Equal("hook",    callOrder[1], "hook ran first")
        Assert.Equal("publish", callOrder[2], "publish ran after hook")
    }

    finalize_does_not_invoke_hook_when_not_active()
    {
        ; FinalizeRun on idle state returns false early; the hook
        ; shouldn't run — there's no run to save.
        hookRan := false
        this.svc.SetOnBeforeFinalize(() => hookRan := true)

        result := this.svc.FinalizeRun()

        Assert.False(result, "finalize returns false on idle state")
        Assert.False(hookRan, "hook does not fire when state is idle")
    }

    finalize_publishes_run_completed_even_when_hook_throws()
    {
        ; Defensive contract: a throw inside the hook must not block
        ; the lifecycle event. Widgets, state-clearers, and any other
        ; subscriber of RunCompleted still need to react when the run
        ; is finalized — a misbehaving Save can't stop the run from
        ; ending in the user's perception.
        this.svc.SetOnBeforeFinalize(() => RunServiceTests._ThrowSimulated())   ; provokes a throw
        publishCount := 0
        this.bus.Subscribe(Events.RunCompleted, (data) => publishCount += 1)

        this.svc.NewRun()
        this.svc.FinalizeRun()

        Assert.Equal(1, publishCount, "RunCompleted fired despite hook throw")
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

    cancel_invokes_on_before_cancel_before_publishing()
    {
        ; Same contract as finalize — but more critical here, since
        ; ZoneTrackingService and RunStatsRecorder DO clear their
        ; state on RunCancelled. The hook is the only safe point to
        ; capture totals for a saved long-cancelled run.
        callOrder := []
        this.svc.SetOnBeforeCancel(() => callOrder.Push("hook"))
        this.bus.Subscribe(Events.RunCancelled, (data) => callOrder.Push("publish"))

        this.svc.NewRun()
        this.svc.CancelRun()

        Assert.Equal(2, callOrder.Length)
        Assert.Equal("hook",    callOrder[1])
        Assert.Equal("publish", callOrder[2])
    }

    cancel_does_not_invoke_hook_when_not_active()
    {
        hookRan := false
        this.svc.SetOnBeforeCancel(() => hookRan := true)

        result := this.svc.CancelRun()

        Assert.False(result)
        Assert.False(hookRan, "hook does not fire on idle cancel")
    }

    cancel_publishes_run_cancelled_even_when_hook_throws()
    {
        this.svc.SetOnBeforeCancel(() => RunServiceTests._ThrowSimulated())
        publishCount := 0
        this.bus.Subscribe(Events.RunCancelled, (data) => publishCount += 1)

        this.svc.NewRun()
        this.svc.CancelRun()

        Assert.Equal(1, publishCount, "RunCancelled fired despite hook throw")
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

    ; ----- RunOutcomeReported on reset -----
    ; ResetRun on an active run publishes Evt.RunOutcomeReported
    ; with outcome="reset" so the banner can surface "RESET ·
    ; NOT SAVED" to the user. The duration is captured BEFORE
    ; timer.Reset clears it, so the event reflects what the run
    ; actually was — not the post-reset zero. On idle state the
    ; event is NOT published, since a reset-of-nothing has no
    ; user-meaningful outcome.

    reset_publishes_run_outcome_when_active()
    {
        this.svc.NewRun()
        captured := this._CaptureEvents(Events.RunOutcomeReported)
        this.svc.ResetRun()

        Assert.Equal(1, captured.Length,
            "Active reset must publish exactly one outcome event")
        Assert.Equal("reset", captured[1]["outcome"])
    }

    reset_outcome_carries_pre_reset_duration()
    {
        ; The duration on the event is the runMs measured BEFORE
        ; timer.Reset() clears it. Without this, the banner would
        ; render "RESET · 00:00" — useless for the speedrunner who
        ; wants to know how much time they dropped.
        this.svc.NewRun()
        this.stubClock.AdvanceMs(12500)
        captured := this._CaptureEvents(Events.RunOutcomeReported)

        this.svc.ResetRun()

        Assert.Equal(12500, captured[1]["durationMs"],
            "outcome carries the runMs measured just before reset")
    }

    reset_outcome_pb_changed_is_always_false()
    {
        ; pbChanged is meaningful only for outcome="saved". The
        ; other three (dnf, too_short, reset) are always false.
        ; Documents the contract so widgets can rely on the field
        ; existing on every outcome event.
        this.svc.NewRun()
        captured := this._CaptureEvents(Events.RunOutcomeReported)
        this.svc.ResetRun()

        Assert.False(captured[1]["pbChanged"],
            "reset outcome must always carry pbChanged=false")
    }

    reset_does_not_publish_outcome_when_idle()
    {
        ; ResetRun on idle state is a defensive no-op (state was
        ; already empty). No user-meaningful outcome to report —
        ; surfacing "RESET" when nothing was actually reset would
        ; be a UI lie. The RunReset lifecycle event still fires
        ; because subscribers may have idle-state cleanup to do.
        capturedOutcome := this._CaptureEvents(Events.RunOutcomeReported)
        capturedReset   := this._CaptureEvents(Events.RunReset)

        this.svc.ResetRun()

        Assert.Equal(0, capturedOutcome.Length,
            "Idle reset must NOT publish an outcome event")
        Assert.Equal(1, capturedReset.Length,
            "Idle reset still publishes the RunReset lifecycle event")
    }

    reset_outcome_runs_after_run_reset_in_order()
    {
        ; Publish order: Evt.RunReset first, then
        ; Evt.RunOutcomeReported. Subscribers that listen to both
        ; (rare — the banner only listens to the outcome) will see
        ; the lifecycle fact before the user-facing summary.
        ; Pinned because a reordering refactor that publishes
        ; outcome first would break any future subscriber that
        ; reads runId from the lifecycle event before clearing
        ; downstream state on the outcome.
        this.svc.NewRun()
        callOrder := []
        this.bus.Subscribe(Events.RunReset,
            (data) => callOrder.Push("reset"))
        this.bus.Subscribe(Events.RunOutcomeReported,
            (data) => callOrder.Push("outcome"))

        this.svc.ResetRun()

        Assert.Equal(2, callOrder.Length, "both events fired")
        Assert.Equal("reset",   callOrder[1], "RunReset publishes first")
        Assert.Equal("outcome", callOrder[2], "RunOutcomeReported publishes second")
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
    ; B2 Ctrl+5 routing
    ; ============================================================
    ;
    ; The handler subscribed to Cmd.ResetRunRequested routes
    ; between three behaviours based on (a) whether a run is
    ; active and (b) whether any (act, stage) checkpoint has
    ; been captured. Behaviour matrix:
    ;
    ;   IsActive=false                  → ResetRun() (idempotent;
    ;                                                  no prompt)
    ;   IsActive=true, lastComplete>0   → CancelRun() (DNF save
    ;                                                  via the
    ;                                                  snapshot saver;
    ;                                                  no prompt)
    ;   IsActive=true, lastComplete=0   → confirm → ResetRun() on
    ;                                              "Yes", no-op
    ;                                              otherwise
    ;
    ; Both routing deps (actCheckpoints, confirmDiscardFn) are
    ; optional. Missing actCheckpoints → lastComplete treated as 0,
    ; falls through to confirm path. Missing confirmDiscardFn →
    ; default fn returns "Yes" (matches pre-B2 "always discard"
    ; semantic for back-compat with existing tests).

    routing_idle_calls_reset_without_confirm()
    {
        ; Idle state: ResetRun is idempotent cleanup; no
        ; confirmation prompt because there's nothing to lose.
        ; Wire a tracking confirmFn to assert it ISN'T invoked.
        promptCalls := []
        confirmFn := (msg, title) => (promptCalls.Push(title), "Yes")
        actCp := _RunServiceStubActCheckpoints()
        svc := RunService(this.stubClock, this.bus,
            TimerService(this.stubClock, this.bus),
            RunStateRepository(IniFile(Fixtures.TempPath("ini"))),
            "", actCp, confirmFn)
        try
        {
            ; Not active: state is idle from construction.
            this.bus.Publish(Commands.ResetRunRequested, Map())

            Assert.Equal("idle", svc.GetStatus())
            Assert.Equal(0, promptCalls.Length,
                "Confirm fn must NOT fire when state is already idle")
        }
        finally svc.Dispose()
    }

    routing_with_complete_act_calls_cancel()
    {
        ; Active run with ≥1 complete (act, stage) bucket. Ctrl+5
        ; saves as DNF (via CancelRun) instead of discarding. The
        ; resulting state must be "cancelled" — same outcome as a
        ; direct CancelRun call.
        actCp := _RunServiceStubActCheckpoints()
        actCp.SetCheckpointsByStage(Map("1|normal", 300000))

        svc := RunService(this.stubClock, this.bus,
            TimerService(this.stubClock, this.bus),
            RunStateRepository(IniFile(Fixtures.TempPath("ini"))),
            "", actCp, "")
        try
        {
            svc.NewRun()
            this.bus.Publish(Commands.ResetRunRequested, Map())

            Assert.Equal("cancelled", svc.GetStatus(),
                "Run with complete act routes Ctrl+5 to CancelRun, not ResetRun")
        }
        finally svc.Dispose()
    }

    routing_with_complete_act_does_not_invoke_confirm()
    {
        ; Symmetric to the idle test: with complete acts the work
        ; is preserved (CancelRun saves a DNF), so the confirm
        ; prompt would be misplaced friction.
        promptCalls := []
        confirmFn := (msg, title) => (promptCalls.Push(title), "Yes")
        actCp := _RunServiceStubActCheckpoints()
        actCp.SetCheckpointsByStage(Map("1|normal", 300000))

        svc := RunService(this.stubClock, this.bus,
            TimerService(this.stubClock, this.bus),
            RunStateRepository(IniFile(Fixtures.TempPath("ini"))),
            "", actCp, confirmFn)
        try
        {
            svc.NewRun()
            this.bus.Publish(Commands.ResetRunRequested, Map())

            Assert.Equal(0, promptCalls.Length,
                "Cancel path is non-destructive; no prompt fires")
        }
        finally svc.Dispose()
    }

    routing_no_complete_act_yes_confirm_calls_reset()
    {
        ; Active run with no captured checkpoint (user gave up
        ; mid-Act 1). Destructive path — confirm fires, returns
        ; "Yes", ResetRun runs.
        actCp := _RunServiceStubActCheckpoints()
        ; checkpointsByStage stays empty.
        confirmFn := (msg, title) => "Yes"
        svc := RunService(this.stubClock, this.bus,
            TimerService(this.stubClock, this.bus),
            RunStateRepository(IniFile(Fixtures.TempPath("ini"))),
            "", actCp, confirmFn)
        try
        {
            svc.NewRun()
            this.bus.Publish(Commands.ResetRunRequested, Map())

            Assert.Equal("idle", svc.GetStatus(),
                "User confirmed discard → run resets to idle")
            Assert.Equal("", svc.GetRunId())
        }
        finally svc.Dispose()
    }

    routing_no_complete_act_no_confirm_preserves_run()
    {
        ; Same destructive path, but the user dismisses the
        ; prompt. The run stays active — no state change.
        actCp := _RunServiceStubActCheckpoints()
        confirmFn := (msg, title) => "No"
        svc := RunService(this.stubClock, this.bus,
            TimerService(this.stubClock, this.bus),
            RunStateRepository(IniFile(Fixtures.TempPath("ini"))),
            "", actCp, confirmFn)
        try
        {
            svc.NewRun()
            preserveRunId := svc.GetRunId()
            this.bus.Publish(Commands.ResetRunRequested, Map())

            Assert.Equal("running", svc.GetStatus(),
                "User dismissed prompt → active run preserved")
            Assert.Equal(preserveRunId, svc.GetRunId(),
                "runId unchanged when user cancels the discard")
        }
        finally svc.Dispose()
    }

    routing_no_actCheckpoints_dep_falls_through_to_confirm()
    {
        ; Back-compat: callers that don't wire actCheckpoints get
        ; lastComplete=0 implicitly (the IsObject guard skips the
        ; query entirely). The destructive path runs the confirm
        ; fn just like the explicit-empty case above.
        promptCalls := []
        confirmFn := (msg, title) => (promptCalls.Push(title), "Yes")
        svc := RunService(this.stubClock, this.bus,
            TimerService(this.stubClock, this.bus),
            RunStateRepository(IniFile(Fixtures.TempPath("ini"))),
            "", "", confirmFn)   ; actCheckpoints intentionally ""
        try
        {
            svc.NewRun()
            this.bus.Publish(Commands.ResetRunRequested, Map())

            Assert.Equal(1, promptCalls.Length,
                "Missing actCheckpoints dep falls through to the prompt path")
            Assert.Equal("idle", svc.GetStatus(),
                "Confirm fn returned 'Yes', ResetRun ran")
        }
        finally svc.Dispose()
    }

    constructor_default_confirm_fn_returns_yes_for_back_compat()
    {
        ; Critical back-compat invariant: the ~hundreds of existing
        ; tests that publish Cmd.ResetRunRequested without injecting
        ; a confirmFn rely on the default fn returning "Yes". This
        ; test pins that default at the constructor level so a
        ; future change to the default (e.g. swap to "Cancel" out
        ; of an excess of caution) shows up as a single explicit
        ; failure here rather than a cascade across the suite.
        svc := RunService(this.stubClock, this.bus,
            TimerService(this.stubClock, this.bus),
            RunStateRepository(IniFile(Fixtures.TempPath("ini"))))
        try
        {
            svc.NewRun()
            this.bus.Publish(Commands.ResetRunRequested, Map())

            Assert.Equal("idle", svc.GetStatus(),
                "Default confirmFn returns 'Yes' → ResetRun runs unconditionally")
        }
        finally svc.Dispose()
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

    ; ============================================================
    ; Pre-publish hooks (SetOnBeforeFinalize / SetOnBeforeCancel)
    ; ============================================================

    set_on_before_finalize_throws_when_callback_not_callable()
    {
        ; Fail-fast at wiring time. A wiring bug that passes a Map
        ; (or some plausible-looking object) must trip here, not at
        ; the next FinalizeRun call when the run is mid-flight.
        s := this.svc
        Assert.Throws(TypeError, () => s.SetOnBeforeFinalize("not callable"))
        Assert.Throws(TypeError, () => s.SetOnBeforeFinalize(Map("not", "a func")))
        Assert.Throws(TypeError, () => s.SetOnBeforeFinalize(42))
    }

    set_on_before_cancel_throws_when_callback_not_callable()
    {
        s := this.svc
        Assert.Throws(TypeError, () => s.SetOnBeforeCancel("not callable"))
        Assert.Throws(TypeError, () => s.SetOnBeforeCancel(Map("not", "a func")))
        Assert.Throws(TypeError, () => s.SetOnBeforeCancel(42))
    }

    set_on_before_finalize_accepts_empty_string_to_clear()
    {
        ; Empty string is the "unwired" sentinel — setters accept it
        ; so a caller can deliberately clear a previously-installed
        ; hook. After clearing, FinalizeRun runs but doesn't invoke
        ; anything.
        hookRan := false
        this.svc.SetOnBeforeFinalize(() => hookRan := true)
        this.svc.SetOnBeforeFinalize("")   ; clear

        this.svc.NewRun()
        this.svc.FinalizeRun()

        Assert.False(hookRan, "cleared hook does not fire on FinalizeRun")
    }

    hook_throw_is_warned_through_log()
    {
        ; A throw from a hook is caught and surfaced as a WARN through
        ; the injected logger. Production wires LogService here so a
        ; misbehaving Save shows up in speedkalandra.log with the hook
        ; name ("OnBeforeFinalize" / "OnBeforeCancel") and the
        ; exception message.
        freshBus    := Fixtures.MakeBus()
        freshTimer  := TimerService(this.stubClock, freshBus)
        freshRepoP  := Fixtures.TempPath("ini")
        freshRepo   := RunStateRepository(IniFile(freshRepoP))
        memLog      := InMemoryLogger()
        freshSvc    := RunService(this.stubClock, freshBus, freshTimer, freshRepo, memLog)

        freshSvc.SetOnBeforeFinalize(() => RunServiceTests._ThrowSimulated())
        freshSvc.NewRun()
        freshSvc.FinalizeRun()

        Assert.True(memLog.HasEntry("WARN", "OnBeforeFinalize threw"),
            "warn carries the hook name")

        try freshSvc.Dispose()
    }

    ; Static helper to provide a callable throw that AHK v2 lambdas
    ; can reference (a lambda body `() => throw X` is a parse error in
    ; v2 because `throw` is a statement, not an expression).
    static _ThrowSimulated()
    {
        throw Error("simulated hook failure")
    }

    ; ============================================================
    ; Lifecycle persistence failure (silent-save guard)
    ; ============================================================

    lifecycle_persist_failure_warns_through_log()
    {
        ; The silent `try this._stateRepo.Save(...)` in _Persist was
        ; flagged in a senior review: a failed lifecycle save means
        ; crash recovery will see stale data on the next boot, and
        ; the user would never know. The fix wraps the call in a
        ; real try/catch + warn through the injected logger. This
        ; test pins that contract.
        ;
        ; PersistTimer (every-5s) stays silent on purpose — the next
        ; tick retries and warning per tick would flood the log. The
        ; warn lives on the lifecycle path only.
        freshBus    := Fixtures.MakeBus()
        freshTimer  := TimerService(this.stubClock, freshBus)
        freshRepoP  := Fixtures.TempPath("ini")
        throwingRepo := _ThrowingRunStateRepository(IniFile(freshRepoP))
        memLog      := InMemoryLogger()
        freshSvc    := RunService(this.stubClock, freshBus, freshTimer, throwingRepo, memLog)

        ; Force the next Save (called inside NewRun → _Persist) to throw.
        throwingRepo.ThrowOnNextSave()
        freshSvc.NewRun()   ; must NOT propagate the throw; bus/runtime stays alive

        Assert.True(memLog.HasEntry("WARN", "Lifecycle persist failed"),
            "_Persist surfaces save failure through the log")
        Assert.True(freshSvc.IsActive(),
            "NewRun still succeeds in memory despite a failed lifecycle persist")

        try freshSvc.Dispose()
    }

    lifecycle_persist_failure_sets_degraded_flag()
    {
        ; The persistence-degraded contract: a failed lifecycle
        ; persist must (a) set IsPersistenceDegraded() to true so
        ; UI/tray can surface stale crash recovery, and (b) fire
        ; exactly one TrayTip on first failure (cooldown gate
        ; passes because the sentinel init is -60000).
        freshBus     := Fixtures.MakeBus()
        freshTimer   := TimerService(this.stubClock, freshBus)
        freshRepoP   := Fixtures.TempPath("ini")
        throwingRepo := _ThrowingRunStateRepository(IniFile(freshRepoP))
        memLog       := InMemoryLogger()
        freshSvc     := RunService(this.stubClock, freshBus, freshTimer, throwingRepo, memLog)

        Assert.False(freshSvc.IsPersistenceDegraded(),
            "degraded flag is false before any save runs")
        Assert.Equal(0, freshSvc.GetPersistenceTrayTipCount(),
            "TrayTip count is 0 before any save runs")

        throwingRepo.ThrowOnNextSave()
        freshSvc.NewRun()

        Assert.True(freshSvc.IsPersistenceDegraded(),
            "degraded flag must flip to true after a failed lifecycle persist")
        Assert.Equal(1, freshSvc.GetPersistenceTrayTipCount(),
            "first failure must fire exactly one TrayTip (sentinel init lets it pass the gate)")

        try freshSvc.Dispose()
    }

    lifecycle_persist_success_after_failure_clears_degraded_flag()
    {
        ; Recovery contract: once a subsequent lifecycle persist
        ; succeeds, the degraded flag clears and the log carries
        ; an Info entry marking the recovery so a log tail shows
        ; the transition explicitly.
        freshBus     := Fixtures.MakeBus()
        freshTimer   := TimerService(this.stubClock, freshBus)
        freshRepoP   := Fixtures.TempPath("ini")
        throwingRepo := _ThrowingRunStateRepository(IniFile(freshRepoP))
        memLog       := InMemoryLogger()
        freshSvc     := RunService(this.stubClock, freshBus, freshTimer, throwingRepo, memLog)

        ; First persist fails -> degraded.
        throwingRepo.ThrowOnNextSave()
        freshSvc.NewRun()
        Assert.True(freshSvc.IsPersistenceDegraded(),
            "precondition: degraded after first failure")

        ; FinalizeRun's _Persist call runs without a queued throw,
        ; so the underlying RunStateRepository.Save succeeds. The
        ; degraded flag must clear and an Info entry must show up.
        freshSvc.FinalizeRun()

        Assert.False(freshSvc.IsPersistenceDegraded(),
            "degraded flag must clear after a successful lifecycle persist")
        Assert.True(memLog.HasEntry("INFO", "Lifecycle persist recovered"),
            "recovery must be logged at INFO so a log tail shows the transition")

        try freshSvc.Dispose()
    }

    lifecycle_persist_traytip_rate_limited_to_one_per_60s()
    {
        ; Throttle contract: at most one TrayTip per 60 s window.
        ; Without this, a transient lock (antivirus, OneDrive sync)
        ; could burst 3+ notifications across a NewRun -> Finalize
        ; -> NewRun sequence in a couple of seconds.
        ;
        ; Setup baseline at clock=10000 (Setup's fake clock init).
        ; Sentinel _lastDegradedTrayTipMs=-60000 means diff=70000
        ; on the first check -> passes the 60000 ms cooldown gate
        ; and fires. After firing, last := 10000.
        ;
        ; +30 s -> clock=40000, diff=30000 -> blocked.
        ; +31 s -> clock=71000, diff=61000 -> passes gate, fires.
        freshBus     := Fixtures.MakeBus()
        freshTimer   := TimerService(this.stubClock, freshBus)
        freshRepoP   := Fixtures.TempPath("ini")
        throwingRepo := _ThrowingRunStateRepository(IniFile(freshRepoP))
        memLog       := InMemoryLogger()
        freshSvc     := RunService(this.stubClock, freshBus, freshTimer, throwingRepo, memLog)

        ; First failure at clock=10000 -> fires (sentinel gate).
        throwingRepo.ThrowOnNextSave()
        freshSvc.NewRun()
        Assert.Equal(1, freshSvc.GetPersistenceTrayTipCount(),
            "first failure must fire exactly one TrayTip")

        ; Advance 30 s. Second failure at clock=40000.
        ; diff = 40000 - 10000 = 30000 ms < 60000 ms cooldown.
        ; TrayTip must NOT fire; the flag stays degraded; log
        ; still records the WARN.
        this.stubClock.AdvanceMs(30000)
        throwingRepo.ThrowOnNextSave()
        freshSvc.FinalizeRun()
        Assert.Equal(1, freshSvc.GetPersistenceTrayTipCount(),
            "second failure within the 60 s window must NOT fire a TrayTip")
        Assert.True(freshSvc.IsPersistenceDegraded(),
            "degraded flag stays set across consecutive failures")

        ; Advance 31 s more (total +61 s vs first fire). Third
        ; failure at clock=71000. diff = 71000 - 10000 = 61000
        ; ms >= 60000 ms cooldown. TrayTip must fire again.
        this.stubClock.AdvanceMs(31000)
        throwingRepo.ThrowOnNextSave()
        freshSvc.NewRun()
        Assert.Equal(2, freshSvc.GetPersistenceTrayTipCount(),
            "third failure after the cooldown window must fire a second TrayTip")

        try freshSvc.Dispose()
    }

    lifecycle_persist_publishes_health_event_on_first_failure_only()
    {
        ; PersistenceHealthChanged must fire exactly ONCE on the
        ; first failure (false→true transition) and stay silent
        ; on subsequent failures while already degraded. UI/tray
        ; subscribers track *state*, not *attempts* — republishing
        ; on every failure would just spam them.
        freshBus     := Fixtures.MakeBus()
        freshTimer   := TimerService(this.stubClock, freshBus)
        freshRepoP   := Fixtures.TempPath("ini")
        throwingRepo := _ThrowingRunStateRepository(IniFile(freshRepoP))
        memLog       := InMemoryLogger()
        freshSvc     := RunService(this.stubClock, freshBus, freshTimer, throwingRepo, memLog)

        captured := []
        freshBus.Subscribe(Events.PersistenceHealthChanged,
            (data) => captured.Push(data))

        ; First failure → publish (false→true).
        throwingRepo.ThrowOnNextSave()
        freshSvc.NewRun()
        Assert.Equal(1, captured.Length,
            "first failure must publish PersistenceHealthChanged")
        Assert.True(captured[1]["degraded"],
            "first publish must carry degraded=true")

        ; Second failure while already degraded → NO publish.
        throwingRepo.ThrowOnNextSave()
        freshSvc.FinalizeRun()
        Assert.Equal(1, captured.Length,
            "second failure (already degraded) must NOT republish")

        try freshSvc.Dispose()
    }

    lifecycle_persist_publishes_health_event_with_degraded_false_on_recovery()
    {
        ; Recovery contract: when a save succeeds after a previous
        ; failure, publish PersistenceHealthChanged{degraded:false}
        ; so the tray-menu indicator (or widget marker) can clear.
        freshBus     := Fixtures.MakeBus()
        freshTimer   := TimerService(this.stubClock, freshBus)
        freshRepoP   := Fixtures.TempPath("ini")
        throwingRepo := _ThrowingRunStateRepository(IniFile(freshRepoP))
        memLog       := InMemoryLogger()
        freshSvc     := RunService(this.stubClock, freshBus, freshTimer, throwingRepo, memLog)

        captured := []
        freshBus.Subscribe(Events.PersistenceHealthChanged,
            (data) => captured.Push(data))

        ; Force first failure.
        throwingRepo.ThrowOnNextSave()
        freshSvc.NewRun()
        Assert.Equal(1, captured.Length, "sanity: first failure published")

        ; Next persist succeeds → recovery publish (true→false).
        freshSvc.FinalizeRun()
        Assert.Equal(2, captured.Length,
            "recovery must publish PersistenceHealthChanged")
        Assert.False(captured[2]["degraded"],
            "recovery publish must carry degraded=false")

        try freshSvc.Dispose()
    }

    lifecycle_persist_success_when_healthy_does_not_publish_health_event()
    {
        ; Happy path sanity: a successful save with no prior
        ; degraded state must NOT publish anything. The event is
        ; for transitions only.
        freshBus     := Fixtures.MakeBus()
        freshTimer   := TimerService(this.stubClock, freshBus)
        freshRepoP   := Fixtures.TempPath("ini")
        freshRepo    := RunStateRepository(IniFile(freshRepoP))   ; real repo, no throws
        memLog       := InMemoryLogger()
        freshSvc     := RunService(this.stubClock, freshBus, freshTimer, freshRepo, memLog)

        captured := []
        freshBus.Subscribe(Events.PersistenceHealthChanged,
            (data) => captured.Push(data))

        freshSvc.NewRun()
        freshSvc.FinalizeRun()

        Assert.Equal(0, captured.Length,
            "successful lifecycle saves must NOT publish health events when never degraded")

        try freshSvc.Dispose()
    }
}

TestRegistry.Register(RunServiceTests)
