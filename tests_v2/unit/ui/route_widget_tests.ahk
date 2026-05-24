; ============================================================
; RouteWidgetTests
; ============================================================
;
; RouteWidget is a standalone (non-WidgetBase) UI surface that
; glues itself below an anchor timer widget. Tests cover the
; reactive plumbing + state derivation in headless mode (Gui calls
; are skipped). Live rendering is exercised only smoke-test via
; integration tests / manual smoke; the headless surface is the
; main testable contract.
;
; Coverage:
;   - Constructor (type checks + subscriptions)
;   - Show / Hide (cfg gate, anchor presence, empty route)
;   - Pass-through state (GetLastRenderedSlice / GetLastAnchorId)
;   - Event handlers:
;       RouteChanged          -> captures slice in headless
;       RouteVisibilityToggled -> show/hide based on payload
;       WidgetGeometryChanged -> re-renders only when widgetId
;                                matches current anchor
;       OverlayModeChanged    -> always re-resolves anchor
;   - Static helpers (_ColorFor, _IsCallable)
;   - Dispose (unsubscribes + idempotent)


; Minimal anchor stub. Satisfies the contract RouteWidget needs:
;   .id        — string used to compare against WidgetGeometryChanged.widgetId
;   .GetScale()
;   .GetHwnd() — must return 0 for headless tests (no real Gui).
class _FakeAnchor
{
    id    := ""
    scale := 1.0
    hwnd  := 0

    __New(id, scale := 1.0, hwnd := 0)
    {
        this.id    := id
        this.scale := scale
        this.hwnd  := hwnd
    }

    GetScale() => this.scale
    GetHwnd()  => this.hwnd
}


class RouteWidgetTests extends TestCase
{
    bus    := ""
    cfg    := ""
    repo   := ""
    svc    := ""
    anchor := ""
    widget := ""

    Setup()
    {
        this.bus    := Fixtures.MakeBus()
        this.cfg    := AppSettings.Defaults()
        this.cfg.routeWidgetVisible := true
        this.cfg.routeRowsVisible   := 5
        this.repo   := RouteRepository(Fixtures.TempDir())
        this.svc    := RouteService(this.bus, this.repo)
        this.anchor := _FakeAnchor("steveLayout", 1.0, 0)
        this.widget := RouteWidget(
            this.bus, this.cfg, this.svc,
            () => this.anchor,
            true    ; headless
        )
    }

