; ============================================================
; LayoutWidgetBase — base class for layout widgets
; ============================================================
;
; The LayoutWidgets (CompactLayoutWidget, MicroLayoutWidget,
; SteveLayoutWidget) render with FIXED containerized layouts.
;
; CHARACTERISTICS:
;   - Fixed BASE size (override _GetFixedSize in the subclass).
;     E.g.: Compact = 500x96, Micro = 200x32.
;   - REAL size scaled by _position.scale.
;     Show() applies: _w = Round(baseW * scale), _h = Round(baseH * scale).
;   - Fixed position (no automatic drag), but the user can move via
;     Ctrl+drag and resize via Ctrl+wheel (OverlayInteractionService).
;
; PHILOSOPHY:
;   - Inherits from WidgetBase to reuse the lifecycle (Show/Hide/
;     SetModeVisible/SetScale) and the position-ref.
;   - Subclasses override _BuildGui to build the visual structure,
;     and _GetFixedSize to return Map("w", baseW, "h", baseH) with
;     the reference size at scale=1.0.
;   - _BuildGui should read this._w / this._h (already scaled by Show)
;     and this._position.scale to scale internal dimensions (margins,
;     line positions, font sizes). It should not call _GetFixedSize
;     again inside _BuildGui.
;
; OPTIONAL HEADER:
;   _BuildKalandraBand(x, y, w, h, surfaceName) creates a colored
;   Progress band used as a section background (legacy style).
;
; CONSTRUCTION:
;   class CompactLayoutWidget extends LayoutWidgetBase
;   {
;       __New(bus, position, onPersist, ...services)
;       {
;           super.__New("compactLayout", "Layout Compact", bus, position, onPersist)
;           ; ... capture services
;           ; subscribe events
;       }
;
;       _GetFixedSize() => Map("w", 500, "h", 96)
;
;       _BuildGui()
;       {
;           w := this._w           ; already scaled by Show
;           h := this._h
;           s := this._position.scale
;           ; ... create controls applying scale s in all dimensions
;       }
;   }


class LayoutWidgetBase extends WidgetBase
{
    ; ============================================================
    ; Show override: applies _position scale on top of the BASE
    ; size from _GetFixedSize. Result in this._w / this._h is
    ; available to the subclass's _BuildGui.
    ; ============================================================
    Show()
    {
        if !this._position.visible
            return
        if !this._modeVisible
            return
        if this._gui
            return

        wg := Gui("+ToolWindow +AlwaysOnTop -Caption +E0x08000000")
        wg.BackColor := Theme.Color("bg")
        wg.MarginX := 0
        wg.MarginY := 0
        this._gui := wg
        this._ctrls := Map()

        ; BASE size from subclass + scale from _position.
        sz := this._GetFixedSize()
        if (!IsObject(sz) || !sz.Has("w") || !sz.Has("h"))
            throw Error("LayoutWidgetBase.Show: '" this.id "'._GetFixedSize() must return Map(w,h)")

        scale := this._position.scale
        if (!IsNumber(scale) || scale <= 0)
            scale := 1.0

        this._w := Round(sz["w"] * scale)
        this._h := Round(sz["h"] * scale)

        ; Subclass fills this._gui with bands, headers, controls
        ; using this._w / this._h (already scaled) + this._position.scale
        ; to dimension things internally.
        this._BuildGui()

        ; Creates the highlight border (hidden) that appears when
        ; Ctrl is held. Uses the same helper from WidgetBase.
        this._BuildCtrlHighlight()

        ; Calculate position on screen (same logic as WidgetBase, but
        ; with scaled _w/_h)
        monW := A_ScreenWidth
        monH := A_ScreenHeight
        if this._position.centered
            posX := Round((monW - this._w) / 2)
        else
            posX := Round((this._position.left / 100) * monW)
        posY := Round((this._position.top / 100) * monH)

        wg.Show("NoActivate X" posX " Y" posY " W" this._w " H" this._h)

        ; After Show: enable click-through. Sets LAYERED + alpha=255 +
        ; TRANSPARENT. Details in WidgetBase.Show.
        try WinSetTransparent(255, "ahk_id " wg.Hwnd)
        try WinSetExStyle("+0x20", "ahk_id " wg.Hwnd)

        ; Register Hwnd with OverlayInteractionService so that
        ; Ctrl+drag (move) and Ctrl+wheel (scale) work on layout
        ; widgets. This Show() override does NOT call super, so the
        ; equivalent block from WidgetBase.Show has to be replicated
        ; here -- without it, the overlay becomes uninteractable
        ; (silent failure: the widget renders but ignores Ctrl-based
        ; input).
        if (OverlayInteractionService.Instance != "")
        {
            OverlayInteractionService.Instance.RegisterHwnd(
                this._gui.Hwnd,
                this._UpdatePositionFromGui.Bind(this),
                this._OnWheelResize.Bind(this)
            )
        }
    }

