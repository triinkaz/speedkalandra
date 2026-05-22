; ============================================================
; SteveLayoutPlusWidget — Plus variant of the Steve layout
; ============================================================
;
; Opt-in via cfg.layoutVariant = "plus" (Settings > LAYOUTS BETA).
; Shares WIDGET_ID and base dimensions with SteveLayoutWidget so
; both variants persist into the same [Overlay] entry — the user's
; positioning, scale, and (in the future) custom width/height
; carry across a Classic↔Plus flip without a manual move.
;
; LAYOUT (base 380×64 at scale=1.0):
;
;   +-------------------------------------------------------+
;   | Act 1 · The Riverbank              02:31.234         |  ← LINE1
;   | ✗ 3   XP   PB 2:15           RUN · PB 4:23           |  ← LINE2
;   | [Map][Loading][Town]                                 |  ← 4px footer
;   +-------------------------------------------------------+
;
; The right-side timer is monospaced (Theme.FONT_MONO) so the
; digits don't shimmy under the per-50ms refresh — proportional
; fonts shift the colon-second alignment every other frame.
;
; DELTAS FROM CLASSIC:
;   - Adds a per-act PB chip on LINE2 ("PB MM:SS"), reading
;     pbService.GetRunPbForAct(currentAct) — same path Classic
;     already uses for the timer's color comparison.
;   - Adds a RUN · PB sublabel showing the FULL run PB (the same
;     value chained PBs converge to), so the user can see both
;     act-PB and run-PB without toggling layouts.
;   - 4 px distribution footer (no labels) using the colors from
;     theme aliases map/loading/town.
;   - Re-injects loadingTotals (needed for the distribution footer)
;     and cfg (plumbed for future Plus-only settings).
;
; CONSTRUCTION:
;   widget := SteveLayoutPlusWidget(
;       bus, position, onPersist,
;       timer, zoneTracker, xpService,
;       zonesCatalog, pbService, loadingTotals, cfg)


class SteveLayoutPlusWidget extends LayoutWidgetBase
{
    ; WIDGET_ID matches Classic so both variants share the same
    ; [Overlay] entry. OverlayLayout / OverlayModeApplier treat the
    ; ID as the slot, not the implementation, so toggling
    ; layoutVariant doesn't orphan a position.
    static WIDGET_ID := "steveLayout"
    static DISPLAY_NAME := "Layout Steve+"

    ; BASE size (scale=1.0). Identical to Classic so the user's
    ; positioning is preserved across the toggle.
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

    ; LINE2: chips (left) + RUN · PB sublabel (right)
    static LINE2_Y       := 36
    static LINE2_H       := 16
    static CHIP_DEATHS_W := 36
    static CHIP_XP_W     := 22
    static CHIP_PB_W     := 80
    static CHIP_GAP      := 6
    static RUN_PB_W      := 110

    ; Distribution footer
    static BAR_Y := 56
    static BAR_H := 4

    ; BASE fonts (scale=1.0). Timer is in Theme.FONT_MONO (Consolas)
    ; so the digits don't reflow under the 50ms refresh.
    static FONT_ACT_ZONE := 9
    static FONT_TIMER    := 22    ; smaller than Classic's 28 because
                                  ; mono is wider per char and we
                                  ; cap timer width at TIMER_W
    static FONT_CHIP     := 8
    static FONT_RUN_PB   := 8

