; ============================================================
; TimerServiceTests
; ============================================================
;
; TimerService: 3-state state machine with injectable clock + bus.
;   - STOPPED : !_active
;   - RUNNING : _active && !_paused
;   - PAUSED  : _active && _paused
;
; Commands: Start, Pause, Resume, Stop, Reset, Toggle, Hydrate
; Queries:  IsActive, IsRunning, IsPaused, GetRunMs
; Events:   TimerStarted/Paused/Resumed/Stopped/Reset (all via bus)
;
; NOTE: the local variable `events` collides case-insensitively with
; the `Events` CLASS (pitfall #4 of the README). Use `evtLog` instead.
;
; Coverage:
;   - Constructor (clock/bus validation)
;   - Initial queries
;   - Each valid transition + published event
;   - No-ops (command in wrong state: returns false, doesn't publish)
;   - GetRunMs in each state + after pause/resume
;   - Toggle (state machine)
;   - Reset (always publishes)
;   - Hydrate (silent, 3 status hints, defensive)


class TimerServiceTests extends TestCase
{
    bus       := ""
    stubClock := ""
    svc       := ""

    Setup()
    {
        this.bus       := Fixtures.MakeBus()
        this.stubClock := Fixtures.MakeFakeClock(1000)   ; initialMs=1000
        this.svc       := TimerService(this.stubClock, this.bus)
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_clock_missing_now_ms",
        "constructor_throws_when_clock_is_string",
        "constructor_throws_when_bus_not_event_bus",
        "constructor_accepts_valid_clock_and_bus",

        ; --- Initial queries ---
        "is_active_false_initially",
        "is_running_false_initially",
        "is_paused_false_initially",
        "get_run_ms_zero_initially",

        ; --- Start ---
        "start_from_idle_activates_and_returns_true",
        "start_from_idle_publishes_timer_started_with_zero_run_ms",
        "start_when_already_running_returns_false",
        "start_when_already_running_does_not_publish",
        "start_when_paused_returns_false",

        ; --- GetRunMs while RUNNING ---
        "get_run_ms_returns_zero_immediately_after_start",
        "get_run_ms_returns_clock_delta_while_running",
        "get_run_ms_increases_with_clock_advance",

        ; --- Pause ---
        "pause_from_running_returns_true",
        "pause_from_running_marks_as_paused",
        "pause_publishes_timer_paused_with_current_run_ms",
        "pause_when_idle_returns_false",
        "pause_when_already_paused_returns_false",

        ; --- GetRunMs while PAUSED ---
        "get_run_ms_constant_while_paused_after_advance",
        "pause_commits_delta_to_base_ms",

        ; --- Resume ---
        "resume_from_paused_returns_true",
        "resume_marks_as_running_again",
        "resume_publishes_timer_resumed_with_run_ms",
        "resume_when_idle_returns_false",
        "resume_when_running_returns_false",
        "resume_continues_accumulating_after_pause",

        ; --- Stop ---
        "stop_from_running_deactivates",
        "stop_from_paused_deactivates",
        "stop_preserves_base_ms_in_get_run_ms",
        "stop_publishes_timer_stopped_with_base_ms",
        "stop_when_idle_returns_false",

        ; --- Reset ---
        "reset_zeroes_base_ms_and_state",
        "reset_publishes_timer_reset_with_scope_all",
        "reset_works_from_idle",
        "reset_works_from_running",
        "reset_works_from_paused",

        ; --- Toggle ---
        "toggle_idle_calls_start",
        "toggle_running_calls_pause",
        "toggle_paused_calls_resume",

        ; --- Hydrate ---
        "hydrate_default_status_is_stopped",
        "hydrate_running_sets_active_not_paused",
        "hydrate_paused_sets_active_and_paused",
        "hydrate_unknown_status_falls_back_to_stopped",
        "hydrate_running_accumulates_after_clock_advance",
        "hydrate_paused_keeps_run_ms_constant_after_advance",
        "hydrate_clamps_negative_to_zero",
        "hydrate_with_non_number_uses_zero",
        "hydrate_does_not_publish_any_event",

        ; --- AddPenaltyMs (v0.1.3 - death penalty in real-time timer) ---
        "add_penalty_ms_returns_true_with_positive_value",
        "add_penalty_ms_returns_false_with_zero",
        "add_penalty_ms_returns_false_with_negative",
        "add_penalty_ms_returns_false_with_non_number",
        "add_penalty_ms_increases_run_ms_when_running",
        "add_penalty_ms_increases_run_ms_when_paused",
        "add_penalty_ms_increases_run_ms_when_idle",
        "add_penalty_ms_does_not_freeze_running_timer",
        "add_penalty_ms_does_not_publish_any_event",
        "add_penalty_ms_coerces_float_to_int",
        "add_penalty_ms_can_be_applied_multiple_times",
        "add_penalty_ms_zero_does_not_modify_state",
        "add_penalty_ms_persists_through_pause_resume_cycle"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    ; Captures all timer events into an array. Returns the array.
    ; NOTE: handlers hardcoded instead of a loop to avoid the
    ; closure-in-loop bug (AHK v2 captures local variable by reference;
    ; a loop with a closure capturing `localName := nm` makes all 5
    ; handlers see the last value of `localName` = "TimerReset").
    _CaptureAllTimerEvents()
    {
        out := []
        this.bus.Subscribe(Events.TimerStarted,
            (data) => out.Push(Map("event", "TimerStarted", "data", data)))
        this.bus.Subscribe(Events.TimerPaused,
            (data) => out.Push(Map("event", "TimerPaused", "data", data)))
        this.bus.Subscribe(Events.TimerResumed,
            (data) => out.Push(Map("event", "TimerResumed", "data", data)))
        this.bus.Subscribe(Events.TimerStopped,
            (data) => out.Push(Map("event", "TimerStopped", "data", data)))
        this.bus.Subscribe(Events.TimerReset,
            (data) => out.Push(Map("event", "TimerReset", "data", data)))
        return out
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_clock_missing_now_ms()
    {
        ; Object without NowMs
        fakeClockNoMethod := { Now: () => "20260101000000" }
        Assert.Throws(TypeError, () => TimerService(fakeClockNoMethod, this.bus))
    }

    constructor_throws_when_clock_is_string()
    {
        Assert.Throws(TypeError, () => TimerService("not a clock", this.bus))
    }

    constructor_throws_when_bus_not_event_bus()
    {
        clk := this.stubClock
        Assert.Throws(TypeError, () => TimerService(clk, "not a bus"))
    }

    constructor_accepts_valid_clock_and_bus()
    {
        ; Setup already creates svc. Verifies it's operational.
        Assert.False(this.svc.IsActive())
    }

    ; ============================================================
    ; Initial queries
    ; ============================================================

    is_active_false_initially()  => Assert.False(this.svc.IsActive())
    is_running_false_initially() => Assert.False(this.svc.IsRunning())
    is_paused_false_initially()  => Assert.False(this.svc.IsPaused())
    get_run_ms_zero_initially()  => Assert.Equal(0, this.svc.GetRunMs())

    ; ============================================================
    ; Start
    ; ============================================================

    start_from_idle_activates_and_returns_true()
    {
        Assert.True(this.svc.Start())
        Assert.True(this.svc.IsActive())
        Assert.True(this.svc.IsRunning())
        Assert.False(this.svc.IsPaused())
    }

    start_from_idle_publishes_timer_started_with_zero_run_ms()
    {
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Start()
        Assert.Equal(1, evtLog.Length)
        Assert.Equal("TimerStarted", evtLog[1]["event"])
        Assert.Equal(0, evtLog[1]["data"]["runMs"])
    }

    start_when_already_running_returns_false()
    {
        this.svc.Start()
        Assert.False(this.svc.Start())
    }

    start_when_already_running_does_not_publish()
    {
        this.svc.Start()
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Start()
        Assert.Equal(0, evtLog.Length)
    }

    start_when_paused_returns_false()
    {
        this.svc.Start()
        this.svc.Pause()
        Assert.False(this.svc.Start(), "Start in PAUSED is no-op (use Resume)")
    }

    ; ============================================================
    ; GetRunMs while RUNNING
    ; ============================================================

    get_run_ms_returns_zero_immediately_after_start()
    {
        this.svc.Start()
        Assert.Equal(0, this.svc.GetRunMs())
    }

    get_run_ms_returns_clock_delta_while_running()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(2500)
        Assert.Equal(2500, this.svc.GetRunMs())
    }

    get_run_ms_increases_with_clock_advance()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(1000)
        Assert.Equal(1000, this.svc.GetRunMs())
        this.stubClock.AdvanceMs(500)
        Assert.Equal(1500, this.svc.GetRunMs())
    }

    ; ============================================================
    ; Pause
    ; ============================================================

    pause_from_running_returns_true()
    {
        this.svc.Start()
        Assert.True(this.svc.Pause())
    }

    pause_from_running_marks_as_paused()
    {
        this.svc.Start()
        this.svc.Pause()
        Assert.True(this.svc.IsActive())
        Assert.False(this.svc.IsRunning())
        Assert.True(this.svc.IsPaused())
    }

    pause_publishes_timer_paused_with_current_run_ms()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(3000)
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Pause()
        Assert.Equal(1, evtLog.Length)
        Assert.Equal("TimerPaused", evtLog[1]["event"])
        Assert.Equal(3000, evtLog[1]["data"]["runMs"])
    }

    pause_when_idle_returns_false()
    {
        Assert.False(this.svc.Pause())
    }

    pause_when_already_paused_returns_false()
    {
        this.svc.Start()
        this.svc.Pause()
        Assert.False(this.svc.Pause())
    }

    ; ============================================================
    ; GetRunMs while PAUSED
    ; ============================================================

    get_run_ms_constant_while_paused_after_advance()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(2000)
        this.svc.Pause()
        Assert.Equal(2000, this.svc.GetRunMs())

        ; Clock advances but paused: run ms doesn't change
        this.stubClock.AdvanceMs(10000)
        Assert.Equal(2000, this.svc.GetRunMs())
    }

    pause_commits_delta_to_base_ms()
    {
        ; After pause, base_ms = accumulated delta. Even if another
        ; clock advance happens, GetRunMs stays the same.
        this.svc.Start()
        this.stubClock.AdvanceMs(5000)
        this.svc.Pause()
        Assert.Equal(5000, this.svc.GetRunMs())
    }

    ; ============================================================
    ; Resume
    ; ============================================================

    resume_from_paused_returns_true()
    {
        this.svc.Start()
        this.svc.Pause()
        Assert.True(this.svc.Resume())
    }

    resume_marks_as_running_again()
    {
        this.svc.Start()
        this.svc.Pause()
        this.svc.Resume()
        Assert.True(this.svc.IsActive())
        Assert.True(this.svc.IsRunning())
        Assert.False(this.svc.IsPaused())
    }

    resume_publishes_timer_resumed_with_run_ms()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(2000)
        this.svc.Pause()
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Resume()
        Assert.Equal(1, evtLog.Length)
        Assert.Equal("TimerResumed", evtLog[1]["event"])
        Assert.Equal(2000, evtLog[1]["data"]["runMs"])
    }

    resume_when_idle_returns_false()
    {
        Assert.False(this.svc.Resume())
    }

    resume_when_running_returns_false()
    {
        this.svc.Start()
        Assert.False(this.svc.Resume(), "Resume in RUNNING is no-op (use Pause)")
    }

    resume_continues_accumulating_after_pause()
    {
        ; Start at t=1000, advance 2s, Pause (base=2000),
        ; advance 5s (no effect), Resume at t=8000,
        ; advance 1s => GetRunMs = 2000 + 1000 = 3000
        this.svc.Start()
        this.stubClock.AdvanceMs(2000)
        this.svc.Pause()
        this.stubClock.AdvanceMs(5000)
        this.svc.Resume()
        this.stubClock.AdvanceMs(1000)
        Assert.Equal(3000, this.svc.GetRunMs())
    }

    ; ============================================================
    ; Stop
    ; ============================================================

    stop_from_running_deactivates()
    {
        this.svc.Start()
        this.svc.Stop()
        Assert.False(this.svc.IsActive())
        Assert.False(this.svc.IsRunning())
        Assert.False(this.svc.IsPaused())
    }

    stop_from_paused_deactivates()
    {
        this.svc.Start()
        this.svc.Pause()
        this.svc.Stop()
        Assert.False(this.svc.IsActive())
    }

    stop_preserves_base_ms_in_get_run_ms()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(7000)
        this.svc.Stop()
        Assert.Equal(7000, this.svc.GetRunMs())
        ; Clock advance after stop: no change
        this.stubClock.AdvanceMs(10000)
        Assert.Equal(7000, this.svc.GetRunMs())
    }

    stop_publishes_timer_stopped_with_base_ms()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(4000)
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Stop()
        Assert.Equal(1, evtLog.Length)
        Assert.Equal("TimerStopped", evtLog[1]["event"])
        Assert.Equal(4000, evtLog[1]["data"]["runMs"])
    }

    stop_when_idle_returns_false()
    {
        Assert.False(this.svc.Stop())
    }

    ; ============================================================
    ; Reset
    ; ============================================================

    reset_zeroes_base_ms_and_state()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(5000)
        this.svc.Reset()
        Assert.False(this.svc.IsActive())
        Assert.Equal(0, this.svc.GetRunMs())
    }

    reset_publishes_timer_reset_with_scope_all()
    {
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Reset()
        Assert.Equal(1, evtLog.Length)
        Assert.Equal("TimerReset", evtLog[1]["event"])
        Assert.Equal("all", evtLog[1]["data"]["scope"])
    }

    reset_works_from_idle()
    {
        ; Reset in IDLE always publishes (unconditional)
        Assert.True(this.svc.Reset())
    }

    reset_works_from_running()
    {
        this.svc.Start()
        Assert.True(this.svc.Reset())
        Assert.False(this.svc.IsActive())
    }

    reset_works_from_paused()
    {
        this.svc.Start()
        this.svc.Pause()
        Assert.True(this.svc.Reset())
        Assert.False(this.svc.IsActive())
    }

    ; ============================================================
    ; Toggle
    ; ============================================================

    toggle_idle_calls_start()
    {
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Toggle()
        Assert.Equal("TimerStarted", evtLog[1]["event"])
        Assert.True(this.svc.IsRunning())
    }

    toggle_running_calls_pause()
    {
        this.svc.Start()
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Toggle()
        Assert.Equal("TimerPaused", evtLog[1]["event"])
        Assert.True(this.svc.IsPaused())
    }

    toggle_paused_calls_resume()
    {
        this.svc.Start()
        this.svc.Pause()
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Toggle()
        Assert.Equal("TimerResumed", evtLog[1]["event"])
        Assert.True(this.svc.IsRunning())
    }

    ; ============================================================
    ; Hydrate (silent)
    ; ============================================================

    hydrate_default_status_is_stopped()
    {
        this.svc.Hydrate(5000)   ; default = "stopped"
        Assert.False(this.svc.IsActive())
        Assert.Equal(5000, this.svc.GetRunMs())
    }

    hydrate_running_sets_active_not_paused()
    {
        this.svc.Hydrate(5000, "running")
        Assert.True(this.svc.IsActive())
        Assert.True(this.svc.IsRunning())
        Assert.False(this.svc.IsPaused())
    }

    hydrate_paused_sets_active_and_paused()
    {
        this.svc.Hydrate(5000, "paused")
        Assert.True(this.svc.IsActive())
        Assert.False(this.svc.IsRunning())
        Assert.True(this.svc.IsPaused())
    }

    hydrate_unknown_status_falls_back_to_stopped()
    {
        this.svc.Hydrate(5000, "nonsense_status")
        Assert.False(this.svc.IsActive())
        Assert.Equal(5000, this.svc.GetRunMs())
    }

    hydrate_running_accumulates_after_clock_advance()
    {
        ; After hydrate "running", clock advance enters GetRunMs.
        this.svc.Hydrate(5000, "running")
        Assert.Equal(5000, this.svc.GetRunMs())
        this.stubClock.AdvanceMs(2000)
        Assert.Equal(7000, this.svc.GetRunMs(), "5000 base + 2000 delta")
    }

    hydrate_paused_keeps_run_ms_constant_after_advance()
    {
        this.svc.Hydrate(5000, "paused")
        Assert.Equal(5000, this.svc.GetRunMs())
        this.stubClock.AdvanceMs(10000)
        Assert.Equal(5000, this.svc.GetRunMs(), "paused = constant base")
    }

    hydrate_clamps_negative_to_zero()
    {
        this.svc.Hydrate(-1000)
        Assert.Equal(0, this.svc.GetRunMs())
    }

    hydrate_with_non_number_uses_zero()
    {
        this.svc.Hydrate("not a number")
        Assert.Equal(0, this.svc.GetRunMs())
    }

    hydrate_does_not_publish_any_event()
    {
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Hydrate(5000, "running")
        this.svc.Hydrate(7000, "paused")
        this.svc.Hydrate(3000, "stopped")
        Assert.Equal(0, evtLog.Length, "Hydrate is silent by design")
    }

    ; ============================================================
    ; AddPenaltyMs (v0.1.3 — death penalty in real-time timer)
    ; ============================================================
    ;
    ; Contract:
    ;   - Argument positive > 0 → adds to _baseMs, returns true
    ;   - Zero / negative / non-number → no-op, returns false
    ;   - In RUNNING: commits current delta before adding (preserves
    ;     the elapsed time up to the penalty moment); timer keeps
    ;     counting after the addition.
    ;   - In PAUSED or IDLE: direct addition to _baseMs.
    ;   - NEVER publishes bus events (design decision: widgets refresh
    ;     on the next Tick and show the new runMs without needing a
    ;     dedicated event).

    add_penalty_ms_returns_true_with_positive_value()
    {
        this.svc.Start()
        Assert.True(this.svc.AddPenaltyMs(150000))
    }

    add_penalty_ms_returns_false_with_zero()
    {
        this.svc.Start()
        Assert.False(this.svc.AddPenaltyMs(0),
            "Zero is no-op (no effective penalty)")
    }

    add_penalty_ms_returns_false_with_negative()
    {
        this.svc.Start()
        Assert.False(this.svc.AddPenaltyMs(-100))
        Assert.False(this.svc.AddPenaltyMs(-1))
    }

    add_penalty_ms_returns_false_with_non_number()
    {
        this.svc.Start()
        Assert.False(this.svc.AddPenaltyMs("abc"))
        Assert.False(this.svc.AddPenaltyMs(""))
        ; AHK v2 treats Map() as non-number
        Assert.False(this.svc.AddPenaltyMs(Map()))
    }

    add_penalty_ms_increases_run_ms_when_running()
    {
        ; Start at t=1000, advance 2s (runMs=2000), penalty 500ms
        ; → runMs should become 2500 immediately.
        this.svc.Start()
        this.stubClock.AdvanceMs(2000)
        Assert.Equal(2000, this.svc.GetRunMs())

        this.svc.AddPenaltyMs(500)
        Assert.Equal(2500, this.svc.GetRunMs(),
            "Penalty goes straight into runMs in RUNNING")
    }

    add_penalty_ms_increases_run_ms_when_paused()
    {
        ; Start, advance, Pause at runMs=3000, penalty 500
        ; → runMs becomes 3500 and stays constant (paused).
        this.svc.Start()
        this.stubClock.AdvanceMs(3000)
        this.svc.Pause()
        Assert.Equal(3000, this.svc.GetRunMs())

        this.svc.AddPenaltyMs(500)
        Assert.Equal(3500, this.svc.GetRunMs())

        ; Clock advance in PAUSED: runMs must not change
        this.stubClock.AdvanceMs(10000)
        Assert.Equal(3500, this.svc.GetRunMs(),
            "In PAUSED, runMs remains with penalty included")
    }

    add_penalty_ms_increases_run_ms_when_idle()
    {
        ; In IDLE, GetRunMs returns _baseMs. AddPenaltyMs increments
        ; _baseMs unconditionally — the caller (app handler) is who
        ; filters with the IsActive() check. The method itself doesn't
        ; reject.
        Assert.Equal(0, this.svc.GetRunMs())
        Assert.True(this.svc.AddPenaltyMs(500))
        Assert.Equal(500, this.svc.GetRunMs(),
            "In IDLE, penalty adds to _baseMs (caller filters)")
    }

    add_penalty_ms_does_not_freeze_running_timer()
    {
        ; Important: penalty doesn't stop the timer. Clock keeps
        ; accumulating normally after AddPenaltyMs.
        ;   Start at t=1000
        ;   advance 2s → runMs=2000
        ;   penalty 500 → runMs=2500
        ;   advance 1s → runMs=3500 (timer still running)
        this.svc.Start()
        this.stubClock.AdvanceMs(2000)
        this.svc.AddPenaltyMs(500)
        Assert.Equal(2500, this.svc.GetRunMs())

        this.stubClock.AdvanceMs(1000)
        Assert.Equal(3500, this.svc.GetRunMs(),
            "Timer keeps running after penalty")

        Assert.True(this.svc.IsRunning(),
            "RUNNING state preserved after penalty")
    }

    add_penalty_ms_does_not_publish_any_event()
    {
        ; Penalty changes runMs but is silent — widgets refresh on the
        ; next Tick. Guarantees that none of the 5 timer events are
        ; published (Start/Pause/Resume/Stop/Reset).
        this.svc.Start()
        this.stubClock.AdvanceMs(1000)

        evtLog := this._CaptureAllTimerEvents()
        this.svc.AddPenaltyMs(500)
        this.svc.Pause()
        this.svc.AddPenaltyMs(500)
        this.svc.Resume()
        this.svc.AddPenaltyMs(500)

        ; Only Paused + Resumed should have appeared — none of the 3
        ; AddPenaltyMs calls published anything.
        Assert.Equal(2, evtLog.Length,
            "AddPenaltyMs doesn't publish events (only Pause/Resume should appear)")
        Assert.Equal("TimerPaused",  evtLog[1]["event"])
        Assert.Equal("TimerResumed", evtLog[2]["event"])
    }

    add_penalty_ms_coerces_float_to_int()
    {
        ; Float penalties must be truncated to int (consistent with
        ; the Duration constructor and other project helpers).
        this.svc.Start()
        this.stubClock.AdvanceMs(1000)
        this.svc.AddPenaltyMs(500.7)
        Assert.Equal(1500, this.svc.GetRunMs(),
            "500.7 truncated to 500")
    }

    add_penalty_ms_can_be_applied_multiple_times()
    {
        ; Each call accumulates. Realistic scenario: player dies 3x in
        ; the same run.
        this.svc.Start()
        this.stubClock.AdvanceMs(60000)   ; 1min into the run

        this.svc.AddPenaltyMs(150000)     ; 1st death
        this.svc.AddPenaltyMs(150000)     ; 2nd death
        this.svc.AddPenaltyMs(150000)     ; 3rd death

        ; 60s clock + 3 * 150s penalty = 60 + 450 = 510s = 510000ms
        Assert.Equal(510000, this.svc.GetRunMs())
    }

    add_penalty_ms_zero_does_not_modify_state()
    {
        ; Confirms that no-ops (return false) don't touch anything.
        this.svc.Start()
        this.stubClock.AdvanceMs(2000)
        before := this.svc.GetRunMs()

        this.svc.AddPenaltyMs(0)
        this.svc.AddPenaltyMs(-100)
        this.svc.AddPenaltyMs("abc")

        Assert.Equal(before, this.svc.GetRunMs(),
            "None of the no-ops changed the state")
    }

    add_penalty_ms_persists_through_pause_resume_cycle()
    {
        ; Scenario: death during RUNNING (penalty applied), player
        ; pauses to go to the bathroom, resumes and continues. The
        ; penalty must be sewn into _baseMs.
        ;   t=1000: Start
        ;   t=3000: advance 2s, runMs=2000
        ;   penalty 500: runMs=2500
        ;   Pause: commits, _baseMs=2500
        ;   advance 5s (no effect — paused)
        ;   Resume
        ;   advance 1s → runMs=3500
        this.svc.Start()
        this.stubClock.AdvanceMs(2000)
        this.svc.AddPenaltyMs(500)
        this.svc.Pause()
        Assert.Equal(2500, this.svc.GetRunMs())

        this.stubClock.AdvanceMs(5000)
        this.svc.Resume()
        this.stubClock.AdvanceMs(1000)
        Assert.Equal(3500, this.svc.GetRunMs(),
            "Penalty survives the Pause/Resume")
    }
}

TestRegistry.Register(TimerServiceTests)
