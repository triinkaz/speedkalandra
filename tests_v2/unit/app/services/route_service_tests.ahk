; ============================================================
; RouteServiceTests
; ============================================================
;
; RouteService is reactive via bus + delegates state to Route:
;   - Subscribes ZoneEntered    -> AdvanceTo (skipping towns)
;   - Subscribes RunStarted/Reset/Cancelled -> Route.Reset
;   - Subscribes ProfileChanged -> reload from repo
;   - Publishes RouteChanged when state actually changes
;
; Coverage:
;   - Constructor (bus + repo validation, subscriptions)
;   - LoadRouteForProfile / Refresh
;   - Pass-through queries (HasRoute, Count, GetCurrentIdx,
;     GetVisibleSlice, GetCurrentRoute)
;   - ZoneEntered behavior: advance, town filter, off-route
;     silent no-op, defensive against malformed data
;   - Run lifecycle: every event resets _currentIdx
;   - Hydrated runs reset too (route position is NOT persisted)
;   - ProfileChanged reloads
;   - Dispose unsubscribes + idempotent

class RouteServiceTests extends TestCase
{
    bus  := ""
    repo := ""
    svc  := ""

    ; Captured payload from the last Evt.RouteChanged event.
    ; Tests assert on its content to verify the service published
    ; the right state changes.
    captured := ""

    Setup()
    {
        this.bus      := Fixtures.MakeBus()
        this.repo     := RouteRepository(Fixtures.TempDir())
        this.svc      := RouteService(this.bus, this.repo)
        this.captured := ""
        ; Subscribe a capture handler AFTER the service so the
        ; service's own subscribe order doesn't interfere. The
        ; bus is FIFO, so our handler runs after the service's
        ; internal updates — captured payload reflects post-event
        ; state.
        this.bus.Subscribe(Events.RouteChanged,
            (data) => this._CaptureRouteChanged(data))
    }

    Teardown()
    {
        if IsObject(this.svc)
            this.svc.Dispose()
        Fixtures.CleanupAll()
    }

