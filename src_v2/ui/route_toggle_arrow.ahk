; ============================================================
; RouteToggleArrow — small Ctrl+Click arrow at the bottom-right
; of an anchor-eligible timer widget. Toggles the RouteWidget's
; global visibility flag.
; ============================================================
;
; This is a thin helper, NOT a widget itself. It exists to keep
; the four anchor-eligible widgets (MicroLayout, MicroLayoutPlus,
; SteveLayout, SteveLayoutPlus) from each carrying ~30 lines of
; duplicated arrow-control plumbing.
;
; Lifecycle is owned by the host widget:
;   - Host calls RouteToggleArrow.Build(...) at the end of its
;     own _BuildGui to add the text control to its Gui.
;   - Host subscribes to Evt.RouteVisibilityToggled and, on each
;     event, calls RouteToggleArrow.RefreshGlyph(ctrl, visible)
;     to swap the arrow ▾ ↔ ▴ in place. No rebuild required.
;   - Host's click handler publishes Cmd.ToggleRouteVisibilityRequested
;     and the composition root flips cfg.routeWidgetVisible.
;
; The arrow stays invisible-to-click in production until Ctrl is
; held — the four host widgets all enable Ctrl-gating via
; OverlayInteractionService.RegisterHwnd, which removes
; WS_EX_TRANSPARENT on Ctrl-down so this text control can receive
; clicks. Without Ctrl, the click passes through to the game. This
; matches the V1/V2/V3 vendor button pattern in CompactLayoutWidget.
;
; Glyph choice:
;   ▾ (U+25BE) = route is currently HIDDEN; clicking will show it
;   ▴ (U+25B4) = route is currently SHOWN;  clicking will hide it
;   The shape semantics match the down/up direction the user
;   would associate with "open/close a panel below me".

class RouteToggleArrow
{
    static GLYPH_HIDDEN  := "▾"
    static GLYPH_VISIBLE := "▴"

    static SIZE_BASE   := 12    ; px square at scale=1.0
    static MARGIN_BASE := 3     ; px from the widget's right/bottom edges
    static FONT_BASE   := 9     ; pt at scale=1.0

    ; Returns the glyph string for the given visibility state.
    ; Used both at initial render time (read from cfg) and on
    ; every RouteVisibilityToggled event (read from payload).
    static GlyphFor(visible) =>
        visible ? RouteToggleArrow.GLYPH_VISIBLE
                : RouteToggleArrow.GLYPH_HIDDEN

    ; Builds the arrow Text control inside the host widget's Gui.
    ; Caller passes the post-scale widget dimensions (w, h) and the
    ; current scale; the arrow positions itself at the bottom-right
    ; corner with `MARGIN_BASE` padding on both axes.
    ;
    ; Optional `customX` / `customY` (default -1) override the
    ; auto-calculated bottom-right position with an explicit
    ; pixel coordinate. Used by host widgets whose bottom-right
    ; corner is already occupied (e.g. CompactLayoutWidget puts
    ; the V1/V2/V3 vendor buttons there, so the arrow lives at
    ; the top-right above them instead). The host is responsible
    ; for computing both coordinates when overriding; mixing one
    ; default with one override is allowed (e.g. customY=4 keeps
    ; the default rightmost X but pins the arrow to the top).
    ;
    ; Returns the new Text control. Caller stores it (e.g. in
    ; this._ctrls["routeArrow"]) for later RefreshGlyph calls.
    ;
    ; Parameters:
    ;   gui         — the host widget's Gui object
    ;   w, h        — post-scale widget dimensions (Integer)
    ;   scale       — the host widget's current scale (Number, ≥0)
    ;   visible     — initial visibility state, drives the glyph
    ;   fontFamily  — Theme.FONT_UI typically
    ;   onClick     — callable to receive the Click event
    ;   customX     — -1 to auto-position at right edge, else px
    ;   customY     — -1 to auto-position at bottom edge, else px
    static Build(gui, w, h, scale, visible, fontFamily, onClick, customX := -1, customY := -1)
    {
        size   := Max(8, Round(RouteToggleArrow.SIZE_BASE * scale))
        margin := Max(1, Round(RouteToggleArrow.MARGIN_BASE * scale))
        font   := Max(7, Round(RouteToggleArrow.FONT_BASE * scale))

        x := (customX >= 0) ? customX : (w - margin - size)
        y := (customY >= 0) ? customY : (h - margin - size)

        ; Subtle color so the arrow doesn't compete with the timer
        ; or PB chips — it's a tiny affordance, not a status surface.
        ; Background matches the widget surface so the arrow blends
        ; in when the user isn't holding Ctrl.
        gui.SetFont("s" font " c" Theme.Color("subtle") " bold",
            fontFamily)
        ctrl := gui.Add("Text",
            "x" x " y" y " w" size " h" size
            . " Center 0x200 Background" Theme.Color("surface"),
            RouteToggleArrow.GlyphFor(visible))

        ; The control is created as a click-through child of a
        ; click-through host. Without OnEvent("Click", ...) the
        ; AHK runtime wouldn't synthesize a Click message for the
        ; control even when Ctrl is held. With the binding here,
        ; the control fires Click on the Ctrl+down → Ctrl+up
        ; sequence (no drag).
        if RouteToggleArrow._IsCallable(onClick)
            ctrl.OnEvent("Click", onClick)
        return ctrl
    }

    ; Hot-update the glyph of a previously-built arrow control.
    ; Used in response to Evt.RouteVisibilityToggled — avoids a
    ; full widget rebuild for what's a single-character swap.
    ;
    ; Silent no-op when ctrl is "" / null so callers can call this
    ; even on hidden or pre-Build paths without guarding.
    static RefreshGlyph(ctrl, visible)
    {
        if !IsObject(ctrl)
            return
        try ctrl.Value := RouteToggleArrow.GlyphFor(visible)
    }

    static _IsCallable(f)
    {
        if (f = "")
            return false
        return HasMethod(f, "Call")
    }
}