    ; ============================================================
    ; _OnWheelResize - callback called by OverlayInteractionService
    ;   when the user turns the mouse wheel with Ctrl held over the
    ;   widget.
    ;
    ;   steps: +N (wheel up = increase) or -N (down = decrease)
    ;
    ;   Each step = +/- 0.1 in scale. SetScale inherited from WidgetBase
    ;   clamps [0.5, 3.0] + Persist + ReRender automatically.
    ; ============================================================
    _OnWheelResize(steps)
    {
        if !IsNumber(steps)
            return
        currentScale := this._position.scale
        if (!IsNumber(currentScale) || currentScale <= 0)
            currentScale := 1.0
        newScale := currentScale + (steps * 0.1)
        ; Round to avoid float drift (0.1+0.1+0.1 != 0.3 etc.)
        newScale := Round(newScale * 10) / 10
        this.SetScale(newScale)
    }

    ; ============================================================
    ; Subclass overrides
    ; ============================================================

    ; Returns Map("w", baseWidth, "h", baseHeight) with the widget's
    ; BASE size at scale=1.0. Subclass MUST override. Show() applies
    ; scale on top of these values.
    _GetFixedSize()
    {
        throw Error("LayoutWidgetBase._GetFixedSize must be overridden by subclass")
    }

    ; ============================================================
    ; Protected helpers for building Kalandra-style layouts
    ; ============================================================

    ; Creates a Progress band as a colored background. Uses theme
    ; Kalandra colors: surface (lighter), surface2, surface3 (darker).
    ; Returns the created control.
    ;
    ; surfaceName: "surface" | "surface2" | "surface3"
    ;
    ; +Disabled ensures clicks pass straight through to controls on
    ; top of the band (important for MicroLayoutWidget which has
    ; buttons over the background).
    _BuildKalandraBand(x, y, w, h, surfaceName := "surface")
    {
        wg := this._gui
        bgColor := Theme.Color(surfaceName)
        ; Progress with color=bg and Background=bg renders as a solid rectangle.
        return wg.Add("Progress",
            "x" x " y" y " w" w " h" h " Disabled c" bgColor " Background" bgColor,
            100)
    }

    ; Creates the "accent stripe" orange (3px high) that sits on top
    ; of the bands in the legacy. Color: accent (D8492F).
    _BuildAccentStripe(x, y, w, h := 3)
    {
        wg := this._gui
        accent := Theme.Color("accent")
        return wg.Add("Progress",
            "x" x " y" y " w" w " h" h " c" accent " Background" Theme.Color("surface3"),
            100)
    }

    ; Creates a band header (small uppercase text, subtle color, bold).
    ; Legacy style: "MAP", "OBJECTIVE", "REWARDS", etc.
    _BuildBandHeader(x, y, w, text)
    {
        wg := this._gui
        wg.SetFont("s8 c" Theme.Color("subtle") " bold", Theme.FONT_UI)
        return wg.Add("Text", "x" x " y" y " w" w, text)
    }

    ; Creates a horizontal accent divider (thin orange line).
    _BuildDivider(x, y, w, h := 2)
    {
        wg := this._gui
        accent := Theme.Color("accent")
        return wg.Add("Progress",
            "x" x " y" y " w" w " h" h " Disabled c" accent " Background" Theme.Color("surface3"),
            100)
    }

    ; Applies a theme font with size/color/weight. Concise helper to
    ; replace the wg.SetFont boilerplate in sequences of Add()s.
    _SetFont(size, colorName, weight := "")
    {
        opts := "s" size " c" Theme.Color(colorName)
        if (weight != "")
            opts .= " " weight
        this._gui.SetFont(opts, Theme.FONT_UI)
    }
}
