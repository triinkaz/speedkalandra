; ============================================================
; CompactLayoutWidget — horizontal speedrun overlay (Compact layout)
; ============================================================
;
; Base size 380×96 at scale=1.0; the widget rescales interactively
; via Ctrl+wheel and clamps to [0.5, 3.0] inside WidgetBase.SetScale.
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
; LEFT COLUMN: ACT label on top, zone name in two stacked lines
; (one word per line, first two words only via _SplitToTwoWords).
; A very long single word falls back to ellipsis truncation via
; _TruncateToWidth. The two ZONE/RUN blocks stack header + mono
; timer + PB sub-label and are pushed to the right side of the
; widget, next to the V1/V2/V3 vendor column.
;
; PB SUB-LABELS show "PB --:--" muted when no PB exists -- predictable
; structure, no surprise gap. Distribution footer is 4 px high
; without inline labels (color-only).
;
; SUBSCRIPTIONS — 9 lifecycle/state events plus PbDisplayModeChanged
; (hot-reload of the PB/avg5 mode flag). XpService.GetXpPenaltyInfo()
; consults area level, so refreshing on AreaLevelChanged keeps the
; XP chip color accurate without waiting for the next tick.
;
; PB DISPLAY MODE (cfg.pbDisplayMode):
;   - "pb" (default): "ZONE" / "RUN" sub-labels read "PB MM:SS"
;     and the live-timer colour compares against zone-PB / per-act
;     PB respectively.
;   - "avg5": same sub-labels read "AVG MM:SS"; both timer colours
;     compare against the latest-5-run average (per-zone / per-act).
;     Hot-reloadable via Evt.PbDisplayModeChanged — no restart.
;
; CONSTRUCTION:
;   widget := CompactLayoutWidget(
;       bus, position, onPersist,
;       timer, zoneTracker, xpService,
;       zonesCatalog, loadingTotals, cfg, pbService, avgService)


class CompactLayoutWidget extends LayoutWidgetBase
{
    static WIDGET_ID := "compactLayout"
    static DISPLAY_NAME := "Layout Compact"

    ; Base widget dimensions at scale=1.0.
    static FIXED_W := 380
    static FIXED_H := 96

    ; BASE layout (scale=1.0). _BuildGui multiplies by scale.
    ;
    ; Vertical budget at base size (FIXED_H=96):
    ;   pad_top(2) + LINE1(14) + gap(6) + BLOCK(50) + gap(4)
    ;     + CHIP(12) + gap(2) + BAR(4) + pad_bottom(2) = 96
    ;
    ; Three constraints drive the sizing:
    ;
    ; 1. BLOCK >= 50. With fontTimer=14, the internal stack fits:
    ;    header pad(4) + header(11) + gap(1) + timer(20=floor)
    ;    + gap(2) + pb(10) + pad(2) = 50. Reducing BLOCK below 50
    ;    triggers the defensive floor and overflows into the PB
    ;    strip.
    ;
    ; 2. CHIP >= 12 because AHK Text controls don't auto-clip the
    ;    bounding box to font line height — a control with h=10
    ;    and a font that needs ~12 px of vertical room renders
    ;    the top of each letter and crops the bottom.
    ;
    ; 3. LINE1 = 14 with FONT_ZONE = 10. Segoe UI 10pt has total
    ;    line height ~13 px including ascenders and descenders.
    ;    A box of 14 fits comfortably with 1 px of slack and
    ;    doesn't clip 'p' / 'g' / 'y' / 'q' descenders.
    ;
    ; Known limitation: at scale < ~0.7, the rounded pads drop
    ;    below the threshold AHK needs for non-clipped Windows
    ;    rendering. The widget is designed for scale 0.8-1.5;
    ;    outside that range the layout starts to break visually.
    static MARGIN_X     := 12
    static STRIPE_H     := 3

