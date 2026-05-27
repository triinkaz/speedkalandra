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
    bus     := ""
    cfg     := ""
    repo    := ""
    svc     := ""
    anchor  := ""
    widget  := ""
    tracker := ""    ; lazily attached by _AttachTracker (zoneTracker tests only)

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
        ; Tracker is only attached by the optional _AttachTracker
        ; helper (zoneTracker tests). Dispose unsubscribes its
        ; ZoneChanged/TimerPaused/etc handlers from the shared
        ; bus so the next test starts with a clean subscriber list.
        if IsObject(this.tracker)
            try this.tracker.Dispose()
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
        "dispose_is_idempotent",

        ; --- zoneTracker dep (live per-zone time) ---
        "constructor_accepts_optional_zone_tracker",
        "constructor_throws_on_invalid_zone_tracker_type",
        "constructor_back_compat_without_zone_tracker",
        "format_time_renders_M_SS_under_one_hour",
        "format_time_renders_H_MM_SS_at_or_over_one_hour",
        "format_time_returns_empty_for_zero_or_negative",
        "compute_time_text_returns_empty_without_tracker",
        "compute_time_text_returns_empty_for_zero_ms",
        "compute_time_text_formats_when_total_positive",

        ; --- Note rendering (per-zone tips below current zone) ---
        "estimate_note_lines_returns_zero_for_empty",
        "estimate_note_lines_returns_one_for_short_text",
        "estimate_note_lines_counts_hard_newlines",
        "estimate_note_lines_treats_empty_line_as_one_row",
        "estimate_note_lines_wraps_long_text_on_narrow_column",
        "estimate_note_height_returns_zero_for_empty",
        "estimate_note_height_grows_with_line_count",
        "get_current_note_from_slice_returns_empty_for_no_current_row",
        "get_current_note_from_slice_returns_empty_when_zone_has_no_note",
        "get_current_note_from_slice_returns_note_when_current_has_note",
        "get_current_note_from_slice_is_case_insensitive",

        ; --- _ResolveNoteFontSize (B4 follow-up; configurable
        ;     base size via cfg.routeNoteFontSize) ---
        "resolve_note_font_size_uses_cfg_value_when_valid",
        "resolve_note_font_size_scales_with_anchor",
        "resolve_note_font_size_falls_back_to_base_when_cfg_sub_six",
        "resolve_note_font_size_falls_back_to_base_when_cfg_non_numeric",
        "resolve_note_font_size_floors_at_six_pt",

        ; --- _ResolveNoteLineHeight (B4 follow-up; line height
        ;     scales with the configured font so 16 pt doesn't
        ;     get clipped — TUGs feedback "cortada na metade") ---
        "resolve_note_line_height_default_8pt_returns_14_px",
        "resolve_note_line_height_grows_proportionally_with_font",
        "resolve_note_line_height_respects_constant_floor_for_small_fonts",
        "resolve_note_line_height_handles_invalid_scale",

        ; --- _LogicalWidthFromPhysical (DPI conversion for the
        ;     route-anchor width handoff; TUGs's 150% 4K overhang) ---
        "logical_width_from_physical_no_op_at_96_dpi",
        "logical_width_from_physical_unscales_125_percent",
        "logical_width_from_physical_unscales_150_percent",
        "logical_width_from_physical_falls_back_to_96_when_dpi_invalid",
        "logical_width_from_physical_returns_zero_for_non_positive_width"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _SaveAndLoadRoute(zones)
    {
        this.repo.Save("Default", Route(zones))
        this.svc.LoadRouteForProfile("Default")
    }

    ; Same as _SaveAndLoadRoute but also persists per-zone notes,
    ; used by the note-rendering tests below. notesMap is a
    ; Map<zoneName, noteText> matching Route's constructor contract.
    ; Round-trips through the repo so the loaded Route's _notes are
    ; populated exactly as production would have them after the
    ; user authored tips in the Settings UI.
    _SaveAndLoadRouteWithNotes(zones, notesMap)
    {
        this.repo.Save("Default", Route(zones, notesMap))
        this.svc.LoadRouteForProfile("Default")
    }

    ; Disposes the default widget from Setup and replaces it with a
    ; new widget WIRED to a fresh ZoneTrackingService. Used by the
    ; zoneTracker-aware tests below; existing tests that don't care
    ; about per-zone time keep using the Setup widget unchanged.
    ; Both widget AND tracker are assigned to instance fields so
    ; Teardown disposes them — a leaked tracker would keep its
    ; bus subscriptions live across tests.
    _AttachTracker()
    {
        if IsObject(this.widget)
            try this.widget.Dispose()
        ; RealClock is fine here — we don't drive any timing path
        ; that compares ms across calls; the tracker is only used
        ; for GetZoneTotalWithActive(zoneName) reads, which fold
        ; in active elapsed only when the zone is the current
        ; _activeZone (never the case in these tests).
        clock := RealClock()
        this.tracker := ZoneTrackingService(this.bus, clock)
        this.widget := RouteWidget(
            this.bus, this.cfg, this.svc,
            () => this.anchor,
            true,           ; headless
            this.tracker
        )
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
    ; zoneTracker dep (live per-zone time)
    ; ============================================================
    ;
    ; RouteWidget accepts an optional zoneTracker (ZoneTrackingService
    ; or empty) as the 6th ctor arg. When wired, each rendered row
    ; gets a right-aligned time cell driven by
    ; GetZoneTotalWithActive(zoneName), refreshed every 500 ms via
    ; a SetTimer registered with ObjBindMethod (so Stop can cancel
    ; by the same reference). Headless tests skip the SetTimer
    ; entirely — _StartTick early-returns when this._headless is
    ; true — so these tests can exercise the formatting + read paths
    ; without a live timer.

    constructor_accepts_optional_zone_tracker()
    {
        ; Wired version constructs cleanly. Validation rejects
        ; non-empty non-ZoneTrackingService inputs (next test).
        threw := false
        try this._AttachTracker()
        catch
            threw := true
        Assert.False(threw,
            "constructing with a real ZoneTrackingService must not throw")
        Assert.True(this.widget is RouteWidget,
            "widget must be assignable after _AttachTracker")
    }

    constructor_throws_on_invalid_zone_tracker_type()
    {
        ; A Map is the most common shape that someone might
        ; mistakenly pass; type validation rejects it. Empty
        ; string (the default) is allowed — covered by
        ; constructor_back_compat_without_zone_tracker.
        Assert.Throws(TypeError, () => RouteWidget(
            this.bus, this.cfg, this.svc,
            () => this.anchor, true,
            Map()))
    }

    constructor_back_compat_without_zone_tracker()
    {
        ; 5-arg call (pre-zoneTracker signature) must still work.
        ; The default empty-string value bypasses type validation
        ; and leaves _zoneTracker empty; the time column then
        ; stays blank (verified by compute_time_text_returns_
        ; empty_without_tracker below).
        legacyWidget := RouteWidget(
            this.bus, this.cfg, this.svc,
            () => this.anchor, true)
        Assert.True(legacyWidget is RouteWidget,
            "5-arg ctor must remain valid for legacy call sites")
        try legacyWidget.Dispose()
    }

    format_time_renders_M_SS_under_one_hour()
    {
        ; 95 000 ms = 1 minute 35 seconds = "1:35".
        Assert.Equal("1:35", RouteWidget._FormatTime(95000),
            "1m35s renders as M:SS")
        ; 999 ms (under 1s) floors to 0 seconds = "0:00".
        Assert.Equal("0:00", RouteWidget._FormatTime(999),
            "sub-second floors to 0:00 (no rounding up)")
        ; 60 000 ms = exactly 1 minute.
        Assert.Equal("1:00", RouteWidget._FormatTime(60000),
            "exactly 1 minute renders as 1:00")
        ; 59 999 ms = 59 seconds (one tick under 1 minute).
        Assert.Equal("0:59", RouteWidget._FormatTime(59999),
            "just under 1 minute floors to 0:59")
    }

    format_time_renders_H_MM_SS_at_or_over_one_hour()
    {
        ; 3 725 000 ms = 1h 2m 5s = "1:02:05".
        Assert.Equal("1:02:05", RouteWidget._FormatTime(3725000),
            "1h02m05s renders as H:MM:SS (zero-padded MM and SS)")
        ; 3 600 000 ms = exactly 1h — boundary; the H:MM:SS branch
        ; takes over the moment total minutes reach 60.
        Assert.Equal("1:00:00", RouteWidget._FormatTime(3600000),
            "exactly 1h crosses the M:SS → H:MM:SS boundary")
        ; 3 599 999 ms = 59m 59s — stays in M:SS.
        Assert.Equal("59:59", RouteWidget._FormatTime(3599999),
            "just under 1h stays in M:SS (no leading 0:)")
    }

    format_time_returns_empty_for_zero_or_negative()
    {
        ; Zero-ms zones render blank (Q4 decision: no '0:00' noise).
        ; Negative is defensive -- unexpected but must not throw
        ; or render weird strings.
        Assert.Equal("", RouteWidget._FormatTime(0),
            "0 ms renders as empty string")
        Assert.Equal("", RouteWidget._FormatTime(-1),
            "negative ms renders as empty string")
        Assert.Equal("", RouteWidget._FormatTime(-99999),
            "large-negative ms also defensive")
    }

    compute_time_text_returns_empty_without_tracker()
    {
        ; The Setup widget has NO tracker wired (5-arg ctor in
        ; Setup). _ComputeTimeText must early-return "" so the
        ; time column stays blank for every row regardless of
        ; what zone name we ask about.
        Assert.Equal("", this.widget._ComputeTimeText("The Riverbank"),
            "no tracker -> empty string (no '0:00' placeholder)")
        Assert.Equal("", this.widget._ComputeTimeText("AnythingAtAll"),
            "no tracker -> empty for any zone")
    }

    compute_time_text_returns_empty_for_zero_ms()
    {
        ; Tracker is wired but the zone was never entered, so
        ; GetZoneTotalWithActive returns 0 -> empty string per
        ; the Q4 decision (no '0:00' placeholders cluttering
        ; the overlay before zones are visited).
        this._AttachTracker()
        Assert.Equal("", this.widget._ComputeTimeText("Never Visited"),
            "zero-ms zone renders blank")
    }

    compute_time_text_formats_when_total_positive()
    {
        ; Hydrate the tracker with a fixed total for one zone,
        ; then verify the widget renders the formatted string.
        ; Hydrate writes directly to _totals without going through
        ; the ZoneChanged → _FlushActive path, so this test
        ; isolates the read+format pipeline from the timing path.
        this._AttachTracker()
        totals := Map()
        totals["The Riverbank"]   := 95000      ; 1:35
        totals["Hunting Grounds"] := 3725000    ; 1:02:05
        this.tracker.Hydrate(totals)
        Assert.Equal("1:35",
            this.widget._ComputeTimeText("The Riverbank"),
            "95 000 ms renders via _FormatTime as 1:35")
        Assert.Equal("1:02:05",
            this.widget._ComputeTimeText("Hunting Grounds"),
            "3 725 000 ms crosses into H:MM:SS as 1:02:05")
        Assert.Equal("",
            this.widget._ComputeTimeText("Unknown Zone"),
            "zone not in totals still renders blank")
    }

    ; ============================================================
    ; Internal helper used by show_does_not_throw_when_resolver_throws
    ; ============================================================
    static _AlwaysThrows()
    {
        throw Error("resolver bug — simulated")
    }

    ; ============================================================
    ; Note rendering (per-zone tips below current zone)
    ; ============================================================
    ;
    ; The widget renders an extra row below the CURRENT zone row
    ; when the runner authored a per-zone tip. Headless tests can't
    ; observe the actual Gui control (it's never created), but the
    ; helpers that compute height and resolve the current-zone note
    ; are static / instance methods and can be exercised directly.

    estimate_note_lines_returns_zero_for_empty()
    {
        ; An empty / unset note produces zero lines — the render
        ; path uses this to know that no note row should be drawn,
        ; and _EstimateNoteHeight uses it to short-circuit the
        ; padding addition. Both branches must stay coherent.
        Assert.Equal(0, RouteWidget._EstimateNoteLines("",  300, 10))
        Assert.Equal(0, RouteWidget._EstimateNoteLines("",  100, 8))
    }

    estimate_note_lines_returns_one_for_short_text()
    {
        ; Short text on a wide column never wraps — fits in a
        ; single rendered line.
        Assert.Equal(1, RouteWidget._EstimateNoteLines("hi", 300, 10))
    }

    estimate_note_lines_counts_hard_newlines()
    {
        ; Three short lines separated by `n. None of them wrap
        ; (each is 1 char on a 300px column), so the count is
        ; exactly equal to the number of segments.
        Assert.Equal(3, RouteWidget._EstimateNoteLines("a`nb`nc", 300, 10))
    }

    estimate_note_lines_treats_empty_line_as_one_row()
    {
        ; "a\n\nb" = line "a", blank line, line "b" = 3 rows of
        ; vertical space. Empty segments must still count so the
        ; user can author a tip with visual breathing room.
        Assert.Equal(3, RouteWidget._EstimateNoteLines("a`n`nb", 300, 10))
    }

    estimate_note_lines_wraps_long_text_on_narrow_column()
    {
        ; Narrow column forces wrap. At font 10 with the 0.55
        ; chars-per-pt ratio, ~50 px of usable width gives
        ; ~8 chars per line; 32-char text wraps to >= 3 lines.
        ; Test uses >= rather than exact so the wrap-math constant
        ; can be tuned without breaking the assertion.
        longText := "abcdefghijklmnopqrstuvwxyz123456"
        lines := RouteWidget._EstimateNoteLines(longText, 50, 10)
        Assert.True(lines >= 3,
            "long text on narrow column wraps to >= 3 lines (got " lines ")")
    }

    estimate_note_height_returns_zero_for_empty()
    {
        ; Zero lines → zero pixels reserved. The render loop
        ; depends on this to know whether to advance the cursor
        ; or skip the note row entirely.
        Assert.Equal(0, RouteWidget._EstimateNoteHeight("", 300, 10, 14))
    }

    estimate_note_height_grows_with_line_count()
    {
        ; 1 line: lineHeight (14) + 4 px padding = 18 px.
        ; 3 lines: 3*14 + 4 = 46 px.
        ; The +4 is the internal padding added by _EstimateNoteHeight
        ; so the bottom row of text doesn't touch the row's edge.
        h1 := RouteWidget._EstimateNoteHeight("single",                 300, 10, 14)
        h3 := RouteWidget._EstimateNoteHeight("one`ntwo`nthree",         300, 10, 14)
        Assert.Equal(14 + 4,   h1, "1 line: lineHeight + 4 px padding")
        Assert.Equal(3*14 + 4, h3, "3 lines: 3*lineHeight + 4 px padding")
        Assert.True(h3 > h1, "more lines always means taller box")
    }

    get_current_note_from_slice_returns_empty_for_no_current_row()
    {
        ; Slice with only upcoming/before rows — no row whose
        ; status is "current" — yields no note regardless of
        ; what the Route has authored. Matches the render's
        ; "only render the current row's note" rule.
        this._SaveAndLoadRouteWithNotes(["A", "B"], Map(
            "A", "tip for A", "B", "tip for B"))
        slice := [
            Map("name", "A", "idx", 0, "status", "upcoming"),
            Map("name", "B", "idx", 1, "status", "upcoming")
        ]
        Assert.Equal("", this.widget._GetCurrentNoteFromSlice(slice),
            "no current row → no note even when other zones have one")
    }

    get_current_note_from_slice_returns_empty_when_zone_has_no_note()
    {
        ; Current row is A; only B has a note. The widget must
        ; not borrow B's note onto A's row.
        this._SaveAndLoadRouteWithNotes(["A", "B"], Map("B", "tip for B"))
        slice := [
            Map("name", "A", "idx", 0, "status", "current"),
            Map("name", "B", "idx", 1, "status", "upcoming")
        ]
        Assert.Equal("", this.widget._GetCurrentNoteFromSlice(slice),
            "current zone has no note → empty (other zone's note ignored)")
    }

    get_current_note_from_slice_returns_note_when_current_has_note()
    {
        ; Happy path: current zone has an authored tip. The widget
        ; resolves it through RouteService.GetCurrentRoute().GetNote
        ; — if the round-trip through repo/service drops notes,
        ; this test catches it.
        this._SaveAndLoadRouteWithNotes(["A", "B"], Map(
            "A", "vendor first"))
        slice := [
            Map("name", "A", "idx", 0, "status", "current"),
            Map("name", "B", "idx", 1, "status", "upcoming")
        ]
        Assert.Equal("vendor first",
            this.widget._GetCurrentNoteFromSlice(slice))
    }

    get_current_note_from_slice_is_case_insensitive()
    {
        ; Slice carries the zone's display name (may differ from
        ; the stored note key's casing). Route.GetNote lowercases
        ; internally; verify the widget's resolve path inherits
        ; that case-insensitivity end-to-end (slice display name
        ; → Route key match).
        this._SaveAndLoadRouteWithNotes(["Mud Burrow"], Map(
            "Mud Burrow", "skip optional"))
        slice := [
            Map("name", "MUD BURROW", "idx", 0, "status", "current")
        ]
        Assert.Equal("skip optional",
            this.widget._GetCurrentNoteFromSlice(slice),
            "display-name casing variance still resolves the note")
    }

    ; ============================================================
    ; _ResolveNoteFontSize (B4 follow-up: configurable base size)
    ; ============================================================
    ;
    ; Public-static helper that routes cfg.routeNoteFontSize →
    ; effective font size (after anchor-scale multiplication and a
    ; defensive floor at 6 pt). Tests bypass _Render entirely — the
    ; helper has no Gui dependency so the policy can be locked
    ; without spinning up a widget.

    resolve_note_font_size_uses_cfg_value_when_valid()
    {
        ; Happy path: cfg carries a valid in-range value and
        ; scale is 1.0, so the resolver returns the cfg value
        ; verbatim. Pin all three reasonable values (default,
        ; mid-range, max) so a future change to the formula has
        ; to confront every common shape at once.
        cfg := AppSettings.Defaults()

        cfg.routeNoteFontSize := 8
        Assert.Equal(8, RouteWidget._ResolveNoteFontSize(cfg, 1.0),
            "default 8 pt at scale 1.0 → 8 pt")

        cfg.routeNoteFontSize := 12
        Assert.Equal(12, RouteWidget._ResolveNoteFontSize(cfg, 1.0),
            "mid-range 12 pt at scale 1.0 → 12 pt")

        cfg.routeNoteFontSize := 16
        Assert.Equal(16, RouteWidget._ResolveNoteFontSize(cfg, 1.0),
            "max 16 pt at scale 1.0 → 16 pt")
    }

    resolve_note_font_size_scales_with_anchor()
    {
        ; The whole point of multiplying by scale is so the note
        ; grows when the user resizes the anchor widget up. Base
        ; 8 pt at scale 2.0 = 16 pt; the same value reachable by
        ; setting the cfg slider to 16 directly at scale 1.0.
        cfg := AppSettings.Defaults()
        cfg.routeNoteFontSize := 8
        Assert.Equal(16, RouteWidget._ResolveNoteFontSize(cfg, 2.0),
            "base 8 × scale 2.0 = 16 pt")

        ; Mid-fractional scale: 10 × 1.5 = 15 (Round of 15.0 = 15).
        cfg.routeNoteFontSize := 10
        Assert.Equal(15, RouteWidget._ResolveNoteFontSize(cfg, 1.5),
            "base 10 × scale 1.5 = 15 pt (Round of 15.0)")

        ; Invalid scale (zero / negative / non-numeric) falls
        ; back to scale 1.0 — a buggy anchor shouldn't zero out
        ; the note font.
        cfg.routeNoteFontSize := 12
        Assert.Equal(12, RouteWidget._ResolveNoteFontSize(cfg, 0),
            "zero scale falls back to 1.0 → 12 pt unchanged")
        Assert.Equal(12, RouteWidget._ResolveNoteFontSize(cfg, -1),
            "negative scale falls back to 1.0 → 12 pt unchanged")
        Assert.Equal(12, RouteWidget._ResolveNoteFontSize(cfg, "oops"),
            "non-numeric scale falls back to 1.0 → 12 pt unchanged")
    }

    resolve_note_font_size_falls_back_to_base_when_cfg_sub_six()
    {
        ; Defensive belt-and-suspenders: the AppSettings.FromMap
        ; clamp already bounds the field at [6, 16] on load, but
        ; a cfg constructed outside FromMap (e.g. a test that
        ; mutates the field directly, or a future programmatic
        ; caller) could land with a sub-6 value. The helper
        ; rejects it and falls back to NOTE_FONT_SIZE_BASE so the
        ; render path never tries to draw 3-pt text.
        cfg := AppSettings.Defaults()
        cfg.routeNoteFontSize := 4
        Assert.Equal(8, RouteWidget._ResolveNoteFontSize(cfg, 1.0),
            "sub-6 cfg value falls back to NOTE_FONT_SIZE_BASE (8 pt)")

        cfg.routeNoteFontSize := 0
        Assert.Equal(8, RouteWidget._ResolveNoteFontSize(cfg, 1.0),
            "zero cfg value falls back to NOTE_FONT_SIZE_BASE (8 pt)")

        cfg.routeNoteFontSize := -2
        Assert.Equal(8, RouteWidget._ResolveNoteFontSize(cfg, 1.0),
            "negative cfg value falls back to NOTE_FONT_SIZE_BASE (8 pt)")
    }

    resolve_note_font_size_falls_back_to_base_when_cfg_non_numeric()
    {
        ; Same defensive policy for non-numeric values — a
        ; programmatic caller might set the field to a string
        ; (the Settings dialog read path goes through _ClampFontSize
        ; which always returns an Integer, but a direct mutator
        ; could bypass it).
        cfg := AppSettings.Defaults()
        cfg.routeNoteFontSize := "not a number"
        Assert.Equal(8, RouteWidget._ResolveNoteFontSize(cfg, 1.0),
            "non-numeric cfg value falls back to NOTE_FONT_SIZE_BASE (8 pt)")

        cfg.routeNoteFontSize := ""
        Assert.Equal(8, RouteWidget._ResolveNoteFontSize(cfg, 1.0),
            "empty-string cfg value falls back to NOTE_FONT_SIZE_BASE (8 pt)")
    }

    resolve_note_font_size_floors_at_six_pt()
    {
        ; Even with a valid 6-pt cfg, a very small anchor scale
        ; (e.g. 0.5) would compute to 3 pt. The final Max(6, ...)
        ; floor guarantees the rendered text never drops below
        ; readable. 6 × 0.5 = 3 → floored to 6.
        cfg := AppSettings.Defaults()
        cfg.routeNoteFontSize := 6
        Assert.Equal(6, RouteWidget._ResolveNoteFontSize(cfg, 0.5),
            "6 × 0.5 = 3 floors at 6 pt")

        ; Same floor protects against a sub-6 cfg getting
        ; multiplied down further: cfg=4 (sub-6) falls back to
        ; base 8, then 8 × 0.5 = 4 → floored to 6.
        cfg.routeNoteFontSize := 4
        Assert.Equal(6, RouteWidget._ResolveNoteFontSize(cfg, 0.5),
            "sub-6 cfg + scale 0.5 still floors at 6 pt (8 base × 0.5 = 4 → 6)")
    }

    ; ============================================================
    ; _ResolveNoteLineHeight (B4 follow-up: line height tracks font)
    ; ============================================================
    ;
    ; Public-static helper that picks the px line height for the
    ; note row given the already-scaled noteFontSize. TUGs's first
    ; report at 16 pt was "cortada na metade" because the old
    ; formula returned fontSize+2 (=18 px), well below the ~22 px
    ; Segoe UI actually needs at 16 pt. The 1.75x ratio comes from
    ; the pre-config baseline (NOTE_LINE_HEIGHT_BASE=14 over
    ; NOTE_FONT_SIZE_BASE=8) so default renders are unchanged.

    resolve_note_line_height_default_8pt_returns_14_px()
    {
        ; Default font: the helper must return exactly 14 px so
        ; existing renders (every install upgrading over the
        ; previous version) look identical. Pins the backward-
        ; compat contract.
        Assert.Equal(14, RouteWidget._ResolveNoteLineHeight(8, 1.0),
            "8 pt at scale 1.0 → 14 px (matches NOTE_LINE_HEIGHT_BASE)")
    }

    resolve_note_line_height_grows_proportionally_with_font()
    {
        ; The whole point of the change: larger fonts get
        ; proportionally taller rows so descenders don't clip.
        ; The implementation uses Ceil (not Round) on the ratio
        ; so the .5 boundaries never land a pixel short of the
        ; glyph height — Round in AHK v2 uses banker's rounding
        ; which would flip 24.5 → 24 (the unsafe direction).
        ;
        ; At Ceil(1.75x):
        ;   10 → 18 px (Ceil(17.5) = 18; ratio dominates)
        ;   12 → 21 px (Ceil(21.0) = 21)
        ;   14 → 25 px (Ceil(24.5) = 25, the case Round() got wrong)
        ;   16 → 28 px (Ceil(28.0) = 28; the value TUGs needed)
        Assert.Equal(18, RouteWidget._ResolveNoteLineHeight(10, 1.0),
            "10 pt × 1.75 = 17.5 → 18 px (Ceil)")
        Assert.Equal(21, RouteWidget._ResolveNoteLineHeight(12, 1.0),
            "12 pt × 1.75 = 21 px")
        Assert.Equal(25, RouteWidget._ResolveNoteLineHeight(14, 1.0),
            "14 pt × 1.75 = 24.5 → 25 px (Ceil; Round would underflow)")
        Assert.Equal(28, RouteWidget._ResolveNoteLineHeight(16, 1.0),
            "16 pt × 1.75 = 28 px (fixes TUGs 'cortada na metade')")
    }

    resolve_note_line_height_respects_constant_floor_for_small_fonts()
    {
        ; At small font sizes the 1.75x ratio drops below the
        ; absolute 14 px floor (NOTE_LINE_HEIGHT_BASE) and below
        ; the fontSize+2 floor. The Max() across the three floors
        ; guarantees the row never gets ridiculously short.
        ;   6 pt: ratio=11, +2=8, base=14 → Max = 14
        Assert.Equal(14, RouteWidget._ResolveNoteLineHeight(6, 1.0),
            "6 pt: 14 px floor wins over ratio (11) and +2 (8)")

        ; At scale 2.0 the constant floor scales too: base=28.
        ; For a 6 pt font at scale 2.0, ratio=11 (the input is
        ; already scaled), but constant floor pushes to 28.
        Assert.Equal(28, RouteWidget._ResolveNoteLineHeight(6, 2.0),
            "6 pt at scale 2.0: 14*2 = 28 px constant floor wins")
    }

    resolve_note_line_height_handles_invalid_scale()
    {
        ; Invalid scale (zero, negative, non-numeric) falls back
        ; to 1.0 — a buggy anchor shouldn't zero out the constant
        ; floor and let the line height collapse.
        Assert.Equal(28, RouteWidget._ResolveNoteLineHeight(16, 0),
            "zero scale falls back to 1.0 → same as scale=1.0")
        Assert.Equal(28, RouteWidget._ResolveNoteLineHeight(16, -1),
            "negative scale falls back to 1.0")
        Assert.Equal(28, RouteWidget._ResolveNoteLineHeight(16, "oops"),
            "non-numeric scale falls back to 1.0")
    }

    ; ============================================================
    ; _LogicalWidthFromPhysical (DPI conversion)
    ; ============================================================
    ;
    ; Pure helper that inverts the DPI scaling AHK v2 applies to
    ; DPI-aware Guis. WinGetPos returns physical pixels but
    ; Gui.Show treats W as logical and re-applies the DPI factor;
    ; without this inverse the route surface overhangs the anchor
    ; on any monitor scaled above 100% (the exact bug TUGs hit on
    ; his 150% 4K primary). The DllCall wrapper around this helper
    ; (_ResolveAnchorLogicalWidth) is not unit-tested — it's a
    ; trivial dispatch onto this function, and the Win32 API call
    ; can't be exercised meaningfully in a headless test.

    logical_width_from_physical_no_op_at_96_dpi()
    {
        ; 100% DPI (Rafael's PC, default Windows install) — the
        ; helper must be a perfect no-op or it would regress every
        ; user who never had the bug.
        Assert.Equal(350, RouteWidget._LogicalWidthFromPhysical(350, 96),
            "96 dpi: physical = logical")
        Assert.Equal(100, RouteWidget._LogicalWidthFromPhysical(100, 96),
            "96 dpi at smaller widths: still no-op")
    }

    logical_width_from_physical_unscales_125_percent()
    {
        ; 125% scaling = 120 dpi. A logical 350 anchor renders as
        ; 437 physical (Round(350 * 1.25)); the inverse takes 437
        ; back to ~350. Round(437 * 96 / 120) = Round(349.6) = 350.
        Assert.Equal(350, RouteWidget._LogicalWidthFromPhysical(437, 120),
            "125% scaling: 437 physical → 350 logical")
    }

    logical_width_from_physical_unscales_150_percent()
    {
        ; The exact case TUGs was hitting on his 4K 32" primary.
        ; A logical 350 anchor renders as 525 physical; the
        ; inverse takes 525 back to 350. Regression here means
        ; the route surface overhangs the anchor again.
        Assert.Equal(350, RouteWidget._LogicalWidthFromPhysical(525, 144),
            "150% scaling: 525 physical → 350 logical (TUGs's setup)")
    }

    logical_width_from_physical_falls_back_to_96_when_dpi_invalid()
    {
        ; GetDpiForWindow can return 0 or throw on pre-Win10-1607
        ; systems. The wrapper catches the throw and leaves dpi at
        ; 96; the helper itself also defends against 0 / non-numeric
        ; / sub-72 values, all coerced to 96. Net effect: legacy
        ; systems fall through the no-op branch (physical = logical)
        ; which matches what they actually do at the OS level.
        Assert.Equal(525, RouteWidget._LogicalWidthFromPhysical(525, 0),
            "dpi=0 coerces to 96, physical preserved")
        Assert.Equal(525, RouteWidget._LogicalWidthFromPhysical(525, ""),
            "dpi='' coerces to 96")
        Assert.Equal(525, RouteWidget._LogicalWidthFromPhysical(525, "garbage"),
            "non-numeric dpi coerces to 96")
        Assert.Equal(525, RouteWidget._LogicalWidthFromPhysical(525, 50),
            "sub-72 dpi (impossible in practice) coerces to 96")
    }

    logical_width_from_physical_returns_zero_for_non_positive_width()
    {
        ; The _Render path already early-returns on (aw <= 0), but
        ; a future refactor could route through the helper with
        ; junk; defend against silent negative-pixel widths
        ; reaching Gui.Show.
        Assert.Equal(0, RouteWidget._LogicalWidthFromPhysical(0, 96),
            "width=0 returns 0 (no rendering possible)")
        Assert.Equal(0, RouteWidget._LogicalWidthFromPhysical(-50, 96),
            "negative width returns 0")
        Assert.Equal(0, RouteWidget._LogicalWidthFromPhysical("", 96),
            "empty-string width returns 0")
        Assert.Equal(0, RouteWidget._LogicalWidthFromPhysical("garbage", 96),
            "non-numeric width returns 0")
    }
}

TestRegistry.Register(RouteWidgetTests)
