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
    static MIN_SCALE       := 0.5
    ; Time column reservation (right side of each row). Holds
    ; "99:59" comfortably and clips "H:MM:SS" gracefully (longest
    ; per-zone time is rare; 50 px at scale 1.0 is enough for
    ; MM:SS, and the column scales with the anchor).
    static TIME_COL_BASE   := 50
    ; Live-tick interval. 500 ms is fast enough that the current
    ; zone's time visibly moves between glances at the overlay,
    ; slow enough that even on slow machines the SetTimer overhead
    ; is invisible. Headless mode bypasses SetTimer entirely.
    static TICK_MS         := 500
    ; Note row visuals — rendered below the current zone when the
    ; runner authored a per-zone tip. Smaller font than zone rows
    ; so the tip reads as secondary information (the zone name and
    ; live time stay the primary signals on the overlay). Line
    ; height is a multiplier of the font size so wrapped lines and
    ; literal-`n breaks share consistent vertical spacing.
    static NOTE_FONT_SIZE_BASE := 8
    static NOTE_LINE_HEIGHT_BASE := 14
    ; Conservative chars-per-line estimate used to predict wrap
    ; height without measuring the GDI text metrics. The actual
    ; ratio depends on the font + DPI, but "avg char width ≈ 55%
    ; of the font's pt size" is close enough for Segoe UI at the
    ; sizes we render. Slight overshoot is preferable to clipping
    ; the bottom line of a tip.
    static NOTE_CHAR_WIDTH_RATIO := 0.55

    _bus            := ""
    _cfg            := ""
    _routeService   := ""
    _anchorResolver := ""
    _zoneTracker    := ""   ; ZoneTrackingService or "" — supplies per-zone time
    _headless       := false

    ; Live state.
    _gui              := ""    ; rendered Gui or "" when hidden
    _lastRenderedSlice := ""   ; array — captured for test inspection
    _lastAnchorId     := ""    ; id of the anchor used in the last
                               ; successful render; updated on every
                               ; _Render so an OverlayModeChanged
                               ; that swaps anchors still rebinds.
    ; Per-row Text control handles, populated by _Render so the
    ; live-tick can update only the time cells without rebuilding
    ; the Gui. Cleared by Hide() and on every _Render restart.
    ; Two parallel arrays (name + time), 1:1 with _lastRenderedSlice.
    _rowNameControls  := ""
    _rowTimeControls  := ""
    ; ObjBindMethod handle for the live tick. Reused across
    ; Start/Stop so SetTimer can cancel it by the same reference.
    ; A naive `() => this._OnTick()` lambda would produce a new
    ; object on every call and SetTimer(0) would fail to cancel.
    _tickFn           := ""
    _tickActive       := false

    _handlerRouteChanged           := ""
    _handlerWidgetGeometryChanged  := ""
    _handlerRouteVisibilityToggled := ""
    _handlerOverlayModeChanged     := ""

    __New(bus, cfg, svc, anchorResolver, headless := false, zoneTracker := "")
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
        ; zoneTracker is optional — when missing, the time column
        ; stays empty (no "0:00" placeholders, per the Q4 decision).
        ; Param name `zoneTracker` doesn't collide with the
        ; `ZoneTrackingService` class (lowercase forms `zonetracker`
        ; vs `zonetrackingservice` differ).
        if (zoneTracker != "" && !(zoneTracker is ZoneTrackingService))
            throw TypeError("RouteWidget: 'zoneTracker' must be ZoneTrackingService")

        this._bus            := bus
        this._cfg            := cfg
        this._routeService   := svc
        this._anchorResolver := anchorResolver
        this._headless       := !!headless
        this._zoneTracker    := zoneTracker
        this._rowNameControls := []
        this._rowTimeControls := []
        ; ObjBindMethod gives a stable callable that SetTimer can
        ; both register and cancel by reference. Done once here so
        ; Start/Stop never construct fresh closures.
        this._tickFn := ObjBindMethod(this, "_OnTick")

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
        ; Start the live tick AFTER _Render so the first tick has
        ; control handles to update. _StartTick is a no-op when
        ; there's no _gui (Render hides) or no zoneTracker wired.
        this._StartTick()
    }

    Hide()
    {
        this._StopTick()
        if this._gui
        {
            ; Unregister from OverlayInteractionService BEFORE
            ; Destroy() to avoid the hover poll's WinGetPos firing
            ; against a zombie Hwnd between Unregister and Destroy.
            ; Mirror of the pattern used by WidgetBase.Hide.
            if (OverlayInteractionService.Instance != "")
            {
                try OverlayInteractionService.Instance.UnregisterHwnd(this._gui.Hwnd)
            }
            try this._gui.Destroy()
            this._gui := ""
        }
        this._rowNameControls := []
        this._rowTimeControls := []
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
        timeColW := Round(RouteWidget.TIME_COL_BASE * scale)
        if (fontSize < 6)
            fontSize := 6    ; lower bound — sub-6 pt is unreadable

        ; Pre-compute the note row size budget so the Gui's total
        ; height covers any note that the current zone carries.
        ; The widget's height has to be reserved BEFORE the
        ; Gui.Show() call, so we tally everything up front (one
        ; pass to know currentZone's note dimensions, second pass
        ; to actually render rows with the cursor-based layout).
        ;
        ; The note font size routing lives in _ResolveNoteFontSize
        ; so the cfg-fallback-clamp policy can be unit-tested
        ; without spinning up a Gui (the _Render path is gated
        ; behind a headless early-return well below this point).
        noteFontSize := RouteWidget._ResolveNoteFontSize(this._cfg, scale)
        ; Line height must SCALE with the font size, or larger
        ; configured sizes get clipped at the bottom edge of the
        ; Text control (TUGs at 16 pt: "cortada na metade" — the
        ; descender of g/p/q/y was overflowing). Extracted into
        ; _ResolveNoteLineHeight so the ratio policy is testable
        ; without spinning up a Gui.
        noteLineH := RouteWidget._ResolveNoteLineHeight(noteFontSize, scale)
        currentNote  := this._GetCurrentNoteFromSlice(slice)

        ; Width matches the anchor exactly per the visual-continuation contract documented in the header. DPI conversion lives in the helper.
        width  := RouteWidget._ResolveAnchorLogicalWidth(anchorHwnd, aw)
        ; Note row width is the full inner width (uses both the
        ; name column AND the time column) since it has nothing to
        ; align against on the right — it's a free-form text block.
        noteWidth  := width - padding * 2
        noteHeight := 0
        if (currentNote != "")
            noteHeight := RouteWidget._EstimateNoteHeight(currentNote, noteWidth, noteFontSize, noteLineH)

        height := padding * 2 + rowH * slice.Length + noteHeight
        x      := ax
        y      := ay + ah

        ; Rebuild the Gui from scratch each render so per-row colors
        ; reflect the latest currentIdx. The alternative — keep the
        ; Gui and only update each text control's text + color — would
        ; require tracking control handles per row, which we DO
        ; track now (_rowNameControls/_rowTimeControls) but only for
        ; live-tick time updates; full row rebuilds on RouteChanged
        ; would still need the colour/weight reset, so a full Gui
        ; rebuild is simpler than partial.
        if this._gui
        {
            ; Unregister the previous Hwnd BEFORE Destroy so the
            ; hover poll doesn't race against a half-torn-down
            ; window. The register at the end of this method (after
            ; the new Show) pairs with this unregister.
            if (OverlayInteractionService.Instance != "")
            {
                try OverlayInteractionService.Instance.UnregisterHwnd(this._gui.Hwnd)
            }
            try this._gui.Destroy()
            this._gui := ""
        }
        this._rowNameControls := []
        this._rowTimeControls := []

        wg := Gui("+ToolWindow +AlwaysOnTop -Caption +E0x08000000")
        wg.BackColor := Theme.Color("surface")
        wg.MarginX := 0
        wg.MarginY := 0

        ; Each row gets TWO Text controls so the tick can update the
        ; time independently of the name (which doesn't change between
        ; rebuilds and would lose its color/weight if rewritten). Name
        ; column is left-aligned and takes the full width minus the
        ; reserved time column. Time column is right-aligned via SS_RIGHT
        ; (0x2) so "0:32" and "12:45" align cleanly on the same edge.
        nameW := width - padding * 2 - timeColW
        if (nameW < 10)
            nameW := 10    ; degenerate width — keep the row visible
        timeX := width - padding - timeColW

        ; Cursor-based Y rather than index-based (i * rowH) because
        ; a note row inserted below the current zone makes the
        ; layout non-uniform — subsequent rows have to start AFTER
        ; the note's variable height. Tracking currentY explicitly
        ; keeps the slot reservations correct without per-row
        ; arithmetic in two places.
        currentY := padding
        for i, row in slice
        {
            status   := row["status"]
            colorKey := RouteWidget._ColorFor(status)
            weight   := (status = "current") ? " bold" : " norm"

            ; Name (left side).
            wg.SetFont(
                "s" fontSize " c" Theme.Color(colorKey) weight,
                Theme.FONT_UI
            )
            nameCtrl := wg.Add(
                "Text",
                "x" padding " y" currentY
                . " w" nameW
                . " h" rowH
                . " Background" Theme.Color("surface")
                . " 0x200",    ; SS_CENTERIMAGE — vertical centering
                row["name"]
            )
            this._rowNameControls.Push(nameCtrl)

            ; Time (right side). Color is muted by default; the
            ; CURRENT row uses the text color (still bold) so the
            ; live-updating value reads as part of the highlight. An
            ; empty value renders no visible character but keeps the
            ; control's bounding box reserved for the next tick.
            timeColorKey := (status = "current") ? colorKey : "muted"
            wg.SetFont(
                "s" fontSize " c" Theme.Color(timeColorKey) weight,
                Theme.FONT_UI
            )
            timeText := this._ComputeTimeText(row["name"])
            timeCtrl := wg.Add(
                "Text",
                "x" timeX " y" currentY
                . " w" timeColW
                . " h" rowH
                . " Background" Theme.Color("surface")
                . " 0x200"    ; SS_CENTERIMAGE (vertical)
                . " 0x2",     ; SS_RIGHT (horizontal)
                timeText
            )
            this._rowTimeControls.Push(timeCtrl)

            currentY += rowH

            ; Note row — only for the CURRENT zone, only when the
            ; runner authored a tip for it. Upcoming and before
            ; rows never get a note row (would create noise; the
            ; runner can't read 5 notes at once anyway). The note
            ; row uses surface3 background to visually differentiate
            ; from the zone rows (surface), and the muted text
            ; color so the tip reads as a secondary signal beneath
            ; the highlighted current-zone name. Newlines in the
            ; note text (decoded from \n on disk) render naturally
            ; in a Text control — AHK splits at LF without
            ; additional flags.
            if (status = "current" && currentNote != "")
            {
                wg.SetFont(
                    "s" noteFontSize " c" Theme.Color("muted") " norm",
                    Theme.FONT_UI
                )
                wg.Add(
                    "Text",
                    "x" padding " y" currentY
                    . " w" noteWidth
                    . " h" noteHeight
                    . " Background" Theme.Color("surface3"),
                    currentNote
                )
                currentY += noteHeight
            }
        }

        wg.Show("NoActivate X" x " Y" y " W" width " H" height)

        ; Click-through pattern, same as RunOutcomeBannerWidget /
        ; WidgetBase. Without WS_EX_TRANSPARENT the route surface
        ; would steal clicks meant for the game beneath it.
        try WinSetTransparent(255, "ahk_id " wg.Hwnd)
        try WinSetExStyle("+0x20", "ahk_id " wg.Hwnd)

        this._gui := wg

        ; Register the Hwnd with OverlayInteractionService so the
        ; hover-dim behaviour (alpha 25 on mouse over the overlay)
        ; applies to this widget too, matching the timer widgets it
        ; anchors to. Without this, the route surface stays at full
        ; alpha 255 when the cursor passes over it — inconsistent
        ; with the anchor and visually surprising for the user who
        ; expects the whole overlay stack to fade together so the
        ; underlying game state is readable. The note row in
        ; particular triggered the TUGs feedback that motivated the
        ; fix: "when hovering over the notes they don't become
        ; transparent like the main area". The two callbacks are
        ; empty because RouteWidget does not support Ctrl-drag
        ; (position is derived from the anchor; persisting a
        ; drag-moved RouteWidget would be a lie) or Ctrl-wheel
        ; resize (scale follows the anchor's scale).
        ;
        ; The 4th arg (groupId) is the ANCHOR's Hwnd. This pairs
        ; with WidgetBase passing its own Hwnd as the anchor's
        ; groupId, so the service's _IsInHoveredGroup match rule
        ; ("thisGroup = hoveredHwnd") fires when the anchor is
        ; hovered, and the symmetric rule ("hoveredGroup = thisHwnd")
        ; fires when the route widget is hovered. Net effect: hover
        ; on EITHER surface dims BOTH, which is what Rafael asked
        ; for after the slider lived in for a session.
        ;
        ; If the anchor's hwnd later changes (mode switch, ReRender),
        ; the next WidgetGeometryChanged or OverlayModeChanged event
        ; triggers _Render which calls Unregister/Register here, so
        ; the groupId tracks the live anchor automatically.
        ;
        ; The register pairs with the unregister at the top of
        ; this method (called BEFORE the previous gui.Destroy) and
        ; with the one in Hide(). Headless mode skips the call
        ; because Instance is "" when the service was constructed
        ; with headless=true (the static singleton field is still
        ; assigned but the service itself is inert).
        if (OverlayInteractionService.Instance != "")
        {
            try OverlayInteractionService.Instance.RegisterHwnd(
                wg.Hwnd, "", "", anchorHwnd)
        }
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
    ; Live-tick handlers (zone-time updates)
    ; ============================================================

    ; Starts the SetTimer that refreshes per-row time cells. No-op
    ; in headless mode (tests never want a background timer) and
    ; when there's no zoneTracker wired (nothing to read times from).
    _StartTick()
    {
        if this._headless
            return
        if !IsObject(this._zoneTracker)
            return
        if !this._tickFn
            return
        if this._tickActive
            return
        try SetTimer(this._tickFn, RouteWidget.TICK_MS)
        this._tickActive := true
    }

    _StopTick()
    {
        if !this._tickActive
            return
        if !this._tickFn
            return
        try SetTimer(this._tickFn, 0)
        this._tickActive := false
    }

    ; Tick body. Updates each row's time cell in place — no Gui
    ; rebuild. Skipped when the widget is hidden or the slice/
    ; controls are out of sync (defensive against a race with a
    ; concurrent _Render rebuild, though AHK v2's single-threaded
    ; message pump makes this nearly impossible in practice).
    _OnTick()
    {
        if !this._gui
            return
        if !IsObject(this._zoneTracker)
            return
        if !IsObject(this._lastRenderedSlice)
            return
        if !(this._rowTimeControls is Array)
            return
        for i, row in this._lastRenderedSlice
        {
            if (i > this._rowTimeControls.Length)
                continue
            ctrl := this._rowTimeControls[i]
            if (ctrl = "")
                continue
            newText := this._ComputeTimeText(row["name"])
            try ctrl.Value := newText
        }
    }

    ; Computes the display string for a zone's time cell. Returns
    ; "" when there's no tracker wired OR the zone has no recorded
    ; time (zones never visited stay blank rather than showing
    ; "0:00" — less visual noise per Q4 decision). Includes the
    ; in-flight active elapsed when the zone is currently active,
    ; so the row visibly ticks up between renders.
    ;
    ; The "empty when zero" filter lives in _FormatTime (single
    ; source of truth); this method only adds the tracker-absent
    ; guard plus a defensive try around the read.
    _ComputeTimeText(zoneName)
    {
        if !IsObject(this._zoneTracker)
            return ""
        ms := 0
        try ms := this._zoneTracker.GetZoneTotalWithActive(zoneName)
        return RouteWidget._FormatTime(ms)
    }

    ; ============================================================
    ; Note rendering helpers
    ; ============================================================

    ; Returns the note text for the current zone in the slice (the
    ; row with status="current"), or "" when (a) no current row in
    ; the slice, (b) RouteService doesn't expose a current Route,
    ; or (c) the current zone has no authored note. Defensive
    ; try/catch around the Route read so a domain-layer bug never
    ; cascades into a render crash.
    _GetCurrentNoteFromSlice(slice)
    {
        if !IsObject(slice)
            return ""
        currentRow := ""
        for _, row in slice
        {
            if (row["status"] = "current")
            {
                currentRow := row
                break
            }
        }
        if !IsObject(currentRow)
            return ""
        try
        {
            route := this._routeService.GetCurrentRoute()
            if !IsObject(route)
                return ""
            return route.GetNote(currentRow["name"])
        }
        catch
        {
            return ""
        }
    }

    ; Estimates the pixel height needed to render the given note
    ; text inside a control of width availW at the given font
    ; size. Counts hard line breaks (`n) AND soft wraps (chars per
    ; line based on the font + width). Conservative — overshoots
    ; slightly on long lines so the last visible line isn't
    ; clipped at the bottom edge of the control.
    ;
    ; The estimate is good enough for typical tips (< 200 chars)
    ; on the widget's normal width (~120-300 px). Notes longer
    ; than that would benefit from a real GDI measurement, but
    ; that complexity isn't worth the cost — the smoke test will
    ; catch any tip that visibly clips, and the user can break
    ; long notes manually.
    static _EstimateNoteHeight(note, availW, fontSize, lineHeight)
    {
        lines := RouteWidget._EstimateNoteLines(note, availW, fontSize)
        if (lines < 1)
            return 0
        ; +4 px padding inside the note row so the bottom line of
        ; text doesn't touch the row's visual edge. Pure aesthetics;
        ; the wrap math above accounts for the text itself.
        return lines * lineHeight + 4
    }

    static _EstimateNoteLines(note, availW, fontSize)
    {
        s := String(note)
        if (s = "")
            return 0
        avgCharW := Max(4, fontSize * RouteWidget.NOTE_CHAR_WIDTH_RATIO)
        ; Subtract a little for the internal padding the Text
        ; control reserves around its text; otherwise lines that
        ; fit *exactly* at the boundary would be miscounted as 1
        ; when AHK actually wraps them to 2.
        usableW := Max(20, availW - 4)
        charsPerLine := Max(8, Floor(usableW / avgCharW))

        totalLines := 0
        for _, line in StrSplit(s, "`n", "`r")
        {
            len := StrLen(line)
            if (len = 0)
            {
                ; Hard `n with no content — user intentionally left
                ; a blank line; still occupies one row of vertical
                ; space.
                totalLines += 1
                continue
            }
            wraps := Ceil(len / charsPerLine)
            if (wraps < 1)
                wraps := 1
            totalLines += wraps
        }
        return Max(1, totalLines)
    }

    ; Formats milliseconds as M:SS (or H:MM:SS once a single zone
    ; exceeds an hour, rare but defensive). Floors seconds via
    ; integer division — the 500 ms tick already coarsens the
    ; display, so rounding doesn't add precision.
    ;
    ; Zero and negative ms both render as "" (the Q4 "no 0:00 noise"
    ; rule lives here). Sub-second positive values like 500 ms still
    ; render as "0:00" — the user sees the time appear immediately
    ; on zone entry, rather than waiting a full second for the
    ; first non-empty cell.
    static _FormatTime(ms)
    {
        if (!IsNumber(ms) || ms <= 0)
            return ""
        totalSec := ms // 1000
        m := totalSec // 60
        s := totalSec - m * 60
        if (m >= 60)
        {
            h := m // 60
            m := m - h * 60
            return Format("{:d}:{:02d}:{:02d}", h, m, s)
        }
        return Format("{:d}:{:02d}", m, s)
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

    ; Resolves the effective note font size in pt for a given cfg
    ; and anchor scale. Public-static so the cfg-fallback-clamp
    ; policy can be unit-tested without going through Gui creation
    ; (the _Render path early-returns in headless mode before this
    ; would otherwise be exercised).
    ;
    ; Policy:
    ;   1. Pull the BASE from cfg.routeNoteFontSize (user-
    ;      configurable in Settings → ROUTE).
    ;   2. If the cfg is missing the field, has a non-numeric
    ;      value, or carries a sub-6-pt value (defensive against a
    ;      cfg constructed outside FromMap), fall back to the
    ;      NOTE_FONT_SIZE_BASE constant (8 pt). The clamp in
    ;      AppSettings.FromMap already bounds the field at load,
    ;      so this is belt-and-suspenders.
    ;   3. Multiply by the anchor's render scale so the note
    ;      scales with the overlay, same as the zone-row font.
    ;   4. Floor the final value at 6 pt so an extremely small
    ;      anchor scale (e.g. 0.5) on a base of 6 pt doesn't
    ;      compute to 3 pt (sub-readable).
    static _ResolveNoteFontSize(cfg, scale)
    {
        configuredBase := ""
        try configuredBase := cfg.routeNoteFontSize
        if !IsNumber(configuredBase) || configuredBase < 6
            configuredBase := RouteWidget.NOTE_FONT_SIZE_BASE
        effectiveScale := IsNumber(scale) && scale > 0 ? scale : 1.0
        return Max(6, Round(configuredBase * effectiveScale))
    }

    ; Resolves the line height (px) for the note row given a
    ; resolved note font size (also px, already scaled) and the
    ; anchor scale. Public-static so the ratio policy can be
    ; unit-tested without going through Gui creation.
    ;
    ; Policy:
    ;   1. PRIMARY ratio: 1.75x the font size (mirrors the
    ;      pre-config baseline NOTE_LINE_HEIGHT_BASE=14 over
    ;      NOTE_FONT_SIZE_BASE=8). At default 8 pt the result is
    ;      14 px exactly, so existing renders are unchanged.
    ;   2. Floor at fontSize + 2 (an even tighter floor than the
    ;      ratio for very small fonts) so the row is never less
    ;      than glyph height + minimal padding.
    ;   3. Floor at NOTE_LINE_HEIGHT_BASE * scale so even a
    ;      tiny configured font on a small overlay keeps the
    ;      absolute minimum row height.
    ;
    ; The 1.75 ratio is conservative for Segoe UI — 1pt ≈ 1.33 px
    ; at 96 DPI plus 1.2-1.3x line spacing, so 1.7x covers
    ; descenders (g, p, q, y) without clipping. TUGs feedback at
    ; 16 pt before this change: "a fonte maxima ficou cortada na
    ; metade" — the old fontSize+2 formula gave 18 px at 16 pt,
    ; well below the 22 px Segoe UI actually needs.
    static _ResolveNoteLineHeight(noteFontSize, scale)
    {
        effectiveScale := IsNumber(scale) && scale > 0 ? scale : 1.0
        ; Ceil rather than Round on the ratio so the .5 boundary
        ; (10, 14, 18 pt etc. on a 1.75 ratio) never lands a pixel
        ; short of the glyph height — over-allocating one pixel of
        ; vertical space is invisible (the bg fills it), while
        ; under-allocating by one pixel re-introduces the clip bug.
        ; Round() in AHK v2 uses banker's rounding which would
        ; flip 24.5 → 24 (the unsafe direction).
        return Max(
            noteFontSize + 2,
            Ceil(noteFontSize * 1.75),
            Round(RouteWidget.NOTE_LINE_HEIGHT_BASE * effectiveScale))
    }

    ; Converts a physical-pixel width (as returned by WinGetPos)
    ; into the logical-pixel width that Gui.Show expects for a
    ; DPI-aware Gui. Pure function so it can be unit-tested without
    ; touching the Win32 DPI APIs.
    ;
    ; Why this exists:
    ;   AHK v2 Guis are per-monitor-DPI-aware by default. When you
    ;   call Gui.Show("W 350") on a 150% monitor, the window is
    ;   actually 525 physical pixels wide. WinGetPos on that same
    ;   window returns 525 (physical). If you take that 525 and
    ;   feed it back into another Gui.Show as W, the OS scales it
    ;   AGAIN — 525 logical -> 787 physical. That's the bug TUGs
    ;   reported: route surface overhanging anchor on his 150% 4K
    ;   primary monitor (the secondary 100% monitor showed the
    ;   same overhang because AHK fixes the DPI awareness at
    ;   process start, so both Guis use the system DPI regardless
    ;   of which monitor they render on).
    ;
    ;   Inverse formula: logical = physical * 96 / dpi.
    ;
    ; Fallbacks:
    ;   1. physicalWidth not a number, or <= 0  -> return 0. Caller
    ;      already hides on (aw <= 0), but a separate code path
    ;      could send junk; defensive.
    ;   2. dpi not a number, or < 72 (sub-Win95 territory, never
    ;      happens in practice)  -> coerce to 96. Effectively a
    ;      no-op at standard DPI — keeps the function safe to call
    ;      with raw DllCall return values.
    static _LogicalWidthFromPhysical(physicalWidth, dpi)
    {
        if (!IsNumber(physicalWidth) || physicalWidth <= 0)
            return 0
        if (!IsNumber(dpi) || dpi < 72)
            dpi := 96
        return Round(physicalWidth * 96.0 / dpi)
    }

    ; Thin wrapper: queries the anchor window's actual per-monitor
    ; DPI via GetDpiForWindow and forwards to the pure helper. Kept
    ; minimal because the DllCall path is not unit-testable; all
    ; the math lives in _LogicalWidthFromPhysical.
    ;
    ; GetDpiForWindow exists since Windows 10 1607. On older
    ; Windows the DllCall throws or returns 0, both caught by the
    ; helper's dpi-fallback to 96 — and on those legacy systems
    ; the OS doesn't do per-monitor scaling anyway, so the
    ; physical=logical equivalence holds in practice.
    static _ResolveAnchorLogicalWidth(anchorHwnd, physicalWidth)
    {
        dpi := 96
        try dpi := DllCall("User32\GetDpiForWindow", "Ptr", anchorHwnd, "UInt")
        return RouteWidget._LogicalWidthFromPhysical(physicalWidth, dpi)
    }
}