    ; LEFT COLUMN: ACT label (top) + zone name in two stacked lines.
    ; The ACT label introduces the row at y=ACT_Y; the two zone
    ; lines sit below, one word per line (truncated to the first
    ; two words of the zone name).
    ;
    ; h >= fontPt * 1.6 rule (h is pixels, font is points). Segoe
    ; UI 10pt is ~13 px glyph height + ~3 px descender = ~16 px.
    ; ZONE_NAME_LINE_H=18 + 0x200 (vcenter) gives ~1 px of slack
    ; on each side. ACT_H=16 fits the smaller FONT_ACT=9 the same
    ; way (9 * 1.6 = ~14.4).
    ;
    ; ZONE_NAME_W=92 is the largest left column that leaves room
    ; for both ZONE/RUN blocks + V1/V2/V3 column at scale=1.0:
    ;   MARGIN(12) + ZONE_NAME_W(92) + NAME_BLOCK_GAP(8)
    ; + BLOCK(110) + BLOCK_GAP(14) + BLOCK(110) + MARGIN(12)
    ; + BTN_COL(22) = 380.
    static ACT_Y             := 4
    static ACT_H             := 16
    static ACT_W             := 60       ; wider than "ACT 1" for headroom
    static ZONE_NAME_LINE1_Y := 22
    static ZONE_NAME_LINE2_Y := 44
    static ZONE_NAME_LINE_H  := 18
    static ZONE_NAME_W       := 92
    static NAME_BLOCK_GAP    := 8        ; gap between left column and ZONE block

    ; BLOCKS (ZONE / RUN, pushed right next to the V1/V2/V3 column).
    ; blocksStartX is computed in _BuildGui from the left column
    ; width — keeping the offset dynamic lets the proportion
    ; survive scale changes without a separate static for the X.
    ;
    ; BLOCK_Y=22 vertically aligns the block with the start of the
    ; first zone-name line on the left, so the two halves of the
    ; widget read as a coherent row (ACT + name on the left,
    ; timers on the right).
    static BLOCK_Y      := 22
    static BLOCK_H      := 50
    static BLOCK_W      := 110   ; each block; total = 2 * 110 + gap
    static BLOCK_GAP    := 14

    ; CHIPS (mortes + XP)
    static CHIP_Y       := 76    ; block ends y=72, gap=4 to here
    static CHIP_H       := 12
    static CHIP_DEATHS_W := 40
    static CHIP_XP_W     := 22
    static CHIP_GAP      := 8

    ; FOOTER distribution bar. BAR_Y is informational — _BuildGui
    ; uses runtime `this._h - barH` so the bar always sits at the
    ; bottom of the rendered container. Color-only (no inline
    ; labels), so 4 px is enough to remain legible.
    static BAR_Y := 92
    static BAR_H := 4

    ; Vendor V1/V2/V3 column (right side).
    static BTN_COL_W    := 22
    static BTN_SIZE     := 18
    static BTN_VGAP     := 3
    static BTN_MARGIN_R := 4

    ; Fonts at scale=1.0. FONT_BLOCK_TIMER uses Theme.FONT_MONO
    ; (Consolas) so the digits don't reflow under the 50 ms refresh;
    ; everything else uses Theme.FONT_UI.
    static FONT_ACT     := 9
    static FONT_ZONE    := 10
    static FONT_BLOCK_HEADER := 7
    static FONT_BLOCK_TIMER  := 14   ; mono
    static FONT_BLOCK_PB     := 8
    static FONT_CHIP    := 9
    static FONT_BTN     := 8

    ; High-freq timer refresh (50 ms) — the default Tick rate
    ; (300 ms) would visibly stutter the centiseconds-free MM:SS
    ; display when seconds tick over.
    static TIMER_REFRESH_MS := 50

    ; Services
    _timer         := ""
    _zoneTracker   := ""
    _xp            := ""
    _zonesCatalog  := ""
    _loadingTotals := ""
    _cfg           := ""
    _pbService     := ""
    _avgService    := ""   ; RunAverageService (optional; required for cfg.pbDisplayMode = "avg5")

    ; State
    _currentZone := ""
    _currentAct  := 0
    _deathCount  := 0

    ; Render caches — skip SetFont / Value writes when the value
    ; didn't change tick-to-tick.
    _lastActText         := ""
    _lastZoneLine1Text   := ""
    _lastZoneLine2Text   := ""
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
    _handlerPbDisplayMode  := ""   ; Evt.PbDisplayModeChanged — full refresh on toggle
    _handlerRouteVis       := ""   ; Evt.RouteVisibilityToggled — refreshes the arrow glyph in place

    _highFreqTimerFn := ""

