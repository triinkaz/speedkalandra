; ============================================================
; OverlayInteractionServiceTests
; ============================================================
;
; Service controls click-through and drag/resize of overlay
; widgets. In headless=true mode: Start()/Stop() doesn't install
; real SetTimer/OnMessage. The state machine
; (Register/Unregister/SetCtrlState) is testable.
;
; OUT OF SCOPE (requires real OnMessage/Win32):
;   - _OnLButtonDown drag start
;   - _OnDragMove / _OnDragUp drag handlers
;   - _OnMouseWheel resize
;   - _UpdateHoverState (depends on WinGetPos/MouseGetPos)
;
; Singleton: OverlayInteractionService.Instance is overwritten on
; each new() — expected, Setup creates a fresh instance.


class OverlayInteractionServiceTests extends TestCase
{
    bus := ""
    svc := ""

    Setup()
    {
        this.bus := Fixtures.MakeBus()
        this.svc := OverlayInteractionService(this.bus, true)   ; headless
    }

    Teardown()
    {
        if IsObject(this.svc)
        {
            try this.svc.Stop()
        }
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_default_headless_false",
        "constructor_accepts_headless_true",
        "constructor_sets_static_instance",
        "constructor_initial_state_disabled",
        "constructor_initial_ctrl_down_false",

        ; --- Start / Stop ---
        "start_sets_enabled_true",
        "start_is_idempotent",
        "stop_sets_enabled_false",
        "stop_is_idempotent",
        "stop_clears_drag_state",

        ; --- RegisterHwnd ---
        "register_hwnd_adds_to_widgets",
        "register_hwnd_with_zero_no_op",
        "register_hwnd_duplicate_is_no_op",
        "register_hwnd_with_callbacks_stores_them",
        "register_hwnd_default_group_id_is_zero",
        "register_hwnd_with_group_id_stores_it",

        ; --- UnregisterHwnd ---
        "unregister_hwnd_removes_from_widgets",
        "unregister_hwnd_with_zero_no_op",
        "unregister_hwnd_for_unknown_no_op",
        "unregister_hwnd_during_drag_clears_drag_state",

        ; --- SetCtrlState ---
        "set_ctrl_state_true_updates_internal_state",
        "set_ctrl_state_false_updates_internal_state",
        "set_ctrl_state_coerces_truthy_to_bool",
        "set_ctrl_state_idempotent_returns_false",
        "set_ctrl_state_publishes_event_on_change",
        "set_ctrl_state_does_not_publish_on_no_change",
        "set_ctrl_state_event_payload_has_active",

        ; --- Static constants ---
        "static_poll_ms_is_50",
        "static_drag_watchdog_ms_is_100",
        "static_ws_ex_transparent_is_correct",

        ; --- _IsInHoveredGroup (hover-group propagation;
        ;     anchor + RouteWidget dim together) ---
        "is_in_hovered_group_returns_false_when_nothing_hovered",
        "is_in_hovered_group_self_match",
        "is_in_hovered_group_satellite_to_primary",
        "is_in_hovered_group_primary_to_satellite",
        "is_in_hovered_group_peers_with_shared_explicit_group",
        "is_in_hovered_group_unrelated_widgets_false",
        "is_in_hovered_group_unregistered_hwnd_false"
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

    _WidgetCount()
    {
        ; Accesses _widgets via indirect reflection: register/remove to
        ; count is awkward. Instead, expose via incremental count:
        ; (the only way to count is by registering and checking
        ; duplicate behavior).
        return this.svc._widgets.Length
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        Assert.Throws(TypeError, () => OverlayInteractionService("not bus"))
    }

    constructor_default_headless_false()
    {
        ; Only tests that it doesn't crash; we won't call Start() to
        ; avoid real SetTimer/OnMessage.
        svc2 := OverlayInteractionService(this.bus)
        Assert.False(svc2.IsEnabled())
    }

    constructor_accepts_headless_true()
    {
        Assert.False(this.svc.IsEnabled())
    }

    constructor_sets_static_instance()
    {
        ; Singleton pattern: Instance points to the last one constructed.
        Assert.True(OverlayInteractionService.Instance is OverlayInteractionService)
    }

    constructor_initial_state_disabled()
    {
        Assert.False(this.svc.IsEnabled())
    }

    constructor_initial_ctrl_down_false()
    {
        Assert.False(this.svc.IsCtrlDown())
    }

    ; ============================================================
    ; Start / Stop
    ; ============================================================

    start_sets_enabled_true()
    {
        this.svc.Start()
        Assert.True(this.svc.IsEnabled())
    }

    start_is_idempotent()
    {
        this.svc.Start()
        this.svc.Start()
        Assert.True(this.svc.IsEnabled())
    }

    stop_sets_enabled_false()
    {
        this.svc.Start()
        this.svc.Stop()
        Assert.False(this.svc.IsEnabled())
    }

    stop_is_idempotent()
    {
        this.svc.Stop()
        this.svc.Stop()
        Assert.False(this.svc.IsEnabled())
    }

    stop_clears_drag_state()
    {
        this.svc.Start()
        this.svc._dragHwnd := 12345   ; simulates an ongoing drag
        this.svc.Stop()
        Assert.Equal(0, this.svc._dragHwnd)
    }

    ; ============================================================
    ; RegisterHwnd
    ; ============================================================

    register_hwnd_adds_to_widgets()
    {
        this.svc.Start()
        this.svc.RegisterHwnd(12345)
        Assert.Equal(1, this._WidgetCount())
    }

    register_hwnd_with_zero_no_op()
    {
        this.svc.Start()
        this.svc.RegisterHwnd(0)
        Assert.Equal(0, this._WidgetCount())
    }

    register_hwnd_duplicate_is_no_op()
    {
        this.svc.Start()
        this.svc.RegisterHwnd(12345)
        this.svc.RegisterHwnd(12345)
        Assert.Equal(1, this._WidgetCount(), "Duplicate: doesn't add again")
    }

    register_hwnd_with_callbacks_stores_them()
    {
        this.svc.Start()
        cbDragEnd := (*) => "drag-end-called"
        cbResize  := (steps) => "resize-" steps
        this.svc.RegisterHwnd(12345, cbDragEnd, cbResize)
        Assert.Equal(1, this._WidgetCount())
        ; Verifies via _widgets directly (private view)
        Assert.Equal(cbDragEnd, this.svc._widgets[1]["onDragEnd"])
        Assert.Equal(cbResize,  this.svc._widgets[1]["onResize"])
    }

    register_hwnd_default_group_id_is_zero()
    {
        ; 3-arg call (back-compat with code that pre-dates the
        ; groupId concept) must store groupId=0 so the legacy
        ; per-hwnd hover dim semantics are preserved. Without the
        ; default-zero guarantee, an unrelated registration could
        ; accidentally land in some other widget's group.
        this.svc.Start()
        this.svc.RegisterHwnd(12345)
        Assert.Equal(0, this.svc._widgets[1]["groupId"],
            "3-arg RegisterHwnd defaults groupId to 0")
    }

    register_hwnd_with_group_id_stores_it()
    {
        ; 4-arg call (WidgetBase + RouteWidget convention) stores
        ; the explicit groupId so _IsInHoveredGroup can match it.
        ; Lock the storage contract so a future refactor that
        ; changes the field name surfaces here, not as a silent
        ; "hover dim no longer syncs" regression.
        this.svc.Start()
        this.svc.RegisterHwnd(12345, "", "", 999)
        Assert.Equal(999, this.svc._widgets[1]["groupId"])
    }

    ; ============================================================
    ; UnregisterHwnd
    ; ============================================================

    unregister_hwnd_removes_from_widgets()
    {
        this.svc.Start()
        this.svc.RegisterHwnd(12345)
        this.svc.RegisterHwnd(67890)
        this.svc.UnregisterHwnd(12345)
        Assert.Equal(1, this._WidgetCount())
        Assert.Equal(67890, this.svc._widgets[1]["hwnd"])
    }

    unregister_hwnd_with_zero_no_op()
    {
        this.svc.Start()
        this.svc.RegisterHwnd(12345)
        this.svc.UnregisterHwnd(0)
        Assert.Equal(1, this._WidgetCount())
    }

    unregister_hwnd_for_unknown_no_op()
    {
        this.svc.Start()
        this.svc.RegisterHwnd(12345)
        this.svc.UnregisterHwnd(99999)
        Assert.Equal(1, this._WidgetCount())
    }

    unregister_hwnd_during_drag_clears_drag_state()
    {
        this.svc.Start()
        this.svc.RegisterHwnd(12345)
        ; Simulates an ongoing drag on that hwnd
        this.svc._dragHwnd := 12345
        this.svc.UnregisterHwnd(12345)
        Assert.Equal(0, this.svc._dragHwnd,
            "Cancels ongoing drag when unregistering the target hwnd")
    }

    ; ============================================================
    ; SetCtrlState
    ; ============================================================

    set_ctrl_state_true_updates_internal_state()
    {
        this.svc.SetCtrlState(true)
        Assert.True(this.svc.IsCtrlDown())
    }

    set_ctrl_state_false_updates_internal_state()
    {
        this.svc.SetCtrlState(true)
        this.svc.SetCtrlState(false)
        Assert.False(this.svc.IsCtrlDown())
    }

    set_ctrl_state_coerces_truthy_to_bool()
    {
        this.svc.SetCtrlState(1)
        Assert.True(this.svc.IsCtrlDown())
        this.svc.SetCtrlState(0)
        Assert.False(this.svc.IsCtrlDown())
    }

    set_ctrl_state_idempotent_returns_false()
    {
        this.svc.SetCtrlState(true)
        Assert.False(this.svc.SetCtrlState(true),
            "Same state: returns false (no change)")
    }

    set_ctrl_state_publishes_event_on_change()
    {
        capturedEvents := this._CaptureEvents(Events.CtrlStateChanged)
        this.svc.SetCtrlState(true)
        Assert.Equal(1, capturedEvents.Length)
    }

    set_ctrl_state_does_not_publish_on_no_change()
    {
        this.svc.SetCtrlState(true)   ; first time
        capturedEvents := this._CaptureEvents(Events.CtrlStateChanged)
        this.svc.SetCtrlState(true)   ; idempotent
        Assert.Equal(0, capturedEvents.Length)
    }

    set_ctrl_state_event_payload_has_active()
    {
        capturedEvents := this._CaptureEvents(Events.CtrlStateChanged)
        this.svc.SetCtrlState(true)
        Assert.True(capturedEvents[1]["active"])
    }

    ; ============================================================
    ; Static constants
    ; ============================================================

    static_poll_ms_is_50()
    {
        Assert.Equal(50, OverlayInteractionService.POLL_MS,
            "Ctrl polling: ~20Hz")
    }

    static_drag_watchdog_ms_is_100()
    {
        Assert.Equal(100, OverlayInteractionService.DRAG_WATCHDOG_MS,
            "Watchdog interval for the lost-LBUTTONUP edge case")
    }

    static_ws_ex_transparent_is_correct()
    {
        Assert.Equal(0x20, OverlayInteractionService.WS_EX_TRANSPARENT,
            "Win32 WS_EX_TRANSPARENT = 0x20")
    }

    ; ============================================================
    ; _IsInHoveredGroup
    ;
    ; Group-hover propagation: when the cursor enters one widget
    ; of a group, ALL widgets in that group dim together. Match
    ; rules covered:
    ;   1. hwnd IS the hovered one              (self-match)
    ;   2. hwnd.groupId points to hoveredHwnd   (satellite → primary)
    ;   3. hovered.groupId points to hwnd       (primary ← satellite)
    ;   4. both share the same non-zero groupId (peers in a group)
    ;
    ; Production wiring exercises rules 2 + 3 specifically: the
    ; WidgetBase anchor passes its own Hwnd as groupId, and the
    ; RouteWidget passes the anchor's Hwnd as ITS groupId. So
    ; hovering the anchor triggers rule 3 (hovered=anchor,
    ; hovered.groupId=anchor.hwnd=route.hwnd — actually wait, no:
    ; hovered.groupId=anchor.hwnd; for the route, the check is
    ; `hovered.groupId = thisHwnd` which is anchor.hwnd = route.hwnd?
    ; No — anchor.groupId = anchor.hwnd, route.hwnd ≠ anchor.hwnd.
    ; Rule 3 needs hovered.groupId = thisHwnd. So hovered=anchor,
    ; hovered.groupId=anchor.hwnd, thisHwnd=route.hwnd. Doesn't
    ; match rule 3. RULE 2 from route's perspective:
    ; thisGroup=route.groupId=anchor.hwnd=hoveredHwnd → MATCHES.
    ; So when anchor hovered, rule 2 fires for the route widget.
    ; When route hovered, rule 3 fires for the anchor (hovered=route,
    ; hovered.groupId=route.groupId=anchor.hwnd, thisHwnd=anchor.hwnd,
    ; match). Rule 4 is exercised by widgets that explicitly share
    ; a third group key — not used in production today but the
    ; rule keeps the model symmetric.
    ; ============================================================

    is_in_hovered_group_returns_false_when_nothing_hovered()
    {
        ; Baseline: with no hover active (_hoveredHwnd = 0), no
        ; widget should report as in-group. Otherwise the default
        ; rendering state would dim everything.
        this.svc.RegisterHwnd(12345, "", "", 12345)
        Assert.False(this.svc._IsInHoveredGroup(12345),
            "no hover → no widget is in-group")
    }

    is_in_hovered_group_self_match()
    {
        ; Rule 1: the hovered hwnd is trivially in its own group.
        ; This is the legacy per-hwnd dim behaviour and must work
        ; even when no groupId is configured (group 0 → group 0
        ; doesn't normally match peers, but self-match takes
        ; precedence regardless).
        this.svc.RegisterHwnd(12345)
        this.svc._hoveredHwnd := 12345
        Assert.True(this.svc._IsInHoveredGroup(12345),
            "hwnd matches itself when hovered")
    }

    is_in_hovered_group_satellite_to_primary()
    {
        ; Rule 2: the route-widget side of the production link.
        ; Anchor registers with groupId=anchor.Hwnd; route widget
        ; registers with groupId=anchor.Hwnd. When the anchor is
        ; hovered, the route widget's groupId points to the
        ; hovered hwnd → in-group.
        anchorHwnd := 1111
        routeHwnd  := 2222
        this.svc.RegisterHwnd(anchorHwnd, "", "", anchorHwnd)
        this.svc.RegisterHwnd(routeHwnd,  "", "", anchorHwnd)
        this.svc._hoveredHwnd := anchorHwnd

        Assert.True(this.svc._IsInHoveredGroup(routeHwnd),
            "satellite (route) hovers along with primary (anchor)")
    }

    is_in_hovered_group_primary_to_satellite()
    {
        ; Rule 3: the anchor side of the same production link.
        ; When the route widget is hovered, hovered.groupId =
        ; anchor.Hwnd = thisHwnd (the anchor) → in-group.
        anchorHwnd := 1111
        routeHwnd  := 2222
        this.svc.RegisterHwnd(anchorHwnd, "", "", anchorHwnd)
        this.svc.RegisterHwnd(routeHwnd,  "", "", anchorHwnd)
        this.svc._hoveredHwnd := routeHwnd

        Assert.True(this.svc._IsInHoveredGroup(anchorHwnd),
            "primary (anchor) hovers along with satellite (route)")
    }

    is_in_hovered_group_peers_with_shared_explicit_group()
    {
        ; Rule 4: two widgets that both carry the same non-zero
        ; groupId match each other regardless of either hwnd. Not
        ; used in production today but locks the symmetric model
        ; so future multi-satellite scenarios (e.g. two route
        ; surfaces attached to one anchor) keep working.
        sharedGroup := 9999
        peerA := 3333
        peerB := 4444
        this.svc.RegisterHwnd(peerA, "", "", sharedGroup)
        this.svc.RegisterHwnd(peerB, "", "", sharedGroup)
        this.svc._hoveredHwnd := peerA

        Assert.True(this.svc._IsInHoveredGroup(peerB),
            "two widgets sharing the same explicit groupId are peers")
    }

    is_in_hovered_group_unrelated_widgets_false()
    {
        ; Negative case: two registered widgets with NO shared
        ; group key (default groupId=0 on both) must NOT dim
        ; together. Without this, the legacy per-hwnd behaviour
        ; would silently regress — every hover would dim every
        ; widget on screen.
        this.svc.RegisterHwnd(1111)    ; groupId default 0
        this.svc.RegisterHwnd(2222)    ; groupId default 0
        this.svc._hoveredHwnd := 1111

        Assert.False(this.svc._IsInHoveredGroup(2222),
            "unrelated widgets (no shared group) stay independent")
    }

    is_in_hovered_group_unregistered_hwnd_false()
    {
        ; Defensive: an hwnd that was never registered (e.g. a
        ; stale value cached on the caller side) shouldn't appear
        ; to match anything. The lookup in _GetGroupId returns 0
        ; for unknown hwnds, which combined with the hoveredGroup
        ; check keeps the result false.
        this.svc.RegisterHwnd(1111, "", "", 1111)
        this.svc._hoveredHwnd := 1111

        Assert.False(this.svc._IsInHoveredGroup(9999),
            "unregistered hwnd doesn't match the hovered group")
    }
}

TestRegistry.Register(OverlayInteractionServiceTests)
