; ============================================================
; WidgetBase — base class for all overlay widgets
; ============================================================
;
; Responsibilities:
;   - Lifecycle: Show/Hide/ReRender/Destroy.
;   - Shared helpers: _BuildHeader (title bar + decorative X).
;   - Position/scale/visibility mutators that persist via callback.
;
; NOT done yet (open items):
;   - Drag/resize via mouse (will live in WidgetManager when introduced).
;   - Close button click handler (X is decorative now).
;   - Hover-hide transparency.
;
; Philosophy:
;   - Each concrete widget extends WidgetBase and implements _BuildGui()
;     which populates this._gui with controls and sets this._w / this._h.
;   - WidgetBase doesn't know about TimerService/RunService/etc.
;     Subclasses receive refs via constructor. WidgetBase only knows
;     about theme, position, and Gui lifecycle.
;
; Construction:
;   class TimerWidget extends WidgetBase
;   {
;       __New(bus, position, onPersist, timerService, analytics)
;       {
;           super.__New("timer", "Timer (Run/Step)", bus, position, onPersist)
;           this._timer := timerService
;           ; ... other deps
;       }
;       _BuildGui() { ... create controls ..., set this._w, this._h }
;   }
;
;   widget := TimerWidget(bus, position, () => settingsRepo.Save(cfg), timer, analytics)
;   widget.Show()
;
; About 'position':
;   It's a mutable reference to an OverlayPosition (part of
;   AppSettings.overlay.widgets["timer"]). WidgetBase mutates
;   fields inline (visible, scale, leftPct, topPct, centered) and
;   then calls onPersist() — the composition root injects a callback
;   that calls settingsRepo.Save(appSettings).


class WidgetBase
{
    ; --- Identity ---
    id   := ""    ; "timer", "zone", etc.
    name := ""    ; "Timer (Run/Step)" — display name

    ; --- Dependencies ---
    _bus       := ""    ; EventBus (subclasses subscribe to it)
    _position  := ""    ; OverlayPosition (mutable, shared with AppSettings)
    _onPersist := ""    ; optional callable or "" (called after mutations)

    ; --- Render state ---
    _gui    := ""        ; Gui or ""
    _ctrls  := Map()     ; Map<key, GuiControl> populated by _BuildGui
    _w      := 0         ; width calculated by _BuildGui
    _h      := 0         ; height calculated by _BuildGui

    ; --- Mode-driven visibility ---
    ; NON-persistent flag, controlled by OverlayModeApplier according
    ; to the current mode (NORMAL/COMPACT/MICRO). Show() requires both
    ; _position.visible (user preference, persisted) and _modeVisible
    ; (temporary mode filter) = true.
    _modeVisible := true

    __New(idStr, nameStr, bus, position, onPersist := "")
    {
        if (idStr = "")
            throw ValueError("WidgetBase: 'idStr' cannot be empty")
        if (nameStr = "")
            throw ValueError("WidgetBase: 'nameStr' cannot be empty")
        if !(bus is EventBus)
            throw TypeError("WidgetBase: 'bus' must be EventBus")
        if !(position is OverlayPosition)
            throw TypeError("WidgetBase: 'position' must be OverlayPosition")
        ; onPersist can be "" (no persistence) or callable
        if (onPersist != "" && !IsObject(onPersist))
            throw TypeError("WidgetBase: 'onPersist' must be callable or empty string")

        this.id        := idStr
        this.name      := nameStr
        this._bus      := bus
        this._position := position
        this._onPersist := onPersist

        ; Subscribes to Ctrl state changes to show/hide the highlight
        ; border (visual feedback of "now clickable/draggable"). Tolerant
        ; of Show not yet called — _SetCtrlHighlightVisible is a no-op
        ; if ctrls is empty.
        this._bus.Subscribe(Events.CtrlStateChanged, (data) => this._OnCtrlStateChanged(data))
    }

    ; ============================================================
    ; Queries
    ; ============================================================

    IsVisible()  => this._position.visible        ; user preference
    IsRendered() => this._gui != ""                ; actually rendered on screen
    IsModeVisible() => this._modeVisible           ; mode filter
    GetPosition() => this._position
    GetScale()    => this._position.scale
    ; Returns the Win32 HWND of the rendered Gui, or 0 when the
    ; widget isn't currently on screen. Used by dependent widgets
    ; (RouteWidget) that need to read live geometry via WinGetPos
    ; — they can pair this with WidgetGeometryChanged for updates
    ; and use the hwnd directly for the initial render.
    GetHwnd() => this._gui ? this._gui.Hwnd : 0
    GetSize()     => Map("w", this._w, "h", this._h)