    __New(bus, position, onPersist, timer, zoneTracker, xp,
          zonesCatalog := "", loadingTotals := "", cfg := "", pbService := "",
          avgService := "")
    {
        super.__New(CompactLayoutWidget.WIDGET_ID,
                    CompactLayoutWidget.DISPLAY_NAME,
                    bus, position, onPersist)
        this._timer         := timer
        this._zoneTracker   := zoneTracker
        this._xp            := xp
        this._zonesCatalog  := zonesCatalog
        this._loadingTotals := loadingTotals
        this._cfg           := cfg
        this._pbService     := pbService
        this._avgService    := avgService

        this._handlerTick           := (data) => this._OnTick(data)
        this._handlerZoneEntered    := (data) => this._OnZoneEntered(data)
        this._handlerCharLevelUp    := (data) => this._Refresh()
        this._handlerAreaLevelChg   := (data) => this._Refresh()
        this._handlerRunStarted     := (data) => this._OnRunStateChange()
        this._handlerRunReset       := (data) => this._OnRunStateChange()
        this._handlerRunCancelled   := (data) => this._OnRunStateChange()
        this._handlerDeathDetected  := (data) => this._OnDeathDetected(data)
        this._handlerVendorChanged  := (data) => this._OnVendorRegexesChanged(data)
        this._handlerPbDisplayMode  := (data) => this._OnPbDisplayModeChanged()

        bus.Subscribe(Events.Tick,                  this._handlerTick)
        bus.Subscribe(Events.ZoneEntered,           this._handlerZoneEntered)
        bus.Subscribe(Events.CharacterLevelUp,      this._handlerCharLevelUp)
        bus.Subscribe(Events.AreaLevelChanged,      this._handlerAreaLevelChg)
        bus.Subscribe(Events.DeathDetected,         this._handlerDeathDetected)
        bus.Subscribe(Events.RunStarted,            this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,              this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled,          this._handlerRunCancelled)
        bus.Subscribe(Events.VendorRegexesChanged,  this._handlerVendorChanged)
        bus.Subscribe(Events.PbDisplayModeChanged,  this._handlerPbDisplayMode)

        ; B4 Stage 2: route toggle arrow. Subscribe only when cfg
        ; was wired (opt-in at the composition root).
        if IsObject(cfg)
        {
            this._handlerRouteVis := (data) => this._OnRouteVisibilityToggled(data)
            bus.Subscribe(Events.RouteVisibilityToggled, this._handlerRouteVis)
        }
    }

    _GetFixedSize() => Map("w", CompactLayoutWidget.FIXED_W, "h", CompactLayoutWidget.FIXED_H)

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

        marginX := Max(4, Round(CompactLayoutWidget.MARGIN_X * s))
        stripeH := Max(1, Round(CompactLayoutWidget.STRIPE_H * s))
        btnColW := Round(CompactLayoutWidget.BTN_COL_W * s)
        contentW := w - btnColW

        ; --- Scaled Y/H ---
        actY        := Round(CompactLayoutWidget.ACT_Y * s)
        actH        := Max(8, Round(CompactLayoutWidget.ACT_H * s))
        zoneL1Y     := Round(CompactLayoutWidget.ZONE_NAME_LINE1_Y * s)
        zoneL2Y     := Round(CompactLayoutWidget.ZONE_NAME_LINE2_Y * s)
        zoneLineH   := Max(8, Round(CompactLayoutWidget.ZONE_NAME_LINE_H * s))
        blockY := Round(CompactLayoutWidget.BLOCK_Y * s)
        blockH := Max(20, Round(CompactLayoutWidget.BLOCK_H * s))
        chipY  := Round(CompactLayoutWidget.CHIP_Y * s)
        chipH  := Max(8, Round(CompactLayoutWidget.CHIP_H * s))

        ; Distribution bar pins to the bottom edge of the rendered
        ; container so the footer stays the last (BAR_H × scale) px
        ; regardless of widget height.
        barH := Max(2, Round(CompactLayoutWidget.BAR_H * s))
        barY := h - barH

        ; --- Scaled widths ---
        actW         := Max(20, Round(CompactLayoutWidget.ACT_W * s))
        zoneNameW    := Max(40, Round(CompactLayoutWidget.ZONE_NAME_W * s))
        nameBlockGap := Max(4, Round(CompactLayoutWidget.NAME_BLOCK_GAP * s))
        blockW     := Max(60, Round(CompactLayoutWidget.BLOCK_W * s))
        blockGap   := Max(4, Round(CompactLayoutWidget.BLOCK_GAP * s))
        chipDeathsW := Max(20, Round(CompactLayoutWidget.CHIP_DEATHS_W * s))
        chipXpW     := Max(15, Round(CompactLayoutWidget.CHIP_XP_W * s))
        chipGap     := Max(2, Round(CompactLayoutWidget.CHIP_GAP * s))

