; ============================================================
; RouteWidget — route walkthrough surface glued below a timer widget
; ============================================================
;
; Standalone widget (does NOT extend WidgetBase) because:
;   - Not directly positionable by the user. Its position is
;     derived from an anchor timer widget on every render —
;     persisting an OverlayPosition for it would be a lie, since
;     anything the user "moved" would snap back the next time the
;     anchor moved.
;   - Doesn't participate in the NORMAL/COMPACT/MICRO mode filter.
;     The anchor does; this widget follows whichever anchor the
;     active mode picked.
;   - No Ctrl-drag, no scale wheel, no highlight border. Same
;     reasoning as RunOutcomeBannerWidget: pulling in WidgetBase
;     would mean carrying machinery that's never used.
;
; Anchor resolution:
;   The composition root provides an anchorResolver — a callable
;   that returns the active timer widget for the current overlay
;   mode (one of micro / micro_plus / steve / steve_plus). The
;   resolver is invoked on every render, NOT cached, so a mode
;   switch (CycleLayout) automatically picks up the new anchor.
;
;   Anchor eligibility is enforced by the resolver, not here —
;   the only contract this widget needs is "returns a WidgetBase
;   or empty string when no eligible widget is rendered".
;
; Glue semantics (B4 "sabor 2"):
;   RouteWidget reads the anchor's live screen geometry via
;   WinGetPos at render time. The width matches the anchor's
;   width (visual continuation), the x matches the anchor's
;   left edge, and the y sits immediately below the anchor
;   (y = anchorY + anchorH). The two windows LOOK like one
;   composite surface, but they're independent Gui objects so
;   the anchor's own machinery (drag, scale, mode filter) stays
;   uncoupled from the route surface.
;
;   Sync points:
;     - Evt.WidgetGeometryChanged{widgetId == anchor.id}
;       → re-render after drag-end / SetScale / SetPosition
;     - Evt.OverlayModeChanged
;       → re-resolve anchor + re-render (different timer now)
;     - Evt.RouteChanged
;       → re-render rows (zone advanced/retreated, route edited)
;     - Evt.RouteVisibilityToggled{visible}
;       → Show/Hide
;
;   During the drag motion itself NO repositioning happens — the
;   sabor 2 trade-off explicitly accepted a brief "detached" frame
;   to keep the drag hot path off the event bus.
;
; Headless mode:
;   When headless=true, render captures the slice into
;   _lastRenderedSlice and skips all Gui calls. Tests can drive
;   event handlers directly and inspect the state.
;
; Opt-out:
;   cfg.routeWidgetVisible=false makes Show() a silent no-op.
;   The widget still subscribes to all events for lifecycle
;   symmetry, so flipping the cfg back on (via Settings) takes
;   effect on the next RouteVisibilityToggled.

class RouteWidget
{
    ; Visual nominals — multiplied by anchor scale at render time
    ; so the route surface visually matches the timer.
    static ROW_HEIGHT_BASE := 18
    static PADDING_BASE    := 6
    static FONT_SIZE_BASE  := 10
    static MIN_WIDTH       := 120
    static MIN_SCALE       := 0.5

    _bus            := ""
    _cfg            := ""
    _routeService   := ""
    _anchorResolver := ""
    _headless       := false

    ; Live state.
    _gui              := ""    ; rendered Gui or "" when hidden
    _lastRenderedSlice := ""   ; array — captured for test inspection
    _lastAnchorId     := ""    ; id of the anchor used in the last
                               ; successful render; updated on every
                               ; _Render so an OverlayModeChanged
                               ; that swaps anchors still rebinds.

    _handlerRouteChanged           := ""
    _handlerWidgetGeometryChanged  := ""
    _handlerRouteVisibilityToggled := ""
    _handlerOverlayModeChanged     := ""

    __New(bus, cfg, svc, anchorResolver, headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("RouteWidget: 'bus' must be EventBus")
        if !(cfg is AppSettings)
            throw TypeError("RouteWidget: 'cfg' must be AppSettings")
        ; Parameter is named `svc` (not `routeService`) because AHK v2
        ; identifier lookup is case-insensitive, so a local
        ; `routeService` would shadow the global `RouteService` class
        ; and the `is RouteService` check would fail with
        ; `TypeError: Expected a Class but got a RouteService`.
        ; Same trap that previously caught us with `route`/`Route` in
        ; the repository and `routeRepository`/`RouteRepository` in
        ; the service constructor.
        if !(svc is RouteService)
            throw TypeError("RouteWidget: 'svc' must be RouteService")
        if !RouteWidget._IsCallable(anchorResolver)
            throw TypeError("RouteWidget: 'anchorResolver' must be a callable")

        this._bus            := bus
        this._cfg            := cfg
        this._routeService   := svc
        this._anchorResolver := anchorResolver
        this._headless       := !!headless

        this._handlerRouteChanged           := (data) => this._OnRouteChanged(data)
        this._handlerWidgetGeometryChanged  := (data) => this._OnWidgetGeometryChanged(data)
        this._handlerRouteVisibilityToggled := (data) => this._OnRouteVisibilityToggled(data)
        this._handlerOverlayModeChanged     := (data) => this._OnOverlayModeChanged(data)

        bus.Subscribe(Events.RouteChanged,           this._handlerRouteChanged)
        bus.Subscribe(Events.WidgetGeometryChanged,  this._handlerWidgetGeometryChanged)
        bus.Subscribe(Events.RouteVisibilityToggled, this._handlerRouteVisibilityToggled)
        bus.Subscribe(Events.OverlayModeChanged,     this._handlerOverlayModeChanged)
    }