    ; ============================================================
    ; Lifecycle
    ; ============================================================

    ; Creates the Gui and shows it on screen. No-op if:
    ;   - position.visible = false (widget marked as invisible)
    ;   - _modeVisible = false (current mode hides this widget)
    ;   - already rendered
    Show()
    {
        if !this._position.visible
            return
        if !this._modeVisible
            return
        if this._gui
            return

        ; Click-through: the widget needs LAYERED + TRANSPARENT, set
        ; AFTER Gui creation via WinSetTransparent + WinSetExStyle.
        ;
        ; Why not in the Gui creation flag? In AHK v2, creating the
        ; Gui with `+E0x80020` (LAYERED + TRANSPARENT) makes the
        ; window be born with LAYERED but without LWA_ALPHA configured.
        ; WinSetTransparent called later doesn't always set alpha
        ; correctly — widget ends up invisible (alpha=0).
        ;
        ; Correct approach: the Gui is born normal (only NOACTIVATE),
        ; then WinSetTransparent(255) ADDS LAYERED + alpha=255 via
        ; SetLayeredWindowAttributes (which AHK manages). Then
        ; WinSetExStyle("+0x20") adds TRANSPARENT.
        ;
        ; DYNAMIC toggle of the TRANSPARENT bit by OverlayInteractionService
        ; when Ctrl flips: without Ctrl click passes through, with
        ; Ctrl the widget is interactive.
        wg := Gui("+ToolWindow +AlwaysOnTop -Caption +E0x08000000")
        wg.BackColor := Theme.Color("bg")
        wg.MarginX := 0
        wg.MarginY := 0
        this._gui := wg
        this._ctrls := Map()
        this._w := 0
        this._h := 0

        ; Subclass fills in controls and sets this._w / this._h
        this._BuildGui()

        if (this._w <= 0 || this._h <= 0)
            throw Error("WidgetBase.Show: '" this.id "'._BuildGui did not set _w/_h correctly")

        ; Highlight border: creates 4 Progress controls as the
        ; (hidden initially) border, shown/hidden via Evt.CtrlStateChanged.
        ; Added AFTER _BuildGui so they are at the top of the z-order
        ; (rendered over the content).
        this._BuildCtrlHighlight()

        ; Calculate position on screen
        monW := A_ScreenWidth
        monH := A_ScreenHeight
        if this._position.centered
            posX := Round((monW - this._w) / 2)
        else
            posX := Round((this._position.left / 100) * monW)
        posY := Round((this._position.top / 100) * monH)

        wg.Show("NoActivate X" posX " Y" posY " W" this._w " H" this._h)

        ; WinSetTransparent ADDS LAYERED + alpha=255 (fully opaque)
        ; via SetLayeredWindowAttributes. More reliable than setting
        ; LAYERED via Gui flag.
        try WinSetTransparent(255, "ahk_id " wg.Hwnd)
        ; WS_EX_TRANSPARENT (0x20) adds cross-process click-through.
        ; OverlayInteractionService toggles this bit when Ctrl flips.
        try WinSetExStyle("+0x20", "ahk_id " wg.Hwnd)

        ; Register the Hwnd with OverlayInteractionService for
        ; click-through (default) + Ctrl drag (interactive). Static
        ; singleton set by the composition root in Start(). In
        ; headless or if the service didn't come up, silent no-op.
        if (OverlayInteractionService.Instance != "")
            OverlayInteractionService.Instance.RegisterHwnd(
                this._gui.Hwnd,
                this._UpdatePositionFromGui.Bind(this)
            )
    }

    ; Destroys the Gui if visible. Idempotent.
    Hide()
    {
        if !this._gui
            return
        ; Unregister from OverlayInteractionService BEFORE Destroy()
        ; to avoid drag callback receiving a zombie Hwnd.
        if (OverlayInteractionService.Instance != "")
        {
            try OverlayInteractionService.Instance.UnregisterHwnd(this._gui.Hwnd)
        }
        try this._gui.Destroy()
        this._gui := ""
        this._ctrls := Map()
        this._w := 0
        this._h := 0
    }

    ; Re-creates the Gui (useful after a scale change).
    ; If position.visible = false or !_modeVisible, just ensures
    ; there's no Gui (internal Show() does the check).
    ReRender()
    {
        if this._gui
            this.Hide()
        if (this._position.visible && this._modeVisible)
            this.Show()
    }