        ; --- Scaled fonts ---
        fontAct          := Max(6, Round(CompactLayoutWidget.FONT_ACT * s))
        fontZone         := Max(7, Round(CompactLayoutWidget.FONT_ZONE * s))
        fontBlockHeader  := Max(5, Round(CompactLayoutWidget.FONT_BLOCK_HEADER * s))
        fontBlockTimer   := Max(10, Round(CompactLayoutWidget.FONT_BLOCK_TIMER * s))
        fontBlockPb      := Max(6, Round(CompactLayoutWidget.FONT_BLOCK_PB * s))
        fontChip         := Max(6, Round(CompactLayoutWidget.FONT_CHIP * s))

        ; Background + top accent stripe.
        this._BuildKalandraBand(0, 0, w, h, "surface")
        this._BuildAccentStripe(0, 0, w, stripeH)

        ; ============ LEFT COLUMN: ACT + 2 zone-name lines ============
        ; 0x200 = SS_CENTERIMAGE = vertical center alignment.
        ; Without it, AHK Text controls top-align the glyph, which
        ; clips descenders ('p' in "Encampment") at the bottom edge
        ; if h is close to the font's actual pixel line height.
        ; With 0x200, the glyph centers in the box — any overflow
        ; splits equally top/bottom rather than all-at-the-bottom.
        ;
        ; ACT label in accent color, left-aligned at the top of the
        ; left column.
        wg.SetFont("s" fontAct " c" Theme.Color("accent") " bold", Theme.FONT_UI)
        this._ctrls["line1_act"] := wg.Add("Text",
            "x" marginX " y" actY
            " w" actW " h" actH
            " Left 0x200"
            " Background" Theme.Color("surface"),
            "")

        ; Zone name in two stacked lines (one word per line). The
        ; word split is done in _RefreshLine1 via _SplitToTwoWords;
        ; words after the second are dropped. A single very long
        ; word still falls back to the ellipsis truncation in
        ; _TruncateToWidth.
        this._SetFont(fontZone, "text", "")
        this._ctrls["zone_line1"] := wg.Add("Text",
            "x" marginX " y" zoneL1Y
            " w" zoneNameW " h" zoneLineH
            " Left 0x200"
            " Background" Theme.Color("surface"),
            "")
        this._SetFont(fontZone, "text", "")
        this._ctrls["zone_line2"] := wg.Add("Text",
            "x" marginX " y" zoneL2Y
            " w" zoneNameW " h" zoneLineH
            " Left 0x200"
            " Background" Theme.Color("surface"),
            "")

        ; ============ BLOCKS: ZONE | RUN ============
        ; Two blocks pushed to the right side of the content area
        ; (left of the V1/V2/V3 column). The left column already
        ; occupies marginX..marginX+zoneNameW; the blocks pick up
        ; from there + nameBlockGap. Each block stacks vertically:
        ;   header "ZONE" / "RUN" (subtle, small)
        ;   timer mono (text or conditional color vs PB)
        ;   "PB MM:SS" sub-label (pb color, or "--:--" muted)
        blocksStartX := marginX + zoneNameW + nameBlockGap

        this._BuildBlock("zone", blocksStartX, blockY, blockW, blockH,
            "ZONE", fontBlockHeader, fontBlockTimer, fontBlockPb)
        this._BuildBlock("run", blocksStartX + blockW + blockGap, blockY, blockW, blockH,
            "RUN", fontBlockHeader, fontBlockTimer, fontBlockPb)

        ; ============ CHIPS: × N + XP ============
        ; Both chips use 0x200 (vertical center) — fontChip=9 pt
        ; ≈ 12 px line height + descender, the bounding box at
        ; h=12 is too tight for top-aligned rendering.
        chipX := marginX

        this._SetFont(fontChip, "muted", "bold")
        this._ctrls["chip_deaths"] := wg.Add("Text",
            "x" chipX " y" chipY
            " w" chipDeathsW " h" chipH
            " Left 0x200"
            " Background" Theme.Color("surface"),
            "")
        chipX += chipDeathsW + chipGap