    ; High-frequency timer refresh — same as Classic, kept inline
    ; (the SetTimer pattern doesn't generalize well into the base).
    static TIMER_REFRESH_MS := 50

    ; Services
    _timer         := ""
    _zoneTracker   := ""
    _xp            := ""
    _zonesCatalog  := ""
    _pbService     := ""
    _loadingTotals := ""
    _cfg           := ""

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
    _lastActPbText      := ""
    _lastRunPbText      := ""
    _lastRenderMs       := 0

    ; Handler refs — same pattern as Classic, kept as fields so
    ; Dispose's Unsubscribe references the same closure.
    _handlerTick           := ""
    _handlerZoneEntered    := ""
    _handlerCharLevelUp    := ""
    _handlerDeathDetected  := ""
    _handlerRunStarted     := ""
    _handlerRunReset       := ""
    _handlerRunCancelled   := ""

    _highFreqTimerFn := ""

    __New(bus, position, onPersist, timer, zoneTracker, xp,
          zonesCatalog := "", pbService := "", loadingTotals := "", cfg := "")
    {
        super.__New(SteveLayoutPlusWidget.WIDGET_ID,
                    SteveLayoutPlusWidget.DISPLAY_NAME,
                    bus, position, onPersist)
        this._timer         := timer
        this._zoneTracker   := zoneTracker
        this._xp            := xp
        this._zonesCatalog  := zonesCatalog
        this._pbService     := pbService
        this._loadingTotals := loadingTotals
        this._cfg           := cfg

        this._handlerTick           := (data) => this._OnTick(data)
        this._handlerZoneEntered    := (data) => this._OnZoneEntered(data)
        this._handlerCharLevelUp    := (data) => this._Refresh()
        this._handlerDeathDetected  := (data) => this._OnDeathDetected(data)
        this._handlerRunStarted     := (data) => this._OnRunStateChange()
        this._handlerRunReset       := (data) => this._OnRunStateChange()
        this._handlerRunCancelled   := (data) => this._OnRunStateChange()

        bus.Subscribe(Events.Tick,             this._handlerTick)
        bus.Subscribe(Events.ZoneEntered,      this._handlerZoneEntered)
        bus.Subscribe(Events.CharacterLevelUp, this._handlerCharLevelUp)
        bus.Subscribe(Events.DeathDetected,    this._handlerDeathDetected)
        bus.Subscribe(Events.RunStarted,       this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,         this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled,     this._handlerRunCancelled)
    }

    _GetFixedSize() => Map("w", SteveLayoutPlusWidget.FIXED_W, "h", SteveLayoutPlusWidget.FIXED_H)

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
        marginX := Max(4, Round(SteveLayoutPlusWidget.MARGIN_X * s))
        stripeH := Max(1, Round(SteveLayoutPlusWidget.STRIPE_H * s))
        timerW  := Max(80, Round(SteveLayoutPlusWidget.TIMER_W * s))
        chipGap := Max(2, Round(SteveLayoutPlusWidget.CHIP_GAP * s))

        line1Y := Round(SteveLayoutPlusWidget.LINE1_Y * s)
        line1H := Round(SteveLayoutPlusWidget.LINE1_H * s)
        line2Y := Round(SteveLayoutPlusWidget.LINE2_Y * s)
        line2H := Round(SteveLayoutPlusWidget.LINE2_H * s)

        chipDeathsW := Round(SteveLayoutPlusWidget.CHIP_DEATHS_W * s)
        chipXpW     := Round(SteveLayoutPlusWidget.CHIP_XP_W * s)
        chipPbW     := Round(SteveLayoutPlusWidget.CHIP_PB_W * s)
        runPbW      := Round(SteveLayoutPlusWidget.RUN_PB_W * s)

        ; Distribution footer pins to the bottom edge of the rendered
        ; container.
        barH := Max(2, Round(SteveLayoutPlusWidget.BAR_H * s))
        barY := h - barH

        fontActZone := Max(7, Round(SteveLayoutPlusWidget.FONT_ACT_ZONE * s))
        fontTimer   := Max(12, Round(SteveLayoutPlusWidget.FONT_TIMER * s))
        fontChip    := Max(6, Round(SteveLayoutPlusWidget.FONT_CHIP * s))
        fontRunPb   := Max(6, Round(SteveLayoutPlusWidget.FONT_RUN_PB * s))

        ; Background + top accent stripe (shared visual signature
        ; with Compact/Classic).
        this._BuildKalandraBand(0, 0, w, h, "surface")
        this._BuildAccentStripe(0, 0, w, stripeH)

        contentX := marginX

        ; ============ LINE 1: act+zone (left) | mono timer (right) ============
        actZoneW := w - contentX - marginX - timerW - SteveLayoutPlusWidget.ACT_ZONE_GAP
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

        ; Death chip — same convention as Classic: muted at 0,
        ; warn (amber) when >= 1.
        this._SetFont(fontChip, "muted", "bold")
        this._ctrls["line2_deaths"] := wg.Add("Text",
            "x" x " y" line2Y
            " w" chipDeathsW " h" line2H
            " Left"
            " Background" Theme.Color("surface"),
            "")
        x += chipDeathsW + chipGap

        ; XP chip — fixed "XP" label, dynamic color from XpRules
        ; (same as Compact/Classic).
        this._SetFont(fontChip, "muted", "bold")
        this._ctrls["line2_xp"] := wg.Add("Text",
            "x" x " y" line2Y
            " w" chipXpW " h" line2H
            " Left"
            " Background" Theme.Color("surface"),
            "XP")
        x += chipXpW + chipGap

        ; PB chip — current act's PB ("PB MM:SS"), teal color so it
        ; doesn't share the green/red palette used by the live timer.
        wg.SetFont("s" fontChip " c" Theme.Color("pb") " bold", Theme.FONT_UI)
        this._ctrls["line2_act_pb"] := wg.Add("Text",
            "x" x " y" line2Y
            " w" chipPbW " h" line2H
            " Left"
            " Background" Theme.Color("surface"),
            "")

        ; RUN · PB sublabel — right-aligned, teal. Shows the FULL
        ; run PB (currently the same as act-N PB because PBs are
        ; per-act only; placeholder for a future overall-run PB).
        runPbX := w - marginX - runPbW
        wg.SetFont("s" fontRunPb " c" Theme.Color("pb"), Theme.FONT_UI)
        this._ctrls["line2_run_pb"] := wg.Add("Text",
            "x" runPbX " y" line2Y
            " w" runPbW " h" line2H
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
        this._lastActPbText   := ""
        this._lastRunPbText   := ""

        this._Refresh()

        ; Start high-freq timer (50 ms). Without this the timer
        ; centiseconds visibly stutter on the default Tick rate
        ; (300 ms).
        this._highFreqTimerFn := this._OnHighFreqTimer.Bind(this)
        try SetTimer(this._highFreqTimerFn, SteveLayoutPlusWidget.TIMER_REFRESH_MS)
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
        this._RefreshActPb()
        this._RefreshRunPb()
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
        marginX    := Max(4, Round(SteveLayoutPlusWidget.MARGIN_X * s))
        timerW     := Max(80, Round(SteveLayoutPlusWidget.TIMER_W * s))
        actZoneGap := Max(2, Round(SteveLayoutPlusWidget.ACT_ZONE_GAP * s))
        actZoneW   := this._w - marginX - marginX - timerW - actZoneGap
        if (actZoneW < 40)
            actZoneW := 40
        fontActZone := Max(7, Round(SteveLayoutPlusWidget.FONT_ACT_ZONE * s))
        text := SteveLayoutPlusWidget._TruncateToWidth(text, fontActZone, actZoneW)

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
        text := SteveLayoutPlusWidget._FormatMs(runMs)

        pbMs := this._GetRunPbMs()
        color := SteveLayoutPlusWidget._ResolveTimerColor(runMs, pbMs)

        ctrl := this._ctrls["line1_timer"]

        if (color != this._lastTimerColor)
        {
            fontTimer := Max(12, Round(SteveLayoutPlusWidget.FONT_TIMER * this._GetScale()))
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
            fontChip := Max(6, Round(SteveLayoutPlusWidget.FONT_CHIP * this._GetScale()))
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
            fontChip := Max(6, Round(SteveLayoutPlusWidget.FONT_CHIP * this._GetScale()))
            try ctrl.SetFont("s" fontChip " c" color " bold", Theme.FONT_UI)
            this._lastXpColor := color
        }
    }

    _RefreshActPb()
    {
        if !this._ctrls.Has("line2_act_pb")
            return

        pbMs := this._GetRunPbMs()
        text := pbMs > 0 ? ("PB " SteveLayoutPlusWidget._FormatMsShort(pbMs)) : "PB " Chr(0x2014)

        if (text != this._lastActPbText)
        {
            try this._ctrls["line2_act_pb"].Value := text
            this._lastActPbText := text
        }
    }

    _RefreshRunPb()
    {
        if !this._ctrls.Has("line2_run_pb")
            return

        ; Currently maps to the same per-act PB the chip shows; kept
        ; as a separate method so a future "overall run PB" surface
        ; only changes _GetOverallRunPbMs().
        pbMs := this._GetRunPbMs()
        text := pbMs > 0
            ? ("RUN " Chr(0x00B7) " PB " SteveLayoutPlusWidget._FormatMsShort(pbMs))
            : ("RUN " Chr(0x00B7) " PB " Chr(0x2014))

        if (text != this._lastRunPbText)
        {
            try this._ctrls["line2_run_pb"].Value := text
            this._lastRunPbText := text
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
        marginX  := Max(4, Round(SteveLayoutPlusWidget.MARGIN_X * s))
        barX     := marginX
        barW     := this._w - 2 * marginX
        barH     := Max(2, Round(SteveLayoutPlusWidget.BAR_H * s))
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
    ; Helpers — PB lookup mirrors Classic exactly so the comparison
    ; basis stays identical between Steve variants.
    ; ============================================================

    _GetRunPbMs()
    {
        if !IsObject(this._pbService)
            return 0
        act := this._currentAct
        if (act <= 0 && IsObject(this._zonesCatalog) && this._currentZone != "")
            act := this._zonesCatalog.GetActOfName(this._currentZone)
        if (act <= 0)
            return 0
        try
            return this._pbService.GetRunPbForAct(act)
        return 0
    }

    static _ResolveTimerColor(currentMs, pbMs)
    {
        if (pbMs <= 0 || currentMs <= 0)
            return Theme.Color("text")
        if (currentMs <= pbMs)
            return Theme.Color("goodStrong")
        return Theme.Color("danger")
    }

    ; Full-precision format for the live timer (MM:SS.cc < 1h, else
    ; H:MM:SS — same as Classic so 1h+ runs don't crop).
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

    ; Plus-only truncation policy (spec section 6.b): keep font, cut
    ; text with trailing "...". Width estimate uses the same chars
    ; x fontSize x 0.6 heuristic Classic uses for shrink decisions.
    ; Reserves space for "..." up front so the visible prefix doesn't
    ; have to be re-trimmed after appending the ellipsis. Ported from
    ; CompactLayoutPlusWidget to keep both widgets on the same
    ; truncation policy.
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
    }
}
