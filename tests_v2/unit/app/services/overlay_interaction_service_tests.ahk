; ============================================================
; OverlayInteractionServiceTests
; ============================================================
;
; Service controla click-through e drag/resize de widgets do overlay.
; Em headless=true: Start()/Stop() nao instala SetTimer/OnMessage reais.
; State machine (Register/Unregister/SetCtrlState) eh testavel.
;
; OUT OF SCOPE (requer OnMessage/Win32 real):
;   - _OnLButtonDown drag start
;   - _OnMouseWheel resize
;   - _DragTick movimento
;   - _UpdateHoverState (depende de WinGetPos/MouseGetPos)
;
; Singleton: OverlayInteractionService.Instance eh sobrescrita a cada
; new() — esperado, Setup cria fresh instance.


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
        ; --- Construtor ---
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
        "static_drag_tick_ms_is_16",
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
        ; Acessa _widgets via reflexao indireta: registra e remove pra contar
        ; eh chato. Em vez disso, exponho via incremental count:
        ; (so consigo contar registrando e checando comportamento de duplicates)
        return this.svc._widgets.Length
    }

    ; ============================================================
    ; Construtor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        Assert.Throws(TypeError, () => OverlayInteractionService("not bus"))
    }

    constructor_default_headless_false()
    {
        ; So testa que nao crasha; nao vamos chamar Start() pra evitar
        ; SetTimer/OnMessage real.
        svc2 := OverlayInteractionService(this.bus)
        Assert.False(svc2.IsEnabled())
    }

    constructor_accepts_headless_true()
    {
        Assert.False(this.svc.IsEnabled())
    }

    constructor_sets_static_instance()
    {
        ; Singleton pattern: Instance aponta pra ultima construida.
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
        this.svc._dragHwnd := 12345   ; simula drag em andamento
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
        Assert.Equal(1, this._WidgetCount(), "Duplicado: nao adiciona de novo")
    }

    register_hwnd_with_callbacks_stores_them()
    {
        this.svc.Start()
        cbDragEnd := (*) => "drag-end-called"
        cbResize  := (steps) => "resize-" steps
        this.svc.RegisterHwnd(12345, cbDragEnd, cbResize)
        Assert.Equal(1, this._WidgetCount())
        ; Verifica via _widgets diretamente (vista privada)
        Assert.Equal(cbDragEnd, this.svc._widgets[1]["onDragEnd"])
        Assert.Equal(cbResize,  this.svc._widgets[1]["onResize"])
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
        ; Simula drag em andamento naquele hwnd
        this.svc._dragHwnd := 12345
        this.svc.UnregisterHwnd(12345)
        Assert.Equal(0, this.svc._dragHwnd,
            "Cancela drag em andamento ao desregistrar o hwnd alvo")
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
            "Mesmo state: retorna false (sem mudanca)")
    }

    set_ctrl_state_publishes_event_on_change()
    {
        capturedEvents := this._CaptureEvents(Events.CtrlStateChanged)
        this.svc.SetCtrlState(true)
        Assert.Equal(1, capturedEvents.Length)
    }

    set_ctrl_state_does_not_publish_on_no_change()
    {
        this.svc.SetCtrlState(true)   ; primeira vez
        capturedEvents := this._CaptureEvents(Events.CtrlStateChanged)
        this.svc.SetCtrlState(true)   ; idempotente
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
            "Polling de Ctrl: ~20Hz")
    }

    static_drag_tick_ms_is_16()
    {
        Assert.Equal(16, OverlayInteractionService.DRAG_TICK_MS,
            "Drag tick: ~60fps")
    }

    static_ws_ex_transparent_is_correct()
    {
        Assert.Equal(0x20, OverlayInteractionService.WS_EX_TRANSPARENT,
            "Win32 WS_EX_TRANSPARENT = 0x20")
    }
}

TestRegistry.Register(OverlayInteractionServiceTests)