    ; Semantic alias for final cleanup.
    Destroy() => this.Hide()

    ; ============================================================
    ; Mutators (called by WidgetManager or the composition root)
    ; ============================================================

    ; Toggles visibility. Persists and shows/hides the Gui.
    SetVisible(value)
    {
        newVal := !!value
        if (this._position.visible = newVal)
            return
        this._position.visible := newVal
        this._Persist()
        if newVal
            this.Show()
        else
            this.Hide()
    }

    ; Toggles temporary mode-driven visibility. Does NOT
    ; persist — it's the current-mode filter applied by
    ; OverlayModeApplier on Evt.OverlayModeChanged.
    ;
    ; - Show (true): calls Show() which still checks _position.visible;
    ;   if the user disabled the widget, it stays hidden even with
    ;   mode true.
    ; - Hide (false): calls Hide() unconditionally.
    SetModeVisible(value)
    {
        newVal := !!value
        if (this._modeVisible = newVal)
            return
        this._modeVisible := newVal
        if newVal
            this.Show()
        else
            this.Hide()
    }

    ; Swaps the OverlayPosition reference used by the widget.
    ; Does NOT persist — it's just a swap to point to the current mode's
    ; layout (OverlayModeApplier queries OverlayLayout.GetPositionForMode
    ; and passes the result here before SetModeVisible).
    ;
    ; Behavior:
    ;   - If newPos == current _position: silent no-op
    ;   - If rendered, does Hide() + Show() to reflect new position/scale
    ;   - Type validation: TypeError if not OverlayPosition
    ;
    ; Notable: does NOT call _Persist(). INI files are written via
    ; SetVisible/SetScale/SetPosition which touch this._position —
    ; and the current reference points to the mode's layout. User
    ; drag/resize will persist in the active mode (which is the
    ; ambitious design's desired behavior).
    SetActivePosition(newPos)
    {
        if !(newPos is OverlayPosition)
            throw TypeError("WidgetBase.SetActivePosition: 'newPos' must be OverlayPosition")
        if (this._position == newPos)
            return
        this._position := newPos
        ; Re-renders with the new position if it was visible.
        ; ReRender only re-shows if _position.visible && _modeVisible.
        if this._gui
            this.ReRender()
    }

    ; Changes scale. Clamps to [0.5, 3.0] (same range as OverlayPosition).
    ; Re-renders if currently visible.
    SetScale(value)
    {
        if (!IsNumber(value) || value <= 0)
            throw ValueError("WidgetBase.SetScale: scale must be a positive number")
        if (value < 0.5)
            value := 0.5
        if (value > 3.0)
            value := 3.0
        if (this._position.scale = value)
            return
        this._position.scale := value
        this._Persist()
        this.ReRender()
        ; Notify subscribers that this widget changed geometry so
        ; dependent widgets (e.g. RouteWidget glued below the
        ; active timer) can realign. Helper is a no-op when the
        ; widget isn't currently rendered.
        this._PublishGeometryChanged()
    }

    ; Changes percentage position. Clamps to [0, 95] (aligned with
    ; OverlayPosition.MAX_PCT_SAFE to avoid off-screen widgets).
    ; centered=true ignores left.
    SetPosition(leftPct, topPct, centered := false)
    {
        if (!IsNumber(leftPct) || !IsNumber(topPct))
            throw TypeError("WidgetBase.SetPosition: leftPct/topPct must be numbers")
        if (leftPct < 0)
            leftPct := 0
        if (leftPct > 95)
            leftPct := 95
        if (topPct < 0)
            topPct := 0
        if (topPct > 95)
            topPct := 95
        this._position.left     := leftPct
        this._position.top      := topPct
        this._position.centered := !!centered
        this._Persist()
        this.ReRender()
        this._PublishGeometryChanged()
    }

    ; ============================================================
    ; Subclass overrides
    ; ============================================================

    ; Template method: subclasses fill this._gui with controls (using
    ; this._gui.Add(...) and helpers like _BuildHeader) and set
    ; this._w / this._h (total widget width/height).
    _BuildGui()
    {
        throw Error("WidgetBase._BuildGui must be overridden by subclass")
    }

    ; ============================================================
    ; Protected helpers (subclass uses these in _BuildGui)
    ; ============================================================

    ; Creates a standard header: accent stripe (3px) + title bar with
    ; title on the left and a (decorative) X button on the right.
    ; Returns headerH (TOTAL height: stripe + title bar).
    ;
    ; The accent stripe (3px burnt orange) is the visual signature of
    ; the Kalandra theme (mirrored from CompactLayoutWidget). Gives
    ; consistent visual identity between loose widgets and layout
    ; containers.
    ;
    ; Args:
    ;   title    : string shown uppercase (e.g. "Timer")
    ;   contentW : total widget width (px)
    ;
    ; Adds to this._ctrls:
    ;   "accent" -> Progress control of the stripe (decorative, value=100)
    ;   "header" -> Text control of the bar
    ;   "close"  -> Text control of the X
    _BuildHeader(title, contentW)
    {
        s       := this._position.scale
        stripeH := Theme.Size(s, 3)
        titleH  := Theme.Size(s, 18)
        tSz     := Theme.Size(s, 7)
        cSz     := Theme.Size(s, 11)
        cBtnW   := Theme.Size(s, 20)
        tW      := contentW - cBtnW

        wg := this._gui

        ; Accent stripe (3px orange, full width, decorative).
        accent := wg.Add(
            "Progress",
            "x0 y0 w" contentW " h" stripeH
                . " c" Theme.Color("accent") " Background" Theme.Color("surface3"),
            100
        )
        this._ctrls["accent"] := accent

        ; Title bar (right below the stripe).
        wg.SetFont("s" tSz " c" Theme.Color("subtle") " bold", Theme.FONT_UI)
        hdr := wg.Add(
            "Text",
            "x0 y" stripeH " w" tW " h" titleH " Background" Theme.Color("surface2") " 0x200",
            "  " StrUpper(title)
        )
        this._ctrls["header"] := hdr

        wg.SetFont("s" cSz " c" Theme.Color("subtle"), Theme.FONT_UI)
        closeBtn := wg.Add(
            "Text",
            "x" tW " y" stripeH " w" cBtnW " h" titleH
                . " Background" Theme.Color("surface2") " Center 0x200",
            "X"
        )
        this._ctrls["close"] := closeBtn

        return stripeH + titleH
    }

    ; Updates the text of an existing control. Tolerant:
    ;   - No-op if !rendered
    ;   - No-op if ctrl doesn't exist
    ;   - Try-catch around the write (control may have been destroyed
    ;     between check and set)
    ;
    ; Used by Tick/event handlers to update values without manually
    ; checking anything on each call.
    _TrySetText(ctrlKey, text)
    {
        if !this._gui
            return
        if !this._ctrls.Has(ctrlKey)
            return
        try this._ctrls[ctrlKey].Text := text
    }

    ; Updates a control's font color. Tolerant (same semantics).
    ;   colorName: valid name in Theme.Color (e.g. "green", "amber")
    _TrySetFontColor(ctrlKey, colorName)
    {
        if !this._gui
            return
        if !this._ctrls.Has(ctrlKey)
            return
        try this._ctrls[ctrlKey].SetFont("c" Theme.Color(colorName))
    }

    ; ============================================================
    ; Ctrl highlight border — visual feedback when Ctrl is active
    ; ============================================================
    ;
    ; Creates 4 Progress controls of 3px in accent color ('D8492F' orange),
    ; one on each border (top/bottom/left/right). Hidden by default.
    ; Made visible when OverlayInteractionService publishes
    ; Evt.CtrlStateChanged { active: true } and re-hidden when
    ; active=false.
    ;
    ; Why Progress and not Picture/Border? Progress accepts foreground
    ; color (`c`) and background (`Background`) with value=100, and
    ; renders as a solid rectangle. Same pattern used by
    ; LayoutWidgetBase._BuildAccentStripe. Disabled ensures that
    ; clicks pass through to the controls below (important for
    ; normal interaction when the highlight is on).
    ;
    ; Z-order: called AFTER _BuildGui in Show(), so renders OVER the
    ; widget content. The top/bottom/left/right borders cover 3px of
    ; the widget's content — for widgets with header (accent stripe
    ; already at y=0..3) the overlap is visually consistent (same color).
    ;
    ; Initial sync: if OverlayInteractionService.Instance is up and
    ; Ctrl is already pressed when the widget is shown, shows the
    ; highlight immediately (instead of waiting for the next poll flip).
    ; ============================================================