        ; XP chip — fixed "XP" text, dynamic color from XpRules.
        this._SetFont(fontChip, "muted", "bold")
        this._ctrls["chip_xp"] := wg.Add("Text",
            "x" chipX " y" chipY
            " w" chipXpW " h" chipH
            " Left 0x200"
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

        ; B4 Stage 2: route toggle arrow. Sits above V1 in the
        ; V1/V2/V3 column (right edge, top).
        if IsObject(this._cfg)
        {
            btnSize := Max(10, Round(CompactLayoutWidget.BTN_SIZE * s))
            mRight  := Max(1, Round(CompactLayoutWidget.BTN_MARGIN_R * s))
            stripeH := Max(1, Round(CompactLayoutWidget.STRIPE_H * s))
            arrowX  := this._w - mRight - btnSize
            arrowY  := stripeH + Max(1, Round(2 * s))
            this._ctrls["routeArrow"] := RouteToggleArrow.Build(
                wg, this._w, this._h, s,
                this._cfg.routeWidgetVisible,
                Theme.FONT_UI,
                (*) => this._OnRouteArrowClick(),
                arrowX, arrowY)
        }

        ; Initial state resync (handles mid-run widget swap)
        this._ResolveInitialActZone()

        ; Reset caches so first render writes everything.
        this._lastActText        := ""
        this._lastZoneLine1Text  := ""
        this._lastZoneLine2Text  := ""
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

        ; Start high-freq timer (50ms) — the default Tick rate
        ; (300ms) would visibly stutter centiseconds.
        this._highFreqTimerFn := this._OnHighFreqTimer.Bind(this)
        try SetTimer(this._highFreqTimerFn, CompactLayoutWidget.TIMER_REFRESH_MS)
    }

    ; Builds a single ZONE/RUN block at (bx, by, bw, bh). Controls
    ; stored under "{prefix}_header", "{prefix}_timer", "{prefix}_pb".
    ;
    ; Internal vertical stack (top → bottom):
    ;   pad(2) | header(fontHeader+4) | gap(1) | timer(rest) | gap(2) | pb(fontPb+2) | pad(2)
    ;
    ; PB is anchored to the bottom, header to the top, and the
    ; timer fills whatever vertical space is left in between. The
    ; defensive floor `timerH >= fontTimer+6` guarantees the mono
    ; bounding box doesn't shrink below the Consolas line height
    ; even if a future smaller BLOCK_H is introduced.
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

        ; Layout math (see header comment above for the stack).
        ; pbH = fontPb + 2 is the minimum that keeps the PB box
        ; readable at scale 1.0; if the user shrinks below ~0.8
        ; the PB bottom may clip 1 px, accepted limitation.
        headerY := by + 4
        headerH := fontHeader + 4

        pbH := fontPb + 2
        pbY := by + bh - pbH - 2

        timerY := headerY + headerH + 1
        timerH := pbY - timerY - 2
        if (timerH < fontTimer + 6)
            timerH := fontTimer + 6

        ; Header label (top of block, subtle/small).
        ; 0x200 (SS_CENTERIMAGE) centers the glyph vertically in
        ; the box so the font's actual pixel height (fontPt * 1.33)
        ; doesn't clip against the smaller bounding box (fontPt+4).
        wg.SetFont("s" fontHeader " c" Theme.Color("subtle") " bold", Theme.FONT_UI)
        this._ctrls[prefix "_header"] := wg.Add("Text",
            "x" bx " y" headerY
            " w" bw " h" headerH
            " Center 0x200"
            " Background" Theme.Color("surface2"),
            headerText)

        ; Timer (mono, dynamic color set in _Refresh*Timer).
        wg.SetFont("s" fontTimer " c" Theme.Color("text") " bold", Theme.FONT_MONO)
        this._ctrls[prefix "_timer"] := wg.Add("Text",
            "x" bx " y" timerY
            " w" bw " h" timerH
            " Center 0x200"
            " Background" Theme.Color("surface2"),
            "")

