; ============================================================
; RunStatsRecorderTests
; ============================================================
;
; RunStatsRecorder is reactive, with 2 deps (bus + clock):
;
;   bus    : EventBus
;   clock  : object with NowMs() (validated but NOT used in
;            _NowTimestamp, which delegates to FormatTime(A_Now, ...)
;            — real timestamps).
;
; Subscribers:
;   LoadingMeasured -> push into _loadingEvents
;   DeathDetected   -> _deathCount += 1
;   RunStarted      -> Reset + capture runId/startedAt + _firstTs
;   RunReset        -> Reset
;   RunCancelled    -> Reset
;   RunCompleted    -> NO-OP (preserves state for the final plot)
;
; GetSnapshot(zoneTotalsMap, runDurationMs) -> Map with all the
; fields for RunStatsPlotBuilder to consume.
;
; NOTE: _NowTimestamp is non-deterministic (uses A_Now). Tests only
; verify format/length, not the exact value.


class RunStatsRecorderTests extends TestCase
{
    bus       := ""
    stubClock := ""
    svc       := ""

    Setup()
    {
        this.bus       := Fixtures.MakeBus()
        this.stubClock := Fixtures.MakeFakeClock(1000)
        this.svc       := RunStatsRecorder(this.bus, this.stubClock)
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
        "constructor_throws_when_clock_missing_now_ms",
        "constructor_throws_when_clock_is_string",
        "constructor_subscribes_to_loading_measured",
        "constructor_subscribes_to_death_detected",
        "constructor_subscribes_to_all_run_lifecycle_events",

        ; --- Defaults ---
        "run_id_empty_initially",
        "first_ts_empty_initially",
        "loading_events_empty_initially",
        "death_count_zero_initially",

        ; --- RunStarted ---
        "run_started_captures_run_id_from_data",
        "run_started_sets_first_ts_to_timestamp_string",
        "run_started_resets_state_before_capture",
        "run_started_with_non_object_data_still_resets",
        "run_started_with_missing_run_id_leaves_it_empty",

        ; --- LoadingMeasured ---
        "loading_measured_pushes_event_to_array",
        "loading_measured_captures_from_zone_and_to_zone",
        "loading_measured_captures_duration_ms",
        "loading_measured_captures_source",
        "loading_measured_includes_timestamp_in_event",
        "loading_measured_ignores_zero_duration",
        "loading_measured_ignores_negative_duration",
        "loading_measured_ignores_non_object_data",
        "loading_measured_with_missing_fields_uses_empty_strings",
        "loading_measured_accumulates_multiple_events",

        ; --- DeathDetected ---
        "death_detected_increments_count",
        "death_detected_accumulates",

        ; --- Lifecycle handlers ---
        "run_reset_clears_state",
        "run_cancelled_clears_state",
        "run_completed_preserves_state_for_plot",

        ; --- GetSnapshot ---
        "snapshot_includes_all_required_keys",
        "snapshot_uses_provided_zone_totals_map",
        "snapshot_uses_provided_run_duration_ms",
        "snapshot_defaults_zone_totals_to_empty_map",
        "snapshot_defaults_run_duration_to_zero",
        "snapshot_loading_events_is_defensive_copy",

        ; --- GetLoadingEvents returns a copy ---
        "get_loading_events_returns_defensive_copy",
        "mutating_returned_loading_events_does_not_affect_internal",

        ; --- Manual Reset ---
        "reset_clears_run_id_and_first_ts",
        "reset_clears_loading_events",
        "reset_zeroes_death_count",

        ; --- Dispose ---
        "dispose_unsubscribes_loading_measured",
        "dispose_unsubscribes_death_detected",
        "dispose_unsubscribes_all_run_lifecycle",
        "dispose_is_idempotent"
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        clk := this.stubClock
        Assert.Throws(TypeError, () => RunStatsRecorder("not a bus", clk))
    }

    constructor_throws_when_clock_missing_now_ms()
    {
        b := this.bus
        emptyObj := { foo: () => 0 }
        Assert.Throws(TypeError, () => RunStatsRecorder(b, emptyObj))
    }

