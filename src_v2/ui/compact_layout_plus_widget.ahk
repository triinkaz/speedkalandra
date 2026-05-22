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
; DELTAS FROM CLASSIC (spec section 4.1):
;   - Removed: Lv N, LOAD %, TOWN % text chips, Area N
;   - Two ZONE/RUN blocks pushed to the right side of the widget
;     (mirrors Classic's right-aligned timers, see image 1 in the
;     design session). The left column stacks ACT on top of the
;     zone name in two lines (one word per line, first two words
;     only). Each block stacks header + mono timer + PB sub-label.
;   - PB sub-labels show "PB --:--" muted when no PB exists --
;     predictable structure, no surprise gap (spec section 5).
;   - Zone-name truncation by WORDS (first two only, see
;     _SplitToTwoWords). Long single words fall back to the
;     ellipsis truncation from _TruncateToWidth.
;   - Distribution footer is 4 px high without labels (Classic's
;     bar has inline "Map 70%" text). The Plus aesthetic is
;     "fewer words, more visual".
;
; (The ASCII LAYOUT diagram above is approximate -- the actual
; horizontal budget is documented next to the LEFT COLUMN /
; BLOCKS static constants below.)
;
; SUBSCRIPTIONS — same 9 events as Classic. Note that Plus skips
; AreaLevelChanged because the Area chip was removed; Classic
; subscribes because XP indicator updates on area-level changes.
; Plus keeps the subscription anyway: XpService.GetXpPenaltyInfo()
; consults area level, and refreshing the XP chip color on area
; changes keeps it accurate without an extra tick wait.
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
    ;
    ; Vertical budget at base size (FIXED_H=96):
    ;   pad_top(2) + LINE1(14) + gap(6) + BLOCK(50) + gap(4)
    ;     + CHIP(12) + gap(2) + BAR(6) + pad_bottom(0) = 96
    ;
    ; Two design moves bought the visible LINE1→BLOCK and
    ; BLOCK→CHIP gaps the user asked for:
    ;   - FONT_ZONE dropped from 11pt to 10pt, shrinking LINE1
    ;     to h=14 (Segoe UI 10pt fits cleanly).
    ;   - FONT_BLOCK_TIMER dropped from 16pt to 14pt, shrinking
    ;     BLOCK from 54 to 50 without losing the mono-glyph room
    ;     (defensive floor: timerH >= fontTimer+6=20, exact match
    ;     at bh=50).
    ; The 8 px reclaimed pay for: gap LINE1→BLOCK 4→6,
    ; gap BLOCK→CHIP 2→4.
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
    ; The chip→bar gap is implicit (runtime barY = this._h - barH
    ; = 90, chip ends at 88, gap = 2 px).
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
    ; two words of the zone name). Mirrors the Classic Compact
    ; layout's left column — see image 1 in the design discussion.
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
    ; bottom regardless of resize-by-border height.
    ; BAR_H=4 (was 6) to free 2 px for the LINE1→BLOCK gap. The
    ; bar is decorative color-only (no labels) in Plus, so a
    ; thinner footer remains legible.
    static BAR_Y := 92
    static BAR_H := 4

    ; Vendor V1/V2/V3 column (right side) — same dimensions as Classic
    ; so the visual signature is preserved across the toggle.
    static BTN_COL_W    := 22
    static BTN_SIZE     := 18
    static BTN_VGAP     := 3
    static BTN_MARGIN_R := 4

    ; Fonts at scale=1.0.
    ;   FONT_ZONE: 11→10 to free LINE1 vertical pixels for the
    ;     LINE1→BLOCK gap.
    ;   FONT_BLOCK_TIMER: 16→14 to shrink BLOCK from 54 to 50,
    ;     freeing pixels for the BLOCK→CHIP gap. Timer remains
    ;     dominant and legible in the block — 14pt mono Consolas
    ;     is still substantially larger than the surrounding
    ;     UI labels.
    static FONT_ACT     := 9
    static FONT_ZONE    := 10
    static FONT_BLOCK_HEADER := 7
    static FONT_BLOCK_TIMER  := 14   ; mono
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
        actY        := Round(CompactLayoutPlusWidget.ACT_Y * s)
        actH        := Max(8, Round(CompactLayoutPlusWidget.ACT_H * s))
        zoneL1Y     := Round(CompactLayoutPlusWidget.ZONE_NAME_LINE1_Y * s)
        zoneL2Y     := Round(CompactLayoutPlusWidget.ZONE_NAME_LINE2_Y * s)
        zoneLineH   := Max(8, Round(CompactLayoutPlusWidget.ZONE_NAME_LINE_H * s))
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
        actW         := Max(20, Round(CompactLayoutPlusWidget.ACT_W * s))
        zoneNameW    := Max(40, Round(CompactLayoutPlusWidget.ZONE_NAME_W * s))
        nameBlockGap := Max(4, Round(CompactLayoutPlusWidget.NAME_BLOCK_GAP * s))
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
        ; the third word and beyond are dropped (PLUS rule, per
        ; user discussion). A single very long word still falls
        ; back to the existing ellipsis truncation.
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

        ; Start high-freq timer (50ms) — same justification as
        ; Steve Plus: the default Tick rate (300ms) would visibly
        ; stutter centiseconds.
        this._highFreqTimerFn := this._OnHighFreqTimer.Bind(this)
        try SetTimer(this._highFreqTimerFn, CompactLayoutPlusWidget.TIMER_REFRESH_MS)
    }

    ; Builds a single ZONE/RUN block at (bx, by, bw, bh). Controls
    ; stored under "{prefix}_header", "{prefix}_timer", "{prefix}_pb".
    ;
    ; Internal vertical stack (top → bottom):
    ;   pad(2) | header(fontHeader+4) | gap(1) | timer(rest) | gap(2) | pb(fontPb+2) | pad(2)
    ;
    ; PB is anchored to the bottom (PB sub-label has a fixed visual
    ; height proportional to its font), header to the top, and the
    ; timer fills whatever vertical space is left in between. This
    ; avoids the older formula (timerY = bh * 0.30, timerH = fontTimer
    ; + 6) which produced an overlap between timer and PB at bh=42
    ; — the mono timer glyphs were visibly clipped because the
    ; effective bounding box was smaller than the Consolas line
    ; height. Defensive floor at the bottom guarantees the timer
    ; bounding box never shrinks below fontTimer+6 even if a future
    ; smaller BLOCK_H gets introduced.
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
        ; headerY = by + 4 (was by + 2) pushes the "ZONE"/"RUN"
        ; label down inside the block — combined with the 4 px
        ; gap before the block, the visual distance from the
        ; LINE1 text descender to the header is comfortable.
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
        zoneNameW := Max(40, Round(CompactLayoutPlusWidget.ZONE_NAME_W * s))
        fontZone  := Max(7, Round(CompactLayoutPlusWidget.FONT_ZONE * s))

        split := CompactLayoutPlusWidget._SplitToTwoWords(zoneStr)
        line1Text := CompactLayoutPlusWidget._TruncateToWidth(split["line1"], fontZone, zoneNameW)
        line2Text := CompactLayoutPlusWidget._TruncateToWidth(split["line2"], fontZone, zoneNameW)

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

    ; Live-timer format. MM:SS under 1h, H:MM:SS at 1h+. The Plus
    ; Compact widget intentionally drops centiseconds from the live
    ; timer (user feedback in design discussion): the ZONE/RUN blocks
    ; sit next to a static zone-name column on the left, and the
    ; ticking last two digits competed visually with the steady
    ; left-column text. PB sub-labels were already cs-free via
    ; _FormatMsShort — dropping cs from the live timer brings both
    ; rows to the same MM:SS shape so the eye doesn't have to track
    ; a different precision per row.
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
    ; second are dropped — the Compact Plus left column has room
    ; for two stacked lines, one word each, and showing partial
    ; tails ("Strand" of "The Twilight Strand") would clutter the
    ; column without communicating the rest of the name. Empty
    ; input returns two empty strings; single-word input returns
    ; that word as line1 and empty line2 (so the second control
    ; renders blank rather than echoing line1).
    static _SplitToTwoWords(text)
    {
        if (text = "")
            return Map("line1", "", "line2", "")
        parts := StrSplit(text, " ")
        line1 := parts.Length >= 1 ? parts[1] : ""
        line2 := parts.Length >= 2 ? parts[2] : ""
        return Map("line1", line1, "line2", line2)
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
