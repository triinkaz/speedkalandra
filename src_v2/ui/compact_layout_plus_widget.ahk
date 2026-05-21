; ============================================================
; CompactLayoutPlusWidget — Plus variant of the Compact layout
; ============================================================
;
; Opt-in via cfg.layoutVariant = "plus" (Settings > LAYOUTS BETA).
; Shares WIDGET_ID and base dimensions with CompactLayoutWidget so
; the user's persisted position/scale carry across the toggle —
; PLUS_LAYOUTS_SPEC.md §11 anti-regression.
;
; LAYOUT (base 380×96 at scale=1.0):
;
;   +-------------------------------------------------------+
;   | ACT 1  Clearfell                                  [1] |  ← LINE1
;   |                                                   [2] |
;   |        ┌────────┐  ┌────────┐                     [3] |
;   |        │ ZONE   │  │ RUN    │                         |  ← BLOCKS
;   |        │ 00:28  │  │ 03:33  │                         |
;   |        │ PB 28  │  │ PB 333 │                         |
;   |        └────────┘  └────────┘                         |
;   | × 0  XP                                               |  ← CHIPS
;   | ▓▓▓▓▓▓▓▓▓▓▓░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓     |  ← FOOTER 6px
;   +-------------------------------------------------------+
;
; DELTAS FROM CLASSIC (spec §4.1):
;   - Removed: Lv N, LOAD %, TOWN % text chips, Area N
;   - Two centered ZONE/RUN blocks (each: header + mono timer +
;     PB sub-label). Larger than Classic's right-aligned timers
;     because the chip row is sparser (only two chips now).
;   - PB sub-labels show "PB --:--" muted when no PB exists —
;     predictable structure, no surprise gap (spec §5).
;   - Zone-name truncation via "..." (NOT font shrink as in
;     Classic). Spec §6.b.
;   - Distribution footer is 6 px high without labels (Classic's
;     bar has inline "Map 70%" text). The Plus aesthetic is
;     "fewer words, more visual".
;
; SUBSCRIPTIONS — same 9 events as Classic. Note that Plus skips
; AreaLevelChanged because the Area chip was removed; Classic
; subscribes because XP indicator updates on area-level changes.
; Plus keeps the subscription anyway: XpService.GetXpPenaltyInfo()
; consults area level, and refreshing the XP chip color on area
; changes keeps it accurate without an extra tick wait.
;
; RESIZE HOOK:
;   _OnBorderResize(newW, newH) — fired by OverlayInteractionService
;   via the wiring in LayoutWidgetBase.Show (fase 5B). Persists
;   width/height into position and rebuilds the layout. ReRender is
;   heavy (Hide + Show) but keeps the code simple — incremental
;   in-place re-layout would be a future optimization if the live
;   drag stutters on large widgets.
;
; CONSTRUCTION:
;   widget := CompactLayoutPlusWidget(
;       bus, position, onPersist,
;       timer, zoneTracker, xpService,
;       zonesCatalog, loadingTotals, cfg, pbService)


class CompactLayoutPlusWidget extends LayoutWidgetBase
{
    static WIDGET_ID := "compactLayout"
    static DISPLAY_NAME := "Layout Compact+"

    ; BASE size matches Classic so the [Overlay] slot is shared.
    static FIXED_W := 380
    static FIXED_H := 96

    ; BASE layout (scale=1.0). _BuildGui multiplies by scale.
    static MARGIN_X     := 12
    static STRIPE_H     := 3

    ; LINE1: ACT label + zone name
    static LINE1_Y      := 6
    static LINE1_H      := 18
    static ACT_W        := 50    ; "ACT 1"
    static ACT_ZONE_GAP := 6

    ; BLOCKS (ZONE / RUN, centered, side by side)
    static BLOCK_Y      := 26
    static BLOCK_H      := 42
    static BLOCK_W      := 110   ; each block; total = 2 * 110 + gap
    static BLOCK_GAP    := 14
    static BLOCK_HEADER_H := 11  ; "ZONE" / "RUN" label
    static BLOCK_TIMER_H  := 18  ; mono timer
    static BLOCK_PB_H     := 11  ; "PB MM:SS" sub-label

