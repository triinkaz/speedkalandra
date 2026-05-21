; ============================================================
; OverlayInteractionService — Ctrl-drag + Ctrl-wheel resize + click-through
; ============================================================
;
; Behavior:
;   - Without Ctrl: clicks on the overlay PASS THROUGH to the window
;     behind (PoE2 receives the click). The overlay does not block
;     game interaction.
;   - With Ctrl: the overlay becomes interactive.
;       * Left click on a registered Gui starts a DRAG (moves the
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
;   - Drag is event-driven: OnMessage(WM_MOUSEMOVE) moves the window
;     while LBUTTON is held, OnMessage(WM_LBUTTONUP) finishes. The
;     LBUTTONDOWN handler calls SetCapture(hwnd) explicitly so mouse
;     messages keep arriving even when the cursor overshoots the
;     overlay on a fast drag. Windows would do this in DefWindowProc,
;     but we return 0 from LBUTTONDOWN to suppress the click on child
;     buttons (V1/V2/V3) — which also suppresses the default capture.
;     A 100ms watchdog covers the rare case where WM_LBUTTONUP is
;     lost (cross-process focus change mid-drag). A polled-tick
;     approach (SetTimer 16ms) competes with the other ~5 SetTimers
;     on the AHK message pump and stutters under DWM load (e.g. when
;     an AlwaysOnTop dialog is open at the same time).
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

    ; Watchdog for the lost-LBUTTONUP edge case (see PHILOSOPHY).
    ; 100ms is imperceptible to humans while keeping CPU cost negligible.
    static DRAG_WATCHDOG_MS := 100

    ; WS_EX_TRANSPARENT bit, used for click-through toggle.
    static WS_EX_TRANSPARENT := 0x20

    ; Dynamic opacity tied to mouse HOVER:
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
    static WM_LBUTTONUP   := 0x202
    static WM_MOUSEMOVE   := 0x200
    static WM_MOUSEWHEEL  := 0x20A

    _bus       := ""
    _headless  := false
    _enabled   := false

    ; State
    _ctrlDown    := false
    _hoveredHwnd := 0      ; hwnd currently under the cursor (0 = none).
    ; Array<Map<"hwnd"|"onDragEnd"|"onResize">>
    _widgets   := ""

    ; Drag state
    _dragHwnd        := 0
    _dragStartMouseX := 0
    _dragStartMouseY := 0
    _dragStartWinX   := 0
    _dragStartWinY   := 0
    ; Last cursor position the drag handler reacted to. Used to skip
    ; redundant WinMove when Windows replays a coalesced WM_MOUSEMOVE
    ; with unchanged coords.
    _lastMouseX      := 0
    _lastMouseY      := 0
    ; Stable BoundFuncs for the drag plumbing (OnMessage handlers +
    ; watchdog timer).
    _dragMoveFn      := ""
    _dragUpFn        := ""
    _dragWatchdogFn  := ""

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

        this._dragMoveFn      := this._OnDragMove.Bind(this)
        this._dragUpFn        := this._OnDragUp.Bind(this)
        this._dragWatchdogFn  := this._DragWatchdog.Bind(this)
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

        ; MouseGetPos defaults to Client coords (relative to the active
        ; window). Both _UpdateHoverState and the drag handlers compare
        ; against WinGetPos which is always Screen — mixing referentials
        ; would silently produce wrong deltas/hits when the active
        ; window changes (e.g. user clicks the game mid-hover). Force
        ; Screen for this thread.
        CoordMode("Mouse", "Screen")

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

        ; Cancel any drag in progress WITHOUT firing the callback:
        ; teardown is not a commit. The widget keeps the position
        ; it persisted on the last completed gesture.
        this._dragHwnd := 0
        this._CleanupDrag()

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
    ;               LButton after a Ctrl-drag. Use to persist the
    ;               new widget position.
    ;   onResize  : callable(steps) or "" — fired on Ctrl+wheel
    ;               (steps = +1 wheel up, -1 down, etc.).
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
        ; freshly registered hwnd so it is born with the correct dimmed
        ; opacity even when Ctrl isn't pressed yet (the default state).
        this._ApplyVisualState(hwnd)
    }

    UnregisterHwnd(hwnd)
    {
        if (hwnd = 0)
            return
        if (this._dragHwnd = hwnd)
        {
            ; Drag target was unregistered mid-gesture (widget hidden,
            ; layout swap). Cancel without firing the callback.
            this._dragHwnd := 0
            this._CleanupDrag()
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
    ; _UpdateHoverState
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

        ; Toggle WS_EX_TRANSPARENT AND opacity on all registered
        ; hwnds (synced with Ctrl state).
        this._ApplyVisualStateToAll()

        try this._bus.Publish(Events.CtrlStateChanged, Map("active", newVal))
        return true
    }

    ; ============================================================
    ; Visual state: click-through (WS_EX_TRANSPARENT) + opacity.
    ; Computes state combining Ctrl + hover:
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
    ;
    ; The decision tree:
    ;   no Ctrl                  → ignore (click-through)
    ;   Ctrl + unregistered hwnd → ignore
    ;   Ctrl + registered hwnd   → start DRAG
    ; ============================================================

    _OnLButtonDown(wParam, lParam, msg, hwnd)
    {
        if !this._ctrlDown
            return
        if !this._IsRegistered(hwnd)
            return

        mx := 0, my := 0, wx := 0, wy := 0
        try
        {
            MouseGetPos(&mx, &my)
            WinGetPos(&wx, &wy, , , "ahk_id " hwnd)
        }

        this._dragHwnd        := hwnd
        this._dragStartMouseX := mx
        this._dragStartMouseY := my
        this._dragStartWinX   := wx
        this._dragStartWinY   := wy
        this._lastMouseX      := mx
        this._lastMouseY      := my
        OutputDebug("OverlayInteractionService: drag start hwnd=" hwnd)

        ; Take mouse capture explicitly. Windows normally does this
        ; in DefWindowProc on LBUTTONDOWN, but we return 0 below to
        ; suppress the click on child buttons (V1/V2/V3), which also
        ; suppresses the default capture. Without explicit capture,
        ; WM_MOUSEMOVE stops arriving the moment the cursor leaves
        ; the overlay window — even by a single pixel — and the drag
        ; freezes until the cursor moves back over it.
        try DllCall("user32\SetCapture", "Ptr", hwnd, "Ptr")

        ; Install drag plumbing. Handlers are torn down in _EndDrag /
        ; _CleanupDrag, so they exist only while a gesture is in
        ; progress — no risk of duplicate handlers across multiple
        ; drags.
        try OnMessage(OverlayInteractionService.WM_MOUSEMOVE, this._dragMoveFn)
        try OnMessage(OverlayInteractionService.WM_LBUTTONUP,  this._dragUpFn)
        try SetTimer(this._dragWatchdogFn, OverlayInteractionService.DRAG_WATCHDOG_MS)

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
    ; Drag handlers (event-driven; see PHILOSOPHY)
    ; ============================================================

    ; WM_MOUSEMOVE: moves the dragged window. Windows already skips
    ; messages when the cursor didn't move; the _lastMouseX/Y guard
    ; only catches a coalesced replay with unchanged coords (rare
    ; but cheap to defend against).
    _OnDragMove(wParam, lParam, msg, hwnd)
    {
        if (this._dragHwnd = 0)
            return
        try
        {
            cx := 0, cy := 0
            MouseGetPos(&cx, &cy)
            if (cx = this._lastMouseX && cy = this._lastMouseY)
                return
            this._lastMouseX := cx
            this._lastMouseY := cy

            WinMove(this._dragStartWinX + (cx - this._dragStartMouseX),
                    this._dragStartWinY + (cy - this._dragStartMouseY),
                    , ,
                    "ahk_id " this._dragHwnd)
        }
    }

    ; WM_LBUTTONUP: normal drag completion.
    _OnDragUp(wParam, lParam, msg, hwnd)
    {
        if (this._dragHwnd = 0)
            return
        this._EndDrag()
    }

    ; Watchdog. Fires only if WM_LBUTTONUP was lost — typically a
    ; cross-process focus change steals mouse capture before the
    ; release reaches us. Detection by direct key state; no WinMove
    ; here, that lives in _OnDragMove.
    _DragWatchdog()
    {
        if (this._dragHwnd = 0)
        {
            try SetTimer(this._dragWatchdogFn, 0)
            return
        }
        if !GetKeyState("LButton", "P")
            this._EndDrag()
    }

    ; Ends the gesture normally: tears down the OnMessage handlers
    ; and watchdog, then fires the onDragEnd callback. Idempotent —
    ; safe to call from both _OnDragUp and _DragWatchdog if the user
    ; releases LBUTTON between watchdog ticks.
    _EndDrag()
    {
        if (this._dragHwnd = 0)
            return
        finishedHwnd := this._dragHwnd
        this._dragHwnd := 0
        this._CleanupDrag()
        OutputDebug("OverlayInteractionService: drag end hwnd=" finishedHwnd)

        this._FireOnDragEnd(finishedHwnd)
    }

    ; Removes the drag-time OnMessage handlers, the watchdog timer
    ; and releases mouse capture. Used by _EndDrag (normal flow) and
    ; by the cancellation paths in Stop() and UnregisterHwnd() (which
    ; clear _dragHwnd directly and skip the onDragEnd callback).
    ; ReleaseCapture is a no-op if we don't currently hold capture
    ; (or if WM_LBUTTONUP already released it via DefWindowProc).
    _CleanupDrag()
    {
        try OnMessage(OverlayInteractionService.WM_MOUSEMOVE, this._dragMoveFn, 0)
        try OnMessage(OverlayInteractionService.WM_LBUTTONUP,  this._dragUpFn,   0)
        try SetTimer(this._dragWatchdogFn, 0)
        try DllCall("user32\ReleaseCapture")
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