        ; PB sub-label (pb color or muted "--:--").
        ; 0x200 prevents descender clipping ('p' in "PB", and the
        ; bottoms of '2'/'3'/'8' in the timer digits) at h=10.
        wg.SetFont("s" fontPb " c" Theme.Color("pb"), Theme.FONT_UI)
        this._ctrls[prefix "_pb"] := wg.Add("Text",
            "x" bx " y" pbY
            " w" bw " h" pbH
            " Center 0x200"
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
        if !this._ctrls.Has("line1_act")
            return
        if !this._ctrls.Has("zone_line1") || !this._ctrls.Has("zone_line2")
            return

        actStr := this._currentAct > 0 ? ("ACT " this._currentAct) : ("ACT " Chr(0x2014))
        if (actStr != this._lastActText)
        {
            try this._ctrls["line1_act"].Value := actStr
            this._lastActText := actStr
        }

        ; Split the zone name by spaces and take the first two
        ; words — "Clearfell Encampment" -> ["Clearfell",
        ; "Encampment"], "The Twilight Strand" -> ["The",
        ; "Twilight"] (Strand dropped). Defensive ellipsis
        ; truncation on each line for the rare case of a very
        ; long single word that exceeds the column width.
        zoneStr := this._currentZone != "" ? this._currentZone : Chr(0x2014)
        s := this._GetScale()
        zoneNameW := Max(40, Round(CompactLayoutWidget.ZONE_NAME_W * s))
        fontZone  := Max(7, Round(CompactLayoutWidget.FONT_ZONE * s))

        split := CompactLayoutWidget._SplitToTwoWords(zoneStr)
        line1Text := CompactLayoutWidget._TruncateToWidth(split["line1"], fontZone, zoneNameW)
        line2Text := CompactLayoutWidget._TruncateToWidth(split["line2"], fontZone, zoneNameW)

        if (line1Text != this._lastZoneLine1Text)
        {
            try this._ctrls["zone_line1"].Value := line1Text
            this._lastZoneLine1Text := line1Text
        }
        if (line2Text != this._lastZoneLine2Text)
        {
            try this._ctrls["zone_line2"].Value := line2Text
            this._lastZoneLine2Text := line2Text
        }
    }

    _RefreshZoneTimer()
    {
        if !this._ctrls.Has("zone_timer")
            return

        zoneMs := IsObject(this._zoneTracker) && this._currentZone != ""
                  ? this._zoneTracker.GetZoneTotalWithActive(this._currentZone)
                  : 0
        text  := CompactLayoutWidget._FormatMs(zoneMs)
        color := CompactLayoutWidget._ResolveTimerColor(zoneMs, this._GetZonePbMs())
        this._WriteTimerCtrl("zone_timer", text, color,
            "_lastZoneTimerText", "_lastZoneTimerColor")
    }

