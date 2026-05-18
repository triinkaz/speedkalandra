; ============================================================
; OverlayInteractionService — Ctrl-drag + Ctrl-wheel resize + click-through
; ============================================================
;
; Behavior:
;   - Without Ctrl: clicks on the overlay PASS THROUGH to the window
;     behind (PoE2 receives the click). The overlay does not block
;     game interaction.
;   - With Ctrl: the overlay becomes interactive.
;       * Left click on a registered Gui starts a drag (moves the
;         whole window).
;       * Mouse wheel over a registered Gui fires the onResize
;         callback (widget changes scale, scales everything inside).
;
; APPROACH:
;   Uses WS_EX_LAYERED + WS_EX_TRANSPARENT set on widget creation
;   (WidgetBase.Show / LayoutWidgetBase.Show). This approach works
;   CROSS-PROCESS — Windows routes mouse messages directly to the
;   window below, ignoring processes.
;
;   Dynamic toggle: when Ctrl flips, this service adds/removes the
;   WS_EX_TRANSPARENT bit on each registered Hwnd:
;     - Without Ctrl: TRANSPARENT on  -> click-through (PoE2 receives)
;     - With Ctrl: TRANSPARENT off -> interactive widget (drag/wheel works)
;
; PHILOSOPHY:
;   - Static singleton (OverlayInteractionService.Instance) so that
;     WidgetBase.Show()/LayoutWidgetBase.Show() can register Hwnds.
;   - Manual drag via SetTimer 16ms (same as legacy).
;   - Ctrl polling (50ms) updates _ctrlDown and triggers toggling the
;     TRANSPARENT bit on all hwnds + publishes Evt.CtrlStateChanged.
;   - Wheel: OnMessage WM_MOUSEWHEEL extracts delta (signed high word
;     of wParam), converts to "steps" (delta/120), calls onResize.
;
; CONSTRUCTION:
;   svc := OverlayInteractionService(bus, headless := false)
;   svc.Start()    ; installs SetTimer poll + OnMessage hooks
;   svc.RegisterHwnd(myGui.Hwnd, () => mySaveCb(), (steps) => myResizeCb(steps))
;   svc.UnregisterHwnd(myGui.Hwnd)
;   svc.Stop()
;
; HEADLESS:
;   headless=true: does not install a real SetTimer/OnMessage. Tests OK.

class OverlayInteractionService
{
    static Instance := ""

    ; Ctrl polling: 50ms (~20Hz) is enough.
    static POLL_MS := 50

    ; Drag tick: 16ms (~60fps) for smooth movement.
    static DRAG_TICK_MS := 16

    ; WS_EX_TRANSPARENT bit, used for click-through toggle (Item 2).
    static WS_EX_TRANSPARENT := 0x20

    ; Dynamic opacity tied to mouse HOVER (v17.14):
    ;   - Default (no hover, no Ctrl):       overlay 100% visible
    ;   - Mouse hovers over the overlay:     overlay ~10% (reveals game beneath)
    ;     -> lets the user see/click on game items hidden by the
    ;        overlay without having to move or hide the widget
    ;   - Ctrl pressed:                      overlay 100% (hover override)
    ;     -> guarantees full visibility during drag/resize/click on V1/V2/V3
    ;
    ; Hover polling runs in the same SetTimer as the Ctrl polling (50ms).
    ; Hit-test is done manually by comparing MouseGetPos with WinGetPos
    ; for each registered widget — this works even with click-through ON
    ; (because WinGetPos/MouseGetPos operate on screen coordinates, not
    ; on mouse-message hit-test).
    ;
    ; Tweaking: OPACITY_DIMMED is on a 0-255 scale (WinSetTransparent alpha).
    ;   25  = ~10% (current choice, very subtle)
    ;   51  = ~20% (more readable but still discreet)
    ;   76  = ~30% (visible)
    ;   128 = ~50%
    static OPACITY_DIMMED := 25
    static OPACITY_FULL   := 255

    ; Win32 message constants
    static WM_LBUTTONDOWN := 0x201
    static WM_MOUSEWHEEL  := 0x20A

    _bus       := ""
    _headless  := false
    _enabled   := false

    ; State
    _ctrlDown    := false
    _hoveredHwnd := 0      ; hwnd currently under the cursor (0 = none). v17.14
    ; Array<Map<"hwnd"|"onDragEnd"|"onResize">>
    _widgets   := ""