    ; CHIPS (mortes + XP)
    static CHIP_Y       := 70
    static CHIP_H       := 12
    static CHIP_DEATHS_W := 40
    static CHIP_XP_W     := 22
    static CHIP_GAP      := 8

    ; FOOTER distribution bar
    static BAR_Y := 86
    static BAR_H := 6

    ; Vendor V1/V2/V3 column (right side) — same dimensions as Classic
    ; so the visual signature is preserved across the toggle.
    static BTN_COL_W    := 22
    static BTN_SIZE     := 18
    static BTN_VGAP     := 3
    static BTN_MARGIN_R := 4

    ; Fonts at scale=1.0
    static FONT_ACT     := 9
    static FONT_ZONE    := 11
    static FONT_BLOCK_HEADER := 7
    static FONT_BLOCK_TIMER  := 16   ; mono
    static FONT_BLOCK_PB     := 8
    static FONT_CHIP    := 9
    static FONT_BTN     := 8

    ; High-freq timer refresh — same as Steve Plus / Classic.
    static TIMER_REFRESH_MS := 50

    ; Services
    _timer         := ""
    _zoneTracker   := ""
    _xp            := ""
    _zonesCatalog  := ""
    _loadingTotals := ""
    _cfg           := ""
    _pbService     := ""

    ; State
    _currentZone := ""
    _currentAct  := 0
    _deathCount  := 0

    ; Render caches — skip SetFont / Value writes when the value
    ; didn't change tick-to-tick.
    _lastActText        := ""
    _lastZoneText       := ""
    _lastZoneTimerText  := ""
    _lastZoneTimerColor := ""
    _lastZonePbText     := ""
    _lastZonePbColor    := ""
    _lastRunTimerText   := ""
    _lastRunTimerColor  := ""
    _lastRunPbText      := ""
    _lastRunPbColor     := ""
    _lastDeathsText     := ""
    _lastDeathsColor    := ""
    _lastXpColor        := ""
    _lastRenderMs       := 0

    ; Handler refs — kept as fields so Dispose passes the same
    ; closure reference to Unsubscribe.
    _handlerTick           := ""
    _handlerZoneEntered    := ""
    _handlerCharLevelUp    := ""
    _handlerAreaLevelChg   := ""
    _handlerRunStarted     := ""
    _handlerRunReset       := ""
    _handlerRunCancelled   := ""
    _handlerDeathDetected  := ""
    _handlerVendorChanged  := ""

    _highFreqTimerFn := ""

    __New(bus, position, onPersist, timer, zoneTracker, xp,
          zonesCatalog := "", loadingTotals := "", cfg := "", pbService := "")
    {
        super.__New(CompactLayoutPlusWidget.WIDGET_ID,
                    CompactLayoutPlusWidget.DISPLAY_NAME,
                    bus, position, onPersist)
        this._timer         := timer
        this._zoneTracker   := zoneTracker
        this._xp            := xp
        this._zonesCatalog  := zonesCatalog
        this._loadingTotals := loadingTotals
        this._cfg           := cfg
        this._pbService     := pbService

        this._handlerTick           := (data) => this._OnTick(data)
        this._handlerZoneEntered    := (data) => this._OnZoneEntered(data)
        this._handlerCharLevelUp    := (data) => this._Refresh()
        this._handlerAreaLevelChg   := (data) => this._Refresh()
        this._handlerRunStarted     := (data) => this._OnRunStateChange()
        this._handlerRunReset       := (data) => this._OnRunStateChange()
        this._handlerRunCancelled   := (data) => this._OnRunStateChange()
        this._handlerDeathDetected  := (data) => this._OnDeathDetected(data)
        this._handlerVendorChanged  := (data) => this._OnVendorRegexesChanged(data)

        bus.Subscribe(Events.Tick,                  this._handlerTick)
        bus.Subscribe(Events.ZoneEntered,           this._handlerZoneEntered)
        bus.Subscribe(Events.CharacterLevelUp,      this._handlerCharLevelUp)
        bus.Subscribe(Events.AreaLevelChanged,      this._handlerAreaLevelChg)
        bus.Subscribe(Events.DeathDetected,         this._handlerDeathDetected)
        bus.Subscribe(Events.RunStarted,            this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,              this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled,          this._handlerRunCancelled)
        bus.Subscribe(Events.VendorRegexesChanged,  this._handlerVendorChanged)
    }