    static _CTRL_HIGHLIGHT_KEYS := ["__ctrlHl_top", "__ctrlHl_bot", "__ctrlHl_lef", "__ctrlHl_rig"]
    static _CTRL_HIGHLIGHT_THICKNESS := 3

    _BuildCtrlHighlight()
    {
        if !this._gui
            return
        if (this._w <= 0 || this._h <= 0)
            return

        wg      := this._gui
        accent  := Theme.Color("accent")
        bw      := WidgetBase._CTRL_HIGHLIGHT_THICKNESS
        w       := this._w
        h       := this._h

        ; Hidden Disabled = initially invisible, click-through (clicks
        ; pass through to controls below). +0x4000000 = WS_EX_TRANSPARENT
        ; not applicable to controls, we use only Disabled.
        opts := " Hidden Disabled c" accent " Background" accent

        top := wg.Add("Progress", "x0 y0 w" w " h" bw . opts, 100)
        bot := wg.Add("Progress", "x0 y" (h - bw) " w" w " h" bw . opts, 100)
        lef := wg.Add("Progress", "x0 y0 w" bw " h" h . opts, 100)
        rig := wg.Add("Progress", "x" (w - bw) " y0 w" bw " h" h . opts, 100)

        this._ctrls["__ctrlHl_top"] := top
        this._ctrls["__ctrlHl_bot"] := bot
        this._ctrls["__ctrlHl_lef"] := lef
        this._ctrls["__ctrlHl_rig"] := rig

        ; Initial sync: if Ctrl is already held at the time of Show.
        try
        {
            if (OverlayInteractionService.Instance != ""
                && OverlayInteractionService.Instance.IsCtrlDown())
                this._SetCtrlHighlightVisible(true)
        }
    }

