; ============================================================
; ZoneTrackingServiceTests
; ============================================================
;
; ZoneTrackingService is the heart of per-zone tracking. Subscribes
; to 8 bus events, state machine with run-active + timer-paused, and
; queries with specific semantics (with/without elapsed from the
; active zone).
;
; Deps:
;   bus     : EventBus
;   clock   : NowMs() (controlled via FakeClock for determinism)
;   catalog : ZonesCatalog or "" (optional)
;
; Behaviors covered:
;   - Constructor + validation + 8 subscribers + Dispose
;   - Defaults + initial state
;   - ZoneChanged: with/without active run, with/without catalog,
;     during pause
;   - Queries: GetActiveElapsedMs, GetZoneTotal[WithActive],
;     GetTotals, GetTotalsForSnapshot, GetActTotals,
;     GetTownTotalsByAct, GetTotalTownMs, GetTotalRunMs
;   - Lifecycle: RunStarted/Reset/Cancelled/Completed
;   - Timer: Paused/Resumed/Stopped (incl. Bug Lechtansi and
;     the TimerStopped flush-before-zero anti-pattern)
;   - Hydrate / SetRunActive / Reset
;   - Published events: ZoneEntered, ZoneTimeAccumulated


class ZoneTrackingServiceTests extends TestCase
{
    bus          := ""
    stubClock    := ""
    catalog      := ""
    catalogPath  := ""
    svc          := ""

