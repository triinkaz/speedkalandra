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
        "register_hwnd_default_resize_border_is_empty_string",
        "register_hwnd_with_resize_border_callback_stores_it",
        "register_hwnd_with_default_min_size_uses_80_x_32",
        "register_hwnd_with_explicit_min_size_stores_them",

        ; --- UnregisterHwnd ---
        "unregister_hwnd_removes_from_widgets",
        "unregister_hwnd_with_zero_no_op",
        "unregister_hwnd_for_unknown_no_op",
        "unregister_hwnd_during_drag_clears_drag_state",
        "unregister_hwnd_during_resize_clears_drag_kind",

        ; --- _FindWidget helper (used by _OnLButtonDown hit-test) ---
        "find_widget_returns_widget_for_registered_hwnd",
        "find_widget_returns_empty_string_for_unknown_hwnd",

        ; --- Drag kind state machine ---
        "initial_drag_kind_is_none",
        "stop_resets_drag_kind",

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
        "static_ws_ex_transparent_is_correct"
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

    register_hwnd_default_resize_border_is_empty_string()
    {
        ; Backward compat: callers that don't pass onResizeBorder
        ; (every Classic widget) get "" stored. _OnLButtonDown
        ; treats "" as "don't hit-test the border" so Classic
        ; behavior is preserved.
        this.svc.Start()
        this.svc.RegisterHwnd(12345, (*) => 0, (steps) => 0)
        Assert.Equal("", this.svc._widgets[1]["onResizeBorder"])
    }

    register_hwnd_with_resize_border_callback_stores_it()
    {
        ; Plus widgets register with the 4th argument (their
        ; _OnBorderResize callback). The map slot must keep the
        ; reference so _OnLButtonDown / _FireOnResizeBorderEnd can
        ; pick it up later.
        this.svc.Start()
        cbBorder := (w, h) => "resize-" w "x" h
        this.svc.RegisterHwnd(12345, (*) => 0, (steps) => 0, cbBorder)
        Assert.Equal(cbBorder, this.svc._widgets[1]["onResizeBorder"])
    }

    register_hwnd_with_default_min_size_uses_80_x_32()
    {
        ; Conservative floor used when the caller doesn't override.
        ; The defaults are smaller than any real widget's FIXED_W ×
        ; MIN_SCALE, so a future widget that forgets to pass
        ; minW/minH still gets a sane lower bound that won't let
        ; the user shrink the overlay into invisibility.
        this.svc.Start()
        this.svc.RegisterHwnd(12345)
        Assert.Equal(80, this.svc._widgets[1]["minW"])
        Assert.Equal(32, this.svc._widgets[1]["minH"])
    }

    register_hwnd_with_explicit_min_size_stores_them()
    {
        ; Plus widgets that want a tighter floor pass minW/minH at
        ; RegisterHwnd time. The service stores them and feeds them
        ; into OverlayResizeGeometry.ComputeNewSize during the
        ; live drag.
        this.svc.Start()
        this.svc.RegisterHwnd(12345, "", "", (*) => 0, 200, 64)
        Assert.Equal(200, this.svc._widgets[1]["minW"])
        Assert.Equal(64,  this.svc._widgets[1]["minH"])
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
        this.svc._dragKind := "move"
        this.svc.UnregisterHwnd(12345)
        Assert.Equal(0, this.svc._dragHwnd,
            "Cancels ongoing drag when unregistering the target hwnd")
        Assert.Equal("none", this.svc._dragKind,
            "Drag kind also reset — a half-unregistered drag would"
            . " leave the next _OnDragMove branching on stale state.")
    }

    unregister_hwnd_during_resize_clears_drag_kind()
    {
        ; Same as above but for a resize gesture. Pins the parity
        ; between the two paths — a regression that handled only
        ; one kind would leave _dragKind="resize" pointing nowhere.
        this.svc.Start()
        this.svc.RegisterHwnd(12345)
        this.svc._dragHwnd := 12345
        this.svc._dragKind := "resize"
        this.svc.UnregisterHwnd(12345)
        Assert.Equal(0, this.svc._dragHwnd)
        Assert.Equal("none", this.svc._dragKind)
    }

    ; ============================================================
    ; _FindWidget helper
    ; ============================================================

    find_widget_returns_widget_for_registered_hwnd()
    {
        ; _FindWidget is the lookup _OnLButtonDown uses to extract
        ; the resize callback + min size. Pin the contract so a
        ; refactor doesn't silently change its return shape.
        this.svc.Start()
        cbBorder := (w, h) => 0
        this.svc.RegisterHwnd(12345, (*) => 0, (s) => 0, cbBorder, 200, 64)

        widget := this.svc._FindWidget(12345)
        Assert.True(widget is Map, "returns the widget Map")
        Assert.Equal(12345,    widget["hwnd"])
        Assert.Equal(cbBorder, widget["onResizeBorder"])
        Assert.Equal(200,      widget["minW"])
        Assert.Equal(64,       widget["minH"])
    }

    find_widget_returns_empty_string_for_unknown_hwnd()
    {
        this.svc.Start()
        this.svc.RegisterHwnd(12345)
        Assert.Equal("", this.svc._FindWidget(99999))
    }

    ; ============================================================
    ; Drag kind state machine
    ; ============================================================

    initial_drag_kind_is_none()
    {
        ; A freshly constructed service has no gesture in flight.
        ; This is what _OnDragMove relies on to know there's nothing
        ; to dispatch — if the field defaulted to "move" or "resize"
        ; the next WM_MOUSEMOVE could start moving a window the user
        ; never clicked.
        Assert.Equal("none", this.svc._dragKind)
    }

    stop_resets_drag_kind()
    {
        ; Symmetric to stop_clears_drag_state: a Stop() in the
        ; middle of a resize must also clear the kind, so a later
        ; Start() + LButtonDown can't pick up the stale "resize"
        ; branch.
        this.svc.Start()
        this.svc._dragHwnd := 12345
        this.svc._dragKind := "resize"
        this.svc.Stop()
        Assert.Equal(0,      this.svc._dragHwnd)
        Assert.Equal("none", this.svc._dragKind)
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
}

TestRegistry.Register(OverlayInteractionServiceTests)