    ; Drag state
    _dragHwnd          := 0
    _dragStartMouseX   := 0
    _dragStartMouseY   := 0
    _dragStartWinX     := 0
    _dragStartWinY     := 0
    _dragTickFn        := ""

    ; Ctrl polling state (stable BoundFunc)
    _pollFn := ""

    ; OnMessage handlers (stable BoundFunc)
    _onLButtonDownFn := ""
    _onMouseWheelFn  := ""

    __New(bus, headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("OverlayInteractionService: 'bus' must be EventBus")
        this._bus      := bus
        this._headless := !!headless
        this._widgets  := []

        this._dragTickFn      := this._DragTick.Bind(this)
        this._pollFn          := this._Poll.Bind(this)
        this._onLButtonDownFn := this._OnLButtonDown.Bind(this)
        this._onMouseWheelFn  := this._OnMouseWheel.Bind(this)

        OverlayInteractionService.Instance := this
    }

    ; ============================================================
    ; Lifecycle
    ; ============================================================

    Start()
    {
        if this._enabled
            return
        this._enabled := true
        if this._headless
            return

        ; Ctrl polling
        SetTimer(this._pollFn, OverlayInteractionService.POLL_MS)

        ; OnMessage WM_LBUTTONDOWN (0x201) — captures clicks when Ctrl
        ; is pressed, to start drag. Only arrives when the widget has
        ; WS_EX_TRANSPARENT off (i.e. Ctrl pressed makes the service
        ; remove TRANSPARENT, the widget receives clicks normally).
        OnMessage(OverlayInteractionService.WM_LBUTTONDOWN, this._onLButtonDownFn)

        ; OnMessage WM_MOUSEWHEEL (0x20A) — captures wheel when Ctrl
        ; pressed, to fire resize. Same TRANSPARENT gating.
        OnMessage(OverlayInteractionService.WM_MOUSEWHEEL, this._onMouseWheelFn)

        OutputDebug("OverlayInteractionService: Start() OK")
    }

    Stop()
    {
        if !this._enabled
            return
        this._enabled := false

        ; Stop any drag in progress
        this._dragHwnd := 0
        try SetTimer(this._dragTickFn, 0)

        if this._headless
            return

        try SetTimer(this._pollFn, 0)
        try OnMessage(OverlayInteractionService.WM_LBUTTONDOWN, this._onLButtonDownFn, 0)
        try OnMessage(OverlayInteractionService.WM_MOUSEWHEEL, this._onMouseWheelFn, 0)
    }

    IsEnabled() => this._enabled
    IsCtrlDown() => this._ctrlDown

    ; ============================================================
    ; Public API: Register/Unregister
    ;
    ;   onDragEnd : callable() or "" — fired when the user releases
    ;               LButton after a drag (use this to persist the new
    ;               widget position)
    ;   onResize  : callable(steps) or "" — fired on Ctrl+wheel
    ;               (steps = +1 wheel up, -1 down, etc.)
    ; ============================================================

    RegisterHwnd(hwnd, onDragEnd := "", onResize := "")
    {
        if (hwnd = 0)
            return
        for w in this._widgets
        {
            if (w["hwnd"] = hwnd)
                return
        }
        this._widgets.Push(Map(
            "hwnd",      hwnd,
            "onDragEnd", onDragEnd,
            "onResize",  onResize
        ))
        OutputDebug("OverlayInteractionService: RegisterHwnd " hwnd " (total=" this._widgets.Length ")")

        ; Apply current visual state (click-through + opacity) to the
        ; freshly registered hwnd. Previously (Item 2) it only applied
        ; when Ctrl was already pressed; now it always applies so the
        ; overlay is born with the correct dimmed opacity when Ctrl is
        ; released (the default).
        this._ApplyVisualState(hwnd)
    }

    UnregisterHwnd(hwnd)
    {
        if (hwnd = 0)
            return
        if (this._dragHwnd = hwnd)
        {
            this._dragHwnd := 0
            try SetTimer(this._dragTickFn, 0)
        }
        for i, w in this._widgets
        {
            if (w["hwnd"] = hwnd)
            {
                this._widgets.RemoveAt(i)
                OutputDebug("OverlayInteractionService: UnregisterHwnd " hwnd " (total=" this._widgets.Length ")")
                return
            }
        }
    }

