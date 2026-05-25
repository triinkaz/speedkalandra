; ============================================================
; SteveLayoutWidget — desktop-sized speedrun overlay (Steve layout)
; ============================================================
;
; Base size 380×64 at scale=1.0; the widget rescales via Ctrl+wheel
; and clamps to [0.5, 3.0] inside WidgetBase.SetScale.
;
; LAYOUT (base 380×64 at scale=1.0):
;
;   +-------------------------------------------------------+
;   | Act 1 · The Riverbank              02:31.234         |  ← LINE1
;   | ✗ 3   XP                                   4:23      |  ← LINE2
;   | [Map][Loading][Town]                                 |  ← 4px footer
;   +-------------------------------------------------------+
;
; The right-side timer is monospaced (Theme.FONT_MONO) so the
; digits don't shimmy under the per-50ms refresh — proportional
; fonts shift the colon-second alignment every other frame.
;
; DESIGN NOTES:
;   - Right-aligned bare PB value (MM:SS, teal) on LINE2 reads the
;     per-act PB (pbService.GetRunPbForAct of the current act) —
;     same source the LINE1 timer compares against for its
;     goodStrong/danger color. NO "PB" or "RUN" label: the teal
;     colour already signals "this is a PB-related value" against
;     the muted chips on the left, and the bare number reads
;     faster mid-run than a labelled chip.
;   - 4 px distribution footer (no labels) using the colors from
;     theme aliases map/loading/town.
;   - cfg is plumbed for runtime settings (pbDisplayMode, route
;     widget visibility).
;
; PB DISPLAY MODE (cfg.pbDisplayMode):
;   - "pb" (default): bare value sources `pbService.GetRunPbForAct`
;     and the LINE1 timer color compares vs the same per-act PB.
;   - "avg5": bare value prefixed with a tilde ("~ MM:SS") to
;     differentiate visually from PB; the source is the latest-5-run
;     average from `avgService.GetAverageRunMsForAct`. The LINE1
;     timer color compares vs the same avg5 target, so "current
;     below target" still reads green either way. Hot-reloadable
;     via Evt.PbDisplayModeChanged (no restart).
;
; CONSTRUCTION:
;   widget := SteveLayoutWidget(
;       bus, position, onPersist,
;       timer, zoneTracker, xpService,
;       zonesCatalog, pbService, loadingTotals, cfg, avgService)


class SteveLayoutWidget extends LayoutWidgetBase
{
    ; WIDGET_ID identifies the [Overlay] slot. OverlayLayout /
    ; OverlayModeApplier treat the ID as the slot, not the
    ; implementation, so the user's persisted position carries
    ; across any future widget revision.
    static WIDGET_ID := "steveLayout"
    static DISPLAY_NAME := "Layout Steve"

    ; Base widget dimensions at scale=1.0.
    static FIXED_W := 380
    static FIXED_H := 64

    ; BASE layout (scale=1.0). _BuildGui multiplies by scale at runtime.
    static MARGIN_X := 10
    static STRIPE_H := 2

    ; LINE1: act/zone (left) + timer mono giant (right)
    static LINE1_Y       := 4
    static LINE1_H       := 30
    static TIMER_W       := 200   ; wide enough for "1:23:45" in Consolas at scale 1.0
    static ACT_ZONE_GAP  := 6

    ; LINE2: chips (left, deaths + XP) + bare PB value (right).
    ; The single PB surface is right-aligned, teal-coloured, with
    ; NO "PB" or "RUN" label — just the MM:SS (or H:MM:SS) value.
    ; History: this slot iterated through "PB MM:SS" (label was
    ; redundant against the colour) and "RUN · PB MM:SS" (the
    ; "RUN" framing implied overall-run PB but the value is
    ; per-act). The bare value is what the runner actually reads.
    ; If a future iteration wants two PB surfaces, the second one
    ; needs a meaningfully different source (e.g. zone-PB or
    ; overall-run-PB via pbService.GetRunPbMs).
    static LINE2_Y       := 36
    static LINE2_H       := 16
    static CHIP_DEATHS_W := 36
    static CHIP_XP_W     := 22
    static CHIP_GAP      := 6
    static PB_W          := 64    ; bare "MM:SS" or "H:MM:SS" up to ~1:23:45 in 9pt