    Setup()
    {
        this.bus       := Fixtures.MakeBus()
        this.stubClock := Fixtures.MakeFakeClock(10000)   ; starts at 10s

        ; Test catalog with 4 zones
        this.catalogPath := Fixtures.TempPath("csv")
        this._SeedCatalog([
            "name;internal_id;act;is_town",
            "Clearfell Encampment;G1_town;1;1",
            "Mud Burrow;G1_2;1;0",
            "The Ardura Caravan;G2_town;2;1",
            "Vastiri Outskirts;G2_1;2;0"
        ])
        this.catalog := ZonesCatalog(this.catalogPath)

        this.svc := ZoneTrackingService(this.bus, this.stubClock, this.catalog)
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
        "constructor_throws_when_catalog_is_random_object",
        "constructor_accepts_empty_catalog",
        "constructor_subscribes_to_zone_changed",
        "constructor_subscribes_to_all_timer_events",
        "constructor_subscribes_to_all_run_lifecycle_events",

        ; --- Defaults ---
        "active_zone_empty_initially",
        "active_elapsed_zero_initially",
        "is_active_false_initially",
        "is_run_active_false_initially",
        "totals_empty_initially",

        ; --- ZoneChanged without active run ---
        "zone_changed_without_run_sets_active_zone",
        "zone_changed_without_run_does_not_start_timer",
        "zone_changed_ignores_non_object_data",
        "zone_changed_ignores_missing_zone_name",
        "zone_changed_ignores_empty_zone_name",
        "zone_changed_publishes_zone_entered_event",

        ; --- ZoneChanged with active run ---
        "zone_changed_during_run_starts_timer_at_now_ms",
        "zone_changed_during_run_flushes_previous_zone",
        "zone_changed_during_run_publishes_zone_entered",
        "zone_entered_includes_act_idx_from_catalog",
        "zone_entered_includes_is_town_from_catalog",
        "zone_entered_act_zero_when_zone_not_in_catalog",
        "zone_entered_act_zero_when_no_catalog",

        ; --- stage propagation (B1 Layer B) ---
        "zone_entered_default_stage_is_normal_when_zone_changed_omits_it",
        "zone_entered_carries_interlude_stage_from_zone_changed",
        "zone_entered_carries_explicit_normal_stage",
        "zone_entered_empty_stage_falls_back_to_normal",

        ; --- ZoneChanged during pause (Bug Lechtansi) ---
        "zone_changed_during_pause_sets_active_zone",
        "zone_changed_during_pause_does_not_start_timer",

        ; --- GetActiveElapsedMs ---
        "get_active_elapsed_zero_when_no_active_zone",
        "get_active_elapsed_zero_when_start_ms_zero",
        "get_active_elapsed_returns_elapsed_since_start",
        "get_active_elapsed_clamps_to_zero_for_negative",

        ; --- GetZoneTotal + WithActive ---
        "get_zone_total_zero_for_unknown_zone",
        "get_zone_total_zero_for_empty_string",
        "get_zone_total_returns_accumulated_after_flush",
        "get_zone_total_with_active_includes_elapsed_for_active",
        "get_zone_total_with_active_just_returns_base_for_other_zone",

        ; --- GetTotals / GetTotalsForSnapshot ---
        "get_totals_returns_defensive_copy",
        "get_totals_for_snapshot_includes_active_zone_elapsed",
        "get_totals_for_snapshot_does_not_modify_internal_state",
        "get_totals_for_snapshot_skips_active_when_start_ms_zero",
        "get_totals_for_snapshot_accumulates_when_active_zone_in_totals",

        ; --- GetActTotals + GetTownTotalsByAct ---
        "get_act_totals_returns_empty_when_no_catalog",
        "get_act_totals_groups_zones_by_act",
        "get_act_totals_ignores_unknown_zones",
        "get_town_totals_by_act_filters_towns_only",

        ; --- GetTotalTownMs ---
        "get_total_town_ms_zero_when_no_catalog",
        "get_total_town_ms_sums_only_town_zones",
        "get_total_town_ms_includes_active_when_town",
        "get_total_town_ms_excludes_active_when_not_town",

        ; --- GetTotalRunMs ---
        "get_total_run_ms_sums_all_totals",
        "get_total_run_ms_includes_active_elapsed",

        ; --- RunStarted ---
        "run_started_zeroes_totals",
        "run_started_sets_run_active_true",
        "run_started_starts_timer_when_zone_already_known",
        "run_started_does_not_start_timer_when_no_active_zone",
        "run_started_with_hydrated_flag_preserves_totals",
        "run_started_without_hydrated_flag_wipes_totals",

        ; --- RunReset / RunCancelled ---
        "run_reset_clears_totals_and_active_zone",
        "run_reset_sets_run_active_false",
        "run_cancelled_clears_state_same_as_reset",

        ; --- RunCompleted ---
        "run_completed_flushes_active_zone_to_totals",
        "run_completed_preserves_totals_for_final_plot",
        "run_completed_sets_run_active_false",

        ; --- TimerPaused / Resumed (Bug Lechtansi) ---
        "timer_paused_flushes_active_zone",
        "timer_paused_keeps_active_zone_logical",
        "timer_paused_zeroes_start_ms",
        "timer_resumed_restarts_start_ms_for_active_zone",
        "timer_resumed_does_nothing_without_active_zone",
        "timer_resumed_does_nothing_without_run_active",
        "timer_paused_then_zone_changed_does_not_restart_timer",

        ; --- TimerStopped (flush before zeroing _startMs) ---
        "timer_stopped_flushes_active_zone_before_zeroing",
        "timer_stopped_keeps_active_zone",

        ; --- Hydrate ---
        "hydrate_throws_when_not_map",
        "hydrate_restores_totals",
        "hydrate_clears_active_zone",
        "hydrate_clears_start_ms",

        ; --- SetRunActive ---
        "set_run_active_true_sets_flag",
        "set_run_active_true_starts_timer_when_zone_known",
        "set_run_active_false_clears_flag",
        "set_run_active_does_not_start_timer_when_zone_empty",

        ; --- Manual Reset ---
        "reset_clears_totals",
        "reset_clears_active_zone",
        "reset_clears_run_active_flag",

        ; --- Dispose ---
        "dispose_unsubscribes_zone_changed",
        "dispose_unsubscribes_all_timer_events",
        "dispose_unsubscribes_all_run_lifecycle",
        "dispose_is_idempotent",

        ; --- ZoneTimeAccumulated publish ---
        "flush_publishes_zone_time_accumulated",
        "flush_does_not_publish_when_elapsed_zero",
        "zone_time_accumulated_includes_zone_name_duration_total",

        ; --- GetCurrentVisitMs / _currentVisitMs ---
        "current_visit_ms_zero_at_construction",
        "current_visit_ms_returns_live_elapsed_during_active_zone",
        "current_visit_ms_survives_timer_pause_resume",
        "current_visit_ms_includes_post_stopped_value",
        "current_visit_ms_resets_on_zone_change",
        "current_visit_ms_accumulates_after_zone_change",
        "current_visit_ms_resets_on_run_started_fresh",
        "current_visit_ms_preserved_on_hydrated_run_started",
        "current_visit_ms_resets_on_run_reset",
        "current_visit_ms_resets_on_run_cancelled",
        "current_visit_ms_resets_on_run_completed",
        "current_visit_ms_resets_on_manual_reset",
        "current_visit_ms_zero_after_hydrate",
        "current_visit_ms_finalize_sequence_returns_interrupted_time"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _SeedCatalog(lines)
    {
        content := ""
        for _, csvLine in lines
            content .= csvLine "`n"
        FileAppend(content, this.catalogPath, "UTF-8")
    }

    ; Captures bus events into an array (subscribe handler).
    ; Returns a ref to the array that will be mutated by handlers.
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
        clk := this.stubClock
        cat := this.catalog
        Assert.Throws(TypeError, () => ZoneTrackingService("not a bus", clk, cat))
    }

    constructor_throws_when_clock_missing_now_ms()
    {
        b := this.bus
        cat := this.catalog
        emptyObj := { foo: () => 0 }
        Assert.Throws(TypeError, () => ZoneTrackingService(b, emptyObj, cat))
    }

    constructor_throws_when_catalog_is_random_object()
    {
        b := this.bus
        clk := this.stubClock
        Assert.Throws(TypeError, () => ZoneTrackingService(b, clk, {not: "catalog"}))
    }

    constructor_accepts_empty_catalog()
    {
        svc2 := ZoneTrackingService(this.bus, this.stubClock, "")
        Assert.True(IsObject(svc2))
        svc2.Dispose()
    }