    Teardown()
    {
        if IsObject(this.widget)
            this.widget.Dispose()
        if IsObject(this.svc)
            this.svc.Dispose()
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_cfg_not_app_settings",
        "constructor_throws_when_route_service_not_route_service",
        "constructor_throws_when_anchor_resolver_empty",
        "constructor_throws_when_anchor_resolver_not_callable",
        "constructor_subscribes_to_route_changed",
        "constructor_subscribes_to_widget_geometry_changed",
        "constructor_subscribes_to_route_visibility_toggled",
        "constructor_subscribes_to_overlay_mode_changed",
        "constructor_starts_hidden_with_empty_state",

        ; --- Show / Hide ---
        "show_is_no_op_when_cfg_route_widget_visible_false",
        "show_in_headless_captures_slice",
        "show_in_headless_records_anchor_id",
        "show_hides_when_anchor_resolver_returns_empty",
        "show_does_not_throw_when_resolver_throws",
        "hide_clears_last_anchor_id",
        "hide_is_idempotent",

        ; --- RouteChanged ---
        "route_changed_captures_slice_in_headless",
        "route_changed_reflects_advanced_position",

        ; --- RouteVisibilityToggled ---
        "visibility_toggled_true_calls_show",
        "visibility_toggled_false_calls_hide",
        "visibility_toggled_ignores_non_object_data",
        "visibility_toggled_ignores_missing_visible_key",

        ; --- WidgetGeometryChanged ---
        "geometry_changed_for_current_anchor_re_renders",
        "geometry_changed_for_different_widget_ignored",
        "geometry_changed_ignored_before_first_render",
        "geometry_changed_ignores_non_object_data",

        ; --- OverlayModeChanged ---
        "overlay_mode_changed_re_renders_when_visible",
        "overlay_mode_changed_re_resolves_to_new_anchor",
        "overlay_mode_changed_ignored_before_first_render",

        ; --- Static helpers ---
        "color_for_current_returns_good_strong",
        "color_for_upcoming_returns_text",
        "color_for_before_returns_subtle",
        "color_for_unknown_returns_text_defensive",
        "is_callable_true_for_arrow_lambda",
        "is_callable_true_for_func",
        "is_callable_false_for_empty_string",
        "is_callable_false_for_map",

        ; --- Dispose ---
        "dispose_unsubscribes_all_four_events",
        "dispose_hides_widget",
        "dispose_is_idempotent"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _SaveAndLoadRoute(zones)
    {
        this.repo.Save("Default", Route(zones))
        this.svc.LoadRouteForProfile("Default")
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        Assert.Throws(TypeError, () => RouteWidget(
            "not a bus", this.cfg, this.svc, () => this.anchor, true))
    }

    constructor_throws_when_cfg_not_app_settings()
    {
        Assert.Throws(TypeError, () => RouteWidget(
            this.bus, "not a cfg", this.svc, () => this.anchor, true))
    }

    constructor_throws_when_route_service_not_route_service()
    {
        Assert.Throws(TypeError, () => RouteWidget(
            this.bus, this.cfg, "not a service", () => this.anchor, true))
    }

    constructor_throws_when_anchor_resolver_empty()
    {
        Assert.Throws(TypeError, () => RouteWidget(
            this.bus, this.cfg, this.svc, "", true))
    }

    constructor_throws_when_anchor_resolver_not_callable()
    {
        ; A Map has no Call method and is the most common shape
        ; people might confuse with a callable in AHK v2.
        Assert.Throws(TypeError, () => RouteWidget(
            this.bus, this.cfg, this.svc, Map(), true))
    }

    constructor_subscribes_to_route_changed()
    {
        ; The widget is the only subscriber: RouteService publishes
        ; RouteChanged but does NOT subscribe to it. So after
        ; constructing the widget, exactly 1 subscriber should
        ; be registered.
        Assert.Equal(1, this.bus.Subscribers(Events.RouteChanged),
            "widget is the sole RouteChanged subscriber")
    }

    constructor_subscribes_to_widget_geometry_changed()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.WidgetGeometryChanged))
    }

    constructor_subscribes_to_route_visibility_toggled()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.RouteVisibilityToggled))
    }

    constructor_subscribes_to_overlay_mode_changed()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.OverlayModeChanged))
    }

    constructor_starts_hidden_with_empty_state()
    {
        Assert.False(this.widget.IsVisible())
        Assert.Equal("", this.widget.GetLastAnchorId())
    }

    ; ============================================================
    ; Show / Hide
    ; ============================================================

    show_is_no_op_when_cfg_route_widget_visible_false()
    {
        ; Opt-out semantic: even if Show is called, the cfg gate
        ; suppresses every render. The Settings UI uses this to
        ; toggle the surface globally without rebuilding the widget.
        ; We instantiate a FRESH widget here so the cfg gate is
        ; observed from the very first event — Setup pre-creates
        ; the widget with cfg.routeWidgetVisible=true, and the
        ; bus events fired by _SaveAndLoadRoute would otherwise
        ; sneak past the gate.
        if IsObject(this.widget)
            this.widget.Dispose()
        this.cfg.routeWidgetVisible := false
        this.widget := RouteWidget(
            this.bus, this.cfg, this.svc, () => this.anchor, true)

        this._SaveAndLoadRoute(["A", "B", "C"])

        this.widget.Show()
        Assert.False(this.widget.IsVisible())
        Assert.Equal("", this.widget.GetLastAnchorId(),
            "Show ran a no-op so no anchor was recorded")
    }

    show_in_headless_captures_slice()
    {
        this._SaveAndLoadRoute(["A", "B", "C", "D"])
        this.widget.Show()
        slice := this.widget.GetLastRenderedSlice()
        Assert.True(IsObject(slice), "slice captured for headless inspection")
        ; Route has 4 zones, currentIdx=-1 → startIdx=0, cfg.routeRowsVisible=5
        ; → slice = min(5, 4) = 4 rows. The widget shows the full route
        ; preview when the run hasn't started yet.
        Assert.Equal(4, slice.Length)
        Assert.Equal("A", slice[1]["name"])
        Assert.Equal("D", slice[4]["name"])
    }

    show_in_headless_records_anchor_id()
    {
        this._SaveAndLoadRoute(["A"])
        this.widget.Show()
        Assert.Equal("steveLayout", this.widget.GetLastAnchorId(),
            "anchor.id captured on render")
    }

    show_hides_when_anchor_resolver_returns_empty()
    {
        ; Resolver returns "" (no eligible timer is mode-visible).
        ; Widget treats that as "hide everything" rather than
        ; rendering at (0,0).
        this._SaveAndLoadRoute(["A"])
        this.anchor := ""
        ; Re-create widget with the empty-returning resolver
        if IsObject(this.widget)
            this.widget.Dispose()
        emptyResolver := () => ""
        this.widget := RouteWidget(
            this.bus, this.cfg, this.svc, emptyResolver, true)

        this.widget.Show()
        Assert.False(this.widget.IsVisible())
    }

    show_does_not_throw_when_resolver_throws()
    {
        ; A buggy resolver shouldn't crash the bus handler.
        ; _ResolveAnchor wraps the call in try/catch and returns
        ; "" on any throw — the widget hides instead of propagating.
        if IsObject(this.widget)
            this.widget.Dispose()
        throwingResolver := () => RouteWidgetTests._AlwaysThrows()
        this.widget := RouteWidget(
            this.bus, this.cfg, this.svc, throwingResolver, true)

        ; Should not raise
        this.widget.Show()
        Assert.False(this.widget.IsVisible(),
            "widget hid itself instead of crashing on resolver throw")
    }

    hide_clears_last_anchor_id()
    {
        this._SaveAndLoadRoute(["A"])
        this.widget.Show()
        Assert.Equal("steveLayout", this.widget.GetLastAnchorId())

        this.widget.Hide()
        Assert.Equal("", this.widget.GetLastAnchorId())
    }

    hide_is_idempotent()
    {
        this.widget.Hide()
        this.widget.Hide()    ; second call must not throw
        Assert.False(this.widget.IsVisible())
    }

    ; ============================================================
    ; RouteChanged
    ; ============================================================

    route_changed_captures_slice_in_headless()
    {
        ; In headless mode the widget must first be "active" (Show
        ; called and anchor resolved) before reacting to events —
        ; mirrors production where a hidden widget ignores updates.
        ; This pins both behaviors at once: Show populates state,
        ; subsequent RouteChanged refreshes it.
        this._SaveAndLoadRoute(["A", "B", "C"])
        this.widget.Show()    ; activates the widget in headless

        ; Now drive another RouteChanged via the service and
        ; verify the captured slice reflects the new state.
        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "B", "isTown", false))

        slice := this.widget.GetLastRenderedSlice()
        Assert.True(IsObject(slice))
        ; After advance to B (idx=1), slice starts at idx=1 and
        ; runs to the end of the route — just [B, C] (2 rows).
        Assert.Equal(2, slice.Length)
        Assert.Equal("B", slice[1]["name"],
            "current zone advanced to B after ZoneEntered")
        Assert.Equal("current", slice[1]["status"])
    }

    route_changed_reflects_advanced_position()
    {
        this._SaveAndLoadRoute(["A", "B", "C", "D"])
        this.widget.Show()    ; activate

        ; Advance to B
        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "B", "isTown", false))

        slice := this.widget.GetLastRenderedSlice()
        Assert.True(IsObject(slice))
        Assert.Equal("B", slice[1]["name"])
        Assert.Equal("current", slice[1]["status"])
    }

    ; ============================================================
    ; RouteVisibilityToggled
    ; ============================================================

    visibility_toggled_true_calls_show()
    {
        this._SaveAndLoadRoute(["A"])
        ; Start hidden
        this.widget.Hide()
        Assert.Equal("", this.widget.GetLastAnchorId())

        this.bus.Publish(Events.RouteVisibilityToggled, Map("visible", true))
        Assert.Equal("steveLayout", this.widget.GetLastAnchorId(),
            "visible:true triggered Show which captured the anchor")
    }

    visibility_toggled_false_calls_hide()
    {
        this._SaveAndLoadRoute(["A"])
        this.widget.Show()
        Assert.Equal("steveLayout", this.widget.GetLastAnchorId())

        this.bus.Publish(Events.RouteVisibilityToggled, Map("visible", false))
        Assert.Equal("", this.widget.GetLastAnchorId(),
            "visible:false triggered Hide which cleared anchor id")
    }

    visibility_toggled_ignores_non_object_data()
    {
        this._SaveAndLoadRoute(["A"])
        this.widget.Show()
        before := this.widget.GetLastAnchorId()

        this.bus.Publish(Events.RouteVisibilityToggled, "not an object")
        Assert.Equal(before, this.widget.GetLastAnchorId(),
            "malformed event left state untouched")
    }

    visibility_toggled_ignores_missing_visible_key()
    {
        this._SaveAndLoadRoute(["A"])
        this.widget.Show()
        before := this.widget.GetLastAnchorId()

        this.bus.Publish(Events.RouteVisibilityToggled, Map("other", true))
        Assert.Equal(before, this.widget.GetLastAnchorId())
    }

    ; ============================================================
    ; WidgetGeometryChanged
    ; ============================================================

    geometry_changed_for_current_anchor_re_renders()
    {
        ; Drive via the service so RouteChanged fires too — in
        ; headless this is what produces a non-empty slice. After
        ; Show, _lastAnchorId = "steveLayout". A geometry event
        ; with the same widgetId should re-render the slice.
        this._SaveAndLoadRoute(["A", "B"])
        this.widget.Show()
        ; Advance to B so the slice content is non-trivial
        this.bus.Publish(Events.ZoneEntered, Map(
            "zoneName", "B", "isTown", false))

        ; Publish geometry change matching the anchor
        this.bus.Publish(Events.WidgetGeometryChanged, Map(
            "widgetId", "steveLayout",
            "x", 100, "y", 100, "w", 200, "h", 50, "scale", 1.0
        ))
        ; A second render should leave _lastAnchorId == "steveLayout"
        Assert.Equal("steveLayout", this.widget.GetLastAnchorId())
        slice := this.widget.GetLastRenderedSlice()
        Assert.Equal("B", slice[1]["name"])
    }

    geometry_changed_for_different_widget_ignored()
    {
        this._SaveAndLoadRoute(["A"])
        this.widget.Show()
        prevSlice := this.widget.GetLastRenderedSlice()

        ; Different widgetId — should be a no-op. We rely on
        ; observing the rendering side: nothing changes because
        ; the handler bails out early.
        this.bus.Publish(Events.WidgetGeometryChanged, Map(
            "widgetId", "compactLayout",
            "x", 0, "y", 0, "w", 200, "h", 50, "scale", 1.0
        ))
        Assert.Equal(prevSlice, this.widget.GetLastRenderedSlice(),
            "unrelated geometry change didn't trigger re-render")
    }

    geometry_changed_ignored_before_first_render()
    {
        ; Without an initial Show, _lastAnchorId is "" so no event
        ; widgetId can match. The handler early-returns. Pin this:
        ; otherwise a geometry event arriving before the user opts
        ; in could cause _Render to fire prematurely.
        this._SaveAndLoadRoute(["A"])
        this.widget.Hide()    ; explicit reset

        this.bus.Publish(Events.WidgetGeometryChanged, Map(
            "widgetId", "steveLayout",
            "x", 0, "y", 0, "w", 200, "h", 50, "scale", 1.0
        ))
        Assert.Equal("", this.widget.GetLastAnchorId(),
            "geometry event before first Show was ignored")
    }

    geometry_changed_ignores_non_object_data()
    {
        this._SaveAndLoadRoute(["A"])
        this.widget.Show()
        before := this.widget.GetLastAnchorId()

        this.bus.Publish(Events.WidgetGeometryChanged, "garbage")
        Assert.Equal(before, this.widget.GetLastAnchorId())
    }

    ; ============================================================
    ; OverlayModeChanged
    ; ============================================================

    overlay_mode_changed_re_renders_when_visible()
    {
        this._SaveAndLoadRoute(["A"])
        this.widget.Show()
        Assert.Equal("steveLayout", this.widget.GetLastAnchorId())

        ; Trigger re-render via mode change. The resolver in this
        ; test returns the same anchor, so _lastAnchorId stays the
        ; same, but the handler did invoke _Render — that's what
        ; this test pins.
        this.bus.Publish(Events.OverlayModeChanged, Map(
            "mode", "MICRO", "prevMode", "STEVE"))
        Assert.Equal("steveLayout", this.widget.GetLastAnchorId(),
            "_Render ran (resolver still returned the same anchor)")
    }

    overlay_mode_changed_re_resolves_to_new_anchor()
    {
        ; Inject a resolver that returns a different anchor after
        ; the mode change. This is the production scenario:
        ; CycleLayout swaps which timer is mode-visible.
        this._SaveAndLoadRoute(["A"])
        anchor1 := _FakeAnchor("steveLayout")
        anchor2 := _FakeAnchor("microLayout")
        current := anchor1

        if IsObject(this.widget)
            this.widget.Dispose()
        this.widget := RouteWidget(
            this.bus, this.cfg, this.svc,
            () => current, true)

        this.widget.Show()
        Assert.Equal("steveLayout", this.widget.GetLastAnchorId())

        ; Simulate a mode switch by swapping which anchor the
        ; resolver returns, then publishing OverlayModeChanged.
        current := anchor2
        this.bus.Publish(Events.OverlayModeChanged, Map(
            "mode", "MICRO", "prevMode", "STEVE"))
        Assert.Equal("microLayout", this.widget.GetLastAnchorId(),
            "anchor swapped after mode change")
    }

    overlay_mode_changed_ignored_before_first_render()
    {
        this._SaveAndLoadRoute(["A"])
        this.widget.Hide()

        this.bus.Publish(Events.OverlayModeChanged, Map(
            "mode", "MICRO", "prevMode", "STEVE"))
        Assert.Equal("", this.widget.GetLastAnchorId(),
            "mode change before first Show was ignored")
    }

    ; ============================================================
    ; Static helpers
    ; ============================================================

    color_for_current_returns_good_strong()
    {
        Assert.Equal("goodStrong", RouteWidget._ColorFor("current"))
    }

    color_for_upcoming_returns_text()
    {
        Assert.Equal("text", RouteWidget._ColorFor("upcoming"))
    }

    color_for_before_returns_subtle()
    {
        Assert.Equal("subtle", RouteWidget._ColorFor("before"))
    }

    color_for_unknown_returns_text_defensive()
    {
        ; Defensive fallback — a future status value not yet
        ; mapped here lands on the default text color rather than
        ; throwing.
        Assert.Equal("text", RouteWidget._ColorFor("future_status"))
        Assert.Equal("text", RouteWidget._ColorFor(""))
    }

    is_callable_true_for_arrow_lambda()
    {
        Assert.True(RouteWidget._IsCallable(() => 42))
    }

    is_callable_true_for_func()
    {
        Assert.True(RouteWidget._IsCallable(StrLen))
    }

    is_callable_false_for_empty_string()
    {
        Assert.False(RouteWidget._IsCallable(""))
    }

    is_callable_false_for_map()
    {
        Assert.False(RouteWidget._IsCallable(Map("a", 1)))
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_all_four_events()
    {
        this.widget.Dispose()
        ; The service publishes but does NOT subscribe to
        ; RouteChanged — so after the widget unsubscribes, there
        ; are zero subscribers for any of the four events the
        ; widget consumed.
        Assert.Equal(0, this.bus.Subscribers(Events.RouteChanged))
        Assert.Equal(0, this.bus.Subscribers(Events.WidgetGeometryChanged))
        Assert.Equal(0, this.bus.Subscribers(Events.RouteVisibilityToggled))
        Assert.Equal(0, this.bus.Subscribers(Events.OverlayModeChanged))
        this.widget := ""    ; prevent Teardown second-dispose
    }

    dispose_hides_widget()
    {
        this._SaveAndLoadRoute(["A"])
        this.widget.Show()
        Assert.Equal("steveLayout", this.widget.GetLastAnchorId())

        this.widget.Dispose()
        Assert.Equal("", this.widget.GetLastAnchorId(),
            "Dispose called Hide which cleared anchor id")
        this.widget := ""
    }

    dispose_is_idempotent()
    {
        this.widget.Dispose()
        this.widget.Dispose()    ; second call must not throw
        Assert.False(this.widget.IsVisible())
        this.widget := ""
    }

    ; ============================================================
    ; Internal helper used by show_does_not_throw_when_resolver_throws
    ; ============================================================
    static _AlwaysThrows()
    {
        throw Error("resolver bug — simulated")
    }
}

TestRegistry.Register(RouteWidgetTests)
