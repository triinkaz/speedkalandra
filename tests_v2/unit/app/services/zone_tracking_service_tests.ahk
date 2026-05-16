; ============================================================
; ZoneTrackingServiceTests
; ============================================================
;
; ZoneTrackingService eh o coracao do tracking por zona. Subscribers
; a 8 eventos do bus, state machine com run-active + timer-paused,
; e queries com semantica especifica (com/sem elapsed da zona ativa).
;
; Deps:
;   bus     : EventBus
;   clock   : NowMs() (controlado via FakeClock pra determinismo)
;   catalog : ZonesCatalog ou "" (opcional)
;
; Comportamentos cobertos:
;   - Construtor + validacao + 8 subscribers + Dispose
;   - Defaults + state inicial
;   - ZoneChanged: com/sem run ativa, com/sem catalog, durante pausa
;   - Queries: GetActiveElapsedMs, GetZoneTotal[WithActive], GetTotals,
;     GetTotalsForSnapshot, GetActTotals, GetTownTotalsByAct,
;     GetTotalTownMs, GetTotalRunMs
;   - Lifecycle: RunStarted/Reset/Cancelled/Completed
;   - Timer: Paused/Resumed/Stopped (inc Bug Lechtansi e Bug #1 v17.15)
;   - Hydrate / SetRunActive / Reset
;   - Eventos publicados: ZoneEntered, ZoneTimeAccumulated


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
        this.stubClock := Fixtures.MakeFakeClock(10000)   ; comeca em 10s

        ; Catalogo de teste com 4 zonas
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
        ; --- Construtor ---
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

        ; --- ZoneChanged sem run ativa ---
        "zone_changed_without_run_sets_active_zone",
        "zone_changed_without_run_does_not_start_timer",
        "zone_changed_ignores_non_object_data",
        "zone_changed_ignores_missing_zone_name",
        "zone_changed_ignores_empty_zone_name",
        "zone_changed_publishes_zone_entered_event",

        ; --- ZoneChanged com run ativa ---
        "zone_changed_during_run_starts_timer_at_now_ms",
        "zone_changed_during_run_flushes_previous_zone",
        "zone_changed_during_run_publishes_zone_entered",
        "zone_entered_includes_act_idx_from_catalog",
        "zone_entered_includes_is_town_from_catalog",
        "zone_entered_act_zero_when_zone_not_in_catalog",
        "zone_entered_act_zero_when_no_catalog",

        ; --- ZoneChanged durante pause (Bug Lechtansi) ---
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

        ; --- TimerStopped (Bug #1 v17.15) ---
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

        ; --- Reset manual ---
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
        "zone_time_accumulated_includes_zone_name_duration_total"
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

    ; Captura eventos do bus pra um array (handler subscribe).
    ; Retorna ref ao array que sera mutado pelos handlers.
    _CaptureEvents(eventName)
    {
        capturedEvents := []
        this.bus.Subscribe(eventName, (data) => capturedEvents.Push(data))
        return capturedEvents
    }

    ; ============================================================
    ; Construtor
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
    ; ZoneChanged sem run ativa
    ; ============================================================

    zone_changed_without_run_sets_active_zone()
    {
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.Equal("Mud Burrow", this.svc.GetActiveZone())
    }

    zone_changed_without_run_does_not_start_timer()
    {
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.False(this.svc.IsActive(), "Sem run, IsActive deve continuar false")
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
    ; ZoneChanged com run ativa
    ; ============================================================

    zone_changed_during_run_starts_timer_at_now_ms()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.stubClock.AdvanceMs(5000)   ; clock = 15000
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.True(this.svc.IsActive())
        Assert.Equal(0, this.svc.GetActiveElapsedMs(), "Mesmo NowMs apos start = 0 elapsed")
        this.stubClock.AdvanceMs(3000)
        Assert.Equal(3000, this.svc.GetActiveElapsedMs())
    }

    zone_changed_during_run_flushes_previous_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(5000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        Assert.Equal(5000, this.svc.GetZoneTotal("Mud Burrow"), "Zona anterior flushed")
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
        Assert.Equal(2, capturedEvents[1]["actIndex"], "Vastiri Outskirts eh Act 2")
    }

    zone_entered_includes_is_town_from_catalog()
    {
        capturedEvents := this._CaptureEvents(Events.ZoneEntered)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Clearfell Encampment"))
        Assert.True(capturedEvents[1]["isTown"], "Clearfell Encampment eh town")

        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.False(capturedEvents[2]["isTown"], "Mud Burrow nao eh town")
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
        ; Cria bus + svc separados pra evitar interferencia do this.svc
        ; (que tem catalog e mascararia o teste publicando actIndex=1).
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
    ; ZoneChanged durante pause (Bug Lechtansi - v0.1.1)
    ; ============================================================

    zone_changed_during_pause_sets_active_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.bus.Publish(Events.TimerPaused, Map())
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        Assert.Equal("Vastiri Outskirts", this.svc.GetActiveZone(),
            "Active zone deve refletir nova zona mesmo durante pause")
    }

    zone_changed_during_pause_does_not_start_timer()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.TimerPaused, Map())
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.False(this.svc.IsActive(),
            "Durante pause, ZoneChanged nao reinicia timer (Bug Lechtansi)")
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
        ; Set zone sem run = _startMs fica 0
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
        ; Edge case: clock voltou (e.g., system clock change). Service
        ; deve clampar pra 0 em vez de retornar negativo.
        ; FakeClock.AdvanceMs aceita valores negativos (`_tickMs += ms`).
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(-7000)   ; clock retrocede abaixo de _startMs
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
        ; Mud Burrow flushed (3000), Vastiri ativa por 2000
        Assert.Equal(2000, this.svc.GetZoneTotalWithActive("Vastiri Outskirts"))
    }

    get_zone_total_with_active_just_returns_base_for_other_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        this.stubClock.AdvanceMs(2000)
        ; Mud Burrow nao eh ativa: so retorna base flushed (3000)
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
        Assert.Equal(4000, snap["Mud Burrow"], "Inclui elapsed da zona ativa")
    }

    get_totals_for_snapshot_does_not_modify_internal_state()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(4000)
        this.svc.GetTotalsForSnapshot()
        ; State interno nao deve ter sido flushed
        Assert.Equal(0, this.svc.GetZoneTotal("Mud Burrow"),
            "GetTotalsForSnapshot nao faz flush — _totals continua sem essa zona")
        Assert.True(this.svc.IsActive(), "Continua active")
    }

    get_totals_for_snapshot_skips_active_when_start_ms_zero()
    {
        ; Zona registrada mas sem run = startMs=0 = nao inclui no snapshot
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        snap := this.svc.GetTotalsForSnapshot()
        Assert.False(snap.Has("Mud Burrow"))
    }

    get_totals_for_snapshot_accumulates_when_active_zone_in_totals()
    {
        ; Cenario: zona visitada antes (flushed pra _totals), depois
        ; revisitada (ativa de novo). Snapshot soma os dois.
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        this.stubClock.AdvanceMs(1000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))   ; revisita
        this.stubClock.AdvanceMs(2000)
        snap := this.svc.GetTotalsForSnapshot()
        Assert.Equal(5000, snap["Mud Burrow"], "3000 flushed + 2000 ativo")
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
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))   ; flush ultimo

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
            "Unknown zone (sem entry no catalog) eh ignorada")
    }

    get_town_totals_by_act_filters_towns_only()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Clearfell Encampment"))   ; town act 1
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))   ; zona act 1
        this.stubClock.AdvanceMs(5000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))   ; flush

        towns := this.svc.GetTownTotalsByAct()
        Assert.Equal(2000, towns[1], "So Clearfell, nao Mud Burrow")
        Assert.False(towns.Has(2), "Nenhuma town no act 2 visitada")
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
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))   ; nao town
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "The Ardura Caravan"))   ; town
        this.stubClock.AdvanceMs(1000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))   ; flush ultimo

        Assert.Equal(3000, this.svc.GetTotalTownMs(), "Clearfell (2000) + Ardura (1000)")
    }

    get_total_town_ms_includes_active_when_town()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Clearfell Encampment"))   ; town ativa
        this.stubClock.AdvanceMs(2500)
        Assert.Equal(2500, this.svc.GetTotalTownMs(),
            "Inclui elapsed da town ativa (mesmo sem flush)")
    }

    get_total_town_ms_excludes_active_when_not_town()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))   ; NAO town
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
        Assert.Equal(4000, this.svc.GetTotalRunMs(), "Inclui elapsed da ativa")
    }

    ; ============================================================
    ; RunStarted
    ; ============================================================

    run_started_zeroes_totals()
    {
        ; Popula totals primeiro via uma "run anterior"
        this.bus.Publish(Events.RunStarted, Map("runId", "old"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))
        Assert.Equal(3000, this.svc.GetZoneTotal("Mud Burrow"))

        ; Nova run zera
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
        ; ZoneChanged ANTES do RunStarted (seed do LogMonitor)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        Assert.False(this.svc.IsActive(), "Ainda nao timing")

        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        Assert.True(this.svc.IsActive(), "RunStarted ativou cronometro")
        this.stubClock.AdvanceMs(1000)
        Assert.Equal(1000, this.svc.GetActiveElapsedMs())
    }

    run_started_does_not_start_timer_when_no_active_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        Assert.False(this.svc.IsActive())
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
        ; Diferente de Reset/Cancelled, Completed NAO zera _totals
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3000)
        this.bus.Publish(Events.RunCompleted, Map())
        Assert.True(this.svc.GetTotals().Count > 0,
            "RunCompleted preserva totals pro plot final")
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
            "TimerPaused flush soma elapsed em _totals")
    }

    timer_paused_keeps_active_zone_logical()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2500)
        this.bus.Publish(Events.TimerPaused, Map())
        Assert.Equal("Mud Burrow", this.svc.GetActiveZone(),
            "Zona logica preservada (keepActive=true)")
    }

    timer_paused_zeroes_start_ms()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2500)
        this.bus.Publish(Events.TimerPaused, Map())
        this.stubClock.AdvanceMs(10000)   ; tempo passa
        Assert.Equal(0, this.svc.GetActiveElapsedMs(),
            "_startMs zerado, elapsed nao acumula durante pause")
    }

    timer_resumed_restarts_start_ms_for_active_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.TimerPaused, Map())
        this.stubClock.AdvanceMs(5000)   ; pause de 5s nao deveria contar
        this.bus.Publish(Events.TimerResumed, Map())
        this.stubClock.AdvanceMs(1000)
        Assert.Equal(1000, this.svc.GetActiveElapsedMs(),
            "So elapsed pos-resume (pause nao contado)")
    }

    timer_resumed_does_nothing_without_active_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.TimerResumed, Map())
        Assert.False(this.svc.IsActive())
    }

    timer_resumed_does_nothing_without_run_active()
    {
        ; Zone setada SEM run ativa, depois TimerResumed
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.bus.Publish(Events.TimerResumed, Map())
        Assert.False(this.svc.IsActive(),
            "Sem run ativa, TimerResumed nao restaura cronometro")
    }

    timer_paused_then_zone_changed_does_not_restart_timer()
    {
        ; Bug Lechtansi: ZoneChanged durante pause nao reinicia _startMs
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.TimerPaused, Map())
        this.stubClock.AdvanceMs(1000)
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Vastiri Outskirts"))
        this.stubClock.AdvanceMs(5000)
        Assert.False(this.svc.IsActive(),
            "Bug Lechtansi: ZoneChanged durante pause NAO reinicia timer")
        Assert.Equal(0, this.svc.GetActiveElapsedMs())
    }

    ; ============================================================
    ; TimerStopped (Bug #1 v17.15)
    ; ============================================================

    timer_stopped_flushes_active_zone_before_zeroing()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(3500)
        this.bus.Publish(Events.TimerStopped, Map())
        Assert.Equal(3500, this.svc.GetZoneTotal("Mud Burrow"),
            "Bug #1 v17.15: flush ANTES de zerar _startMs")
    }

    timer_stopped_keeps_active_zone()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "Mud Burrow"))
        this.stubClock.AdvanceMs(2000)
        this.bus.Publish(Events.TimerStopped, Map())
        Assert.Equal("Mud Burrow", this.svc.GetActiveZone(),
            "TimerStopped usa keepActive=true")
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
        ; Cenario boot: Hydrate seguido de SetRunActive(true) com zona conhecida
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
            "Sem zona conhecida, SetRunActive(true) nao inicia cronometro")
    }

    ; ============================================================
    ; Reset manual
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
        ; sem AdvanceMs = elapsed=0
        this.bus.Publish(Events.ZoneChanged, Map("zoneName", "X"))
        Assert.Equal(0, capturedEvents.Length,
            "elapsed=0 nao publica ZoneTimeAccumulated")
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
}

TestRegistry.Register(ZoneTrackingServiceTests)