    constructor_subscribes_to_zone_changed()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.ZoneChanged))
    }

    constructor_subscribes_to_all_timer_events()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.TimerPaused))
        Assert.Equal(1, this.bus.Subscribers(Events.TimerResumed))
        Assert.Equal(1, this.bus.Subscribers(Events.TimerStopped))
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

    active_zone_empty_initially()   => Assert.Equal("", this.svc.GetActiveZone())
    active_elapsed_zero_initially() => Assert.Equal(0,  this.svc.GetActiveElapsedMs())
    is_active_false_initially()     => Assert.False(this.svc.IsActive())
    is_run_active_false_initially() => Assert.False(this.svc.IsRunActive())
    totals_empty_initially()        => Assert.Equal(0,  this.svc.GetTotals().Count)

    ; ============================================================
    ; ZoneChanged without active run
    ; ============================================================

    zone_changed_without_run_sets_active_zone()
    {
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.Equal("Mud Burrow", this.svc.GetActiveZone())
    }

    zone_changed_without_run_does_not_start_timer()
    {
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.False(this.svc.IsActive(), "Without a run, IsActive must stay false")
        Assert.Equal(0, this.svc.GetActiveElapsedMs())
    }

    zone_changed_ignores_non_object_data()
    {
        this.bus.Publish(Events.ZoneChanged, "not a map")
        Assert.Equal("", this.svc.GetActiveZone())
    }

    zone_changed_ignores_missing_zone_name()
    {
        this.bus.Publish(Events.ZoneChanged, Map("other", "value"))
        Assert.Equal("", this.svc.GetActiveZone())
    }

    zone_changed_ignores_empty_zone_name()
    {
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", ""))
        Assert.Equal("", this.svc.GetActiveZone())
    }

    zone_changed_publishes_zone_entered_event()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneEntered)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.Equal(1, capturedEvents.Length)
    }

    ; ============================================================
    ; ZoneChanged with active run
    ; ============================================================

    zone_changed_during_run_starts_timer_at_now_ms()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.stubClock.AdvanceMs(5000)   ; clock = 15000
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.True(this.svc.IsActive())
        Assert.Equal(0, this.svc.GetActiveElapsedMs(), "Same NowMs after start = 0 elapsed")
        this.stubClock.AdvanceMs(3000)
        Assert.Equal(3000, this.svc.GetActiveElapsedMs())
    }

    zone_changed_during_run_flushes_previous_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(5000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        Assert.Equal(5000, this.svc.GetZoneTotal("Mud Burrow"), "Previous zone flushed")
        Assert.Equal("Vastiri Outskirts", this.svc.GetActiveZone())
    }

    zone_changed_during_run_publishes_zone_entered()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneEntered)
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.Equal(1, capturedEvents.Length)
        Assert.Equal("Mud Burrow", capturedEvents[1]["zoneName"])
    }

    zone_entered_includes_act_idx_from_catalog()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneEntered)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        Assert.Equal(2, capturedEvents[1]["actIndex"], "Vastiri Outskirts is Act 2")
    }

    zone_entered_includes_is_town_from_catalog()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneEntered)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Clearfell Encampment"))
        Assert.True(capturedEvents[1]["isTown"], "Clearfell Encampment is a town")

        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.False(capturedEvents[2]["isTown"], "Mud Burrow is not a town")
    }

    zone_entered_act_zero_when_zone_not_in_catalog()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneEntered)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Unknown Zone"))
        Assert.Equal(0, capturedEvents[1]["actIndex"])
        Assert.False(capturedEvents[1]["isTown"])
    }

    zone_entered_act_zero_when_no_catalog()
    {
        ; Create separate bus + svc to avoid interference from this.svc
        ; (which has a catalog and would mask the test by publishing
        ; actIndex=1).
        bus2 := Fixtures.MakeBus()
        svc2 := ZoneTrackingService(bus2, this.stubClock, "")
        capturedEvents := []
        bus2.Subscribe(Events.ZoneEntered, (data) => capturedEvents.Push(data))
        bus2.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.Equal(0, capturedEvents[1]["actIndex"])
        Assert.False(capturedEvents[1]["isTown"])
        svc2.Dispose()
    }

    ; ============================================================
    ; stage propagation (B1 Layer B)
    ; ============================================================
    ;
    ; LogMonitorService sets stage on ZoneChanged ("normal" for the
    ; [SCENE] branch, "interlude" for the cruel area-gen branch).
    ; ZoneTrackingService forwards it on the outgoing ZoneEntered
    ; so subscribers like ActCheckpointTracker can bucket their
    ; state per-(act, stage). Default "normal" defends against
    ; legacy/programmatic emitters that omit the field.

    zone_entered_default_stage_is_normal_when_zone_changed_omits_it()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneEntered)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.Equal("normal", capturedEvents[1]["stage"])
    }

    zone_entered_carries_interlude_stage_from_zone_changed()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneEntered)
        this.bus.Publish(Events.ZoneChanged, Map(
            "zoneName", "Mud Burrow",
            "stage",    "interlude"
        ))
        Assert.Equal("interlude", capturedEvents[1]["stage"])
    }

    zone_entered_carries_explicit_normal_stage()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneEntered)
        this.bus.Publish(Events.ZoneChanged, Map(
            "zoneName", "Mud Burrow",
            "stage",    "normal"
        ))
        Assert.Equal("normal", capturedEvents[1]["stage"])
    }

    zone_entered_empty_stage_falls_back_to_normal()
    {
        ; Defensive: an explicit empty string is treated as missing.
        capturedEvents := this._CaptureEvents(Events.ZoneEntered)
        this.bus.Publish(Events.ZoneChanged, Map(
            "zoneName", "Mud Burrow",
            "stage",    ""
        ))
        Assert.Equal("normal", capturedEvents[1]["stage"])
    }

    ; ============================================================
    ; ZoneChanged during pause (Bug Lechtansi)
    ; ============================================================

    zone_changed_during_pause_sets_active_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.bus.Publish(Events.TimerPaused, Map())
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        Assert.Equal("Vastiri Outskirts", this.svc.GetActiveZone(),
            "Active zone must reflect new zone even during pause")
    }

    zone_changed_during_pause_does_not_start_timer()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.TimerPaused, Map())
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.False(this.svc.IsActive(),
            "During pause, ZoneChanged doesn't restart the timer (Bug Lechtansi)")
        this.stubClock.AdvanceMs(5000)
        Assert.Equal(0, this.svc.GetActiveElapsedMs())
    }

    ; ============================================================
    ; GetActiveElapsedMs
    ; ============================================================

    get_active_elapsed_zero_when_no_active_zone()
    {
        this.stubClock.AdvanceMs(5000)
        Assert.Equal(0, this.svc.GetActiveElapsedMs())
    }

    get_active_elapsed_zero_when_start_ms_zero()
    {
        ; Set zone without run = _startMs stays 0
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(5000)
        Assert.Equal(0, this.svc.GetActiveElapsedMs())
    }

    get_active_elapsed_returns_elapsed_since_start()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(7000)
        Assert.Equal(7000, this.svc.GetActiveElapsedMs())
    }

    get_active_elapsed_clamps_to_zero_for_negative()
    {
        ; Edge case: clock went back (e.g., system clock change).
        ; Service must clamp to 0 instead of returning negative.
        ; FakeClock.AdvanceMs accepts negative values (`_tickMs += ms`).
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(-7000)   ; clock goes below _startMs
        Assert.Equal(0, this.svc.GetActiveElapsedMs())
    }

    ; ============================================================
    ; GetZoneTotal + WithActive
    ; ============================================================

    get_zone_total_zero_for_unknown_zone()
    {
        Assert.Equal(0, this.svc.GetZoneTotal("Never Visited"))
    }

    get_zone_total_zero_for_empty_string()
    {
        Assert.Equal(0, this.svc.GetZoneTotal(""))
    }

    get_zone_total_returns_accumulated_after_flush()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        Assert.Equal(3000, this.svc.GetZoneTotal("Mud Burrow"))
    }

    get_zone_total_with_active_includes_elapsed_for_active()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        this.stubClock.AdvanceMs(2000)
        ; Mud Burrow flushed (3000), Vastiri active for 2000
        Assert.Equal(2000, this.svc.GetZoneTotalWithActive("Vastiri Outskirts"))
    }

    get_zone_total_with_active_just_returns_base_for_other_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        this.stubClock.AdvanceMs(2000)
        ; Mud Burrow is not active: only returns flushed base (3000)
        Assert.Equal(3000, this.svc.GetZoneTotalWithActive("Mud Burrow"))
    }

    ; ============================================================
    ; GetTotals / GetTotalsForSnapshot
    ; ============================================================

    get_totals_returns_defensive_copy()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        copy := this.svc.GetTotals()
        copy["Hacked"] := 999
        Assert.False(this.svc.GetTotals().Has("Hacked"))
    }

    get_totals_for_snapshot_includes_active_zone_elapsed()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(4000)
        snap := this.svc.GetTotalsForSnapshot()
        Assert.Equal(4000, snap["Mud Burrow"], "Includes elapsed from the active zone")
    }

    get_totals_for_snapshot_does_not_modify_internal_state()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(4000)
        this.svc.GetTotalsForSnapshot()
        ; Internal state must not have been flushed
        Assert.Equal(0, this.svc.GetZoneTotal("Mud Burrow"),
            "GetTotalsForSnapshot doesn't flush — _totals still lacks this zone")
        Assert.True(this.svc.IsActive(), "Stays active")
    }

    get_totals_for_snapshot_skips_active_when_start_ms_zero()
    {
        ; Zone registered but no run = startMs=0 = doesn't enter snapshot
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        snap := this.svc.GetTotalsForSnapshot()
        Assert.False(snap.Has("Mud Burrow"))
    }

    get_totals_for_snapshot_accumulates_when_active_zone_in_totals()
    {
        ; Scenario: zone visited before (flushed to _totals), then
        ; revisited (active again). Snapshot sums both.
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        this.stubClock.AdvanceMs(1000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))   ; revisit
        this.stubClock.AdvanceMs(2000)
        snap := this.svc.GetTotalsForSnapshot()
        Assert.Equal(5000, snap["Mud Burrow"], "3000 flushed + 2000 active")
    }

    ; ============================================================
    ; GetActTotals + GetTownTotalsByAct
    ; ============================================================

    get_act_totals_returns_empty_when_no_catalog()
    {
        svc2 := ZoneTrackingService(this.bus, this.stubClock, "")
        Assert.Equal(0, svc2.GetActTotals().Count)
        svc2.Dispose()
    }

    get_act_totals_groups_zones_by_act()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))   ; act 1
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Clearfell Encampment"))   ; act 1
        this.stubClock.AdvanceMs(1000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))   ; act 2
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))   ; flush last

        acts := this.svc.GetActTotals()
        Assert.Equal(4000, acts[1], "Act 1 = Mud Burrow + Clearfell")
        Assert.Equal(2000, acts[2], "Act 2 = Vastiri Outskirts")
    }

    get_act_totals_ignores_unknown_zones()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Unknown Zone"))
        this.stubClock.AdvanceMs(5000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.Equal(0, this.svc.GetActTotals().Count,
            "Unknown zone (no catalog entry) is ignored")
    }

    get_town_totals_by_act_filters_towns_only()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Clearfell Encampment"))   ; town act 1
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))   ; zone act 1
        this.stubClock.AdvanceMs(5000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))   ; flush

        towns := this.svc.GetTownTotalsByAct()
        Assert.Equal(2000, towns[1], "Only Clearfell, not Mud Burrow")
        Assert.False(towns.Has(2), "No town in act 2 visited")
    }

    ; ============================================================
    ; GetTotalTownMs
    ; ============================================================

    get_total_town_ms_zero_when_no_catalog()
    {
        svc2 := ZoneTrackingService(this.bus, this.stubClock, "")
        Assert.Equal(0, svc2.GetTotalTownMs())
        svc2.Dispose()
    }

    get_total_town_ms_sums_only_town_zones()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Clearfell Encampment"))   ; town
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))   ; not a town
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "The Ardura Caravan"))   ; town
        this.stubClock.AdvanceMs(1000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))   ; flush last

        Assert.Equal(3000, this.svc.GetTotalTownMs(), "Clearfell (2000) + Ardura (1000)")
    }

    get_total_town_ms_includes_active_when_town()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Clearfell Encampment"))   ; active town
        this.stubClock.AdvanceMs(2500)
        Assert.Equal(2500, this.svc.GetTotalTownMs(),
            "Includes elapsed of the active town (even without flush)")
    }

    get_total_town_ms_excludes_active_when_not_town()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))   ; NOT a town
        this.stubClock.AdvanceMs(2500)
        Assert.Equal(0, this.svc.GetTotalTownMs())
    }

    ; ============================================================
    ; GetTotalRunMs
    ; ============================================================

    get_total_run_ms_sums_all_totals()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))   ; flush
        Assert.Equal(5000, this.svc.GetTotalRunMs())
    }

    get_total_run_ms_includes_active_elapsed()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(4000)
        Assert.Equal(4000, this.svc.GetTotalRunMs(), "Includes active elapsed")
    }

    ; ============================================================
    ; RunStarted
    ; ============================================================

    run_started_zeroes_totals()
    {
        ; Populate totals first via a "previous run"
        this.bus.Publish(Events.RunStarted, Map("runId", "old"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))
        Assert.Equal(3000, this.svc.GetZoneTotal("Mud Burrow"))

        ; New run zeroes
        this.bus.Publish(Events.RunStarted, Map("runId", "new"))
        Assert.Equal(0, this.svc.GetTotals().Count)
    }

    run_started_sets_run_active_true()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        Assert.True(this.svc.IsRunActive())
    }

    run_started_starts_timer_when_zone_already_known()
    {
        ; ZoneChanged BEFORE RunStarted (seeded by LogMonitor)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.False(this.svc.IsActive(), "Not timing yet")

        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        Assert.True(this.svc.IsActive(), "RunStarted activated the timer")
        this.stubClock.AdvanceMs(1000)
        Assert.Equal(1000, this.svc.GetActiveElapsedMs())
    }

    run_started_does_not_start_timer_when_no_active_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        Assert.False(this.svc.IsActive())
    }

    run_started_with_hydrated_flag_preserves_totals()
    {
        ; Anti-regression: SpeedKalandraApp.__New defers
        ; runService.Hydrate to the very end of construction so that
        ; subscribers constructed downstream (RunStatsRecorder, etc.)
        ; receive the RunStarted event. By the time the event fires,
        ; ZoneTrackingService has already been hydrated from disk
        ; (Hydrate(map) + SetRunActive(true)). If _OnRunStarted wiped
        ; _totals here, every ms tracked before the previous shutdown
        ; would be lost. The hydrated:true flag instructs the handler
        ; to skip the wipe.
        this.svc.Hydrate(Map("The Riverbank", 180000, "Mud Burrow", 60000))
        this.svc.SetRunActive(true)

        this.bus.Publish(Events.RunStarted, Map(
            "runId", "hydrated_run",
            "hydrated", true
        ))

        Assert.Equal(180000, this.svc.GetZoneTotal("The Riverbank"),
            "Hydrated totals must survive RunStarted{hydrated:true}")
        Assert.Equal(60000, this.svc.GetZoneTotal("Mud Burrow"))
        Assert.True(this.svc.IsRunActive(),
            "Run-active flag stays true after hydrated RunStarted")
    }

    run_started_without_hydrated_flag_wipes_totals()
    {
        ; Negative case for the previous test: a normal new run
        ; (no hydrated flag) must STILL wipe totals — otherwise a
        ; fresh run would inherit ghost time from the previous one.
        this.svc.Hydrate(Map("Some Zone", 12345))

        this.bus.Publish(Events.RunStarted, Map("runId", "fresh"))

        Assert.Equal(0, this.svc.GetZoneTotal("Some Zone"),
            "Normal RunStarted (no hydrated flag) still wipes totals")
        Assert.True(this.svc.IsRunActive())
    }

    ; ============================================================
    ; RunReset / RunCancelled
    ; ============================================================

    run_reset_clears_totals_and_active_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.RunReset, Map())
        Assert.Equal(0,  this.svc.GetTotals().Count)
        Assert.Equal("", this.svc.GetActiveZone())
    }

    run_reset_sets_run_active_false()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.RunReset, Map())
        Assert.False(this.svc.IsRunActive())
    }

    run_cancelled_clears_state_same_as_reset()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.RunCancelled, Map())
        Assert.Equal(0,  this.svc.GetTotals().Count)
        Assert.Equal("", this.svc.GetActiveZone())
        Assert.False(this.svc.IsRunActive())
    }

    ; ============================================================
    ; RunCompleted
    ; ============================================================

    run_completed_flushes_active_zone_to_totals()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(4500)
        this.bus.Publish(Events.RunCompleted, Map())
        Assert.Equal(4500, this.svc.GetZoneTotal("Mud Burrow"))
    }

    run_completed_preserves_totals_for_final_plot()
    {
        ; Unlike Reset/Cancelled, Completed does NOT zero _totals
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.RunCompleted, Map())
        Assert.True(this.svc.GetTotals().Count > 0,
            "RunCompleted preserves totals for the final plot")
    }

    run_completed_sets_run_active_false()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.RunCompleted, Map())
        Assert.False(this.svc.IsRunActive())
    }

    ; ============================================================
    ; TimerPaused / Resumed (Bug Lechtansi)
    ; ============================================================

    timer_paused_flushes_active_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2500)
        this.bus.Publish(Events.TimerPaused, Map())
        Assert.Equal(2500, this.svc.GetZoneTotal("Mud Burrow"),
            "TimerPaused flush sums elapsed into _totals")
    }

    timer_paused_keeps_active_zone_logical()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2500)
        this.bus.Publish(Events.TimerPaused, Map())
        Assert.Equal("Mud Burrow", this.svc.GetActiveZone(),
            "Logical zone preserved (keepActive=true)")
    }

    timer_paused_zeroes_start_ms()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2500)
        this.bus.Publish(Events.TimerPaused, Map())
        this.stubClock.AdvanceMs(10000)   ; time passes
        Assert.Equal(0, this.svc.GetActiveElapsedMs(),
            "_startMs zeroed, elapsed doesn't accumulate during pause")
    }

    timer_resumed_restarts_start_ms_for_active_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.TimerPaused, Map())
        this.stubClock.AdvanceMs(5000)   ; 5s pause should not count
        this.bus.Publish(Events.TimerResumed, Map())
        this.stubClock.AdvanceMs(1000)
        Assert.Equal(1000, this.svc.GetActiveElapsedMs(),
            "Only post-resume elapsed (pause not counted)")
    }

    timer_resumed_does_nothing_without_active_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.TimerResumed, Map())
        Assert.False(this.svc.IsActive())
    }

    timer_resumed_does_nothing_without_run_active()
    {
        ; Zone set WITHOUT active run, then TimerResumed
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.bus.Publish(Events.TimerResumed, Map())
        Assert.False(this.svc.IsActive(),
            "Without active run, TimerResumed doesn't restore the timer")
    }

    timer_paused_then_zone_changed_does_not_restart_timer()
    {
        ; Bug Lechtansi: ZoneChanged during pause doesn't restart _startMs
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.TimerPaused, Map())
        this.stubClock.AdvanceMs(1000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        this.stubClock.AdvanceMs(5000)
        Assert.False(this.svc.IsActive(),
            "Bug Lechtansi: ZoneChanged during pause does NOT restart timer")
        Assert.Equal(0, this.svc.GetActiveElapsedMs())
    }

    ; ============================================================
    ; TimerStopped (flush before zeroing _startMs)
    ; ============================================================
    ;
    ; Anti-pattern: a previous version of _OnTimerStopped zeroed
    ; _startMs without flushing first. FinalizeRun -> timer.Stop ->
    ; TimerStopped then ran ahead of RunCompleted's flush attempt,
    ; and the time since the last ZoneChanged was lost in every
    ; finalized run. The handler now calls _FlushActive(true) BEFORE
    ; zeroing.

    timer_stopped_flushes_active_zone_before_zeroing()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3500)
        this.bus.Publish(Events.TimerStopped, Map())
        Assert.Equal(3500, this.svc.GetZoneTotal("Mud Burrow"),
            "flush BEFORE zeroing _startMs (anti-regression)")
    }

    timer_stopped_keeps_active_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.TimerStopped, Map())
        Assert.Equal("Mud Burrow", this.svc.GetActiveZone(),
            "TimerStopped uses keepActive=true")
    }

    ; ============================================================
    ; Hydrate
    ; ============================================================

    hydrate_throws_when_not_map()
    {
        s := this.svc
        Assert.Throws(TypeError, () => s.Hydrate("not a map"))
        Assert.Throws(TypeError, () => s.Hydrate([1, 2, 3]))
    }

    hydrate_restores_totals()
    {
        this.svc.Hydrate(Map("Clearfell Encampment", 50000, "Mud Burrow", 30000))
        Assert.Equal(50000, this.svc.GetZoneTotal("Clearfell Encampment"))
        Assert.Equal(30000, this.svc.GetZoneTotal("Mud Burrow"))
    }

    hydrate_clears_active_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.svc.Hydrate(Map("Other Zone", 1000))
        Assert.Equal("", this.svc.GetActiveZone())
    }

    hydrate_clears_start_ms()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.svc.Hydrate(Map())
        Assert.Equal(0, this.svc.GetActiveElapsedMs())
    }

    ; ============================================================
    ; SetRunActive
    ; ============================================================

    set_run_active_true_sets_flag()
    {
        this.svc.SetRunActive(true)
        Assert.True(this.svc.IsRunActive())
    }

    set_run_active_true_starts_timer_when_zone_known()
    {
        ; Boot scenario: Hydrate followed by SetRunActive(true) with a
        ; known zone
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.svc.SetRunActive(true)
        this.stubClock.AdvanceMs(1000)
        Assert.True(this.svc.IsActive())
        Assert.Equal(1000, this.svc.GetActiveElapsedMs())
    }

    set_run_active_false_clears_flag()
    {
        this.svc.SetRunActive(true)
        this.svc.SetRunActive(false)
        Assert.False(this.svc.IsRunActive())
    }

    set_run_active_does_not_start_timer_when_zone_empty()
    {
        this.svc.SetRunActive(true)
        Assert.False(this.svc.IsActive(),
            "Without a known zone, SetRunActive(true) doesn't start the timer")
    }

    ; ============================================================
    ; Manual Reset
    ; ============================================================

    reset_clears_totals()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))   ; flush
        this.svc.Reset()
        Assert.Equal(0, this.svc.GetTotals().Count)
    }

    reset_clears_active_zone()
    {
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.svc.Reset()
        Assert.Equal("", this.svc.GetActiveZone())
    }

    reset_clears_run_active_flag()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.svc.Reset()
        Assert.False(this.svc.IsRunActive())
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_zone_changed()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.ZoneChanged))
    }

    dispose_unsubscribes_all_timer_events()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.TimerPaused))
        Assert.Equal(0, this.bus.Subscribers(Events.TimerResumed))
        Assert.Equal(0, this.bus.Subscribers(Events.TimerStopped))
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
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.ZoneChanged))
    }

    ; ============================================================
    ; ZoneTimeAccumulated publish
    ; ============================================================

    flush_publishes_zone_time_accumulated()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneTimeAccumulated)
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2500)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))   ; trigger flush
        Assert.Equal(1, capturedEvents.Length)
    }

    flush_does_not_publish_when_elapsed_zero()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneTimeAccumulated)
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        ; no AdvanceMs = elapsed=0
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))
        Assert.Equal(0, capturedEvents.Length,
            "elapsed=0 doesn't publish ZoneTimeAccumulated")
    }

    zone_time_accumulated_includes_zone_name_duration_total()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneTimeAccumulated)
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))
        ev := capturedEvents[1]
        Assert.Equal("Mud Burrow", ev["zoneName"])
        Assert.Equal(3000,         ev["durationMs"])
        Assert.Equal(3000,         ev["totalMs"])
    }

    ; ============================================================
    ; GetCurrentVisitMs / _currentVisitMs
    ; ============================================================
    ;
    ; Per-visit accumulator that survives pause/resume and
    ; TimerStopped (which keep _activeZone alive). RunSnapshotSaver
    ; reads it in the OnBeforeFinalize hook to discount the
    ; interrupted-by-hotkey visit from PB-eligible zone totals --
    ; the visit never closed via transition, so it isn't PB-eligible.

    current_visit_ms_zero_at_construction()
    {
        Assert.Equal(0, this.svc.GetCurrentVisitMs())
    }

    current_visit_ms_returns_live_elapsed_during_active_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        Assert.Equal(3000, this.svc.GetCurrentVisitMs(),
            "Live elapsed from the active visit is included")
    }

    current_visit_ms_survives_timer_pause_resume()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.TimerPaused, Map())   ; accumulator += 2000
        this.stubClock.AdvanceMs(5000)                ; pause time doesn't count
        this.bus.Publish(Events.TimerResumed, Map())
        this.stubClock.AdvanceMs(1500)
        Assert.Equal(3500, this.svc.GetCurrentVisitMs(),
            "Pre-pause (2000) + post-resume (1500); pause time excluded")
    }

    current_visit_ms_includes_post_stopped_value()
    {
        ; Production sequence's primary case: hotkey -> TimerStopped
        ; flushes the visit's elapsed into the accumulator and zeroes
        ; _startMs (so live elapsed is 0). The accumulator equals the
        ; interrupted visit's total at this point -- this is what
        ; RunSnapshotSaver reads in OnBeforeFinalize.
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3500)
        this.bus.Publish(Events.TimerStopped, Map())
        Assert.Equal(3500, this.svc.GetCurrentVisitMs(),
            "After TimerStopped, accumulator holds the interrupted visit's time")
    }

    current_visit_ms_resets_on_zone_change()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        Assert.Equal(0, this.svc.GetCurrentVisitMs(),
            "New visit starts at zero; previous visit closed via transition")
    }

    current_visit_ms_accumulates_after_zone_change()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        this.stubClock.AdvanceMs(2000)
        Assert.Equal(2000, this.svc.GetCurrentVisitMs(),
            "Tracks only the current visit (Vastiri), not the previous Mud Burrow")
    }

    current_visit_ms_resets_on_run_started_fresh()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "old"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.TimerPaused, Map())            ; accumulator = 2000
        this.bus.Publish(Events.RunStarted, Map("runId", "new"))
        Assert.Equal(0, this.svc.GetCurrentVisitMs(),
            "Fresh RunStarted (non-hydrate) wipes the visit accumulator")
    }

    current_visit_ms_preserved_on_hydrated_run_started()
    {
        ; Hydrate zeroes _currentVisitMs, and RunStarted{hydrated:true}
        ; does NOT touch it -- so it stays zero. Pairs with the
        ; non-persistence decision documented in KNOWN_ISSUES.
        this.svc.Hydrate(Map("Mud Burrow", 60000))
        this.svc.SetRunActive(true)
        this.bus.Publish(Events.RunStarted, Map("runId", "hydrated", "hydrated", true))
        Assert.Equal(0, this.svc.GetCurrentVisitMs(),
            "Hydrated RunStarted leaves the accumulator at zero (post-Hydrate)")
    }

    current_visit_ms_resets_on_run_reset()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.TimerPaused, Map())   ; accumulator = 3000
        this.bus.Publish(Events.RunReset, Map())
        Assert.Equal(0, this.svc.GetCurrentVisitMs())
    }

    current_visit_ms_resets_on_run_cancelled()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.TimerPaused, Map())
        this.bus.Publish(Events.RunCancelled, Map())
        Assert.Equal(0, this.svc.GetCurrentVisitMs())
    }

    current_visit_ms_resets_on_run_completed()
    {
        ; Production sequence: TimerStopped -> RunCompleted. The
        ; defensive zero-out in _OnRunCompleted covers the early-out
        ; path in _FlushActive (where _startMs is already 0).
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.TimerStopped, Map())   ; accumulator = 3000, _startMs = 0
        this.bus.Publish(Events.RunCompleted, Map())
        Assert.Equal(0, this.svc.GetCurrentVisitMs(),
            "_OnRunCompleted defensively zeros the accumulator post-TimerStopped")
    }

    current_visit_ms_resets_on_manual_reset()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.TimerPaused, Map())
        this.svc.Reset()
        Assert.Equal(0, this.svc.GetCurrentVisitMs())
    }

    current_visit_ms_zero_after_hydrate()
    {
        this.svc.Hydrate(Map("Mud Burrow", 60000, "Vastiri Outskirts", 30000))
        Assert.Equal(0, this.svc.GetCurrentVisitMs(),
            "Hydrate zeroes the accumulator -- post-restart, no visit is in progress")
    }

    current_visit_ms_finalize_sequence_returns_interrupted_time()
    {
        ; End-to-end of the bug scenario: long visit in Z1, transition
        ; to Z2, then hotkey while still in Z2. The accumulator after
        ; TimerStopped equals only the interrupted (Z2) visit's time;
        ; Z1's 60s is in _totals but NOT in _currentVisitMs because
        ; that visit closed via transition.
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))   ; Z1
        this.stubClock.AdvanceMs(60000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))   ; transition
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.TimerStopped, Map())   ; hotkey

        Assert.Equal(3000, this.svc.GetCurrentVisitMs(),
            "Only the interrupted visit (3s in Vastiri Outskirts) is in the accumulator")
        Assert.Equal(60000, this.svc.GetZoneTotal("Mud Burrow"),
            "Z1's full visit is preserved in _totals (factual history)")
        Assert.Equal(3000, this.svc.GetZoneTotal("Vastiri Outskirts"),
            "Z2's interrupted visit is also in _totals (factual history)")
    }
}

TestRegistry.Register(ZoneTrackingServiceTests)