    ; Distribution footer
    static BAR_Y := 56
    static BAR_H := 4

    ; BASE fonts (scale=1.0). Timer is in Theme.FONT_MONO (Consolas)
    ; so the digits don't reflow under the 50ms refresh.
    static FONT_ACT_ZONE := 9
    static FONT_TIMER    := 22    ; mono is wider per char and we
                                  ; cap timer width at TIMER_W
    static FONT_CHIP     := 8
    static FONT_PB       := 9     ; one pt bigger than chips so the
                                  ; bare PB value reads at a glance

    ; High-frequency timer refresh.
    static TIMER_REFRESH_MS := 50

    ; Services
    _timer         := ""
    _zoneTracker   := ""
    _xp            := ""
    _zonesCatalog  := ""
    _pbService     := ""
    _loadingTotals := ""
    _cfg           := ""
    _avgService    := ""   ; RunAverageService (optional; required for cfg.pbDisplayMode = "avg5")

    ; State
    _currentZone := ""
    _currentAct  := 0
    _deathCount  := 0

    ; Cache to skip redundant SetFont / Value writes per tick
    _lastTimerText      := ""
    _lastTimerColor     := ""
    _lastActZoneText    := ""
    _lastDeathsText     := ""
    _lastDeathsColor    := ""
    _lastXpColor        := ""
    _lastPbText         := ""
    _lastRenderMs       := 0

    ; Handler refs — kept as fields so Dispose's Unsubscribe
    ; references the same closure.
    _handlerTick           := ""
    _handlerZoneEntered    := ""
    _handlerCharLevelUp    := ""
    _handlerDeathDetected  := ""
    _handlerRunStarted     := ""
    _handlerRunReset       := ""
    _handlerRunCancelled   := ""
    _handlerPbDisplayMode  := ""   ; Evt.PbDisplayModeChanged — forces a full refresh on toggle
    _handlerRouteVis       := ""   ; Evt.RouteVisibilityToggled — refreshes the arrow glyph in place

    _highFreqTimerFn := ""

    __New(bus, position, onPersist, timer, zoneTracker, xp,
          zonesCatalog := "", pbService := "", loadingTotals := "", cfg := "",
          avgService := "")
    {
        super.__New(SteveLayoutWidget.WIDGET_ID,
                    SteveLayoutWidget.DISPLAY_NAME,
                    bus, position, onPersist)
        this._timer         := timer
        this._zoneTracker   := zoneTracker
        this._xp            := xp
        this._zonesCatalog  := zonesCatalog
        this._pbService     := pbService
        this._loadingTotals := loadingTotals
        this._cfg           := cfg
        this._avgService    := avgService

        this._handlerTick           := (data) => this._OnTick(data)
        this._handlerZoneEntered    := (data) => this._OnZoneEntered(data)
        this._handlerCharLevelUp    := (data) => this._Refresh()
        this._handlerDeathDetected  := (data) => this._OnDeathDetected(data)
        this._handlerRunStarted     := (data) => this._OnRunStateChange()
        this._handlerRunReset       := (data) => this._OnRunStateChange()
        this._handlerRunCancelled   := (data) => this._OnRunStateChange()
        ; Force a full re-render when the user flips the PB display
        ; mode in Settings — the cached colour and text of the bare
        ; PB chip + the timer-vs-PB colour both depend on the mode.
        this._handlerPbDisplayMode  := (data) => this._OnPbDisplayModeChanged()

        bus.Subscribe(Events.Tick,             this._handlerTick)
        bus.Subscribe(Events.ZoneEntered,      this._handlerZoneEntered)
        bus.Subscribe(Events.CharacterLevelUp, this._handlerCharLevelUp)
        bus.Subscribe(Events.DeathDetected,    this._handlerDeathDetected)
        bus.Subscribe(Events.RunStarted,       this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,         this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled,     this._handlerRunCancelled)
        bus.Subscribe(Events.PbDisplayModeChanged, this._handlerPbDisplayMode)

        ; B4 Stage 2: route toggle arrow. Subscribe only when cfg
        ; was wired (opt-in at the composition root).
        if IsObject(cfg)
        {
            this._handlerRouteVis := (data) => this._OnRouteVisibilityToggled(data)
            bus.Subscribe(Events.RouteVisibilityToggled, this._handlerRouteVis)
        }
    }

