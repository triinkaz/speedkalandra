; ============================================================
; MicroLayoutWidget - minimal bar
; ============================================================
;
; Ultra-reduced version of the overlay. Appears when OverlayModeService
; enters MICRO (activated via Ctrl+F9 — manual lock). The earlier AUTO
; trigger via panel keys was removed; MICRO is now only activated
; manually.
;
; BASE LAYOUT (200x32 at scale=1.0):
;
;   +-----------------------+
;   | 01:24:17  Lv 47   XP  |
;   +-----------------------+
;
; Two controls:
;   - main (left): total run time + char level
;   - xp_indicator (right): fixed "XP" text whose COLOR communicates
;                            status (green/amber/red/gray)
;
; XP INDICATOR:
;   xp_indicator is a Text control with FIXED "XP" text whose color
;   changes according to the status computed by XpRules. Text is
;   always "XP" — does not show textual status (OK/LIMIT/PENALTY/?)
;   as a UX preference.
;
;   Status -> color (from XpRules):
;     ok       -> desaturated green (B8C7B0)
;     limit    -> amber (F59E0B)
;     penalty  -> desaturated red (F87171)
;     unknown  -> gray (8B8B8B)
;
;   AHK Text controls only support ONE color per control. The color
;   is updated via ctrl.SetFont when the XP status changes (cache
;   avoids repaint every tick).
;
; BOSS TIMER (removed):
;   Boss timer feature was removed from the app (class voice lines
;   did not go to PoE2's Client.txt, detection was unfeasible for
;   most bosses). Micro lost the special "Boss MM:SS" / "✓ MM:SS".
;
; SCALE:
;   The entire widget scales by _position.scale via Ctrl+wheel (same
;   infra as CompactLayoutWidget). _BuildGui reads this._w/this._h
;   (already scaled by Show) and propagates scale into font size +
;   paddings.
;
; CONSTRUCTION:
;   widget := MicroLayoutWidget(bus, position, onPersist, timer, xp)

class MicroLayoutWidget extends LayoutWidgetBase
{
    static WIDGET_ID := "microLayout"
    static DISPLAY_NAME := "Layout Micro"

    ; BASE size (scale=1.0)
    static FIXED_W := 200
    static FIXED_H := 32

    ; BASE layout (scale=1.0)
    static STRIPE_H  := 2
    static PADDING_X := 6
    static PADDING_Y := 6
    static FONT_MAIN := 11

    ; Width reserved for xp_indicator (right-aligned).
    ; Since the text is fixed "XP" (~2 chars), 30px provides
    ; comfortable margin at scale 1.0 and plenty of slack at larger scales.
    static XP_INDICATOR_W := 30

    _timer     := ""
    _xp        := ""

    _lastRenderMs := 0
    _lastXpColor   := ""    ; to avoid unnecessary SetFont

    _handlerTick := ""

    __New(bus, position, onPersist, timer, xp)
    {
        super.__New(MicroLayoutWidget.WIDGET_ID,
                    MicroLayoutWidget.DISPLAY_NAME,
                    bus, position, onPersist)
        this._timer := timer
        this._xp    := xp

        this._handlerTick := (data) => this._OnTick(data)
        bus.Subscribe(Events.Tick, this._handlerTick)
    }

    _GetFixedSize() => Map("w", MicroLayoutWidget.FIXED_W, "h", MicroLayoutWidget.FIXED_H)

    _GetScale()
    {
        s := this._position.scale
        if (!IsNumber(s) || s <= 0)
            return 1.0
        return s
    }

    _BuildGui()
    {
        wg := this._gui
        ; _w / _h already come scaled from LayoutWidgetBase.Show()
        w  := this._w
        h  := this._h
        s  := this._GetScale()

        ; Scaled dimensions
        stripeH := Max(1, Round(MicroLayoutWidget.STRIPE_H * s))
        padX    := Max(2, Round(MicroLayoutWidget.PADDING_X * s))
        padY    := Max(2, Round(MicroLayoutWidget.PADDING_Y * s))
        xpW     := Max(20, Round(MicroLayoutWidget.XP_INDICATOR_W * s))
        fontMain := Max(7, Round(MicroLayoutWidget.FONT_MAIN * s))

        ; Background
        this._BuildKalandraBand(0, 0, w, h, "surface")
        ; Top accent stripe
        this._BuildAccentStripe(0, 0, w, stripeH)

        ; Useful text height (raising a bit for vertical breathing room)
        textH := h - 2*padY + Round(padY/3)

        ; --- main (left): "01:24:17 Lv 47" ---
        ; Width: total - 2*padX - xp_indicator width
        mainW := w - 2*padX - xpW
        this._SetFont(fontMain, "text", "")
        this._ctrls["main"] := wg.Add("Text",
            "x" padX " y" padY
            " w" mainW " h" textH
            " Left"
            " Background" Theme.Color("surface"),
            "")

        ; --- xp_indicator (right): fixed "XP" text, dynamic color ---
        this._SetFont(fontMain, "muted", "bold")
        this._ctrls["xp_indicator"] := wg.Add("Text",
            "x" (w - padX - xpW) " y" padY
            " w" xpW " h" textH
            " Right"
            " Background" Theme.Color("surface"),
            "")

        ; Reset cache to force first SetFont
        this._lastXpColor := ""

        this._Refresh()
    }

    _Refresh()
    {
        if !this._gui
            return

        ; Total run time + char level
        runMs  := IsObject(this._timer) ? this._timer.GetRunMs() : 0
        charLv := IsObject(this._xp) ? this._xp.GetCharacterLevel() : 0
        mainText := this._FormatMs(runMs)
        if (charLv > 0)
            mainText .= "  Lv " charLv

        if this._ctrls.Has("main")
            try this._ctrls["main"].Value := mainText

        ; XP indicator with dynamic color
        this._RefreshXpIndicator()
    }

    ; ============================================================
    ; _RefreshXpIndicator - updates the COLOR of the fixed "XP" text
    ;
    ; Text: always "XP" — does not show OK/LIMIT/PENALTY/? as a UX
    ; preference (only the color communicates status).
    ;
    ; Color comes from XpRules.Calculate (via xpService.GetXpPenaltyInfo).
    ; Optimization: only calls SetFont when the color changed.
    ; ============================================================
    _RefreshXpIndicator()
    {
        if !this._ctrls.Has("xp_indicator")
            return
        if !IsObject(this._xp)
            return

        info := this._xp.GetXpPenaltyInfo()
        color := info.color

        ctrl := this._ctrls["xp_indicator"]

        if (color != this._lastXpColor)
        {
            fontMain := Max(7, Round(MicroLayoutWidget.FONT_MAIN * this._GetScale()))
            try ctrl.SetFont("s" fontMain " c" color " bold", Theme.FONT_UI)
            this._lastXpColor := color
        }
        try ctrl.Value := "XP"
    }

    ; Thin alias kept so call sites in this file don't need rewriting.
    _FormatMs(ms) => Duration.FormatMs(ms)

    _OnTick(data)
    {
        nowMs := A_TickCount
        if (nowMs - this._lastRenderMs < 250)
            return
        this._lastRenderMs := nowMs
        this._Refresh()
    }

    Dispose()
    {
        if (this._handlerTick != "")
        {
            this._bus.Unsubscribe(Events.Tick, this._handlerTick)
            this._handlerTick := ""
        }
    }
}