    ; ============================================================
    ; State polling (Ctrl + hover) — 50ms
    ; ============================================================

    _Poll()
    {
        this.SetCtrlState(!!GetKeyState("Ctrl", "P"))
        this._UpdateHoverState()
    }

    ; ============================================================
    ; _UpdateHoverState (v17.14)
    ;
    ; Detects which widget (if any) is under the cursor and updates
    ; _hoveredHwnd. Fired on every poll (50ms).
    ;
    ; Manual hit-test via coordinate comparison — works even with
    ; click-through active (because WinGetPos/MouseGetPos operate on
    ; screen geometry, not on mouse-message hit-test).
    ;
    ; If Ctrl is pressed, hover is IGNORED (the Ctrl override
    ; guarantees 100% opacity for reading/drag/resize without
    ; distraction).
    ; ============================================================
    _UpdateHoverState()
    {
        if this._ctrlDown
        {
            ; Ctrl override: force hover off so opacity is not dimmed
            ; by mistake. If _hoveredHwnd was set, clear it (the next
            ; ApplyVisualState restores opacity to full).
            this._SetHoveredHwnd(0)
            return
        }

        mx := 0, my := 0
        try MouseGetPos(&mx, &my)

        hoveredHwnd := 0
        for w in this._widgets
        {
            hw := w["hwnd"]
            wx := 0, wy := 0, ww := 0, wh := 0
            try
            {
                WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hw)
                if (mx >= wx && mx < wx + ww && my >= wy && my < wy + wh)
                {
                    hoveredHwnd := hw
                    break
                }
            }
        }

