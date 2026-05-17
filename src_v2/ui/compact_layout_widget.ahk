; ============================================================
; CompactLayoutWidget - horizontal speedrun bar (Wave 4)
; ============================================================
;
; Fully replaces the legacy (which had 8 bands + integrated bossfight
; widget, depended on campaign/step/buffs/syncEngine).
;
; POST-DEMOLITION VERSION: minimalist, focused on pure speedrun.
;
; BASE LAYOUT (380x96 at scale=1.0):
;
;   +-------------------------------------------+
;   | [accent stripe 3px]                       |
;   | LINE 1 (3 zones): Act 1 ·  Zone  · 00:00 / 00:00 |
;   | LINE 2 (3 zones): ✗ 2   | XP  | PB 00:00 / 00:00  |
;   | LINE 3 (stacked bar): [Map][Load][Town]   |
;   +-------------------------------------------+
;
;   LINE 1 zone layout (v17.5 — used to be a single text):
;     - act    (left fixed):     "Act X ·"  font FONT_LINE1
;     - zone   (center variable): zone name with DYNAMIC font
;                                  (shrinks if it doesn't fit)
;     - zone_timer  (right-middle): "·  MM:SS"   dynamic color based on zone PB
;     - run_timer   (right-end):    "/  MM:SS"   dynamic color based on run PB
;
;   When the map name is long, the zone font shrinks iteratively
;   until it fits the available space (instead of pushing the timers
;   right or truncating text).
;
;   LINE 2 zone layout:
;     - Zone 1 (~left quarter):  "✗ N" current-run death counter
;                                 (color muted=gray when 0, warn=amber when >=1).
;                                 Resets on RunStarted/Reset/Cancelled.
;                                 v17.13: replaced the "Lv X · Area Y" display.
;     - Zone 2 (~center quarter): "XP" (fixed text, dynamic color via
;                                 XpRules — green/amber/red/gray)
;     - Zone 3 (right half):      "PB MM:SS / MM:SS" (soft lavender color
;                                 to differentiate from other indicators;
;                                 first = zone PB, second = run PB)
;
; PERSONAL BESTS (v17.13):
;   The 2 LINE 1 timers change color based on comparison to PB:
;     current_timer <= PB → good (desaturated green)
;     current_timer >  PB → danger (desaturated red)
;     PB absent           → text (white)
;
;   PBs are maintained by PersonalBestService (loaded from INI on
;   startup, updated on RunCompleted by the composition root).
;
;   RUN PB PER ACT (v17.13):
;     The Run timer now compares against the CURRENT ACT's PB, not
;     a global PB. Each act has its own PB (total run time at the
;     moment that act ended). When the user changes acts mid-run,
;     the overlay automatically compares to the new act's PB — the
;     timer may change color right then.
;
;     PB DISPLAY (line2_pb): "PB ZONE_PB / ACT_PB" — second number is
;     the current act's PB (not a global PB).
;
;   FIRST TIMER ON LINE 1 = TOTAL time in the active zone during the
;   run (sum of all visits + current elapsed). NOT time since the
;   last entry — that would show 00:00 every time the pause detection
;   pauses/unpauses (each cycle zeroes _startMs internally). Uses
;   GetZoneTotalWithActive() for robustness.
;
;   Base width 380 (v17.4, was 500): user resizes via Ctrl+wheel if
;   they need more width. Long zones get reduced font automatically.
;
; XP INDICATOR (v17.3):
;   xp_indicator is a fixed "XP" Text control whose COLOR changes
;   based on the status computed by XpRules. Text always "XP" —
;   does not show the textual status (OK/LIMIT/PENALTY/?) as a UX
;   preference.
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
; GREEN BOSS DEFEATED (REMOVED in v17.13):
;   Boss timer feature was removed (class voice lines did not go to
;   PoE2's Client.txt, so detection was unfeasible for most bosses).
;
; SCALE:
;   The ENTIRE widget scales by `_position.scale` (interactive via
;   Ctrl+wheel over the widget). _w/_h come from
;   LayoutWidgetBase.Show() already scaled, and _BuildGui propagates
;   the scale into all internal dimensions (margins, line positions,
;   font sizes, stacked bar thresholds).
;
;   Limits: [0.5, 3.0] (clamped in WidgetBase.SetScale).
;
;   STACKED BAR (legacy PerfWidget parity):
;     mapaMs   = max(0, runMs - loadingMs - townMs)
;     mapaPct  = 100 - loadPct - townPct    (ensures sum = 100)
;     Colors: Map blue, Loading yellow, Town purple.
;     Inline text (label + %) only when the segment is >= minLabelW
;     of scaled width (~70px at scale 1.0).
;
; SUBSCRIPTIONS:
;   Events.Tick               -> refresh (300ms typical)
;   Events.ZoneEntered        -> updates zone + act
;   Events.CharacterLevelUp   -> refresh (affects XP indicator)
;   Events.AreaLevelChanged   -> refresh (affects XP indicator)
;   Events.DeathDetected      -> increments death counter (v17.13)
;   Events.RunStarted         -> resets death counter (v17.13)
;   Events.RunReset/Cancelled -> resets counter + returns to empty state
;
; DEPENDENCIES:
;   timer         : TimerService    -> GetRunMs()
;   zoneTracker   : ZoneTrackingService -> GetActiveZone(), GetZoneTotalWithActive(),
;                                           GetTotalTownMs()
;   xp            : XpService       -> GetCharacterLevel(), GetCurrentAreaLevel(),
;                                       GetXpPenaltyInfo()
;   zonesCatalog  : ZonesCatalog (optional) -> maps zone -> act
;   loadingTotals : LoadingTotalsService (optional) -> GetTotalMs() for the stacked bar
;   cfg           : AppSettings (optional) -> vendorRegexes
;   pbService     : PersonalBestService (optional) -> GetRunPbMs(), GetZonePbMs()
;
; CONSTRUCTION:
;   widget := CompactLayoutWidget(bus, position, onPersist,
;                                 timer, zoneTracker, xp,
;                                 zonesCatalog, loadingTotals, cfg,
;                                 pbService)

class CompactLayoutWidget extends LayoutWidgetBase
{
    static WIDGET_ID := "compactLayout"
    static DISPLAY_NAME := "Layout Compact"

    ; BASE dimensions (scale=1.0). Show() applies scale on top.
    static FIXED_W := 380
    static FIXED_H := 96

    ; BASE layout (scale=1.0). _BuildGui multiplies by scale at runtime.
    static MARGIN_X := 12
    static STRIPE_H := 3
    static LINE1_Y  := 10
    static LINE1_H  := 28
    static LINE2_Y  := 42
    static LINE2_H  := 20
    static BAR_Y    := 68
    static BAR_H    := 18

    ; Vendor clipboard buttons (v17.12): 3 discreet squares on the
    ; RIGHT SIDE, stacked vertically and centered vertically. Click
    ; (with Ctrl active) copies cfg.vendorRegexes[i] to A_Clipboard.
    ;
    ; The column takes up BTN_COL_W px on the right side; the main
    ; content (LINE 1/2/3) is re-width-computed for contentW = w - BTN_COL_W.
    ; The surface band and the accent stripe still use full w — the
    ; buttons visually sit "inside" the widget, with bg surface3 over
    ; surface.
    static BTN_COL_W      := 22    ; side-column width (btn + right margin)
    static BTN_SIZE       := 18    ; square side
    static BTN_VGAP       := 3     ; vertical gap between buttons
    static BTN_MARGIN_R   := 4     ; margin between button and right edge of widget

    ; LINE 1 zone widths (v17.5) — BASE at scale=1.0
    ; Reserves fixed space for "Act X ·" (left) and timers (right).
    ; Zone occupies what remains between them and has a dynamic font.
    ; In v17.13 the timer block was SPLIT into zone_timer + run_timer
    ; to have independent PB-based colors. LINE1_TIMER_W is the sum.
    static LINE1_ACT_W        := 60    ; "Act 1 ·"  to "Act 99 ·"
    static LINE1_ZONE_TIMER_W := 80    ; "·  MM:SS"  to "·  1:23:45"
    static LINE1_RUN_TIMER_W  := 70    ; "/  MM:SS"  to "/  1:23:45"
    static LINE1_TIMER_W      := 150   ; sum of the two — kept for legacy calcs

    ; BASE font sizes (scaled by _position.scale at runtime)
    ; FONT_LINE1 reduced from 13 -> 11 in v17.13 to avoid overlap
    ; between long zone label and the 2 separate timers (zone_timer +
    ; run_timer).
    static FONT_LINE1 := 11
    static FONT_LINE2 := 9
    static FONT_BAR   := 8
    static FONT_BTN   := 8    ; v17.12: size of the 1/2/3 labels on the side squares

    ; Minimum font size for the zone name (after shrinking). At scale=1.0,
    ; font 7 is still readable. Smaller than that becomes illegible —
    ; better to truncate than to read.
    static FONT_ZONE_MIN := 7

    ; BASE thresholds for the stacked bar label (at scale=1.0).
    static LABEL_MIN_W      := 70    ; >= this: shows "Map 70%"
    static LABEL_MIN_PCT_W  := 30    ; >= this: shows "70%" only

    ; Stacked bar colors (parity with RunStatsPlotBuilder.SegmentDefinitions)
    static COLOR_MAPA    := "38BDF8"    ; blue
    static COLOR_LOADING := "FACC15"    ; yellow
    static COLOR_CIDADE  := "A78BFA"    ; purple

    ; Color of the PB display (LINE 2 zone 3). Teal-400 (v17.13c) — pink
    ; F472B6 still shared a blue-violet component with the "Town" color
    ; (A78BFA, violet-400), looking similar on some monitors. Teal
    ; completely escapes that spectrum: green-blue, distinct from
    ; everything in the palette:
    ;   - 2DD4BF (R:45 G:212 B:191) - teal
    ;   - A78BFA (R:167 G:139 B:250) - violet town
    ;   - 38BDF8 (R:56 G:189 B:248) - sky map
    ;   - 4ADE80 (R:74 G:222 B:128) - green goodStrong
    ;   - FACC15 (R:250 G:204 B:21) - yellow loading
    static PB_COLOR := "2DD4BF"

    ; --- Deps ---
    _timer         := ""
    _zoneTracker   := ""
    _xp            := ""
    _zonesCatalog  := ""
    _loadingTotals := ""
    _cfg           := ""    ; AppSettings (Wave 8 — used by the V1/V2/V3 buttons)
    _pbService     := ""    ; PersonalBestService (v17.13)

    ; State cache for render
    _currentZone     := ""
    _currentAct      := 0
    _deathCount      := 0    ; v17.13 — current-run death counter
    _lastRenderMs    := 0
    _lastXpColor     := ""   ; to avoid unnecessary SetFont (perf)
    _lastZoneTimerColor := ""   ; idem for line1_zone_timer
    _lastRunTimerColor  := ""   ; idem for line1_run_timer
    _lastDeathColor  := ""   ; idem for line2_left (death counter)
    _lastPbText      := ""   ; cache of PB text to avoid repaint
    _lastZoneFontSize := 0   ; idem for the dynamic line1_zone font
    _lastZoneText    := ""   ; cache of zone text to avoid recompute

    ; Handler refs (Section 17.32)
    _handlerTick           := ""
    _handlerZoneEntered    := ""
    _handlerCharLevelUp    := ""
    _handlerAreaLevelChg   := ""
    _handlerRunStarted     := ""   ; v17.13
    _handlerRunReset       := ""
    _handlerRunCancelled   := ""
    _handlerDeathDetected  := ""   ; v17.13

    __New(bus, position, onPersist, timer, zoneTracker, xp, zonesCatalog := "", loadingTotals := "", cfg := "", pbService := "")
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

        ; Subscribes
        this._handlerTick           := (data) => this._OnTick(data)
        this._handlerZoneEntered    := (data) => this._OnZoneEntered(data)
        this._handlerCharLevelUp    := (data) => this._Refresh()
        this._handlerAreaLevelChg   := (data) => this._Refresh()
        this._handlerRunStarted     := (data) => this._OnRunRestart(data)
        this._handlerRunReset       := (data) => this._OnRunRestart(data)
        this._handlerRunCancelled   := (data) => this._OnRunRestart(data)
        this._handlerDeathDetected  := (data) => this._OnDeathDetected(data)

        bus.Subscribe(Events.Tick,              this._handlerTick)
        bus.Subscribe(Events.ZoneEntered,       this._handlerZoneEntered)
        bus.Subscribe(Events.CharacterLevelUp,  this._handlerCharLevelUp)
        bus.Subscribe(Events.AreaLevelChanged,  this._handlerAreaLevelChg)
        bus.Subscribe(Events.RunStarted,        this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,          this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled,      this._handlerRunCancelled)
        bus.Subscribe(Events.DeathDetected,     this._handlerDeathDetected)
    }

    _GetFixedSize() => Map("w", CompactLayoutWidget.FIXED_W, "h", CompactLayoutWidget.FIXED_H)

    ; ============================================================
    ; _GetScale - reads current scale, with defensive fallback
    ; ============================================================
    _GetScale()
    {
        s := this._position.scale
        if (!IsNumber(s) || s <= 0)
            return 1.0
        return s
    }

    ; ============================================================
    ; _BuildGui - builds controls applying scale
    ; ============================================================
    _BuildGui()
    {
        wg := this._gui
        w  := this._w           ; already scaled by Show()
        h  := this._h
        s  := this._GetScale()

        ; --- Scaled dimensions (px) ---
        marginX := Max(1, Round(CompactLayoutWidget.MARGIN_X * s))
        stripeH := Max(1, Round(CompactLayoutWidget.STRIPE_H * s))
        line1Y  := Round(CompactLayoutWidget.LINE1_Y * s)
        line1H  := Max(8, Round(CompactLayoutWidget.LINE1_H * s))
        line2Y  := Round(CompactLayoutWidget.LINE2_Y * s)
        line2H  := Max(8, Round(CompactLayoutWidget.LINE2_H * s))
        barY    := Round(CompactLayoutWidget.BAR_Y * s)
        barH    := Max(4, Round(CompactLayoutWidget.BAR_H * s))

        ; Scaled LINE 1 zone widths
        line1ActW       := Max(20, Round(CompactLayoutWidget.LINE1_ACT_W        * s))
        line1ZoneTimerW := Max(40, Round(CompactLayoutWidget.LINE1_ZONE_TIMER_W * s))
        line1RunTimerW  := Max(35, Round(CompactLayoutWidget.LINE1_RUN_TIMER_W  * s))
        line1TimerW     := line1ZoneTimerW + line1RunTimerW

        ; --- Font sizes (minimum clamp for readability) ---
        fontL1  := Max(7, Round(CompactLayoutWidget.FONT_LINE1 * s))
        fontL2  := Max(6, Round(CompactLayoutWidget.FONT_LINE2 * s))
        fontBar := Max(6, Round(CompactLayoutWidget.FONT_BAR   * s))

        ; Side column for vendor buttons (v17.12). contentW is the
        ; usable width for LINE 1/2/3 (main content); the surface
        ; band and accent stripe still use full w (covering the
        ; entire widget so the buttons sit visually inside).
        btnColW  := Round(CompactLayoutWidget.BTN_COL_W * s)
        contentW := w - btnColW

        ; Main surface background (band covering everything)
        this._BuildKalandraBand(0, 0, w, h, "surface")

        ; Top accent stripe
        this._BuildAccentStripe(0, 0, w, stripeH)

        ; --- LINE 1: 4 separate controls ---
        ; line1_act:         "Act X ·"        (left, fixed)
        ; line1_zone:        zone name        (center, dynamic font)
        ; line1_zone_timer:  "· MM:SS"        (right-middle, dynamic color vs zone PB)
        ; line1_run_timer:   "/ MM:SS"        (right-end,    dynamic color vs run PB)

        ; line1_act (left, left-aligned)
        this._SetFont(fontL1, "text", "")
        this._ctrls["line1_act"] := wg.Add("Text",
            "x" marginX " y" line1Y
            " w" line1ActW " h" line1H
            " Left Background" Theme.Color("surface"),
            "")

        ; line1_zone (center, left-aligned, dynamic font)
        ; Position: after act, before the timers
        zoneX := marginX + line1ActW
        zoneW := contentW - 2*marginX - line1ActW - line1TimerW
        if (zoneW < 20)
            zoneW := 20   ; defensive: minimum width
        this._SetFont(fontL1, "text", "")
        this._ctrls["line1_zone"] := wg.Add("Text",
            "x" zoneX " y" line1Y
            " w" zoneW " h" line1H
            " Left Background" Theme.Color("surface"),
            "")

        ; line1_zone_timer (right-middle, right-aligned, dynamic color)
        zoneTimerX := contentW - marginX - line1TimerW
        this._SetFont(fontL1, "text", "")
        this._ctrls["line1_zone_timer"] := wg.Add("Text",
            "x" zoneTimerX " y" line1Y
            " w" line1ZoneTimerW " h" line1H
            " Right Background" Theme.Color("surface"),
            "")

        ; line1_run_timer (right-end, right-aligned, dynamic color)
        runTimerX := zoneTimerX + line1ZoneTimerW
        this._SetFont(fontL1, "text", "")
        this._ctrls["line1_run_timer"] := wg.Add("Text",
            "x" runTimerX " y" line1Y
            " w" line1RunTimerW " h" line1H
            " Right Background" Theme.Color("surface"),
            "")

        ; --- LINE 2: 3 zones ---
        ; Zone 1: "Lv 47 · Area 10" (left-aligned)
        ; Zone 2: "XP" (fixed text, centered, dynamic color)
        ; Zone 3: "PB MM:SS / MM:SS" (soft lavender color — PB display, v17.13)
        halfW := contentW / 2
        quarterW := contentW / 4

        ; LINE 2 zone 1 left: char/area level
        this._SetFont(fontL2, "muted", "")
        ctrlLine2Left := wg.Add("Text",
            "x" marginX " y" line2Y
            " w" (quarterW - marginX) " h" line2H
            " Background" Theme.Color("surface"),
            "")
        this._ctrls["line2_left"] := ctrlLine2Left

        ; LINE 2 zone 2 center: XP indicator (dynamic color set in Refresh)
        ; Fixed text "XP" — only the color changes based on status.
        this._SetFont(fontL2, "muted", "bold")
        ctrlXpIndicator := wg.Add("Text",
            "x" quarterW " y" line2Y
            " w" (halfW - quarterW) " h" line2H
            " Center Background" Theme.Color("surface"),
            "")
        this._ctrls["xp_indicator"] := ctrlXpIndicator

        ; LINE 2 zone 3 right: PB display (v17.13).
        ; Text: "PB ZZ:ZZ / TT:TT" — first = zone PB, second = run PB.
        ; Fallback: "—" for absent values (new zone or first app start).
        ; Color: desaturated lavender (PB_COLOR), right-aligned.
        wg.SetFont("s" fontL2 " c" CompactLayoutWidget.PB_COLOR " bold", Theme.FONT_UI)
        ctrlLine2Pb := wg.Add("Text",
            "x" halfW " y" line2Y
            " w" (halfW - marginX) " h" line2H
            " Right Background" Theme.Color("surface"),
            "")
        this._ctrls["line2_pb"] := ctrlLine2Pb

        ; --- LINE 3: STACKED BAR (Map / Loading / Town) ---
        barX := marginX
        barW := contentW - 2*marginX

        bg := wg.Add("Progress",
            "x" barX " y" barY " w" barW " h" barH
            " Disabled c" Theme.Color("surface3") " Background" Theme.Color("surface3"),
            100)
        this._ctrls["bar_bg"] := bg

        wg.SetFont("s" fontBar " bold c" Theme.Color("bg"), Theme.FONT_UI)

        this._ctrls["bar_mapa"] := wg.Add("Text",
            "x" barX " y" barY " w0 h" barH
            " Center 0x200 Background" CompactLayoutWidget.COLOR_MAPA,
            "")
        this._ctrls["bar_loading"] := wg.Add("Text",
            "x" barX " y" barY " w0 h" barH
            " Center 0x200 Background" CompactLayoutWidget.COLOR_LOADING,
            "")
        this._ctrls["bar_cidade"] := wg.Add("Text",
            "x" barX " y" barY " w0 h" barH
            " Center 0x200 Background" CompactLayoutWidget.COLOR_CIDADE,
            "")

        ; --- RIGHT SIDE: VENDOR CLIPBOARD BUTTONS (v17.12) ---
        ; 3 discreet squares stacked vertically. Click with Ctrl active
        ; copies cfg.vendorRegexes[i] to A_Clipboard.
        this._BuildVendorButtons(s)

        ; Reset caches to force the first SetFont
        this._lastXpColor       := ""
        this._lastZoneTimerColor := ""
        this._lastRunTimerColor  := ""
        this._lastPbText        := ""
        this._lastZoneFontSize  := 0
        this._lastZoneText      := ""

        this._Refresh()
    }

    ; ============================================================
    ; Refresh - reads service state and updates controls
    ; ============================================================
    _Refresh()
    {
        if !this._gui
            return

        ; --- LINE 1: 4 separate controls ---
        ; line1_act:         "Act X ·"
        ; line1_zone:        zone name (with dynamic font)
        ; line1_zone_timer:  "·  MM:SS"  (color vs zone PB)
        ; line1_run_timer:   "/  MM:SS"  (color vs run PB)
        actStr   := this._FormatAct() . "  ·"
        zoneStr  := this._currentZone != "" ? this._currentZone : "—"
        zoneMs   := IsObject(this._zoneTracker) && this._currentZone != ""
                    ? this._zoneTracker.GetZoneTotalWithActive(this._currentZone)
                    : 0
        runMs    := IsObject(this._timer) ? this._timer.GetRunMs() : 0

        this._TrySetText("line1_act", actStr)
        this._TrySetText("line1_zone_timer", "·  " this._FormatMs(zoneMs))
        this._TrySetText("line1_run_timer",  "/  " this._FormatMs(runMs))
        this._RefreshTimerColors(zoneMs, runMs)
        this._RefreshZoneText(zoneStr)   ; handles dynamic font

        ; --- LINE 2 zone 1: death counter ---
        this._RefreshDeathCount()

        ; --- LINE 2 zone 2: XP indicator with dynamic color ---
        this._RefreshXpIndicator()

        ; --- LINE 2 zone 3: PB display ---
        this._RefreshPbDisplay()

        ; --- LINE 3: stacked bar ---
        this._RefreshBar(runMs)
    }

    ; ============================================================
    ; _RefreshTimerColors - applies dynamic color to the 2 LINE 1 timers
    ;
    ; Rule (independent for each timer):
    ;   - PB absent (0):                color = text (white)
    ;   - current_timer <= PB:          color = good (desaturated green)
    ;   - current_timer >  PB:          color = danger (desaturated red)
    ;
    ; Edge case: during an in-progress run, comparing runMs (which
    ; grows continuously) with runPB makes sense — visually indicates
    ; whether you are still below the record time.
    ;
    ; Cache _lastZoneTimerColor / _lastRunTimerColor avoids SetFont
    ; every tick when the color did not change.
    ; ============================================================
    _RefreshTimerColors(zoneMs, runMs)
    {
        zoneTimerColor := this._ResolveTimerColor(zoneMs, this._GetZonePbMs())
        runTimerColor  := this._ResolveTimerColor(runMs,  this._GetRunPbMs())

        if (zoneTimerColor != this._lastZoneTimerColor)
        {
            if this._ctrls.Has("line1_zone_timer")
            {
                fontL1 := Max(7, Round(CompactLayoutWidget.FONT_LINE1 * this._GetScale()))
                try this._ctrls["line1_zone_timer"].SetFont(
                    "s" fontL1 " c" zoneTimerColor, Theme.FONT_UI)
            }
            this._lastZoneTimerColor := zoneTimerColor
        }

        if (runTimerColor != this._lastRunTimerColor)
        {
            if this._ctrls.Has("line1_run_timer")
            {
                fontL1 := Max(7, Round(CompactLayoutWidget.FONT_LINE1 * this._GetScale()))
                try this._ctrls["line1_run_timer"].SetFont(
                    "s" fontL1 " c" runTimerColor, Theme.FONT_UI)
            }
            this._lastRunTimerColor := runTimerColor
        }
    }

    ; Resolves the color for a timer based on comparison with the PB.
    ;
    ; v17.13: uses "goodStrong" (4ADE80, vibrant) instead of "good"
    ; (B8C7B0, desaturated) so the "below PB" green is visually
    ; stronger and contrasts with the red.
    _ResolveTimerColor(currentMs, pbMs)
    {
        ; PB absent or timer still at 0: neutral color
        if (pbMs <= 0 || currentMs <= 0)
            return Theme.Color("text")
        if (currentMs <= pbMs)
            return Theme.Color("goodStrong")
        return Theme.Color("danger")
    }

    ; Safe queries to the PB service (tolerates _pbService = "" without deps).
    ;
    ; v17.13: GetRunPbMs now returns the CURRENT ACT's PB instead of
    ; the global PB. When the user changes acts mid-run, the value
    ; updates automatically — _currentAct is updated by _OnZoneEntered
    ; and refresh recalculates every tick.
    ;
    ; ROBUSTNESS (v17.13b): if _currentAct=0 (ZoneEntered has not yet
    ; fired or came without actIndex), tries to derive from
    ; _zonesCatalog using _currentZone as a fallback. Avoids the PB
    ; staying empty during an in-progress run just because the widget
    ; missed the initial ZoneEntered.
    _GetRunPbMs()
    {
        if !IsObject(this._pbService)
            return 0
        act := this._ResolveCurrentAct()
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

    ; Resolves the current act using cascade fallbacks (v17.13b):
    ;   1. this._currentAct (set by _OnZoneEntered)
    ;   2. derive from _currentZone via _zonesCatalog.GetActOfName
    ;   3. query active zone from _zoneTracker + catalog
    ;
    ; Useful for resilience in situations like:
    ;   - App started with a hydrated run (no new ZoneEntered)
    ;   - ZoneEntered came with actIndex=0 (uncatalogued zone)
    _ResolveCurrentAct()
    {
        if (this._currentAct > 0)
            return this._currentAct

        ; Fallback 1: use _currentZone if we have one
        if (this._currentZone != "" && IsObject(this._zonesCatalog))
        {
            act := this._zonesCatalog.GetActOfName(this._currentZone)
            if (act > 0)
            {
                this._currentAct := act    ; cache for next ticks
                return act
            }
        }

        ; Fallback 2: query the zone tracker (in case _currentZone is empty)
        if (IsObject(this._zoneTracker) && IsObject(this._zonesCatalog))
        {
            try
            {
                z := this._zoneTracker.GetActiveZone()
                if (z != "")
                {
                    act := this._zonesCatalog.GetActOfName(z)
                    if (act > 0)
                    {
                        this._currentZone := z
                        this._currentAct  := act
                        return act
                    }
                }
            }
        }

        return 0
    }

    ; ============================================================
    ; _RefreshPbDisplay - updates the line2_pb text
    ;
    ; Format: "PB ZZ:ZZ / TT:TT"  (both available)
    ;         "PB — / TT:TT"     (zone PB absent)
    ;         "PB ZZ:ZZ / —"     (run PB absent)
    ;         "PB — / —"        (both absent)
    ;
    ; v17.13b: always shows the display (even with both PBs absent),
    ; so the user knows WHERE the PB would appear — avoids the feature
    ; looking broken when there are no PBs saved yet.
    ;
    ; Cache _lastPbText avoids repeated writes to the ctrl.
    ; Color is fixed (PB_COLOR) and set in _BuildGui — no need to re-apply.
    ; ============================================================
    _RefreshPbDisplay()
    {
        if !this._ctrls.Has("line2_pb")
            return

        zonePb := this._GetZonePbMs()
        runPb  := this._GetRunPbMs()

        zStr := zonePb > 0 ? this._FormatMs(zonePb) : "—"
        rStr := runPb  > 0 ? this._FormatMs(runPb)  : "—"
        text := "PB " zStr " / " rStr

        if (text != this._lastPbText)
        {
            try this._ctrls["line2_pb"].Value := text
            this._lastPbText := text
        }
    }

    ; ============================================================
    ; _RefreshZoneText - zone text with font that shrinks if needed
    ;
    ; When the map name is long (e.g. "Cemetery of the Eternals"), we
    ; don't want to truncate text or push the timers. Instead, we
    ; reduce the font iteratively until it fits in the available space.
    ;
    ; Width estimate: chars × fontSize × 0.6 (Segoe UI). Not precise
    ; in pixels but enough to decide "fits or doesn't fit".
    ;
    ; Cache _lastZoneFontSize avoids unnecessary SetFont when the same
    ; zone renders repeatedly.
    ; ============================================================
    _RefreshZoneText(zoneStr)
    {
        if !this._ctrls.Has("line1_zone")
            return
        ctrl := this._ctrls["line1_zone"]

        s := this._GetScale()
        baseSize := Max(7, Round(CompactLayoutWidget.FONT_LINE1 * s))
        minSize  := Max(6, Round(CompactLayoutWidget.FONT_ZONE_MIN * s))

        ; Space available for the zone (same math as _BuildGui)
        marginX     := Max(1, Round(CompactLayoutWidget.MARGIN_X * s))
        line1ActW   := Max(20, Round(CompactLayoutWidget.LINE1_ACT_W   * s))
        line1ZoneTimerW := Max(40, Round(CompactLayoutWidget.LINE1_ZONE_TIMER_W * s))
        line1RunTimerW  := Max(35, Round(CompactLayoutWidget.LINE1_RUN_TIMER_W  * s))
        line1TimerW := line1ZoneTimerW + line1RunTimerW
        btnColW     := Round(CompactLayoutWidget.BTN_COL_W * s)
        contentW    := this._w - btnColW
        zoneAvailW  := contentW - 2*marginX - line1ActW - line1TimerW
        if (zoneAvailW < 20)
            zoneAvailW := 20

        ; Find the largest font size that fits (top-down)
        sizeFound := baseSize
        while (sizeFound > minSize)
        {
            estW := CompactLayoutWidget._EstimateTextW(zoneStr, sizeFound)
            if (estW <= zoneAvailW)
                break
            sizeFound--
        }

        ; Apply font only if it changed
        if (sizeFound != this._lastZoneFontSize)
        {
            try ctrl.SetFont("s" sizeFound " c" Theme.Color("text"), Theme.FONT_UI)
            this._lastZoneFontSize := sizeFound
        }

        ; Apply text only if it changed
        if (zoneStr != this._lastZoneText)
        {
            try ctrl.Value := zoneStr
            this._lastZoneText := zoneStr
        }
    }

    ; ============================================================
    ; _EstimateTextW - estimates text width in pixels (Segoe UI)
    ;
    ; Approximation: chars × fontSize × 0.6. Segoe UI has variable
    ; char widths (wide M, narrow i) but the average is around this.
    ;
    ; Conservative (slightly underestimates): wide chars may exceed
    ; the estimate. In exchange, AHK controls truncate gracefully
    ; without breaking layout.
    ; ============================================================
    static _EstimateTextW(text, fontSize)
    {
        return Round(StrLen(text) * fontSize * 0.6)
    }

    ; ============================================================
    ; _RefreshXpIndicator - updates the COLOR of the fixed "XP" text
    ;
    ; Text: always "XP" — does not show OK/LIMIT/PENALTY/? as a UX
    ; preference (only the color communicates status).
    ;
    ; Color comes from XpRules.Calculate (via xpService.GetXpPenaltyInfo):
    ;   ok      -> good (desaturated green)
    ;   limit   -> warn (amber)
    ;   penalty -> danger (desaturated red)
    ;   unknown -> COLOR_UNKNOWN (gray)
    ;
    ; Optimization: only calls SetFont when the color changed (avoids
    ; unnecessary repaint every tick).
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
            fontL2 := Max(6, Round(CompactLayoutWidget.FONT_LINE2 * this._GetScale()))
            try ctrl.SetFont("s" fontL2 " c" color " bold", Theme.FONT_UI)
            this._lastXpColor := color
        }
        try ctrl.Value := "XP"
    }

    ; ============================================================
    ; _RefreshBar - computes pcts and adjusts the 3 segments
    ; ============================================================
    _RefreshBar(runMs)
    {
        s := this._GetScale()
        marginX   := Max(1, Round(CompactLayoutWidget.MARGIN_X * s))
        btnColW   := Round(CompactLayoutWidget.BTN_COL_W * s)
        contentW  := this._w - btnColW
        barX      := marginX
        barY      := Round(CompactLayoutWidget.BAR_Y * s)
        barW      := contentW - 2*marginX
        barH      := Max(4, Round(CompactLayoutWidget.BAR_H * s))
        minLabelW := Max(40, Round(CompactLayoutWidget.LABEL_MIN_W * s))
        minPctW   := Max(20, Round(CompactLayoutWidget.LABEL_MIN_PCT_W * s))

        if (runMs <= 0)
        {
            this._SetBarSegment("bar_mapa",    barX, barY, 0, barH, "")
            this._SetBarSegment("bar_loading", barX, barY, 0, barH, "")
            this._SetBarSegment("bar_cidade",  barX, barY, 0, barH, "")
            return
        }

        loadingMs := IsObject(this._loadingTotals) ? this._loadingTotals.GetTotalMs() : 0
        townMs    := IsObject(this._zoneTracker)   ? this._zoneTracker.GetTotalTownMs() : 0
        if (loadingMs < 0)
            loadingMs := 0
        if (townMs < 0)
            townMs := 0

        loadPct := Round(loadingMs / runMs * 100)
        townPct := Round(townMs / runMs * 100)
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
        mapaPct := 100 - loadPct - townPct

        wMapa  := Round(barW * mapaPct / 100)
        wLoad  := Round(barW * loadPct / 100)
        wTown  := barW - wMapa - wLoad
        if (wTown < 0)
            wTown := 0

        xCursor := barX
        this._SetBarSegment("bar_mapa", xCursor, barY, wMapa, barH,
            CompactLayoutWidget._SegmentLabel("Map", mapaPct, wMapa, minPctW, minLabelW))
        xCursor += wMapa

        this._SetBarSegment("bar_loading", xCursor, barY, wLoad, barH,
            CompactLayoutWidget._SegmentLabel("Load", loadPct, wLoad, minPctW, minLabelW))
        xCursor += wLoad

        this._SetBarSegment("bar_cidade", xCursor, barY, wTown, barH,
            CompactLayoutWidget._SegmentLabel("Town", townPct, wTown, minPctW, minLabelW))
    }

    static _SegmentLabel(name, pct, w, minPctW, minLabelW)
    {
        if (w < minPctW)
            return ""
        if (w < minLabelW)
            return pct "%"
        return name " " pct "%"
    }

    ; ============================================================
    ; Vendor clipboard buttons (right side, v17.12)
    ; ============================================================
    ;
    ; Creates 3 square Text controls (BTN_SIZE x BTN_SIZE) with
    ; surface3 Background, stacked vertically on the right side and
    ; vertically centered in the widget (discounting the top accent
    ; stripe).
    ;
    ; LABELS:
    ;   Filled: number ("1"/"2"/"3") in 'muted' color (desaturated gray)
    ;   Empty:  middle dot ("·") in 'subtle' color (lighter gray)
    ;
    ; CLICK-THROUGH:
    ;   The widget has WS_EX_TRANSPARENT set by default (clicks pass
    ;   through to the game). OverlayInteractionService removes that
    ;   bit while Ctrl is held. That is: the buttons only respond
    ;   with Ctrl active — same behavior as overlay drag/resize.
    ;
    ; CLOSURE CAPTURE:
    ;   _BindVendorButton is an isolated helper method because the
    ;   arrow function needs to capture slotIdx BY VALUE. Since
    ;   slotIdx is a method param, each call creates a fresh scope
    ;   and the closure captures correctly. If we inlined the lambda
    ;   inside the Loop using A_Index or i directly, it would capture
    ;   by reference and all 3 buttons would trigger the last slot.
    ; ============================================================
    _BuildVendorButtons(s)
    {
        wg      := this._gui
        btnSize := Max(10, Round(CompactLayoutWidget.BTN_SIZE * s))
        vGap    := Max(1, Round(CompactLayoutWidget.BTN_VGAP * s))
        mRight  := Max(1, Round(CompactLayoutWidget.BTN_MARGIN_R * s))
        fontBtn := Max(7, Round(CompactLayoutWidget.FONT_BTN * s))
        stripeH := Max(1, Round(CompactLayoutWidget.STRIPE_H * s))

        ; X position: aligned to the widget's right edge
        btnX := this._w - mRight - btnSize

        ; Vertical stacking centered below the accent stripe
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
            label := val != "" ? String(i) : "·"
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

    ; Isolated helper to guarantee slotIdx capture by value (fresh
    ; scope on each call). See _BuildVendorButtons doc.
    _BindVendorButton(btn, slotIdx)
    {
        btn.OnEvent("Click", (*) => this._OnVendorClick(slotIdx))
    }

    ; Click handler. Reads cfg.vendorRegexes[slotIdx]; if empty,
    ; shows a TrayTip guiding the user to Settings. If filled, copies
    ; to A_Clipboard and shows a TrayTip with a preview (first 30 chars).
    ;
    ; Tolerant: cfg can be "" (no injected deps) — silent no-op.
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

    _SetBarSegment(key, x, y, w, h, text)
    {
        if !this._ctrls.Has(key)
            return
        try
        {
            ctrl := this._ctrls[key]
            ctrl.Move(x, y, w, h)
            ctrl.Value := text
        }
    }

    ; ============================================================
    ; Format helpers
    ; ============================================================

    _FormatAct()
    {
        if (this._currentAct > 0)
            return "Act " this._currentAct
        return "Act —"
    }

    ; v0.1.2 (audit #19): consolidated into Duration.FormatMs.
    _FormatMs(ms) => Duration.FormatMs(ms)

    _TrySetText(ctrlKey, text)
    {
        if !this._ctrls.Has(ctrlKey)
            return
        ctrl := this._ctrls[ctrlKey]
        try ctrl.Value := text
    }

    ; ============================================================
    ; Handlers
    ; ============================================================

    _OnTick(data)
    {
        nowMs := A_TickCount
        if (nowMs - this._lastRenderMs < 250)
            return
        this._lastRenderMs := nowMs
        this._Refresh()
    }

    _OnZoneEntered(data)
    {
        if !IsObject(data)
            return
        if data.Has("zoneName")
            this._currentZone := data["zoneName"]
        if data.Has("actIndex")
            this._currentAct := data["actIndex"]
        if (this._currentAct = 0 && IsObject(this._zonesCatalog) && this._currentZone != "")
            this._currentAct := this._zonesCatalog.GetActOfName(this._currentZone)
        this._Refresh()
    }

    ; ============================================================
    ; _OnRunRestart - resets death counter when the run restarts
    ;
    ; Subscribed to 3 events: RunStarted, RunReset, RunCancelled.
    ; Whenever the run enters a "fresh start" state, the counter
    ; goes back to 0. RunCompleted is NOT handled here — when the
    ; user finalizes the run, the data is preserved until the next
    ; Reset/Start (for eventual post-run review/plot).
    ; ============================================================
    _OnRunRestart(data)
    {
        this._deathCount := 0
        this._Refresh()
    }

    ; ============================================================
    ; _OnDeathDetected - increments local counter
    ;
    ; Subscribed to Evt.DeathDetected (published by XpService when
    ; it detects a negative penalty in the log, or another source).
    ; Each fire counts as one death in the current run.
    ; ============================================================
    _OnDeathDetected(data)
    {
        this._deathCount += 1
        this._Refresh()
    }

    ; ============================================================
    ; _RefreshDeathCount - updates the text and color of line2_left
    ;
    ; Format: "✗ N" where N = _deathCount.
    ; Dynamic color:
    ;   - 0 deaths:   muted (desaturated gray) — normal state
    ;   - >= 1 death: warn  (amber)            — already died, subtle signal
    ;
    ; Cache _lastDeathColor avoids unnecessary SetFont when the color
    ; did not change (most ticks, since deaths are rare).
    ; ============================================================
    _RefreshDeathCount()
    {
        if !this._ctrls.Has("line2_left")
            return
        ctrl := this._ctrls["line2_left"]

        deathStr := "✗ " this._deathCount
        targetColor := this._deathCount > 0
                       ? Theme.Color("warn")
                       : Theme.Color("muted")

        if (targetColor != this._lastDeathColor)
        {
            fontL2 := Max(6, Round(CompactLayoutWidget.FONT_LINE2 * this._GetScale()))
            try ctrl.SetFont("s" fontL2 " c" targetColor " bold", Theme.FONT_UI)
            this._lastDeathColor := targetColor
        }
        try ctrl.Value := deathStr
    }

    ; ============================================================
    ; Cleanup
    ; ============================================================
    Dispose()
    {
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
    }
}