    Dispose()
    {
        if (this._handlerRouteChanged != "")
        {
            this._bus.Unsubscribe(Events.RouteChanged, this._handlerRouteChanged)
            this._handlerRouteChanged := ""
        }
        if (this._handlerWidgetGeometryChanged != "")
        {
            this._bus.Unsubscribe(Events.WidgetGeometryChanged, this._handlerWidgetGeometryChanged)
            this._handlerWidgetGeometryChanged := ""
        }
        if (this._handlerRouteVisibilityToggled != "")
        {
            this._bus.Unsubscribe(Events.RouteVisibilityToggled, this._handlerRouteVisibilityToggled)
            this._handlerRouteVisibilityToggled := ""
        }
        if (this._handlerOverlayModeChanged != "")
        {
            this._bus.Unsubscribe(Events.OverlayModeChanged, this._handlerOverlayModeChanged)
            this._handlerOverlayModeChanged := ""
        }
        this.Hide()
    }

    ; ============================================================
    ; Public API (test + composition root)
    ; ============================================================

    IsVisible() => this._gui != ""
    GetLastRenderedSlice() => this._lastRenderedSlice
    GetLastAnchorId() => this._lastAnchorId

    ; Initial Show — called by the composition root on boot when
    ; cfg.routeWidgetVisible is true. Re-checks the cfg every call
    ; so a flip via Settings takes effect without restart. Hides
    ; when there's no anchor (none of the four eligible widgets
    ; is currently mode-visible).
    Show()
    {
        if !this._cfg.routeWidgetVisible
            return
        this._Render()
    }

    Hide()
    {
        if this._gui
        {
            try this._gui.Destroy()
            this._gui := ""
        }
        this._lastAnchorId := ""
    }

    ; ============================================================
    ; Event handlers
    ; ============================================================

    _OnRouteChanged(data)
    {
        ; Re-render only if the widget is conceptually active.
        ; In production this means a Gui exists; in headless mode
        ; it means Show() has been called and resolved to an
        ; anchor (so _lastAnchorId is populated). This keeps the
        ; headless surface symmetric with production — events
        ; arriving before Show or after Hide are no-ops in both.
        if this._IsActive()
            this._Render()
    }

    _OnRouteVisibilityToggled(data)
    {
        if !IsObject(data) || !data.Has("visible")
            return
        if data["visible"]
            this.Show()
        else
            this.Hide()
    }

    _OnWidgetGeometryChanged(data)
    {
        ; Only react if (a) currently active and (b) the changed
        ; widget is our current anchor. Otherwise the event is
        ; about an unrelated widget (e.g. the Compact widget if
        ; the user has multiple widgets registered for drag) and
        ; we don't care.
        if !this._IsActive()
            return
        if !IsObject(data) || !data.Has("widgetId")
            return
        if (this._lastAnchorId = "" || data["widgetId"] != this._lastAnchorId)
            return
        this._Render()
    }

    _OnOverlayModeChanged(data)
    {
        ; Mode switched (CycleLayout via hotkey, or programmatic
        ; SetMode). The active anchor likely changed; re-render so
        ; we pick up the new one. The resolver is invoked fresh
        ; inside _Render — we don't cache anchor identity beyond
        ; _lastAnchorId, which is set at the end of every successful
        ; render and cleared by Hide.
        if !this._IsActive()
            return
        this._Render()
    }

    ; ============================================================
    ; Rendering
    ; ============================================================

    _Render()
    {
        anchor := this._ResolveAnchor()
        if !IsObject(anchor)
        {
            ; No eligible timer is rendered. Hide the route surface
            ; rather than leaving a stale Gui behind — when the user
            ; toggles back to Compact mode (which doesn't have a
            ; route arrow), the route would otherwise float
            ; orphaned over the screen.
            this.Hide()
            return
        }

        n := this._cfg.routeRowsVisible
        slice := this._routeService.GetVisibleSlice(n)
        this._lastRenderedSlice := slice
        this._lastAnchorId      := anchor.id

        if this._headless
            return

        ; Empty slice (no route configured) — hide. The Settings
        ; UI is where the user adds zones; until they do, the
        ; surface stays clean.
        if (slice.Length = 0)
        {
            this.Hide()
            return
        }

        ; Anchor must be rendered to give us valid geometry. Anchor
        ; with no hwnd means it's mode-invisible; the resolver
        ; should have returned "" but we double-check defensively.
        anchorHwnd := anchor.GetHwnd()
        if (!anchorHwnd)
        {
            this.Hide()
            return
        }

        ax := 0, ay := 0, aw := 0, ah := 0
        try
        {
            WinGetPos(&ax, &ay, &aw, &ah, "ahk_id " anchorHwnd)
        }
        catch
        {
            this.Hide()
            return
        }
        if (aw <= 0 || ah <= 0)
        {
            this.Hide()
            return
        }

        scale := anchor.GetScale()
        if (!IsNumber(scale) || scale < RouteWidget.MIN_SCALE)
            scale := 1.0

        rowH     := Round(RouteWidget.ROW_HEIGHT_BASE * scale)
        padding  := Round(RouteWidget.PADDING_BASE * scale)
        fontSize := Round(RouteWidget.FONT_SIZE_BASE * scale)
        if (fontSize < 6)
            fontSize := 6    ; lower bound — sub-6 pt is unreadable

        height := padding * 2 + rowH * slice.Length
        width  := aw < RouteWidget.MIN_WIDTH ? RouteWidget.MIN_WIDTH : aw
        x      := ax
        y      := ay + ah

        ; Rebuild the Gui from scratch each render so per-row colors
        ; reflect the latest currentIdx. The alternative — keep the
        ; Gui and only update each text control's text + color — would
        ; require tracking control handles per row, and the
        ; build cost here is negligible (a few Text controls).
        if this._gui
        {
            try this._gui.Destroy()
            this._gui := ""
        }

        wg := Gui("+ToolWindow +AlwaysOnTop -Caption +E0x08000000")
        wg.BackColor := Theme.Color("surface")
        wg.MarginX := 0
        wg.MarginY := 0

        ; Render each row.
        for i, row in slice
        {
            status   := row["status"]
            colorKey := RouteWidget._ColorFor(status)
            weight   := (status = "current") ? " bold" : " norm"
            wg.SetFont(
                "s" fontSize " c" Theme.Color(colorKey) weight,
                Theme.FONT_UI
            )
            rowY := padding + (i - 1) * rowH
            wg.Add(
                "Text",
                "x" padding " y" rowY
                . " w" (width - padding * 2)
                . " h" rowH
                . " Background" Theme.Color("surface")
                . " 0x200",    ; SS_CENTERIMAGE — vertical centering
                row["name"]
            )
        }

        wg.Show("NoActivate X" x " Y" y " W" width " H" height)

        ; Click-through pattern, same as RunOutcomeBannerWidget /
        ; WidgetBase. Without WS_EX_TRANSPARENT the route surface
        ; would steal clicks meant for the game beneath it.
        try WinSetTransparent(255, "ahk_id " wg.Hwnd)
        try WinSetExStyle("+0x20", "ahk_id " wg.Hwnd)

        this._gui := wg
    }

    ; Returns true when the widget is conceptually "active" — i.e.
    ; in a state where it should react to incoming events. In
    ; production, this is simply "is there a Gui on screen?". In
    ; headless mode, where Gui creation is skipped, we use
    ; _lastAnchorId as a proxy: it is populated at the end of
    ; every successful Show()/Render() and cleared by Hide().
    ;
    ; The headless branch keeps the test surface symmetric with
    ; production: events arriving BEFORE Show (and ANY events
    ; arriving AFTER Hide) are no-ops in both modes, so tests can
    ; pin lifecycle invariants without worrying about which mode
    ; they're running in.
    _IsActive()
    {
        if (this._gui)
            return true
        return this._headless && (this._lastAnchorId != "")
    }

    ; Invokes the injected anchorResolver. Returns the anchor widget
    ; (typically a WidgetBase instance for one of micro/micro_plus/
    ; steve/steve_plus) or "" when no eligible widget is currently
    ; mode-visible. Wraps in try/catch so a resolver bug never
    ; crashes the bus handler that called us.
    _ResolveAnchor()
    {
        try
        {
            return (this._anchorResolver)()
        }
        catch
        {
            return ""
        }
    }

    ; ============================================================
    ; Static helpers
    ; ============================================================

    ; Maps a slice row status to a Theme color key. Current row is
    ; the strongest highlight (goodStrong, same color RunOutcomeBanner
    ; uses for "SAVED · PB" — visually loud, easy to find on the
    ; overlay). Upcoming rows use the regular text color. Before
    ; rows (rare — only surface when currentIdx is -1 and the slice
    ; happens to include preceding rows in a future enhancement)
    ; use subtle, the same color reset banners use.
    static _ColorFor(status)
    {
        switch status
        {
            case "current":  return "goodStrong"
            case "upcoming": return "text"
            case "before":   return "subtle"
            default:         return "text"
        }
    }

    ; Detects whether `f` is callable. AHK v2 has several callable
    ; shapes (Func, BoundFunc, Closure, arrow lambda); HasMethod
    ; "Call" covers all of them uniformly.
    static _IsCallable(f)
    {
        if (f = "")
            return false
        return HasMethod(f, "Call")
    }
}