    _GetFixedSize() => Map("w", SteveLayoutWidget.FIXED_W, "h", SteveLayoutWidget.FIXED_H)

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
        w  := this._w
        h  := this._h
        s  := this._GetScale()

        ; Scaled dimensions
        marginX := Max(4, Round(SteveLayoutWidget.MARGIN_X * s))
        stripeH := Max(1, Round(SteveLayoutWidget.STRIPE_H * s))
        timerW  := Max(80, Round(SteveLayoutWidget.TIMER_W * s))
        chipGap := Max(2, Round(SteveLayoutWidget.CHIP_GAP * s))

        line1Y := Round(SteveLayoutWidget.LINE1_Y * s)
        line1H := Round(SteveLayoutWidget.LINE1_H * s)
        line2Y := Round(SteveLayoutWidget.LINE2_Y * s)
        line2H := Round(SteveLayoutWidget.LINE2_H * s)

        chipDeathsW := Round(SteveLayoutWidget.CHIP_DEATHS_W * s)
        chipXpW     := Round(SteveLayoutWidget.CHIP_XP_W * s)
        pbW         := Round(SteveLayoutWidget.PB_W * s)

        ; Distribution footer pins to the bottom edge of the rendered
        ; container.
        barH := Max(2, Round(SteveLayoutWidget.BAR_H * s))
        barY := h - barH

        fontActZone := Max(7, Round(SteveLayoutWidget.FONT_ACT_ZONE * s))
        fontTimer   := Max(12, Round(SteveLayoutWidget.FONT_TIMER * s))
        fontChip    := Max(6, Round(SteveLayoutWidget.FONT_CHIP * s))
        fontPb      := Max(7, Round(SteveLayoutWidget.FONT_PB * s))

        ; Background + top accent stripe (shared visual signature
        ; with Compact).
        this._BuildKalandraBand(0, 0, w, h, "surface")
        this._BuildAccentStripe(0, 0, w, stripeH)

        contentX := marginX

        ; ============ LINE 1: act+zone (left) | mono timer (right) ============
        actZoneW := w - contentX - marginX - timerW - SteveLayoutWidget.ACT_ZONE_GAP
        if (actZoneW < 40)
            actZoneW := 40

        this._SetFont(fontActZone, "text", "")
        this._ctrls["line1_act_zone"] := wg.Add("Text",
            "x" contentX " y" line1Y
            " w" actZoneW " h" line1H
            " Left 0x200"
            " Background" Theme.Color("surface"),
            "")

        ; Mono timer: Theme.FONT_MONO (Consolas), bold, dynamic color
        ; vs pbService.GetRunPbForAct(currentAct). 0x200 = SS_CENTERIMAGE
        ; centers vertically.
        timerX := w - marginX - timerW
        wg.SetFont("s" fontTimer " c" Theme.Color("text") " bold", Theme.FONT_MONO)
        this._ctrls["line1_timer"] := wg.Add("Text",
            "x" timerX " y" line1Y
            " w" timerW " h" line1H
            " Right 0x200"
            " Background" Theme.Color("surface"),
            "")

        ; ============ LINE 2: chips (left) | RUN · PB (right) ============
        x := contentX

        ; Death chip — muted at 0, warn (amber) when >= 1.
        this._SetFont(fontChip, "muted", "bold")
        this._ctrls["line2_deaths"] := wg.Add("Text",
            "x" x " y" line2Y
            " w" chipDeathsW " h" line2H
            " Left"
            " Background" Theme.Color("surface"),
            "")
        x += chipDeathsW + chipGap