    constructor_throws_when_clock_is_string()
    {
        b := this.bus
        Assert.Throws(TypeError, () => RunStatsRecorder(b, "not a clock"))
    }

    constructor_subscribes_to_loading_measured()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.LoadingMeasured))
    }

    constructor_subscribes_to_death_detected()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.DeathDetected))
    }

    constructor_subscribes_to_all_run_lifecycle_events()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.RunStarted))
        Assert.Equal(1, this.bus.Subscribers(Events.RunReset))
        Assert.Equal(1, this.bus.Subscribers(Events.RunCancelled))
        Assert.Equal(1, this.bus.Subscribers(Events.RunCompleted))
    }

    ; ============================================================
    ; Defaults
    ; ============================================================

    run_id_empty_initially()      => Assert.Equal("", this.svc.GetRunId())
    first_ts_empty_initially()    => Assert.Equal("", this.svc.GetFirstTs())
    loading_events_empty_initially() => Assert.Equal(0, this.svc.GetLoadingEvents().Length)
    death_count_zero_initially()  => Assert.Equal(0, this.svc.GetDeathCount())

    ; ============================================================
    ; RunStarted
    ; ============================================================

    run_started_captures_run_id_from_data()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "20260512_142345"))
        Assert.Equal("20260512_142345", this.svc.GetRunId())
    }

    run_started_sets_first_ts_to_timestamp_string()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "20260512_142345"))
        ts := this.svc.GetFirstTs()
        ; Format yyyy-MM-dd HH:mm:ss = 19 chars
        Assert.Equal(19, StrLen(ts), "Expected timestamp yyyy-MM-dd HH:mm:ss (19 chars)")
        ; Fixed separator positions
        Assert.Equal("-", SubStr(ts, 5, 1))
        Assert.Equal("-", SubStr(ts, 8, 1))
        Assert.Equal(" ", SubStr(ts, 11, 1))
        Assert.Equal(":", SubStr(ts, 14, 1))
        Assert.Equal(":", SubStr(ts, 17, 1))
    }

    run_started_resets_state_before_capture()
    {
        ; Accumulate data from a previous run
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 1000, "toZone", "X"))
        this.bus.Publish(Events.DeathDetected, Map())

        ; New run: internal Reset + capture
        this.bus.Publish(Events.RunStarted, Map("runId", "new_run"))

        Assert.Equal(0, this.svc.GetLoadingEvents().Length)
        Assert.Equal(0, this.svc.GetDeathCount())
        Assert.Equal("new_run", this.svc.GetRunId())
    }

    run_started_with_non_object_data_still_resets()
    {
        this.bus.Publish(Events.DeathDetected, Map())
        ; non-object data: handler still calls Reset, but doesn't capture runId
        this.bus.Publish(Events.RunStarted, "not a map")
        Assert.Equal(0, this.svc.GetDeathCount(), "Reset happened")
        Assert.Equal("", this.svc.GetRunId(), "runId not captured")
    }

    run_started_with_missing_run_id_leaves_it_empty()
    {
        this.bus.Publish(Events.RunStarted, Map("startedAt", 999))
        Assert.Equal("", this.svc.GetRunId())
    }

    ; ============================================================
    ; LoadingMeasured
    ; ============================================================

    loading_measured_pushes_event_to_array()
    {
        this.bus.Publish(Events.LoadingMeasured, Map(
            "durationMs", 4500, "fromZone", "A", "toZone", "B"
        ))
        Assert.Equal(1, this.svc.GetLoadingEvents().Length)
    }

    loading_measured_captures_from_zone_and_to_zone()
    {
        this.bus.Publish(Events.LoadingMeasured, Map(
            "durationMs", 4500, "fromZone", "Clearfell", "toZone", "Mud Burrow"
        ))
        ev := this.svc.GetLoadingEvents()[1]
        Assert.Equal("Clearfell",  ev["fromZone"])
        Assert.Equal("Mud Burrow", ev["toZone"])
    }

    loading_measured_captures_duration_ms()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 4500, "toZone", "X"))
        Assert.Equal(4500, this.svc.GetLoadingEvents()[1]["durationMs"])
    }

    loading_measured_captures_source()
    {
        this.bus.Publish(Events.LoadingMeasured, Map(
            "durationMs", 4500, "toZone", "X", "source", "visual"
        ))
        Assert.Equal("visual", this.svc.GetLoadingEvents()[1]["source"])
    }

    loading_measured_includes_timestamp_in_event()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 4500, "toZone", "X"))
        ts := this.svc.GetLoadingEvents()[1]["ts"]
        Assert.Equal(19, StrLen(ts))
    }

    loading_measured_ignores_zero_duration()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 0, "toZone", "X"))
        Assert.Equal(0, this.svc.GetLoadingEvents().Length)
    }

    loading_measured_ignores_negative_duration()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", -100, "toZone", "X"))
        Assert.Equal(0, this.svc.GetLoadingEvents().Length)
    }

    loading_measured_ignores_non_object_data()
    {
        this.bus.Publish(Events.LoadingMeasured, "string data")
        Assert.Equal(0, this.svc.GetLoadingEvents().Length)
    }

    loading_measured_with_missing_fields_uses_empty_strings()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 4500))
        ev := this.svc.GetLoadingEvents()[1]
        Assert.Equal("", ev["fromZone"])
        Assert.Equal("", ev["toZone"])
        Assert.Equal("", ev["source"])
    }

    loading_measured_accumulates_multiple_events()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 1000, "toZone", "A"))
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 2000, "toZone", "B"))
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 3000, "toZone", "C"))
        Assert.Equal(3, this.svc.GetLoadingEvents().Length)
    }

    ; ============================================================
    ; DeathDetected
    ; ============================================================

    death_detected_increments_count()
    {
        this.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))
        Assert.Equal(1, this.svc.GetDeathCount())
    }

    death_detected_accumulates()
    {
        this.bus.Publish(Events.DeathDetected, Map())
        this.bus.Publish(Events.DeathDetected, Map())
        this.bus.Publish(Events.DeathDetected, Map())
        Assert.Equal(3, this.svc.GetDeathCount())
    }

    ; ============================================================
    ; Lifecycle handlers (RunReset/Cancelled clear, RunCompleted preserves)
    ; ============================================================

    run_reset_clears_state()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "run_x"))
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 1000, "toZone", "X"))
        this.bus.Publish(Events.DeathDetected, Map())

        this.bus.Publish(Events.RunReset, Map("runId", "run_x"))

        Assert.Equal("", this.svc.GetRunId())
        Assert.Equal(0,  this.svc.GetLoadingEvents().Length)
        Assert.Equal(0,  this.svc.GetDeathCount())
    }

    run_cancelled_clears_state()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "run_x"))
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 1000, "toZone", "X"))
        this.bus.Publish(Events.DeathDetected, Map())

        this.bus.Publish(Events.RunCancelled, Map("runId", "run_x"))

        Assert.Equal("", this.svc.GetRunId())
        Assert.Equal(0,  this.svc.GetLoadingEvents().Length)
        Assert.Equal(0,  this.svc.GetDeathCount())
    }

    run_completed_preserves_state_for_plot()
    {
        ; RunCompleted does not reset: composition root needs
        ; everything to build the final plot snapshot.
        this.bus.Publish(Events.RunStarted, Map("runId", "run_x"))
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 1000, "toZone", "X"))
        this.bus.Publish(Events.DeathDetected, Map())

        this.bus.Publish(Events.RunCompleted, Map("runId", "run_x"))

        Assert.Equal("run_x", this.svc.GetRunId(),     "runId preserved")
        Assert.Equal(1,       this.svc.GetLoadingEvents().Length, "events preserved")
        Assert.Equal(1,       this.svc.GetDeathCount(), "deaths preserved")
    }

    ; ============================================================
    ; GetSnapshot
    ; ============================================================

    snapshot_includes_all_required_keys()
    {
        snap := this.svc.GetSnapshot()
        Assert.True(snap.Has("runId"))
        Assert.True(snap.Has("firstTs"))
        Assert.True(snap.Has("runDurationMs"))
        Assert.True(snap.Has("zoneTotals"))
        Assert.True(snap.Has("loadingEvents"))
        Assert.True(snap.Has("deathCount"))
    }

    snapshot_uses_provided_zone_totals_map()
    {
        zoneTotals := Map("Clearfell", 215000, "Mud Burrow", 95000)
        snap := this.svc.GetSnapshot(zoneTotals, 1000000)
        Assert.Equal(215000, snap["zoneTotals"]["Clearfell"])
        Assert.Equal(95000,  snap["zoneTotals"]["Mud Burrow"])
    }

    snapshot_uses_provided_run_duration_ms()
    {
        snap := this.svc.GetSnapshot(Map(), 5040000)
        Assert.Equal(5040000, snap["runDurationMs"])
    }

    snapshot_defaults_zone_totals_to_empty_map()
    {
        snap := this.svc.GetSnapshot()
        Assert.True(snap["zoneTotals"] is Map)
        Assert.Equal(0, snap["zoneTotals"].Count)
    }

    snapshot_defaults_run_duration_to_zero()
    {
        snap := this.svc.GetSnapshot()
        Assert.Equal(0, snap["runDurationMs"])
    }

    snapshot_loading_events_is_defensive_copy()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 1000, "toZone", "X"))
        snap := this.svc.GetSnapshot()

        snapEvents := snap["loadingEvents"]
        snapEvents.Push(Map("durationMs", 9999))   ; mutate copy

        Assert.Equal(1, this.svc.GetLoadingEvents().Length,
            "Internal state intact after mutating the copy")
    }

    ; ============================================================
    ; GetLoadingEvents
    ; ============================================================

    get_loading_events_returns_defensive_copy()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 1000, "toZone", "X"))
        copy1 := this.svc.GetLoadingEvents()
        copy2 := this.svc.GetLoadingEvents()
        Assert.False(copy1 == copy2, "Each call returns a different instance")
    }

    mutating_returned_loading_events_does_not_affect_internal()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 1000, "toZone", "X"))
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 2000, "toZone", "Y"))

        copy := this.svc.GetLoadingEvents()
        copy.Push(Map("durationMs", 9999))   ; mutate copy

        Assert.Equal(2, this.svc.GetLoadingEvents().Length, "Original intact")

        ; Mutate an internal item of the copy (each Map is also copied)
        copy[1]["durationMs"] := 0
        Assert.Equal(1000, this.svc.GetLoadingEvents()[1]["durationMs"],
            "_CopyArrayOfMaps deep-copies the Maps too")
    }

    ; ============================================================
    ; Manual Reset
    ; ============================================================

    reset_clears_run_id_and_first_ts()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "run_x"))
        this.svc.Reset()
        Assert.Equal("", this.svc.GetRunId())
        Assert.Equal("", this.svc.GetFirstTs())
    }

    reset_clears_loading_events()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 1000, "toZone", "X"))
        this.svc.Reset()
        Assert.Equal(0, this.svc.GetLoadingEvents().Length)
    }

    reset_zeroes_death_count()
    {
        this.bus.Publish(Events.DeathDetected, Map())
        this.bus.Publish(Events.DeathDetected, Map())
        this.svc.Reset()
        Assert.Equal(0, this.svc.GetDeathCount())
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_loading_measured()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.LoadingMeasured))
    }

    dispose_unsubscribes_death_detected()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.DeathDetected))
    }

    dispose_unsubscribes_all_run_lifecycle()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.RunStarted))
        Assert.Equal(0, this.bus.Subscribers(Events.RunReset))
        Assert.Equal(0, this.bus.Subscribers(Events.RunCancelled))
        Assert.Equal(0, this.bus.Subscribers(Events.RunCompleted))
    }

    dispose_is_idempotent()
    {
        this.svc.Dispose()
        this.svc.Dispose()   ; second Dispose: no-op
        Assert.Equal(0, this.bus.Subscribers(Events.LoadingMeasured))
    }
}

TestRegistry.Register(RunStatsRecorderTests)