    _CaptureRouteChanged(data)
    {
        this.captured := data
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_repo_not_route_repository",
        "constructor_subscribes_to_zone_entered",
        "constructor_subscribes_to_all_run_lifecycle_events",
        "constructor_subscribes_to_profile_changed",
        "constructor_starts_with_empty_route",
        "constructor_starts_with_no_current_profile",

        ; --- LoadRouteForProfile ---
        "load_route_for_profile_pulls_from_repo",
        "load_route_for_profile_sets_current_profile",
        "load_route_for_profile_publishes_route_changed",
        "load_route_for_profile_with_unknown_profile_loads_empty_route",
        "load_route_for_profile_starts_at_minus_one",

        ; --- Refresh ---
        "refresh_re_loads_from_repo_after_external_edit",
        "refresh_no_op_when_no_profile_loaded",
        "refresh_publishes_route_changed_after_re_load",

        ; --- Pass-through queries ---
        "get_current_route_returns_route_instance",
        "has_route_false_when_empty",
        "has_route_true_after_loading",
        "count_returns_zone_count",
        "get_visible_slice_returns_array_of_rows",

        ; --- ZoneEntered behavior ---
        "zone_entered_advances_route_for_map_zone",
        "zone_entered_publishes_route_changed_on_advance",
        "zone_entered_for_town_does_not_advance",
        "zone_entered_for_town_does_not_publish",
        "zone_entered_off_route_silent_no_op",
        "zone_entered_off_route_does_not_publish",
        "zone_entered_retreats_when_no_forward_match",

        ; --- ZoneEntered defensive ---
        "zone_entered_ignores_non_object_data",
        "zone_entered_ignores_missing_zone_name",
        "zone_entered_ignores_empty_zone_name",
        "zone_entered_ignores_whitespace_zone_name",

        ; --- Run lifecycle ---
        "run_started_resets_current_idx",
        "run_reset_resets_current_idx",
        "run_cancelled_resets_current_idx",
        "run_started_publishes_route_changed",
        "hydrated_run_started_still_resets_position",

        ; --- Run lifecycle re-sync via zoneProvider (B4 hotfix) ---
        "reset_works_without_zone_provider",
        "reset_re_syncs_to_active_zone_when_provider_returns_route_zone",
        "reset_does_not_re_sync_when_provider_returns_empty",
        "reset_leaves_idx_at_minus_one_when_provider_returns_off_route_zone",
        "reset_swallows_zone_provider_throw",

        ; --- ProfileChanged ---
        "profile_changed_loads_new_profile_route",
        "profile_changed_resets_current_idx",
        "profile_changed_ignores_non_object_data",
        "profile_changed_ignores_missing_profile_name",
        "profile_changed_ignores_empty_profile_name",

        ; --- Dispose ---
        "dispose_unsubscribes_zone_entered",
        "dispose_unsubscribes_all_run_lifecycle",
        "dispose_unsubscribes_profile_changed",
        "dispose_is_idempotent"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _SaveRoute(profileName, zones)
    {
        this.repo.Save(profileName, Route(zones))
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        Assert.Throws(TypeError,
            () => RouteService("not a bus", this.repo))
    }

    constructor_throws_when_repo_not_route_repository()
    {
        Assert.Throws(TypeError,
            () => RouteService(this.bus, "not a repo"))
    }

    constructor_subscribes_to_zone_entered()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.ZoneEntered))
    }

    constructor_subscribes_to_all_run_lifecycle_events()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.RunStarted))
        Assert.Equal(1, this.bus.Subscribers(Events.RunReset))
        Assert.Equal(1, this.bus.Subscribers(Events.RunCancelled))
    }

    constructor_subscribes_to_profile_changed()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.ProfileChanged))
    }

    constructor_starts_with_empty_route()
    {
        ; Before LoadRouteForProfile is called, the service holds
        ; an empty Route (not null) so callers never have to type-
        ; check before querying.
        Assert.True(this.svc.GetCurrentRoute() is Route)
        Assert.False(this.svc.HasRoute())
        Assert.Equal(0, this.svc.Count())
    }

    constructor_starts_with_no_current_profile()
    {
        Assert.Equal("", this.svc.GetCurrentProfile())
    }

    ; ============================================================
    ; LoadRouteForProfile
    ; ============================================================

    load_route_for_profile_pulls_from_repo()
    {
        this._SaveRoute("Witch", ["A", "B", "C"])
        this.svc.LoadRouteForProfile("Witch")

        Assert.Equal(3, this.svc.Count())
        Assert.True(this.svc.HasRoute())
    }

    load_route_for_profile_sets_current_profile()
    {
        this.svc.LoadRouteForProfile("Witch")
        Assert.Equal("Witch", this.svc.GetCurrentProfile())
    }

    load_route_for_profile_publishes_route_changed()
    {
        this._SaveRoute("Witch", ["A", "B"])
        this.svc.LoadRouteForProfile("Witch")

        Assert.True(IsObject(this.captured),
            "RouteChanged must fire after Load")
        Assert.Equal(2,  this.captured["totalZones"])
        Assert.Equal(-1, this.captured["currentIdx"])
        Assert.True(this.captured["hasRoute"])
    }

    load_route_for_profile_with_unknown_profile_loads_empty_route()
    {
        ; No file on disk for this profile — repo returns Route().
        this.svc.LoadRouteForProfile("UnsavedProfile")
        Assert.False(this.svc.HasRoute())
        Assert.Equal(0, this.svc.Count())
    }

    load_route_for_profile_starts_at_minus_one()
    {
        this._SaveRoute("Witch", ["A", "B", "C"])
        this.svc.LoadRouteForProfile("Witch")
        Assert.Equal(-1, this.svc.GetCurrentIdx())
    }

    ; ============================================================
    ; Refresh
    ; ============================================================

    refresh_re_loads_from_repo_after_external_edit()
    {
        ; Initial state: route with 2 zones
        this._SaveRoute("Witch", ["A", "B"])
        this.svc.LoadRouteForProfile("Witch")
        Assert.Equal(2, this.svc.Count())

        ; External edit: Settings UI added a third zone via the
        ; repo. Service still sees the old route until Refresh.
        this._SaveRoute("Witch", ["A", "B", "C"])
        Assert.Equal(2, this.svc.Count(), "stale until Refresh")

        this.svc.Refresh()
        Assert.Equal(3, this.svc.Count())
    }

    refresh_no_op_when_no_profile_loaded()
    {
        ; Captured stays empty when there's no profile to refresh.
        Assert.Equal("", this.svc.GetCurrentProfile())
        this.svc.Refresh()
        Assert.Equal("", this.captured,
            "no profile -> no event -> no capture")
    }

    refresh_publishes_route_changed_after_re_load()
    {
        this._SaveRoute("Witch", ["A"])
        this.svc.LoadRouteForProfile("Witch")
        this.captured := ""    ; reset to detect the refresh fire

        this._SaveRoute("Witch", ["A", "B", "C"])
        this.svc.Refresh()
        Assert.True(IsObject(this.captured))
        Assert.Equal(3, this.captured["totalZones"])
    }

    ; ============================================================
    ; Pass-through queries
    ; ============================================================

    get_current_route_returns_route_instance()
    {
        Assert.True(this.svc.GetCurrentRoute() is Route)
    }

    has_route_false_when_empty()
    {
        Assert.False(this.svc.HasRoute())
    }

    has_route_true_after_loading()
    {
        this._SaveRoute("Witch", ["A"])
        this.svc.LoadRouteForProfile("Witch")
        Assert.True(this.svc.HasRoute())
    }

    count_returns_zone_count()
    {
        this._SaveRoute("Witch", ["A", "B", "C", "D"])
        this.svc.LoadRouteForProfile("Witch")
        Assert.Equal(4, this.svc.Count())
    }

    get_visible_slice_returns_array_of_rows()
    {
        this._SaveRoute("Witch", ["A", "B", "C"])
        this.svc.LoadRouteForProfile("Witch")
        slice := this.svc.GetVisibleSlice(5)
        Assert.Equal(3, slice.Length, "slice shrinks at end")
        Assert.Equal("A", slice[1]["name"])
    }

    ; ============================================================
    ; ZoneEntered behavior
    ; ============================================================

    zone_entered_advances_route_for_map_zone()
    {
        this._SaveRoute("Witch", ["The Riverbank", "Clearfell", "The Grelwood"])
        this.svc.LoadRouteForProfile("Witch")

        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "Clearfell",
            "actIndex", 1,
            "isTown",   false
        ))
        Assert.Equal(1, this.svc.GetCurrentIdx())
    }

    zone_entered_publishes_route_changed_on_advance()
    {
        this._SaveRoute("Witch", ["A", "B"])
        this.svc.LoadRouteForProfile("Witch")
        this.captured := ""    ; reset capture

        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "B",
            "isTown",   false
        ))
        Assert.True(IsObject(this.captured))
        Assert.Equal(1, this.captured["currentIdx"])
    }

    zone_entered_for_town_does_not_advance()
    {
        ; Q5: town zones are filtered. ZoneTrackingService
        ; publishes the isTown flag derived from ZonesCatalog,
        ; so the service trusts it.
        this._SaveRoute("Witch", ["A", "Clearfell Encampment", "B"])
        this.svc.LoadRouteForProfile("Witch")

        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "Clearfell Encampment",
            "isTown",   true
        ))
        Assert.Equal(-1, this.svc.GetCurrentIdx(),
            "town zone never advances the route")
    }

    zone_entered_for_town_does_not_publish()
    {
        this._SaveRoute("Witch", ["A", "B"])
        this.svc.LoadRouteForProfile("Witch")
        this.captured := ""

        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "A",   ; would advance if not town
            "isTown",   true
        ))
        Assert.Equal("", this.captured,
            "town zone publishes no RouteChanged event")
    }

    zone_entered_off_route_silent_no_op()
    {
        ; Map zone not present in the route — AdvanceTo returns
        ; false, service stays silent.
        this._SaveRoute("Witch", ["A", "B"])
        this.svc.LoadRouteForProfile("Witch")
        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "SomewhereElse",
            "isTown",   false
        ))
        Assert.Equal(-1, this.svc.GetCurrentIdx())
    }

    zone_entered_off_route_does_not_publish()
    {
        this._SaveRoute("Witch", ["A", "B"])
        this.svc.LoadRouteForProfile("Witch")
        this.captured := ""

        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "OffRoute",
            "isTown",   false
        ))
        Assert.Equal("", this.captured,
            "off-route entries are silent — no bus traffic")
    }

    zone_entered_retreats_when_no_forward_match()
    {
        this._SaveRoute("Witch", ["A", "B", "C", "D"])
        this.svc.LoadRouteForProfile("Witch")

        ; Advance to C first
        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "C", "isTown", false))
        Assert.Equal(2, this.svc.GetCurrentIdx())

        ; Then go back to A — runner returned through earlier zones.
        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "A", "isTown", false))
        Assert.Equal(0, this.svc.GetCurrentIdx(),
            "retreat scanned backward to find A")
    }

    ; ============================================================
    ; ZoneEntered defensive
    ; ============================================================

    zone_entered_ignores_non_object_data()
    {
        this._SaveRoute("Witch", ["A"])
        this.svc.LoadRouteForProfile("Witch")
        this.captured := ""

        this.bus.Publish(Events.ZoneEntered, "not an object")
        Assert.Equal("", this.captured)
        Assert.Equal(-1, this.svc.GetCurrentIdx())
    }

    zone_entered_ignores_missing_zone_name()
    {
        this._SaveRoute("Witch", ["A"])
        this.svc.LoadRouteForProfile("Witch")
        this.captured := ""

        this.bus.Publish(Events.ZoneEntered, Map("isTown", false))
        Assert.Equal("", this.captured)
    }

    zone_entered_ignores_empty_zone_name()
    {
        this._SaveRoute("Witch", ["A"])
        this.svc.LoadRouteForProfile("Witch")
        this.captured := ""

        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "", "isTown", false))
        Assert.Equal("", this.captured)
    }

    zone_entered_ignores_whitespace_zone_name()
    {
        this._SaveRoute("Witch", ["A"])
        this.svc.LoadRouteForProfile("Witch")
        this.captured := ""

        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "   ", "isTown", false))
        Assert.Equal("", this.captured)
    }

    ; ============================================================
    ; Run lifecycle
    ; ============================================================

    run_started_resets_current_idx()
    {
        this._SaveRoute("Witch", ["A", "B"])
        this.svc.LoadRouteForProfile("Witch")
        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "B", "isTown", false))
        Assert.Equal(1, this.svc.GetCurrentIdx())

        this.bus.Publish(Events.RunStarted, Map("runId", "20260101_120000"))
        Assert.Equal(-1, this.svc.GetCurrentIdx())
    }

    run_reset_resets_current_idx()
    {
        this._SaveRoute("Witch", ["A", "B"])
        this.svc.LoadRouteForProfile("Witch")
        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "B", "isTown", false))

        this.bus.Publish(Events.RunReset, Map("runId", "20260101_120000"))
        Assert.Equal(-1, this.svc.GetCurrentIdx())
    }

    run_cancelled_resets_current_idx()
    {
        this._SaveRoute("Witch", ["A", "B"])
        this.svc.LoadRouteForProfile("Witch")
        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "B", "isTown", false))

        this.bus.Publish(Events.RunCancelled, Map("runId", "20260101_120000"))
        Assert.Equal(-1, this.svc.GetCurrentIdx())
    }

    run_started_publishes_route_changed()
    {
        this._SaveRoute("Witch", ["A", "B"])
        this.svc.LoadRouteForProfile("Witch")
        this.captured := ""

        this.bus.Publish(Events.RunStarted, Map("runId", "20260101_120000"))
        Assert.True(IsObject(this.captured))
        Assert.Equal(-1, this.captured["currentIdx"])
    }

    hydrated_run_started_still_resets_position()
    {
        ; Route's _currentIdx is intentionally NOT persisted across
        ; sessions. Even when the app re-launches mid-run (hydrated
        ; flag set), the route widget starts at -1 and re-syncs on
        ; the next ZoneEntered. This pins that decision so a future
        ; refactor doesn't silently "preserve" position.
        this._SaveRoute("Witch", ["A", "B", "C"])
        this.svc.LoadRouteForProfile("Witch")
        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "B", "isTown", false))
        Assert.Equal(1, this.svc.GetCurrentIdx())

        this.bus.Publish(Events.RunStarted, Map(
            "runId", "20260101_120000",
            "hydrated", true
        ))
        Assert.Equal(-1, this.svc.GetCurrentIdx(),
            "hydrated runs reset just like fresh starts")
    }

    ; ============================================================
    ; Run lifecycle re-sync via zoneProvider (B4 hotfix)
    ;
    ; The default Setup constructs the service WITHOUT a
    ; zoneProvider, so all the existing lifecycle tests above
    ; continue to pin the "plain Reset → -1" semantics. The
    ; tests in this section spin up a SECOND service with a
    ; provider injected so the re-sync path is exercised in
    ; isolation.
    ;
    ; Why the re-sync exists: in production, a player can fire
    ; RunStarted while ALREADY standing inside the first route
    ; zone (e.g. The Riverbank at character spawn, autoStart
    ; regex matching an early dialogue line). Without re-sync,
    ; `Reset() → currentIdx = -1` would strip the highlight,
    ; and no ZoneEntered would fire until the player left the
    ; zone — minutes of confusion.
    ; ============================================================

    reset_works_without_zone_provider()
    {
        ; The Setup service was constructed without a provider —
        ; confirm the legacy semantics (Reset always lands at -1)
        ; are preserved when no provider is wired.
        this._SaveRoute("Witch", ["A", "B"])
        this.svc.LoadRouteForProfile("Witch")
        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "B", "isTown", false))

        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        Assert.Equal(-1, this.svc.GetCurrentIdx())
    }

    reset_re_syncs_to_active_zone_when_provider_returns_route_zone()
    {
        ; Build a separate service with a provider returning
        ; "The Riverbank" — the bug-reproducing scenario.
        localBus := Fixtures.MakeBus()
        localRepo := RouteRepository(Fixtures.TempDir())
        localRepo.Save("Witch", Route(
            ["The Riverbank", "Clearfell", "Mud Burrow"]))

        zoneProvider := () => "The Riverbank"
        localSvc := RouteService(localBus, localRepo, "", zoneProvider)
        localSvc.LoadRouteForProfile("Witch")

        ; Position the runner at idx=2 (Mud Burrow) before the
        ; reset — so we can prove the reset AND re-sync both
        ; happen (idx 2 → -1 → 0, not idx 2 stays at 2).
        localBus.Publish(Events.ZoneEntered, Map(
            "zoneName", "Mud Burrow", "isTown", false))
        Assert.Equal(2, localSvc.GetCurrentIdx())

        localBus.Publish(Events.RunStarted, Map("runId", "x"))
        Assert.Equal(0, localSvc.GetCurrentIdx(),
            "reset → -1, then re-sync via provider → 0 (Riverbank)")

        localSvc.Dispose()
    }

    reset_does_not_re_sync_when_provider_returns_empty()
    {
        ; Provider returns "" — typical when ZoneTrackingService
        ; has no active zone yet (boot, between zones). Reset
        ; should leave the route at -1.
        localBus := Fixtures.MakeBus()
        localRepo := RouteRepository(Fixtures.TempDir())
        localRepo.Save("Witch", Route(["A", "B"]))

        zoneProvider := () => ""
        localSvc := RouteService(localBus, localRepo, "", zoneProvider)
        localSvc.LoadRouteForProfile("Witch")
        localBus.Publish(Events.ZoneEntered, Map(
            "zoneName", "B", "isTown", false))

        localBus.Publish(Events.RunStarted, Map("runId", "x"))
        Assert.Equal(-1, localSvc.GetCurrentIdx(),
            "empty active zone keeps idx at -1")

        localSvc.Dispose()
    }

    reset_leaves_idx_at_minus_one_when_provider_returns_off_route_zone()
    {
        ; Provider returns a zone NOT in the route — AdvanceTo
        ; returns false, idx stays at -1 (the route hasn't been
        ; entered yet from the route's perspective).
        localBus := Fixtures.MakeBus()
        localRepo := RouteRepository(Fixtures.TempDir())
        localRepo.Save("Witch", Route(["A", "B"]))

        zoneProvider := () => "Somewhere Else"
        localSvc := RouteService(localBus, localRepo, "", zoneProvider)
        localSvc.LoadRouteForProfile("Witch")
        localBus.Publish(Events.ZoneEntered, Map(
            "zoneName", "B", "isTown", false))

        localBus.Publish(Events.RunStarted, Map("runId", "x"))
        Assert.Equal(-1, localSvc.GetCurrentIdx(),
            "off-route active zone keeps idx at -1")

        localSvc.Dispose()
    }

    reset_swallows_zone_provider_throw()
    {
        ; A buggy provider that throws must not crash the reset
        ; path. Defensive try-catch in _OnRunLifecycleReset
        ; ensures the reset still completes and the route lands
        ; at -1 (same as the no-provider case).
        ;
        ; Note on the lambda shape: AHK v2 arrow functions accept
        ; only a SINGLE expression as the body (no `{ ... }`
        ; blocks — the parser reads `{` as an object literal),
        ; so we wrap the throw inside a static helper and call it
        ; from the arrow. The behavior is identical: invoking the
        ; arrow propagates the throw to RouteService's try/catch.
        localBus := Fixtures.MakeBus()
        localRepo := RouteRepository(Fixtures.TempDir())
        localRepo.Save("Witch", Route(["A", "B"]))

        zoneProvider := () => RouteServiceTests._ThrowingProvider()
        localSvc := RouteService(localBus, localRepo, "", zoneProvider)
        localSvc.LoadRouteForProfile("Witch")
        localBus.Publish(Events.ZoneEntered, Map(
            "zoneName", "B", "isTown", false))

        localBus.Publish(Events.RunStarted, Map("runId", "x"))
        Assert.Equal(-1, localSvc.GetCurrentIdx(),
            "provider throw swallowed; reset still lands at -1")

        localSvc.Dispose()
    }

    ; Helper for `reset_swallows_zone_provider_throw` — see the
    ; comment in that test for why this can't just be inlined as
    ; a `() => { throw ... }` lambda.
    static _ThrowingProvider()
    {
        throw Error("provider crashed")
    }

    ; ============================================================
    ; ProfileChanged
    ; ============================================================

    profile_changed_loads_new_profile_route()
    {
        this._SaveRoute("Witch", ["WitchA", "WitchB"])
        this._SaveRoute("Warrior", ["WarriorA", "WarriorB", "WarriorC"])

        this.svc.LoadRouteForProfile("Witch")
        Assert.Equal(2, this.svc.Count())

        this.bus.Publish(Events.ProfileChanged, Map(
            "profileId",   "p2",
            "profileName", "Warrior"
        ))
        Assert.Equal(3, this.svc.Count())
        Assert.Equal("Warrior", this.svc.GetCurrentProfile())
    }

    profile_changed_resets_current_idx()
    {
        this._SaveRoute("Witch", ["A", "B"])
        this._SaveRoute("Warrior", ["A", "B"])
        this.svc.LoadRouteForProfile("Witch")
        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "B", "isTown", false))
        Assert.Equal(1, this.svc.GetCurrentIdx())

        this.bus.Publish(Events.ProfileChanged, Map("profileName", "Warrior"))
        Assert.Equal(-1, this.svc.GetCurrentIdx(),
            "new profile starts fresh")
    }

    profile_changed_ignores_non_object_data()
    {
        this.svc.LoadRouteForProfile("Witch")
        this.bus.Publish(Events.ProfileChanged, "not an object")
        Assert.Equal("Witch", this.svc.GetCurrentProfile())
    }

    profile_changed_ignores_missing_profile_name()
    {
        this.svc.LoadRouteForProfile("Witch")
        this.bus.Publish(Events.ProfileChanged, Map("profileId", "p2"))
        Assert.Equal("Witch", this.svc.GetCurrentProfile())
    }

    profile_changed_ignores_empty_profile_name()
    {
        this.svc.LoadRouteForProfile("Witch")
        this.bus.Publish(Events.ProfileChanged, Map("profileName", ""))
        Assert.Equal("Witch", this.svc.GetCurrentProfile())
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_zone_entered()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.ZoneEntered))
    }

    dispose_unsubscribes_all_run_lifecycle()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.RunStarted))
        Assert.Equal(0, this.bus.Subscribers(Events.RunReset))
        Assert.Equal(0, this.bus.Subscribers(Events.RunCancelled))
    }

    dispose_unsubscribes_profile_changed()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.ProfileChanged))
    }

    dispose_is_idempotent()
    {
        this.svc.Dispose()
        this.svc.Dispose()    ; second call must not throw
        Assert.Equal(0, this.bus.Subscribers(Events.ZoneEntered))
    }
}

TestRegistry.Register(RouteServiceTests)