        ; XP chip — fixed "XP" label, dynamic color from XpRules
        ; (same convention as the Compact widget).
        this._SetFont(fontChip, "muted", "bold")
        this._ctrls["line2_xp"] := wg.Add("Text",
            "x" x " y" line2Y
            " w" chipXpW " h" line2H
            " Left"
            " Background" Theme.Color("surface"),
            "XP")
        x += chipXpW + chipGap

        ; Bare PB value — right-aligned, teal so the colour
        ; signals "this is PB-related" against the muted chips on
        ; the left without needing a "PB" label prefix. Reads the
        ; per-act PB (pbService.GetRunPbForAct of the current act)
        ; — see header for the full rationale on why this slot has
        ; no label.
        pbX := w - marginX - pbW
        wg.SetFont("s" fontPb " c" Theme.Color("pb") " bold", Theme.FONT_UI)
        this._ctrls["line2_pb"] := wg.Add("Text",
            "x" pbX " y" line2Y
            " w" pbW " h" line2H
            " Right"
            " Background" Theme.Color("surface"),
            "")

        ; ============ FOOTER: 4px distribution bar (no labels) ============
        barX := contentX
        barW := w - 2 * marginX

        ; surface3 background — visible when runMs=0 (no segments yet)
        this._ctrls["bar_bg"] := wg.Add("Progress",
            "x" barX " y" barY " w" barW " h" barH
            " Disabled c" Theme.Color("surface3") " Background" Theme.Color("surface3"),
            100)

        ; Three sized-on-refresh segments (Map / Loading / Town).
        ; No text inside — the bar is 4 px high, labels wouldn't
        ; fit. _RefreshBar sets Move(x, y, w, h) every tick.
        this._ctrls["bar_map"] := wg.Add("Progress",
            "x" barX " y" barY " w0 h" barH
            " Disabled c" Theme.Color("map") " Background" Theme.Color("map"),
            100)
        this._ctrls["bar_loading"] := wg.Add("Progress",
            "x" barX " y" barY " w0 h" barH
            " Disabled c" Theme.Color("loading") " Background" Theme.Color("loading"),
            100)
        this._ctrls["bar_town"] := wg.Add("Progress",
            "x" barX " y" barY " w0 h" barH
            " Disabled c" Theme.Color("town") " Background" Theme.Color("town"),
            100)

        ; Resync from zoneTracker (handles mid-run widget swap)
        this._ResolveInitialActZone()

        ; Reset caches so the first render forces SetFont
        this._lastTimerText  := ""
        this._lastTimerColor := ""
        this._lastActZoneText := ""
        this._lastDeathsText  := ""
        this._lastDeathsColor := ""
        this._lastXpColor     := ""
        this._lastPbText      := ""

        ; B4 Stage 2: bottom-right route toggle arrow.
        if IsObject(this._cfg)
        {
            this._ctrls["routeArrow"] := RouteToggleArrow.Build(
                wg, w, h, s,
                this._cfg.routeWidgetVisible,
                Theme.FONT_UI,
                (*) => this._OnRouteArrowClick())
        }

        this._Refresh()