    _RefreshRunTimer()
    {
        if !this._ctrls.Has("run_timer")
            return

        runMs := IsObject(this._timer) ? this._timer.GetRunMs() : 0
        text  := CompactLayoutWidget._FormatMs(runMs)
        color := CompactLayoutWidget._ResolveTimerColor(runMs, this._GetRunPbMs())
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
            fontTimer := Max(10, Round(CompactLayoutWidget.FONT_BLOCK_TIMER * this._GetScale()))
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
    ; "PB --:--" / "AVG --:--" when absent (predictable structure).
    ; Label switches between "PB" and "AVG" based on
    ; cfg.pbDisplayMode — same value formatter either way so the
    ; row width stays stable across modes.
    _WritePbCtrl(ctrlKey, pbMs, cacheText, cacheColor)
    {
        ctrl := this._ctrls[ctrlKey]
        label := this._IsAvg5Mode() ? "AVG" : "PB"
        if (pbMs > 0)
        {
            text  := label . " " . CompactLayoutWidget._FormatMsShort(pbMs)
            color := Theme.Color("pb")
        }
        else
        {
            text  := label . " --:--"
            color := Theme.Color("muted")
        }
        if (color != this.%cacheColor%)
        {
            fontPb := Max(6, Round(CompactLayoutWidget.FONT_BLOCK_PB * this._GetScale()))
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
            fontChip := Max(6, Round(CompactLayoutWidget.FONT_CHIP * this._GetScale()))
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
            fontChip := Max(6, Round(CompactLayoutWidget.FONT_CHIP * this._GetScale()))
            try ctrl.SetFont("s" fontChip " c" color " bold", Theme.FONT_UI)
            this._lastXpColor := color
        }
    }

    ; Distribution bar: color-only, no inline labels. 100 % map
    ; flash before the first transition is suppressed via the
    ; runMs <= 0 guard.
    _RefreshBar()
    {
        if !this._ctrls.Has("bar_map")
            return

        s        := this._GetScale()
        marginX  := Max(4, Round(CompactLayoutWidget.MARGIN_X * s))
        btnColW  := Round(CompactLayoutWidget.BTN_COL_W * s)
        contentW := this._w - btnColW
        barX     := marginX
        barW     := contentW - 2 * marginX
        barH     := Max(2, Round(CompactLayoutWidget.BAR_H * s))
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
    ; Vendor V1/V2/V3 buttons: muted when the slot is filled,
    ; subtle when empty.
    ; ============================================================

    _BuildVendorButtons(s)
    {
        wg      := this._gui
        btnSize := Max(10, Round(CompactLayoutWidget.BTN_SIZE * s))
        vGap    := Max(1, Round(CompactLayoutWidget.BTN_VGAP * s))
        mRight  := Max(1, Round(CompactLayoutWidget.BTN_MARGIN_R * s))
        fontBtn := Max(7, Round(CompactLayoutWidget.FONT_BTN * s))
        stripeH := Max(1, Round(CompactLayoutWidget.STRIPE_H * s))

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
    ; (A_Index inside a Loop would alias).
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
        fontBtn := Max(7, Round(CompactLayoutWidget.FONT_BTN * this._GetScale()))
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

    ; Hot-reload of cfg.pbDisplayMode — see steve_layout_widget for
    ; the rationale. Both timers AND both block sub-labels depend
    ; on the mode, so all four derived caches reset.
    _OnPbDisplayModeChanged()
    {
        this._lastZoneTimerColor := ""
        this._lastRunTimerColor  := ""
        this._lastZonePbText     := ""
        this._lastZonePbColor    := ""
        this._lastRunPbText      := ""
        this._lastRunPbColor     := ""
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
    ; PB lookups.
    ; cfg.pbDisplayMode routes both run-PB and zone-PB queries to
    ; either PersonalBestService ("pb") or RunAverageService
    ; ("avg5"). The legacy method names are preserved; the timer-
    ; colour resolver above doesn't need to change.
    ; ============================================================

    ; True iff cfg.pbDisplayMode = "avg5" AND _avgService is present.
    ; Dual check is defensive: a future caller could construct the
    ; widget without the avg service even with mode=avg5, and the
    ; safer branch is PB (mode literally says "average" but no
    ; average source available means stale data is worse than the
    ; PB fallback).
    _IsAvg5Mode()
    {
        if !IsObject(this._cfg)
            return false
        if !IsObject(this._avgService)
            return false
        return this._cfg.pbDisplayMode = "avg5"
    }

    _GetRunPbMs()
    {
        act := this._currentAct
        if (act <= 0 && IsObject(this._zonesCatalog) && this._currentZone != "")
            act := this._zonesCatalog.GetActOfName(this._currentZone)
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

    _GetZonePbMs()
    {
        if (this._currentZone = "")
            return 0
        if this._IsAvg5Mode()
        {
            try
                return this._avgService.GetAverageZoneMs(this._currentZone)
            return 0
        }
        if !IsObject(this._pbService)
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

    ; Live-timer format. MM:SS under 1h, H:MM:SS at 1h+. The Compact
    ; widget intentionally drops centiseconds from the live timer:
    ; it sits next to a static zone-name column on the left, and
    ; ticking cs digits compete visually with the steady text. PB
    ; sub-labels are already cs-free via _FormatMsShort, so both
    ; rows end up with the same MM:SS shape.
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
        return Format("{:02d}:{:02d}", m, s)
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

    ; Splits a zone name into the first two words. Words after the
    ; second are dropped — the Compact widget's left column has
    ; room for two stacked lines, one word each, and showing
    ; partial tails ("Strand" of "The Twilight Strand") would
    ; clutter the column without communicating the rest of the
    ; name. Empty input returns two empty strings; single-word
    ; input returns that word as line1 and empty line2 (so the
    ; second control renders blank rather than echoing line1).
    static _SplitToTwoWords(text)
    {
        if (text = "")
            return Map("line1", "", "line2", "")
        parts := StrSplit(text, " ")
        line1 := parts.Length >= 1 ? parts[1] : ""
        line2 := parts.Length >= 2 ? parts[2] : ""
        return Map("line1", line1, "line2", line2)
    }

    ; Truncation policy: keep font, cut text with trailing "...".
    ; Width estimate uses the chars × fontSize × 0.6 heuristic.
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