    _GetFixedSize() => Map("w", CompactLayoutPlusWidget.FIXED_W, "h", CompactLayoutPlusWidget.FIXED_H)

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

        marginX := Max(4, Round(CompactLayoutPlusWidget.MARGIN_X * s))
        stripeH := Max(1, Round(CompactLayoutPlusWidget.STRIPE_H * s))
        btnColW := Round(CompactLayoutPlusWidget.BTN_COL_W * s)
        contentW := w - btnColW

        ; --- Scaled Y/H ---
        line1Y := Round(CompactLayoutPlusWidget.LINE1_Y * s)
        line1H := Max(8, Round(CompactLayoutPlusWidget.LINE1_H * s))
        blockY := Round(CompactLayoutPlusWidget.BLOCK_Y * s)
        blockH := Max(20, Round(CompactLayoutPlusWidget.BLOCK_H * s))
        chipY  := Round(CompactLayoutPlusWidget.CHIP_Y * s)
        chipH  := Max(8, Round(CompactLayoutPlusWidget.CHIP_H * s))

        ; Distribution bar pins to the bottom edge of the rendered
        ; container — same trick as Steve Plus, so the footer stays
        ; the last (BAR_H × scale) px even after a resize-by-border
        ; stretches the widget height.
        barH := Max(2, Round(CompactLayoutPlusWidget.BAR_H * s))
        barY := h - barH

        ; --- Scaled widths ---
        actW       := Max(20, Round(CompactLayoutPlusWidget.ACT_W * s))
        actZoneGap := Max(2, Round(CompactLayoutPlusWidget.ACT_ZONE_GAP * s))
        blockW     := Max(60, Round(CompactLayoutPlusWidget.BLOCK_W * s))
        blockGap   := Max(4, Round(CompactLayoutPlusWidget.BLOCK_GAP * s))
        chipDeathsW := Max(20, Round(CompactLayoutPlusWidget.CHIP_DEATHS_W * s))
        chipXpW     := Max(15, Round(CompactLayoutPlusWidget.CHIP_XP_W * s))
        chipGap     := Max(2, Round(CompactLayoutPlusWidget.CHIP_GAP * s))

        ; --- Scaled fonts ---
        fontAct          := Max(6, Round(CompactLayoutPlusWidget.FONT_ACT * s))
        fontZone         := Max(7, Round(CompactLayoutPlusWidget.FONT_ZONE * s))
        fontBlockHeader  := Max(5, Round(CompactLayoutPlusWidget.FONT_BLOCK_HEADER * s))
        fontBlockTimer   := Max(10, Round(CompactLayoutPlusWidget.FONT_BLOCK_TIMER * s))
        fontBlockPb      := Max(6, Round(CompactLayoutPlusWidget.FONT_BLOCK_PB * s))
        fontChip         := Max(6, Round(CompactLayoutPlusWidget.FONT_CHIP * s))

        ; Background + top accent stripe (shared with Classic).
        this._BuildKalandraBand(0, 0, w, h, "surface")
        this._BuildAccentStripe(0, 0, w, stripeH)

        ; ============ LINE1: ACT + zone ============
        ; ACT label in accent color, left-aligned.
        wg.SetFont("s" fontAct " c" Theme.Color("accent") " bold", Theme.FONT_UI)
        this._ctrls["line1_act"] := wg.Add("Text",
            "x" marginX " y" line1Y
            " w" actW " h" line1H
            " Left"
            " Background" Theme.Color("surface"),
            "")

