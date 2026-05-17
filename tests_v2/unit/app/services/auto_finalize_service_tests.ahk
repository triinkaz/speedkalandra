; ============================================================
; AutoFinalizeServiceTests
; ============================================================
;
; AutoFinalizeService subscribes to LogLineRead + lifecycle. When a
; line matches cfg.autoFinalizeRegex AND hasn't fired in this run
; yet, publishes Cmd.FinalizeRunRequested. Tolerant to invalid
; regex. Dedup via _hasFiredForCurrentRun flag (reset on
; RunStarted/Ended).


class AutoFinalizeServiceTests extends TestCase
{
    bus := ""
    cfg := ""
    svc := ""

    Setup()
    {
        this.bus := Fixtures.MakeBus()
        this.cfg := AppSettings.Defaults()
        this.cfg.autoFinalizeRegex := "Doryani has been slain"   ; canonical final boss
        this.svc := AutoFinalizeService(this.bus, this.cfg)
    }

    Teardown()
    {
        if IsObject(this.svc)
            this.svc.Dispose()
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_cfg_not_app_settings",
        "constructor_subscribes_to_log_line_read",
        "constructor_subscribes_to_all_run_lifecycle",

        ; --- LogLine handler: preconditions ---
        "log_line_ignored_when_data_non_object",
        "log_line_ignored_when_line_key_missing",
        "log_line_ignored_when_line_empty",
        "log_line_ignored_when_regex_empty",
        "log_line_ignored_when_already_fired_for_current_run",

        ; --- LogLine handler: match ---
        "log_line_match_publishes_finalize_run_requested",
        "log_line_no_match_publishes_nothing",
        "log_line_match_event_includes_source_auto",

        ; --- Invalid regex (tolerance) ---
        "log_line_with_invalid_regex_does_not_crash",
        "log_line_with_invalid_regex_does_not_publish",

        ; --- Dedup ---
        "second_match_during_same_run_does_not_publish_again",

        ; --- Lifecycle: reset flag ---
        "run_started_resets_fired_flag",
        "run_reset_resets_fired_flag",
        "run_cancelled_resets_fired_flag",
        "run_completed_resets_fired_flag",

        ; --- Full flow ---
        "after_run_started_can_fire_for_next_run",

        ; --- Dispose ---
        "dispose_unsubscribes_all_handlers",
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

    constructor_throws_when_bus_not_event_bus()
    {
        c := this.cfg
        Assert.Throws(TypeError, () => AutoFinalizeService("not bus", c))
    }

    constructor_throws_when_cfg_not_app_settings()
    {
        b := this.bus
        Assert.Throws(TypeError, () => AutoFinalizeService(b, "not cfg"))
    }

    constructor_subscribes_to_log_line_read()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.LogLineRead))
    }

    constructor_subscribes_to_all_run_lifecycle()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.RunStarted))
        Assert.Equal(1, this.bus.Subscribers(Events.RunReset))
        Assert.Equal(1, this.bus.Subscribers(Events.RunCancelled))
        Assert.Equal(1, this.bus.Subscribers(Events.RunCompleted))
    }

    ; ============================================================
    ; LogLine handler: preconditions
    ; ============================================================

    log_line_ignored_when_data_non_object()
    {
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.LogLineRead, "not a map")
        Assert.Equal(0, capturedEvents.Length)
    }

    log_line_ignored_when_line_key_missing()
    {
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("other", "value"))
        Assert.Equal(0, capturedEvents.Length)
    }

    log_line_ignored_when_line_empty()
    {
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", ""))
        Assert.Equal(0, capturedEvents.Length)
    }

    log_line_ignored_when_regex_empty()
    {
        this.cfg.autoFinalizeRegex := ""
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "Anything"))
        Assert.Equal(0, capturedEvents.Length)
    }

    log_line_ignored_when_already_fired_for_current_run()
    {
        ; First match fires, second does NOT (dedup)
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain again"))
        Assert.Equal(1, capturedEvents.Length)
    }

    ; ============================================================
    ; LogLine handler: match
    ; ============================================================

    log_line_match_publishes_finalize_run_requested()
    {
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))
        Assert.Equal(1, capturedEvents.Length)
    }

    log_line_no_match_publishes_nothing()
    {
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "Random log line"))
        Assert.Equal(0, capturedEvents.Length)
    }

    log_line_match_event_includes_source_auto()
    {
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))
        Assert.Equal("auto", capturedEvents[1]["source"])
    }

    ; ============================================================
    ; Invalid regex (tolerance)
    ; ============================================================

    log_line_with_invalid_regex_does_not_crash()
    {
        this.cfg.autoFinalizeRegex := "(unclosed"
        this.bus.Publish(Events.LogLineRead, Map("line", "(unclosed"))
        Assert.True(true, "Survived invalid regex")
    }

    log_line_with_invalid_regex_does_not_publish()
    {
        this.cfg.autoFinalizeRegex := "(unclosed"
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "(unclosed"))
        Assert.Equal(0, capturedEvents.Length)
    }

    ; ============================================================
    ; Dedup
    ; ============================================================

    second_match_during_same_run_does_not_publish_again()
    {
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))
        Assert.Equal(1, capturedEvents.Length)
    }

    ; ============================================================
    ; Lifecycle: reset flag
    ; ============================================================

    run_started_resets_fired_flag()
    {
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))   ; fired
        this.bus.Publish(Events.RunStarted, Map("runId", "new_run"))                  ; resets
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))   ; fires again
        Assert.Equal(2, capturedEvents.Length)
    }

    run_reset_resets_fired_flag()
    {
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))
        this.bus.Publish(Events.RunReset, Map())
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))
        Assert.Equal(2, capturedEvents.Length)
    }

    run_cancelled_resets_fired_flag()
    {
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))
        this.bus.Publish(Events.RunCancelled, Map())
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))
        Assert.Equal(2, capturedEvents.Length)
    }

    run_completed_resets_fired_flag()
    {
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))
        this.bus.Publish(Events.RunCompleted, Map())
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))
        Assert.Equal(2, capturedEvents.Length)
    }

    ; ============================================================
    ; Full flow
    ; ============================================================

    after_run_started_can_fire_for_next_run()
    {
        capturedEvents := this._CaptureEvents(Commands.FinalizeRunRequested)
        this.bus.Publish(Events.RunStarted, Map("runId", "run_1"))
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))
        this.bus.Publish(Events.RunStarted, Map("runId", "run_2"))
        this.bus.Publish(Events.LogLineRead, Map("line", "Doryani has been slain"))
        Assert.Equal(2, capturedEvents.Length, "Each run can fire once")
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_all_handlers()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.LogLineRead))
        Assert.Equal(0, this.bus.Subscribers(Events.RunStarted))
        Assert.Equal(0, this.bus.Subscribers(Events.RunReset))
        Assert.Equal(0, this.bus.Subscribers(Events.RunCancelled))
        Assert.Equal(0, this.bus.Subscribers(Events.RunCompleted))
    }

    dispose_is_idempotent()
    {
        this.svc.Dispose()
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.LogLineRead))
    }
}

TestRegistry.Register(AutoFinalizeServiceTests)