    ; Toggles the 4 borders. No-op if controls don't exist (widget
    ; not rendered, or _BuildCtrlHighlight not yet called).
    _SetCtrlHighlightVisible(visible)
    {
        if !this._gui
            return
        v := !!visible
        for _, k in WidgetBase._CTRL_HIGHLIGHT_KEYS
        {
            if !this._ctrls.Has(k)
                continue
            try this._ctrls[k].Visible := v
        }
    }

    ; Evt.CtrlStateChanged handler. Tolerant of malformed payload.
    _OnCtrlStateChanged(data)
    {
        if !IsObject(data)
            return
        if !data.Has("active")
            return
        this._SetCtrlHighlightVisible(data["active"])
    }

    ; ============================================================
    ; Private helpers
    ; ============================================================

    ; Callback called by OverlayInteractionService when the user
    ; finishes a drag (LButton up). Reads the Gui's real position via
    ; WinGetPos, converts to percentage relative to the screen, and
    ; persists into this._position. Sets centered=false (user moved
    ; manually).
    _UpdatePositionFromGui()
    {
        if !this._gui
            return
        try
        {
            WinGetPos(&x, &y, , , "ahk_id " this._gui.Hwnd)
            monW := A_ScreenWidth
            monH := A_ScreenHeight
            if (monW > 0 && monH > 0)
            {
                this._position.left     := Round((x / monW) * 100, 2)
                this._position.top      := Round((y / monH) * 100, 2)
                this._position.centered := false
                this._Persist()
            }
        }
        ; After persisting the new percentages, broadcast the
        ; geometry change so dependent widgets can realign
        ; (e.g. RouteWidget glues itself below the active timer
        ; widget).
        this._PublishGeometryChanged()
    }

    ; Publishes Evt.WidgetGeometryChanged with the widget's CURRENT
    ; screen position + dimensions + scale, read directly from
    ; the live Gui via WinGetPos. Used by dependent widgets to
    ; realign after drag-end / scale change / programmatic
    ; SetPosition.
    ;
    ; Silent no-op when the widget isn't rendered — there is no
    ; geometry to report, and a stale read would risk publishing
    ; zeros that subscribers might mistake for a valid position.
    ;
    ; The event is NOT published during the drag motion itself,
    ; only at the gesture end. B4 sabor 2 explicitly accepted
    ; the brief "detached" frame during drag to keep the hot
    ; path free of bus traffic.
    _PublishGeometryChanged()
    {
        if !this._gui
            return
        try
        {
            wx := 0, wy := 0, ww := 0, wh := 0
            WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " this._gui.Hwnd)
            this._bus.Publish(Events.WidgetGeometryChanged, Map(
                "widgetId", this.id,
                "x",        Integer(wx),
                "y",        Integer(wy),
                "w",        Integer(ww),
                "h",        Integer(wh),
                "scale",    this._position.scale
            ))
        }
    }

    ; Calls onPersist if it was configured.
    ; Tolerant of failures: if persistence fails, doesn't take down the widget.
    _Persist()
    {
        if !IsObject(this._onPersist)
            return
        try this._onPersist.Call()
    }
}