        ; Start high-freq timer (50 ms). Without this the timer
        ; centiseconds visibly stutter on the default Tick rate
        ; (300 ms).
        this._highFreqTimerFn := this._OnHighFreqTimer.Bind(this)
        try SetTimer(this._highFreqTimerFn, SteveLayoutWidget.TIMER_REFRESH_MS)
    }

    ; ============================================================
    ; Refresh handlers
    ; ============================================================

    _OnTick(data)
    {
        nowMs := A_TickCount
        if (nowMs - this._lastRenderMs < 250)
            return
        this._lastRenderMs := nowMs
        this._Refresh()
    }

    ; 50 ms timer — refreshes ONLY the live run timer (the digits
    ; that visibly advance). Other fields update on the normal Tick
    ; cadence via _OnTick.
    _OnHighFreqTimer()
    {
        if !this._gui
            return
        if !this._modeVisible
            return
        this._RefreshTimerOnly()
    }

    _Refresh()
    {
        if !this._gui
            return
        this._RefreshActZone()
        this._RefreshTimerOnly()
        this._RefreshDeaths()
        this._RefreshXp()
        this._RefreshPb()
        this._RefreshBar()
    }

    _RefreshActZone()
    {
        if !this._ctrls.Has("line1_act_zone")
            return

        actStr  := this._currentAct > 0 ? ("Act " this._currentAct) : ("Act " Chr(0x2014))
        zoneStr := this._currentZone != "" ? this._currentZone : Chr(0x2014)
        text := actStr " " Chr(0x00B7) " " zoneStr

        ; Truncate with ellipsis if the composed string overflows
        ; the act/zone column. The mono timer on the right takes
        ; TIMER_W pixels, so the act/zone column is the leftover
        ; (~150 px at scale=1.0) — "Act 1 · Clearfell Encampment"
        ; (28 chars) sits right at the boundary and the AHK Text
        ; control would word-wrap to a second line, colliding with
        ; the chip row below. Truncating up front keeps the
        ; rendering on one line.
        s := this._GetScale()
        marginX    := Max(4, Round(SteveLayoutWidget.MARGIN_X * s))
        timerW     := Max(80, Round(SteveLayoutWidget.TIMER_W * s))
        actZoneGap := Max(2, Round(SteveLayoutWidget.ACT_ZONE_GAP * s))
        actZoneW   := this._w - marginX - marginX - timerW - actZoneGap
        if (actZoneW < 40)
            actZoneW := 40
        fontActZone := Max(7, Round(SteveLayoutWidget.FONT_ACT_ZONE * s))
        text := SteveLayoutWidget._TruncateToWidth(text, fontActZone, actZoneW)

        if (text != this._lastActZoneText)
        {
            try this._ctrls["line1_act_zone"].Value := text
            this._lastActZoneText := text
        }
    }

    _RefreshTimerOnly()
    {
        if !this._ctrls.Has("line1_timer")
            return

        runMs := IsObject(this._timer) ? this._timer.GetRunMs() : 0
        text := SteveLayoutWidget._FormatMs(runMs)

        pbMs := this._GetRunPbMs()
        color := SteveLayoutWidget._ResolveTimerColor(runMs, pbMs)

        ctrl := this._ctrls["line1_timer"]

        if (color != this._lastTimerColor)
        {
            fontTimer := Max(12, Round(SteveLayoutWidget.FONT_TIMER * this._GetScale()))
            try ctrl.SetFont("s" fontTimer " c" color " bold", Theme.FONT_MONO)
            this._lastTimerColor := color
        }
        if (text != this._lastTimerText)
        {
            try ctrl.Value := text
            this._lastTimerText := text
        }
    }

    _RefreshDeaths()
    {
        if !this._ctrls.Has("line2_deaths")
            return

        n := this._deathCount
        text := Chr(0x2717) " " n
        color := n > 0 ? Theme.Color("warn") : Theme.Color("muted")

        ctrl := this._ctrls["line2_deaths"]
        if (color != this._lastDeathsColor)
        {
            fontChip := Max(6, Round(SteveLayoutWidget.FONT_CHIP * this._GetScale()))
            try ctrl.SetFont("s" fontChip " c" color " bold", Theme.FONT_UI)
            this._lastDeathsColor := color
        }
        if (text != this._lastDeathsText)
        {
            try ctrl.Value := text
            this._lastDeathsText := text
        }
    }

    _RefreshXp()
    {
        if !this._ctrls.Has("line2_xp") || !IsObject(this._xp)
            return

        info := this._xp.GetXpPenaltyInfo()
        color := info.color

        ctrl := this._ctrls["line2_xp"]
        if (color != this._lastXpColor)
        {
            fontChip := Max(6, Round(SteveLayoutWidget.FONT_CHIP * this._GetScale()))
            try ctrl.SetFont("s" fontChip " c" color " bold", Theme.FONT_UI)
            this._lastXpColor := color
        }
    }

    _RefreshPb()
    {
        if !this._ctrls.Has("line2_pb")
            return

        ; Source + format depend on cfg.pbDisplayMode. "pb" keeps
        ; the original bare value (sourced from PB); "avg5" prefixes
        ; the value with a tilde ("~ MM:SS") to make the change of
        ; semantics visible at a glance without needing a colour
        ; difference. See header "PB DISPLAY MODE" block.
        ;
        ; Em-dash alone is the placeholder when no PB / no average
        ; exists yet — same in both modes so the chip slot still
        ; reserves visual space predictably.
        targetMs := this._GetTargetMs()
        if (targetMs > 0)
        {
            formatted := SteveLayoutWidget._FormatMsShort(targetMs)
            text := this._IsAvg5Mode() ? ("~ " . formatted) : formatted
        }
        else
        {
            text := Chr(0x2014)
        }

        if (text != this._lastPbText)
        {
            try this._ctrls["line2_pb"].Value := text
            this._lastPbText := text
        }
    }

    ; Stacked-bar refresh — same math as Compact, no labels. Skipped
    ; when runMs is 0 so a fresh widget shows a clean surface3 strip
    ; instead of an empty 100 %-map flash.
    _RefreshBar()
    {
        if !this._ctrls.Has("bar_map")
            return

        s        := this._GetScale()
        marginX  := Max(4, Round(SteveLayoutWidget.MARGIN_X * s))
        barX     := marginX
        barW     := this._w - 2 * marginX
        barH     := Max(2, Round(SteveLayoutWidget.BAR_H * s))
        barY     := this._h - barH

        runMs := IsObject(this._timer) ? this._timer.GetRunMs() : 0
        if (runMs <= 0)
        {
            this._SetBarSegment("bar_map",     barX, barY, 0, barH)
            this._SetBarSegment("bar_loading", barX, barY, 0, barH)
            this._SetBarSegment("bar_town",    barX, barY, 0, barH)
            return
        }

        loadingMs := IsObject(this._loadingTotals) ? this._loadingTotals.GetTotalMs() : 0
        townMs    := IsObject(this._zoneTracker)   ? this._zoneTracker.GetTotalTownMs() : 0
        if (loadingMs < 0)
            loadingMs := 0
        if (townMs < 0)
            townMs := 0

        ; Same percentage clamping as Compact. The sum of loadPct +
        ; townPct can't exceed 100; if it does (data corruption), we
        ; rescale them proportionally.
        loadPct := Round(loadingMs / runMs * 100)
        townPct := Round(townMs    / runMs * 100)
        if (loadPct < 0)
            loadPct := 0
        if (loadPct > 100)
            loadPct := 100
        if (townPct < 0)
            townPct := 0
        if (townPct > 100)
            townPct := 100
        if (loadPct + townPct > 100)
        {
            sum := loadPct + townPct
            loadPct := Round(loadPct * 100 / sum)
            townPct := 100 - loadPct
        }
        mapPct := 100 - loadPct - townPct

        wMap  := Round(barW * mapPct / 100)
        wLoad := Round(barW * loadPct / 100)
        wTown := barW - wMap - wLoad
        if (wTown < 0)
            wTown := 0

        cursor := barX
        this._SetBarSegment("bar_map", cursor, barY, wMap, barH)
        cursor += wMap
        this._SetBarSegment("bar_loading", cursor, barY, wLoad, barH)
        cursor += wLoad
        this._SetBarSegment("bar_town", cursor, barY, wTown, barH)
    }

    _SetBarSegment(key, x, y, w, h)
    {
        if !this._ctrls.Has(key)
            return
        try this._ctrls[key].Move(x, y, w, h)
    }

    ; ============================================================
    ; State event handlers
    ; ============================================================

    _OnZoneEntered(data)
    {
        if !IsObject(data)
            return
        if data.Has("zoneName")
            this._currentZone := data["zoneName"]
        if data.Has("actIndex")
        {
            ai := data["actIndex"]
            if (IsNumber(ai) && ai > 0)
                this._currentAct := ai
        }
        ; Fallback: derive act from catalog when actIndex was 0 or absent.
        if (this._currentAct = 0 && IsObject(this._zonesCatalog) && this._currentZone != "")
        {
            a := this._zonesCatalog.GetActOfName(this._currentZone)
            if (a > 0)
                this._currentAct := a
        }
        this._Refresh()
    }

    _OnDeathDetected(data)
    {
        this._deathCount += 1
        this._RefreshDeaths()
    }

    _OnRunStateChange()
    {
        this._deathCount := 0
        this._Refresh()
    }

    ; Hot-reload of cfg.pbDisplayMode (Evt.PbDisplayModeChanged).
    ; Caches that capture *derived* state (text, colour) must be
    ; cleared so the next Refresh writes the new mode's values
    ; instead of short-circuiting on a stale cache hit. The other
    ; caches (act/zone, deaths) are independent of the mode and
    ; aren't touched.
    _OnPbDisplayModeChanged()
    {
        this._lastTimerColor := ""
        this._lastPbText     := ""
        this._Refresh()
    }

    ; B4 Stage 2 — route toggle arrow click handler.
    _OnRouteArrowClick()
    {
        this._bus.Publish(Commands.ToggleRouteVisibilityRequested, Map())
    }

    ; B4 Stage 2 — hot-refresh of arrow glyph after visibility flip.
    _OnRouteVisibilityToggled(data)
    {
        if !this._gui || !this._ctrls.Has("routeArrow")
            return
        visible := IsObject(data) && data.Has("visible")
                   ? data["visible"]
                   : false
        RouteToggleArrow.RefreshGlyph(this._ctrls["routeArrow"], visible)
    }

    _ResolveInitialActZone()
    {
        if !IsObject(this._zoneTracker)
            return
        try
        {
            z := this._zoneTracker.GetActiveZone()
            if (z != "")
            {
                this._currentZone := z
                if (this._currentAct = 0 && IsObject(this._zonesCatalog))
                {
                    a := this._zonesCatalog.GetActOfName(z)
                    if (a > 0)
                        this._currentAct := a
                }
            }
        }
    }

    ; ============================================================
    ; PB lookup helpers.
    ; ============================================================

    ; True when the config opts into the latest-5-run average via
    ; cfg.pbDisplayMode = "avg5" AND the avg service is present.
    ; The dual check keeps mode=avg5 with no service from silently
    ; falling into a misleading branch — it falls back to PB.
    _IsAvg5Mode()
    {
        if !IsObject(this._cfg)
            return false
        if !IsObject(this._avgService)
            return false
        return this._cfg.pbDisplayMode = "avg5"
    }

    ; Resolves the act to use for the per-act lookup. Prefer
    ; _currentAct, fall back to the zones catalog by zone name.
    ; Extracted so the PB-mode and avg5-mode branches share one
    ; act resolution.
    _ResolveActForLookup()
    {
        act := this._currentAct
        if (act <= 0 && IsObject(this._zonesCatalog) && this._currentZone != "")
            act := this._zonesCatalog.GetActOfName(this._currentZone)
        return act
    }

    ; "Target" = the per-act ms value that both the timer colour
    ; comparison and the LINE2 bare value source from. Routes to
    ; PB or avg5 based on cfg.pbDisplayMode. The legacy
    ; _GetRunPbMs name is preserved below as a thin alias so
    ; existing call sites (timer colour) don't need a sweep.
    _GetTargetMs()
    {
        act := this._ResolveActForLookup()
        if (act <= 0)
            return 0
        if this._IsAvg5Mode()
        {
            try
                return this._avgService.GetAverageRunMsForAct(act)
            return 0
        }
        if !IsObject(this._pbService)
            return 0
        try
            return this._pbService.GetRunPbForAct(act)
        return 0
    }

    ; Backwards-compatible alias — the timer-colour path used to
    ; call _GetRunPbMs directly. Now both call _GetTargetMs so the
    ; comparison basis follows cfg.pbDisplayMode.
    _GetRunPbMs() => this._GetTargetMs()

    static _ResolveTimerColor(currentMs, pbMs)
    {
        if (pbMs <= 0 || currentMs <= 0)
            return Theme.Color("text")
        if (currentMs <= pbMs)
            return Theme.Color("goodStrong")
        return Theme.Color("danger")
    }

    ; Full-precision format for the live timer (MM:SS.cc < 1h, else
    ; H:MM:SS — so 1h+ runs don't crop).
    static _FormatMs(ms)
    {
        if (ms < 0)
            ms := 0
        totalSec := Floor(ms / 1000)
        h := Floor(totalSec / 3600)
        m := Floor(Mod(totalSec, 3600) / 60)
        s := Mod(totalSec, 60)
        if (h > 0)
            return Format("{:d}:{:02d}:{:02d}", h, m, s)
        centis := Floor(Mod(ms, 1000) / 10)
        return Format("{:02d}:{:02d}.{:02d}", m, s, centis)
    }

    ; Compact format for PB chips — no centiseconds (PBs are stable
    ; across runs; the cs digits add visual noise without info).
    static _FormatMsShort(ms)
    {
        if (ms < 0)
            ms := 0
        totalSec := Floor(ms / 1000)
        h := Floor(totalSec / 3600)
        m := Floor(Mod(totalSec, 3600) / 60)
        s := Mod(totalSec, 60)
        if (h > 0)
            return Format("{:d}:{:02d}:{:02d}", h, m, s)
        return Format("{:d}:{:02d}", m, s)
    }

    ; Truncation policy: keep font, cut text with trailing "...".
    ; Width estimate uses the chars × fontSize × 0.6 heuristic.
    ; Reserves space for "..." up front so the visible prefix doesn't
    ; have to be re-trimmed after appending the ellipsis. Same
    ; policy as CompactLayoutWidget.
    static _TruncateToWidth(text, fontSize, availW)
    {
        if (text = "" || availW <= 0)
            return ""
        estW := StrLen(text) * fontSize * 0.6
        if (estW <= availW)
            return text
        ellipsisW := 3 * fontSize * 0.6
        targetW := availW - ellipsisW
        if (targetW <= 0)
            return "..."
        maxChars := Floor(targetW / (fontSize * 0.6))
        if (maxChars <= 0)
            return "..."
        return SubStr(text, 1, maxChars) "..."
    }

    Dispose()
    {
        if (this._highFreqTimerFn != "")
        {
            try SetTimer(this._highFreqTimerFn, 0)
            this._highFreqTimerFn := ""
        }

        if (this._handlerTick != "")
        {
            this._bus.Unsubscribe(Events.Tick, this._handlerTick)
            this._handlerTick := ""
        }
        if (this._handlerZoneEntered != "")
        {
            this._bus.Unsubscribe(Events.ZoneEntered, this._handlerZoneEntered)
            this._handlerZoneEntered := ""
        }
        if (this._handlerCharLevelUp != "")
        {
            this._bus.Unsubscribe(Events.CharacterLevelUp, this._handlerCharLevelUp)
            this._handlerCharLevelUp := ""
        }
        if (this._handlerDeathDetected != "")
        {
            this._bus.Unsubscribe(Events.DeathDetected, this._handlerDeathDetected)
            this._handlerDeathDetected := ""
        }
        if (this._handlerRunStarted != "")
        {
            this._bus.Unsubscribe(Events.RunStarted, this._handlerRunStarted)
            this._handlerRunStarted := ""
        }
        if (this._handlerRunReset != "")
        {
            this._bus.Unsubscribe(Events.RunReset, this._handlerRunReset)
            this._handlerRunReset := ""
        }
        if (this._handlerRunCancelled != "")
        {
            this._bus.Unsubscribe(Events.RunCancelled, this._handlerRunCancelled)
            this._handlerRunCancelled := ""
        }
        if (this._handlerPbDisplayMode != "")
        {
            this._bus.Unsubscribe(Events.PbDisplayModeChanged, this._handlerPbDisplayMode)
            this._handlerPbDisplayMode := ""
        }
        if (this._handlerRouteVis != "")
        {
            this._bus.Unsubscribe(Events.RouteVisibilityToggled, this._handlerRouteVis)
            this._handlerRouteVis := ""
        }
    }
}