        this._SetHoveredHwnd(hoveredHwnd)
    }

    ; Updates _hoveredHwnd and reapplies visual state on affected widgets.
    ; Idempotent: if hwnd didn't change, no-op.
    _SetHoveredHwnd(hwnd)
    {
        if (hwnd = this._hoveredHwnd)
            return

        prev := this._hoveredHwnd
        this._hoveredHwnd := hwnd

        ; Restore the previous widget's opacity (left hover)
        if (prev != 0)
            this._ApplyVisualState(prev)

        ; Dim the new widget (entered hover)
        if (hwnd != 0)
            this._ApplyVisualState(hwnd)
    }

    ; ============================================================
    ; SetCtrlState(isDown) — updates the Ctrl state and publishes event
    ; ============================================================
    SetCtrlState(isDown)
    {
        newVal := !!isDown
        if (newVal = this._ctrlDown)
            return false
        this._ctrlDown := newVal
        OutputDebug("OverlayInteractionService: ctrlDown=" (newVal ? "true" : "false"))

        ; Item 2 + v17.14: toggle WS_EX_TRANSPARENT AND opacity on all
        ; registered hwnds (synced with Ctrl state).
        this._ApplyVisualStateToAll()

        try this._bus.Publish(Events.CtrlStateChanged, Map("active", newVal))
        return true
    }

    ; ============================================================
    ; Visual state: click-through (WS_EX_TRANSPARENT) + opacity
    ; (v17.14) — computes state combining Ctrl + hover:
    ;
    ;   Ctrl=on:                          click-through OFF, opacity FULL
    ;     -> interactive widget (drag/wheel/V1V2V3), full visibility
    ;
    ;   Ctrl=off + hover over widget:     click-through ON,  opacity DIMMED
    ;     -> mouse passed over — reveal game beneath
    ;
    ;   Ctrl=off + no hover (default):    click-through ON,  opacity FULL
    ;     -> visible widget but clicks pass through to the game
    ; ============================================================

    _ApplyVisualState(hwnd)
    {
        transparent := !this._ctrlDown
        hovered     := !this._ctrlDown && this._hoveredHwnd = hwnd

        ; Click-through bit (depends ONLY on Ctrl)
        op := transparent ? "+0x20" : "-0x20"
        try WinSetExStyle(op, "ahk_id " hwnd)

        ; Opacity (alpha): dimmed if hovered (and no Ctrl), full otherwise
        alpha := hovered
            ? OverlayInteractionService.OPACITY_DIMMED
            : OverlayInteractionService.OPACITY_FULL
        try WinSetTransparent(alpha, "ahk_id " hwnd)
    }

    _ApplyVisualStateToAll()
    {
        for w in this._widgets
            this._ApplyVisualState(w["hwnd"])
    }

    ; ============================================================
    ; OnMessage WM_LBUTTONDOWN — manual drag
    ; ============================================================

    _OnLButtonDown(wParam, lParam, msg, hwnd)
    {
        ; Only start drag if Ctrl is pressed AND the Gui is registered.
        if !this._ctrlDown
            return
        if !this._IsRegistered(hwnd)
            return

        OutputDebug("OverlayInteractionService: drag start hwnd=" hwnd)

        this._dragHwnd := hwnd
        try
        {
            MouseGetPos(&mx, &my)
            this._dragStartMouseX := mx
            this._dragStartMouseY := my
            WinGetPos(&wx, &wy, , , "ahk_id " hwnd)
            this._dragStartWinX := wx
            this._dragStartWinY := wy
        }
        try SetTimer(this._dragTickFn, OverlayInteractionService.DRAG_TICK_MS)

        ; return 0 = suppress the click so buttons don't activate during drag.
        return 0
    }

    ; ============================================================
    ; OnMessage WM_MOUSEWHEEL — resize via Ctrl+wheel
    ;
    ;   wParam structure (Win32):
    ;     high word (bits 16..31) = wheel delta (SIGNED int16)
    ;     low word  (bits 0..15)  = key flags (MK_CONTROL etc.)
    ;
    ;   Typical delta: +120 (wheel up) or -120 (down).
    ;   We convert to "steps" by dividing by 120 and rounding.
    ;
    ;   Gating: requires Ctrl pressed AND a registered hwnd AND an
    ;   onResize callback defined on register. Otherwise ignored
    ;   silently (lets the wheel propagate normally, e.g. ListView
    ;   scroll).
    ; ============================================================
    _OnMouseWheel(wParam, lParam, msg, hwnd)
    {
        if !this._ctrlDown
            return
        if !this._IsRegistered(hwnd)
            return

        ; Extract delta (signed 16-bit) from the high word of wParam.
        ; wParam is unsigned 64-bit; we need to convert the high word
        ; to signed to distinguish up (positive) from down (negative).
        rawDelta := (wParam >> 16) & 0xFFFF
        if (rawDelta & 0x8000)    ; sign bit
            rawDelta -= 0x10000
        if (rawDelta = 0)
            return

        ; Steps: typically ±1 per wheel click.
        steps := Round(rawDelta / 120)
        if (steps = 0)
            steps := rawDelta > 0 ? 1 : -1

        ; Look up the widget's callback.
        for w in this._widgets
        {
            if (w["hwnd"] != hwnd)
                continue
            cb := w.Has("onResize") ? w["onResize"] : ""
            if IsObject(cb)
            {
                try cb.Call(steps)
                OutputDebug("OverlayInteractionService: wheel resize hwnd=" hwnd " steps=" steps)
            }
            return 0    ; suppress — avoids inadvertent scroll going to the underlying process
        }
    }

    _IsRegistered(hwnd)
    {
        for w in this._widgets
        {
            if (w["hwnd"] = hwnd)
                return true
        }
        return false
    }

    ; ============================================================
    ; Drag tick (16ms = ~60fps, same as legacy)
    ; ============================================================

    _DragTick()
    {
        if (this._dragHwnd = 0)
        {
            try SetTimer(this._dragTickFn, 0)
            return
        }

        if !GetKeyState("LButton", "P")
        {
            finishedHwnd := this._dragHwnd
            this._dragHwnd := 0
            try SetTimer(this._dragTickFn, 0)
            OutputDebug("OverlayInteractionService: drag end hwnd=" finishedHwnd)
            this._FireOnDragEnd(finishedHwnd)
            return
        }

        try
        {
            MouseGetPos(&cx, &cy)
            dx := cx - this._dragStartMouseX
            dy := cy - this._dragStartMouseY
            newX := this._dragStartWinX + dx
            newY := this._dragStartWinY + dy
            WinMove(newX, newY, , , "ahk_id " this._dragHwnd)
        }
    }

    _FireOnDragEnd(hwnd)
    {
        for w in this._widgets
        {
            if (w["hwnd"] = hwnd)
            {
                if IsObject(w["onDragEnd"])
                    try w["onDragEnd"].Call()
                return
            }
        }
    }
}