        ; Zone name — fills remaining space up to the V1/V2/V3 column.
        ; Truncation via "..." in _RefreshLine1 (Plus rule: no shrink).
        zoneX := marginX + actW + actZoneGap
        zoneW := contentW - marginX - actW - actZoneGap - marginX
        if (zoneW < 20)
            zoneW := 20
        this._SetFont(fontZone, "text", "")
        this._ctrls["line1_zone"] := wg.Add("Text",
            "x" zoneX " y" line1Y
            " w" zoneW " h" line1H
            " Left"
            " Background" Theme.Color("surface"),
            "")

        ; ============ BLOCKS: ZONE | RUN ============
        ; Two blocks centered horizontally within the content area
        ; (left of the V1/V2/V3 column). Each block stacks vertically:
        ;   header "ZONE" / "RUN" (subtle, small)
        ;   timer mono (text or conditional color vs PB)
        ;   "PB MM:SS" sub-label (pb color, or "--:--" muted)
        twoBlocksW := 2 * blockW + blockGap
        blocksStartX := Round((contentW - twoBlocksW) / 2)
        if (blocksStartX < marginX)
            blocksStartX := marginX

        this._BuildBlock("zone", blocksStartX, blockY, blockW, blockH,
            "ZONE", fontBlockHeader, fontBlockTimer, fontBlockPb)
        this._BuildBlock("run", blocksStartX + blockW + blockGap, blockY, blockW, blockH,
            "RUN", fontBlockHeader, fontBlockTimer, fontBlockPb)

        ; ============ CHIPS: × N + XP ============
        chipX := marginX

        this._SetFont(fontChip, "muted", "bold")
        this._ctrls["chip_deaths"] := wg.Add("Text",
            "x" chipX " y" chipY
            " w" chipDeathsW " h" chipH
            " Left"
            " Background" Theme.Color("surface"),
            "")
        chipX += chipDeathsW + chipGap

        ; XP chip — fixed "XP" text, dynamic color from XpRules.
        this._SetFont(fontChip, "muted", "bold")
        this._ctrls["chip_xp"] := wg.Add("Text",
            "x" chipX " y" chipY
            " w" chipXpW " h" chipH
            " Left"
            " Background" Theme.Color("surface"),
            "XP")

        ; ============ DISTRIBUTION FOOTER ============
        barX := marginX
        barW := contentW - 2 * marginX

        this._ctrls["bar_bg"] := wg.Add("Progress",
            "x" barX " y" barY " w" barW " h" barH
            " Disabled c" Theme.Color("surface3") " Background" Theme.Color("surface3"),
            100)
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

        ; ============ V1/V2/V3 vendor buttons (right column) ============
        this._BuildVendorButtons(s)

        ; Initial state resync (handles mid-run widget swap)
        this._ResolveInitialActZone()

        ; Reset caches so first render writes everything.
        this._lastActText        := ""
        this._lastZoneText       := ""
        this._lastZoneTimerText  := ""
        this._lastZoneTimerColor := ""
        this._lastZonePbText     := ""
        this._lastZonePbColor    := ""
        this._lastRunTimerText   := ""
        this._lastRunTimerColor  := ""
        this._lastRunPbText      := ""
        this._lastRunPbColor     := ""
        this._lastDeathsText     := ""
        this._lastDeathsColor    := ""
        this._lastXpColor        := ""

        this._Refresh()

