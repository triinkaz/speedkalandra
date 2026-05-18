; ============================================================
; LoadingTotalsServiceTests
; ============================================================
;
; LoadingTotalsService is reactive via bus, minimal state (_totalMs).
;   - Subscribe LoadingMeasured -> accumulates durationMs
;   - Subscribe RunStarted/Reset/Cancelled/Completed -> Reset
;   - Hydrate restores state (defensive against invalid input)
;   - Dispose is idempotent unsubscribe
;
; Coverage:
;   - Constructor (bus validation, defaults)
;   - LoadingMeasured accumulation
;   - Reset on each lifecycle event
;   - Defensive against malformed data
;   - Hydrate (negative clamp, non-number fallback)
;   - Dispose


class LoadingTotalsServiceTests extends TestCase
{
    bus := ""
    svc := ""

    Setup()
    {
        this.bus := Fixtures.MakeBus()
        this.svc := LoadingTotalsService(this.bus)
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
        "constructor_starts_with_zero_total_ms",
        "constructor_subscribes_to_loading_measured",
        "constructor_subscribes_to_all_lifecycle_events",

        ; --- Accumulation ---
        "accumulates_single_loading_event",
        "sums_multiple_loading_events",
        "preserves_total_across_unrelated_events",

        ; --- Reset on lifecycle ---
        "resets_on_run_started",
        "resets_on_run_reset",
        "resets_on_run_cancelled",
        "resets_on_run_completed",

        ; --- Hydration ordering (regression for the hydrated:true sweep) ---
        "run_started_with_hydrated_flag_preserves_total_ms",
        "run_started_without_hydrated_flag_wipes_total_ms",

        ; --- Defensive against malformed data ---
        "ignores_loading_measured_without_duration_ms_key",
        "ignores_loading_measured_with_non_number_duration",
        "ignores_loading_measured_with_zero_duration",
        "ignores_loading_measured_with_negative_duration",
        "ignores_loading_measured_with_non_object_data",

        ; --- Reset / Hydrate ---
        "reset_zeroes_total",
        "hydrate_sets_total_ms",
        "hydrate_clamps_negative_to_zero",
        "hydrate_with_non_number_falls_back_to_zero",
        "hydrate_coerces_float_to_integer",

        ; --- Dispose ---
        "dispose_unsubscribes_loading_measured",
        "dispose_unsubscribes_run_lifecycle",
        "dispose_is_idempotent"
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        Assert.Throws(TypeError, () => LoadingTotalsService("not a bus"))
    }

    constructor_starts_with_zero_total_ms()
    {
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    constructor_subscribes_to_loading_measured()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.LoadingMeasured))
    }

    constructor_subscribes_to_all_lifecycle_events()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.RunStarted))
        Assert.Equal(1, this.bus.Subscribers(Events.RunReset))
        Assert.Equal(1, this.bus.Subscribers(Events.RunCancelled))
        Assert.Equal(1, this.bus.Subscribers(Events.RunCompleted))
    }

    ; ============================================================
    ; Accumulation
    ; ============================================================

    accumulates_single_loading_event()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 4500))
        Assert.Equal(4500, this.svc.GetTotalMs())
    }

    sums_multiple_loading_events()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 1000))
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 2500))
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs",  500))
        Assert.Equal(4000, this.svc.GetTotalMs())
    }

    preserves_total_across_unrelated_events()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 1000))
        ; Non-subscribed events don't affect state
        this.bus.Publish(Events.ZoneEntered, Map("zoneName", "Clearfell"))
        this.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))
        Assert.Equal(1000, this.svc.GetTotalMs())
    }

    ; ============================================================
    ; Reset on lifecycle
    ; ============================================================

    resets_on_run_started()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 3000))
        this.bus.Publish(Events.RunStarted, Map("runId", "20260512_142345"))
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    resets_on_run_reset()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 3000))
        this.bus.Publish(Events.RunReset, Map("runId", "20260512_142345"))
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    resets_on_run_cancelled()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 3000))
        this.bus.Publish(Events.RunCancelled, Map("runId", "20260512_142345"))
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    resets_on_run_completed()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 3000))
        this.bus.Publish(Events.RunCompleted, Map("runId", "20260512_142345"))
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    ; ============================================================
    ; Hydration ordering
    ; ============================================================
    ; The composition root hydrates _totalMs from disk BEFORE
    ; RunService.Hydrate() publishes Evt.RunStarted{hydrated:true}.
    ; If the handler reset the total on that event, the just-restored
    ; loading time would be wiped. The hydrated flag suppresses the
    ; reset. Same pattern as ZoneTrackingService._OnRunStarted.

    run_started_with_hydrated_flag_preserves_total_ms()
    {
        this.svc.Hydrate(12345)
        this.bus.Publish(Events.RunStarted, Map("runId", "20260512_142345", "hydrated", true))
        Assert.Equal(12345, this.svc.GetTotalMs())
    }

    run_started_without_hydrated_flag_wipes_total_ms()
    {
        this.svc.Hydrate(12345)
        this.bus.Publish(Events.RunStarted, Map("runId", "20260512_142345"))
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    ; ============================================================
    ; Defensive against malformed data
    ; ============================================================

    ignores_loading_measured_without_duration_ms_key()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("fromZone", "A", "toZone", "B"))
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    ignores_loading_measured_with_non_number_duration()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", "not a number"))
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    ignores_loading_measured_with_zero_duration()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 0))
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    ignores_loading_measured_with_negative_duration()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", -100))
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    ignores_loading_measured_with_non_object_data()
    {
        ; non-object data: defensive in _OnLoadingMeasured
        this.bus.Publish(Events.LoadingMeasured, "string data")
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    ; ============================================================
    ; Reset / Hydrate
    ; ============================================================

    reset_zeroes_total()
    {
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 5000))
        this.svc.Reset()
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    hydrate_sets_total_ms()
    {
        this.svc.Hydrate(12345)
        Assert.Equal(12345, this.svc.GetTotalMs())
    }

    hydrate_clamps_negative_to_zero()
    {
        this.svc.Hydrate(-500)
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    hydrate_with_non_number_falls_back_to_zero()
    {
        this.svc.Hydrate("not a number")
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    hydrate_coerces_float_to_integer()
    {
        this.svc.Hydrate(42.7)
        Assert.Equal(42, this.svc.GetTotalMs())
        Assert.Equal("Integer", Type(this.svc.GetTotalMs()))
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_loading_measured()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.LoadingMeasured))
        ; After Dispose, events don't accumulate
        this.bus.Publish(Events.LoadingMeasured, Map("durationMs", 1000))
        Assert.Equal(0, this.svc.GetTotalMs())
    }

    dispose_unsubscribes_run_lifecycle()
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
        ; Second Dispose must not throw
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.LoadingMeasured))
    }
}

TestRegistry.Register(LoadingTotalsServiceTests)