        ; Start high-freq timer (50ms) — same justification as
        ; Steve Plus: the default Tick rate (300ms) would visibly
        ; stutter centiseconds.
        this._highFreqTimerFn := this._OnHighFreqTimer.Bind(this)
        try SetTimer(this._highFreqTimerFn, CompactLayoutPlusWidget.TIMER_REFRESH_MS)
    }

    ; Builds a single ZONE/RUN block at (bx, by, bw, bh). Controls
    ; stored under "{prefix}_header", "{prefix}_timer", "{prefix}_pb".
    _BuildBlock(prefix, bx, by, bw, bh, headerText, fontHeader, fontTimer, fontPb)
    {
        wg := this._gui

        ; Block background (subtle surface2 to lift it visually
        ; from the main surface — gives the "boxed" effect from the
        ; mockup without an actual border).
        wg.Add("Progress",
            "x" bx " y" by " w" bw " h" bh
            " Disabled c" Theme.Color("surface2") " Background" Theme.Color("surface2"),
            100)

        ; Header label (top of block, subtle/small).
        headerY := by + 2
        wg.SetFont("s" fontHeader " c" Theme.Color("subtle") " bold", Theme.FONT_UI)
        this._ctrls[prefix "_header"] := wg.Add("Text",
            "x" bx " y" headerY
            " w" bw " h" (fontHeader + 4)
            " Center"
            " Background" Theme.Color("surface2"),
            headerText)

        ; Timer (mono, dynamic color set in _Refresh*Timer).
        ; Block height roughly: header (4-5) + timer (font + 4) + PB
        ; (font + 4) + paddings. Y positions computed from the block's
        ; top so the block re-positions cleanly under resize.
        timerY := by + Round(bh * 0.30)
        timerH := fontTimer + 6
        wg.SetFont("s" fontTimer " c" Theme.Color("text") " bold", Theme.FONT_MONO)
        this._ctrls[prefix "_timer"] := wg.Add("Text",
            "x" bx " y" timerY
            " w" bw " h" timerH
            " Center 0x200"
            " Background" Theme.Color("surface2"),
            "")

        ; PB sub-label (pb color or muted "--:--").
        pbY := by + bh - fontPb - 6
        wg.SetFont("s" fontPb " c" Theme.Color("pb"), Theme.FONT_UI)
        this._ctrls[prefix "_pb"] := wg.Add("Text",
            "x" bx " y" pbY
            " w" bw " h" (fontPb + 4)
            " Center"
            " Background" Theme.Color("surface2"),
            "")
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

    ; 50ms refresh — only the two live timers. Other fields update
    ; on the normal Tick.
    _OnHighFreqTimer()
    {
        if !this._gui
            return
        if !this._modeVisible
            return
        this._RefreshZoneTimer()
        this._RefreshRunTimer()
    }

    _Refresh()
    {
        if !this._gui
            return
        this._RefreshLine1()
        this._RefreshZoneTimer()
        this._RefreshZonePb()
        this._RefreshRunTimer()
        this._RefreshRunPb()
        this._RefreshDeaths()
        this._RefreshXp()
        this._RefreshBar()
    }

    _RefreshLine1()
    {
        if !this._ctrls.Has("line1_act") || !this._ctrls.Has("line1_zone")
            return

        actStr := this._currentAct > 0 ? ("ACT " this._currentAct) : ("ACT " Chr(0x2014))
        if (actStr != this._lastActText)
        {
            try this._ctrls["line1_act"].Value := actStr
            this._lastActText := actStr
        }

        zoneStr := this._currentZone != "" ? this._currentZone : Chr(0x2014)
        ; Plus rule: truncate with "..." instead of shrinking the font
        ; (spec §6.b). _EstimateTextW is the same chars × font × 0.6
        ; estimator Classic uses for its shrink logic; here it drives
        ; truncation.
        s := this._GetScale()
        marginX := Max(4, Round(CompactLayoutPlusWidget.MARGIN_X * s))
        actW    := Max(20, Round(CompactLayoutPlusWidget.ACT_W * s))
        actZoneGap := Max(2, Round(CompactLayoutPlusWidget.ACT_ZONE_GAP * s))
        btnColW := Round(CompactLayoutPlusWidget.BTN_COL_W * s)
        contentW := this._w - btnColW
        zoneAvailW := contentW - marginX - actW - actZoneGap - marginX
        if (zoneAvailW < 20)
            zoneAvailW := 20

        fontZone := Max(7, Round(CompactLayoutPlusWidget.FONT_ZONE * s))
        zoneTruncated := CompactLayoutPlusWidget._TruncateToWidth(zoneStr, fontZone, zoneAvailW)
        if (zoneTruncated != this._lastZoneText)
        {
            try this._ctrls["line1_zone"].Value := zoneTruncated
            this._lastZoneText := zoneTruncated
        }
    }

    _RefreshZoneTimer()
    {
        if !this._ctrls.Has("zone_timer")
            return

        zoneMs := IsObject(this._zoneTracker) && this._currentZone != ""
                  ? this._zoneTracker.GetZoneTotalWithActive(this._currentZone)
                  : 0
        text  := CompactLayoutPlusWidget._FormatMs(zoneMs)
        color := CompactLayoutPlusWidget._ResolveTimerColor(zoneMs, this._GetZonePbMs())
        this._WriteTimerCtrl("zone_timer", text, color,
            "_lastZoneTimerText", "_lastZoneTimerColor")
    }

    _RefreshRunTimer()
    {
        if !this._ctrls.Has("run_timer")
            return

        runMs := IsObject(this._timer) ? this._timer.GetRunMs() : 0
        text  := CompactLayoutPlusWidget._FormatMs(runMs)
        color := CompactLayoutPlusWidget._ResolveTimerColor(runMs, this._GetRunPbMs())
        this._WriteTimerCtrl("run_timer", text, color,
            "_lastRunTimerText", "_lastRunTimerColor")
    }

    ; Shared helper — both block timers share the same SetFont +
    ; Value pattern, the only differences are the ctrl key, the
    ; cache field names, and the color/text inputs.
    _WriteTimerCtrl(ctrlKey, text, color, cacheText, cacheColor)
    {
        ctrl := this._ctrls[ctrlKey]
        if (color != this.%cacheColor%)
        {
            fontTimer := Max(10, Round(CompactLayoutPlusWidget.FONT_BLOCK_TIMER * this._GetScale()))
            try ctrl.SetFont("s" fontTimer " c" color " bold", Theme.FONT_MONO)
            this.%cacheColor% := color
        }
        if (text != this.%cacheText%)
        {
            try ctrl.Value := text
            this.%cacheText% := text
        }
    }

    _RefreshZonePb()
    {
        if !this._ctrls.Has("zone_pb")
            return
        pbMs := this._GetZonePbMs()
        this._WritePbCtrl("zone_pb", pbMs,
            "_lastZonePbText", "_lastZonePbColor")
    }

    _RefreshRunPb()
    {
        if !this._ctrls.Has("run_pb")
            return
        pbMs := this._GetRunPbMs()
        this._WritePbCtrl("run_pb", pbMs,
            "_lastRunPbText", "_lastRunPbColor")
    }

    ; PB sub-label rendering. pb color when value present, muted
    ; "PB --:--" when absent (spec §5: predictable structure).
    _WritePbCtrl(ctrlKey, pbMs, cacheText, cacheColor)
    {
        ctrl := this._ctrls[ctrlKey]
        if (pbMs > 0)
        {
            text  := "PB " CompactLayoutPlusWidget._FormatMsShort(pbMs)
            color := Theme.Color("pb")
        }
        else
        {
            text  := "PB --:--"
            color := Theme.Color("muted")
        }
        if (color != this.%cacheColor%)
        {
            fontPb := Max(6, Round(CompactLayoutPlusWidget.FONT_BLOCK_PB * this._GetScale()))
            try ctrl.SetFont("s" fontPb " c" color, Theme.FONT_UI)
            this.%cacheColor% := color
        }
        if (text != this.%cacheText%)
        {
            try ctrl.Value := text
            this.%cacheText% := text
        }
    }

    _RefreshDeaths()
    {
        if !this._ctrls.Has("chip_deaths")
            return

        n := this._deathCount
        text := Chr(0x2717) " " n
        color := n > 0 ? Theme.Color("warn") : Theme.Color("muted")

        ctrl := this._ctrls["chip_deaths"]
        if (color != this._lastDeathsColor)
        {
            fontChip := Max(6, Round(CompactLayoutPlusWidget.FONT_CHIP * this._GetScale()))
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
        if !this._ctrls.Has("chip_xp") || !IsObject(this._xp)
            return

        info := this._xp.GetXpPenaltyInfo()
        color := info.color

        ctrl := this._ctrls["chip_xp"]
        if (color != this._lastXpColor)
        {
            fontChip := Max(6, Round(CompactLayoutPlusWidget.FONT_CHIP * this._GetScale()))
            try ctrl.SetFont("s" fontChip " c" color " bold", Theme.FONT_UI)
            this._lastXpColor := color
        }
    }

    ; Same math as Compact Classic but no inline labels (footer is
    ; 6 px high — labels wouldn't fit). 100 % map flash before the
    ; first transition is suppressed via the runMs <= 0 guard.
    _RefreshBar()
    {
        if !this._ctrls.Has("bar_map")
            return

        s        := this._GetScale()
        marginX  := Max(4, Round(CompactLayoutPlusWidget.MARGIN_X * s))
        btnColW  := Round(CompactLayoutPlusWidget.BTN_COL_W * s)
        contentW := this._w - btnColW
        barX     := marginX
        barW     := contentW - 2 * marginX
        barH     := Max(2, Round(CompactLayoutPlusWidget.BAR_H * s))
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
    ; Vendor V1/V2/V3 buttons — copied 1:1 from Classic with cfg
    ; injection. Plus aesthetic is the same as Classic: muted when
    ; the slot is filled, subtle when empty.
    ; ============================================================

    _BuildVendorButtons(s)
    {
        wg      := this._gui
        btnSize := Max(10, Round(CompactLayoutPlusWidget.BTN_SIZE * s))
        vGap    := Max(1, Round(CompactLayoutPlusWidget.BTN_VGAP * s))
        mRight  := Max(1, Round(CompactLayoutPlusWidget.BTN_MARGIN_R * s))
        fontBtn := Max(7, Round(CompactLayoutPlusWidget.FONT_BTN * s))
        stripeH := Max(1, Round(CompactLayoutPlusWidget.STRIPE_H * s))

        btnX := this._w - mRight - btnSize
        availH := this._h - stripeH
        totalH := 3 * btnSize + 2 * vGap
        startY := stripeH + Max(0, Round((availH - totalH) / 2))

        Loop 3
        {
            i    := A_Index
            btnY := startY + (i - 1) * (btnSize + vGap)

            val := (IsObject(this._cfg) && IsObject(this._cfg.vendorRegexes)
                    && this._cfg.vendorRegexes.Has(i))
                   ? this._cfg.vendorRegexes[i]
                   : ""
            label := val != "" ? String(i) : Chr(0x00B7)
            color := val != "" ? Theme.Color("muted") : Theme.Color("subtle")

            wg.SetFont("s" fontBtn " c" color " bold", Theme.FONT_UI)
            btn := wg.Add("Text",
                "x" btnX " y" btnY " w" btnSize " h" btnSize
                . " Center 0x200 Background" Theme.Color("surface3"),
                label)
            this._ctrls["vendorBtn" i] := btn
            this._BindVendorButton(btn, i)
        }
    }

    ; Isolated helper so the arrow closure captures slotIdx by value
    ; (same pattern Classic uses; A_Index inside a Loop would alias).
    _BindVendorButton(btn, slotIdx)
    {
        btn.OnEvent("Click", (*) => this._OnVendorClick(slotIdx))
    }

    _OnVendorClick(slotIdx)
    {
        if !IsObject(this._cfg)
            return
        if !IsObject(this._cfg.vendorRegexes)
            return
        if !this._cfg.vendorRegexes.Has(slotIdx)
            return
        regex := this._cfg.vendorRegexes[slotIdx]
        if (regex = "")
        {
            try TrayTip("SpeedKalandra", "Slot V" slotIdx " empty — configure in Settings", "Mute")
            return
        }
        try A_Clipboard := regex
        preview := StrLen(regex) > 30 ? SubStr(regex, 1, 30) "…" : regex
        try TrayTip("SpeedKalandra", "Copied V" slotIdx ": " preview, "Mute")
    }

    _OnVendorRegexesChanged(data)
    {
        if !this._gui
            return
        fontBtn := Max(7, Round(CompactLayoutPlusWidget.FONT_BTN * this._GetScale()))
        Loop 3
        {
            i := A_Index
            ctrlKey := "vendorBtn" i
            if !this._ctrls.Has(ctrlKey)
                continue
            val := (IsObject(this._cfg) && IsObject(this._cfg.vendorRegexes)
                    && this._cfg.vendorRegexes.Has(i))
                   ? this._cfg.vendorRegexes[i]
                   : ""
            label := val != "" ? String(i) : Chr(0x00B7)
            color := val != "" ? Theme.Color("muted") : Theme.Color("subtle")
            try
            {
                ctrl := this._ctrls[ctrlKey]
                ctrl.SetFont("s" fontBtn " c" color " bold", Theme.FONT_UI)
                ctrl.Value := label
            }
        }
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
    ; Resize-by-border (wired by OverlayInteractionService via the
    ; HasMethod check in LayoutWidgetBase.Show). Same body as Steve
    ; Plus: persist width/height, ReRender. ReRender is heavy (Hide+
    ; Show) — fine for the user's occasional drag, would need
    ; in-place re-layout if the gesture stutters.
    ; ============================================================
    _OnBorderResize(newW, newH)
    {
        if (!IsNumber(newW) || !IsNumber(newH))
            return
        if (newW <= 0 || newH <= 0)
            return
        this._position.width  := newW
        this._position.height := newH
        this._Persist()
        this.ReRender()
    }

    ; ============================================================
    ; PB lookups — mirror Classic so the comparison basis is identical.
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

    _GetZonePbMs()
    {
        if !IsObject(this._pbService) || this._currentZone = ""
            return 0
        try
            return this._pbService.GetZonePbMs(this._currentZone)
        return 0
    }

    ; ============================================================
    ; Static pure helpers — color resolution, formatting, truncation.
    ; ============================================================

    static _ResolveTimerColor(currentMs, pbMs)
    {
        if (pbMs <= 0 || currentMs <= 0)
            return Theme.Color("text")
        if (currentMs <= pbMs)
            return Theme.Color("goodStrong")
        return Theme.Color("danger")
    }

    ; Live-timer format. Centiseconds < 1h; H:MM:SS at 1h+ (same
    ; convention as Steve Plus / Classic).
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

    ; PB chip format — no centiseconds (stable values, cs would be
    ; visual noise).
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

    ; Plus-only truncation policy (spec §6.b): keep font, cut text
    ; with trailing "...". Width estimate uses the same chars ×
    ; fontSize × 0.6 heuristic Classic uses for shrink decisions.
    ; Reserves space for "..." up front so the visible prefix doesn't
    ; have to be re-trimmed after appending the ellipsis.
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
        if (this._handlerAreaLevelChg != "")
        {
            this._bus.Unsubscribe(Events.AreaLevelChanged, this._handlerAreaLevelChg)
            this._handlerAreaLevelChg := ""
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
        if (this._handlerDeathDetected != "")
        {
            this._bus.Unsubscribe(Events.DeathDetected, this._handlerDeathDetected)
            this._handlerDeathDetected := ""
        }
        if (this._handlerVendorChanged != "")
        {
            this._bus.Unsubscribe(Events.VendorRegexesChanged, this._handlerVendorChanged)
            this._handlerVendorChanged := ""
        }
    }
}
