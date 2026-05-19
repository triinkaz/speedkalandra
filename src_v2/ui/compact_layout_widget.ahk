; CompactLayoutWidget — horizontal speedrun overlay bar. Base size
; 380×96 at scale 1.0; the widget rescales interactively via
; Ctrl+wheel and clamps to [0.5, 3.0] inside WidgetBase.SetScale.
;
; Layout:
;
;   +-------------------------------------------+
;   | [accent stripe 3px]                       |
;   | LINE 1: Act X ·  Zone  ·  ZZ:ZZ  /  RR:RR |
;   | LINE 2: ✗ N    | XP  | PB ZZ:ZZ / TT:TT   |
;   | LINE 3 (stacked bar): [Map][Load][Town]   |
;   +-------------------------------------------+
;
; LINE 1 splits into four controls so the zone name can shrink its
; font when it doesn't fit, without pushing the timers or truncating:
;   line1_act         "Act X ·"            (left, fixed)
;   line1_zone        zone name            (center, dynamic font)
;   line1_zone_timer  "·  MM:SS"           (right-middle, color vs zone PB)
;   line1_run_timer   "/  MM:SS"           (right-end,    color vs run PB)
;
; LINE 2 zones:
;   left quarter   "✗ N"  current-run death counter (muted=0, warn>=1).
;                  Resets on RunStarted / Reset / Cancelled.
;   center quarter "XP"   fixed label, dynamic color from XpRules
;                  (green ok / amber limit / red penalty / gray unknown).
;                  AHK Text controls support one color per control,
;                  so the color changes via SetFont; a cache avoids
;                  repaint every tick.
;   right half     "PB ZZ:ZZ / TT:TT" — zone PB followed by run PB
;                  (teal so it doesn't share a hue with Town's violet).
;
; Personal Bests (PersonalBestService, loaded from INI on boot,
; updated on RunCompleted by the composition root):
;   LINE 1 timer colors compare against PB independently per timer:
;     current <= PB  →  goodStrong (vibrant green) so the
;                       "under PB" green pops against red
;     current >  PB  →  danger (desaturated red)
;     PB absent / current = 0  →  text (white)
;   The run timer compares against the CURRENT ACT's PB, not a
;   global PB. When the act changes mid-run, the comparison target
;   updates on the next tick and the color may flip immediately.
;
; LINE 1 zone timer = TOTAL time in the active zone during the run
; (sum of all visits + current elapsed). NOT time-since-last-entry,
; which would zero on every pause-detection cycle. We rely on
; ZoneTrackingService.GetZoneTotalWithActive() for that.
;
; LINE 3 stacked bar:
;   mapaMs  = max(0, runMs - loadingMs - townMs)
;   mapaPct = 100 - loadPct - townPct          (sum stays 100)
;   Inline "name pct%" label only when the segment is wide enough
;   (LABEL_MIN_W); narrower segments show "pct%"; narrower still are
;   blank. Colors match RunStatsPlotBuilder.SegmentDefinitions.
;
; Subscriptions:
;   Evt.Tick              → refresh (~300 ms)
;   Evt.ZoneEntered       → updates zone + act
;   Evt.CharacterLevelUp  → refresh (affects XP indicator)
;   Evt.AreaLevelChanged  → refresh (affects XP indicator)
;   Evt.DeathDetected     → increments death counter
;   Evt.RunStarted /
;   Evt.RunReset /
;   Evt.RunCancelled      → resets death counter + empty state
;   Evt.VendorRegexesChanged → hot-refresh of V1/V2/V3 button labels
;
; Dependencies:
;   timer         — TimerService
;   zoneTracker   — ZoneTrackingService
;   xp            — XpService
;   zonesCatalog  — ZonesCatalog (optional)
;   loadingTotals — LoadingTotalsService (optional)
;   cfg           — AppSettings (optional, used by the V1/V2/V3 buttons)
;   pbService     — PersonalBestService (optional)

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

    ; Vendor clipboard buttons — three discreet squares on the right
    ; edge, stacked vertically and centered. Ctrl+click copies
    ; cfg.vendorRegexes[i] to A_Clipboard. The column takes BTN_COL_W
    ; px; main content (lines 1/2/3) is re-laid-out for
    ; contentW = w - BTN_COL_W. The surface band and the accent
    ; stripe still span full w so the buttons visually sit inside
    ; the widget, with surface3 over surface.
    static BTN_COL_W      := 22    ; side-column width (btn + right margin)
    static BTN_SIZE       := 18    ; square side
    static BTN_VGAP       := 3     ; vertical gap between buttons
    static BTN_MARGIN_R   := 4     ; margin between button and right edge of widget

    ; LINE 1 zone widths at scale 1.0. Reserves fixed space for
    ; "Act X ·" on the left and the two timers on the right; the
    ; zone name occupies whatever remains, with a dynamic font that
    ; shrinks when it doesn't fit. The timer block is two separate
    ; controls (zone_timer + run_timer) so each can carry its own
    ; PB-based color; LINE1_TIMER_W is just the sum, useful for
    ; available-zone-width math.
    static LINE1_ACT_W        := 60    ; "Act 1 ·"  to "Act 99 ·"
    static LINE1_ZONE_TIMER_W := 80    ; "·  MM:SS"  to "·  1:23:45"
    static LINE1_RUN_TIMER_W  := 70    ; "/  MM:SS"  to "/  1:23:45"
    static LINE1_TIMER_W      := 150   ; sum of the two

    ; Base font sizes (scaled by _position.scale at runtime). FONT_LINE1
    ; sits at 11 so a long zone label plus zone_timer + run_timer can
    ; coexist on the same line at scale 1.0 without overlap.
    static FONT_LINE1 := 11
    static FONT_LINE2 := 9
    static FONT_BAR   := 8
    static FONT_BTN   := 8    ; the 1/2/3 labels on the side squares

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

    ; Color of the PB display (LINE 2 right). Teal-400 — chosen so
    ; it doesn't share a hue with anything else in the palette:
    ;   2DD4BF teal       (this)
    ;   A78BFA violet     (town)
    ;   38BDF8 sky        (map)
    ;   4ADE80 green      (goodStrong)
    ;   FACC15 yellow     (loading)
    ; Earlier pink variants still shared blue-violet components with
    ; the Town color on some monitors.
    static PB_COLOR := "2DD4BF"

    ; --- Deps ---
    _timer         := ""
    _zoneTracker   := ""
    _xp            := ""
    _zonesCatalog  := ""
    _loadingTotals := ""
    _cfg           := ""    ; AppSettings (drives the V1/V2/V3 buttons)
    _pbService     := ""    ; PersonalBestService

    ; State cache for render. The _last* fields exist to skip SetFont /
    ; control writes when the value didn't change tick-to-tick.
    _currentZone     := ""
    _currentAct      := 0
    _deathCount      := 0
    _lastRenderMs    := 0
    _lastXpColor     := ""
    _lastZoneTimerColor := ""
    _lastRunTimerColor  := ""
    _lastDeathColor  := ""
    _lastPbText      := ""
    _lastZoneFontSize := 0
    _lastZoneText    := ""

    ; Handler refs — kept as fields so Dispose can pass the SAME
    ; closure reference to Unsubscribe (fat-arrow closures generate
    ; fresh references every call site).
    _handlerTick           := ""
    _handlerZoneEntered    := ""
    _handlerCharLevelUp    := ""
    _handlerAreaLevelChg   := ""
    _handlerRunStarted     := ""
    _handlerRunReset       := ""
    _handlerRunCancelled   := ""
    _handlerDeathDetected  := ""
    _handlerVendorChanged  := ""

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
        ; Hot-refresh of the V1/V2/V3 button labels when the user
        ; changes vendor regex slots in Settings. The click handler
        ; always reads cfg.vendorRegexes on demand, so click behavior
        ; is already up to date — only the visual state (filled
        ; "1"/"2"/"3" vs empty "·") needed wiring.
        this._handlerVendorChanged  := (data) => this._OnVendorRegexesChanged(data)

        bus.Subscribe(Events.Tick,              this._handlerTick)
        bus.Subscribe(Events.ZoneEntered,       this._handlerZoneEntered)
        bus.Subscribe(Events.CharacterLevelUp,  this._handlerCharLevelUp)
        bus.Subscribe(Events.AreaLevelChanged,  this._handlerAreaLevelChg)
        bus.Subscribe(Events.RunStarted,        this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,          this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled,      this._handlerRunCancelled)
        bus.Subscribe(Events.DeathDetected,     this._handlerDeathDetected)
        bus.Subscribe(Events.VendorRegexesChanged, this._handlerVendorChanged)
    }

    _GetFixedSize() => Map("w", CompactLayoutWidget.FIXED_W, "h", CompactLayoutWidget.FIXED_H)

    ; Evt.VendorRegexesChanged handler. Refreshes label + color of
    ; each V1/V2/V3 button:
    ;   slot filled  →  label "1"/"2"/"3", color muted
    ;   slot empty   →  label "·",          color subtle
    ; Click behavior already reads cfg.vendorRegexes on demand; this
    ; only fixes the VISUAL state so the overlay doesn't show stale
    ; "·" labels after the user fills a slot in Settings.
    ;
    ; If the GUI hasn't been built yet (called before first Show),
    ; _ctrls is empty and the loop silently no-ops.
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
            label := val != "" ? String(i) : "·"
            color := val != "" ? Theme.Color("muted") : Theme.Color("subtle")
            try
            {
                ctrl := this._ctrls[ctrlKey]
                ctrl.SetFont("s" fontBtn " c" color " bold", Theme.FONT_UI)
                ctrl.Value := label
            }
        }
    }

    ; Reads the current scale, with a defensive fallback to 1.0 if
    ; the persisted value got corrupted.
    _GetScale()
    {
        s := this._position.scale
        if (!IsNumber(s) || s <= 0)
            return 1.0
        return s
    }

    ; Builds every control, applying the current scale to dimensions
    ; and fonts.
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

        ; Side column for vendor buttons. contentW is the usable
        ; width for lines 1/2/3; the surface band and accent stripe
        ; still use full w so the buttons sit visually inside the
        ; widget.
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
        ; Zone 3: "PB MM:SS / MM:SS" — zone PB / run PB, fixed teal color
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

        ; LINE 2 right: PB display.
        ; Text: "PB ZZ:ZZ / TT:TT" — first = zone PB, second = run PB.
        ; Fallback "—" for absent values (new zone or first run).
        ; Color is fixed teal (PB_COLOR); right-aligned.
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

        ; Right edge: vendor clipboard buttons.
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

    ; Reads service state and updates every control.
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

    ; Applies dynamic color to the two LINE 1 timers. Each timer's
    ; rule is independent and uses _ResolveTimerColor (see below).
    ; The _last*Color caches keep us from calling SetFont every tick
    ; when the color hasn't changed.
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

    ; Resolves the color of one timer:
    ;   PB absent (0) or timer at 0  →  text (white), neutral
    ;   current <= PB                →  goodStrong (vibrant green)
    ;   current >  PB                →  danger (desaturated red)
    ; goodStrong is intentional over the desaturated "good" — the
    ; under-PB green needs to pop against the over-PB red.
    _ResolveTimerColor(currentMs, pbMs)
    {
        ; PB absent or timer still at 0: neutral color
        if (pbMs <= 0 || currentMs <= 0)
            return Theme.Color("text")
        if (currentMs <= pbMs)
            return Theme.Color("goodStrong")
        return Theme.Color("danger")
    }

    ; Safe lookups against the PB service (tolerate _pbService = ""
    ; so tests can omit the dep).
    ;
    ; GetRunPbMs returns the CURRENT ACT's PB, not a global PB —
    ; when the user crosses into a new act mid-run, the comparison
    ; target shifts and the timer color may flip on the next tick.
    ;
    ; If _currentAct is still 0 because ZoneEntered hasn't fired (or
    ; arrived without an actIndex), _ResolveCurrentAct falls back to
    ; deriving the act from _currentZone via the catalog. Without
    ; that fallback, the PB stays empty during an in-progress run
    ; whenever the widget missed the initial ZoneEntered.
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

    ; Resolves the current act through cascading fallbacks:
    ;   1. this._currentAct (set by _OnZoneEntered)
    ;   2. derive from _currentZone via ZonesCatalog.GetActOfName
    ;   3. ask ZoneTrackingService for the active zone, then catalog it
    ; Survives the two awkward cases: a hydrated run (no fresh
    ; ZoneEntered after Show) and a ZoneEntered with actIndex = 0
    ; for an uncatalogued zone.
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

    ; Updates the line2_pb text. Always renders even when both PBs
    ; are absent ("PB — / —") so the user can see WHERE the PB would
    ; show up and doesn't think the feature is broken before saving
    ; their first run. Color is fixed (PB_COLOR, set in _BuildGui)
    ; so we only touch Value; _lastPbText avoids redundant writes.
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

    ; Renders the zone name with a font size that shrinks until the
    ; text fits the available width — so a long map name like
    ; "Cemetery of the Eternals" stays visible instead of either
    ; getting truncated or pushing the timers off the line.
    ; Width estimate uses _EstimateTextW; cache _lastZoneFontSize
    ; avoids SetFont when the same zone renders tick after tick.
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

    ; Rough pixel-width estimate for Segoe UI: chars × fontSize × 0.6.
    ; Variable per character (wide M vs narrow i) but the average
    ; sits around 0.6. Slightly underestimates wide-glyph runs, but
    ; AHK Text controls truncate gracefully if we overshoot.
    static _EstimateTextW(text, fontSize)
    {
        return Round(StrLen(text) * fontSize * 0.6)
    }

    ; Updates the color of the fixed "XP" label. The text never
    ; changes — only color communicates status (UX choice). Color
    ; comes from XpRules via XpService.GetXpPenaltyInfo (ok / warn /
    ; danger / unknown). _lastXpColor avoids SetFont every tick.
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

    ; Computes percentages and resizes the three bar segments.
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

    ; ---- Vendor clipboard buttons (right edge) ----
    ;
    ; Three square Text controls (BTN_SIZE × BTN_SIZE) with surface3
    ; background, stacked vertically and centered (minus the top
    ; accent stripe).
    ;
    ; Labels:
    ;   slot filled  →  "1" / "2" / "3" in muted gray
    ;   slot empty   →  "·"             in subtle gray
    ;
    ; Click-through: the widget has WS_EX_TRANSPARENT by default so
    ; clicks pass through to the game. OverlayInteractionService
    ; clears that bit while Ctrl is held; the buttons therefore only
    ; respond with Ctrl active — same gate as overlay drag/resize.
    ;
    ; Closure capture: _BindVendorButton is an isolated helper so the
    ; arrow function captures slotIdx by value (each call to a method
    ; gets a fresh scope). Inlining the lambda inside the Loop using
    ; A_Index or `i` directly would capture by reference, and all
    ; three buttons would fire for the LAST slot only.
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

    ; Isolated helper that gives slotIdx a fresh scope so the arrow
    ; closure captures it by value. See _BuildVendorButtons.
    _BindVendorButton(btn, slotIdx)
    {
        btn.OnEvent("Click", (*) => this._OnVendorClick(slotIdx))
    }

    ; Click handler. Empty slot → TrayTip pointing to Settings.
    ; Filled slot → A_Clipboard receives the value and a TrayTip
    ; previews the first 30 chars. Silent no-op when cfg is "".
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

    ; ---- Format helpers ----

    _FormatAct()
    {
        if (this._currentAct > 0)
            return "Act " this._currentAct
        return "Act —"
    }

    ; Thin alias kept so call sites in this file don't need rewriting.
    _FormatMs(ms) => Duration.FormatMs(ms)

    _TrySetText(ctrlKey, text)
    {
        if !this._ctrls.Has(ctrlKey)
            return
        ctrl := this._ctrls[ctrlKey]
        try ctrl.Value := text
    }

    ; ---- Handlers ----

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

    ; Resets the death counter on any "fresh start" event
    ; (RunStarted / RunReset / RunCancelled). RunCompleted is NOT
    ; handled here so the count survives finalize → review/plot,
    ; and only clears on the next Reset or Start.
    _OnRunRestart(data)
    {
        this._deathCount := 0
        this._Refresh()
    }

    ; Increments the local death counter. Source-agnostic: each
    ; Evt.DeathDetected fire counts as one death in the current run.
    _OnDeathDetected(data)
    {
        this._deathCount += 1
        this._Refresh()
    }

    ; Renders line2_left as "✗ N". Color is muted at 0, warn (amber)
    ; from 1 upward — a subtle signal you've already died. Deaths
    ; are rare per tick, so the _lastDeathColor cache keeps SetFont
    ; off the hot path.
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

    ; ---- Cleanup ----

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
        if (this._handlerVendorChanged != "")
        {
            this._bus.Unsubscribe(Events.VendorRegexesChanged, this._handlerVendorChanged)
            this._handlerVendorChanged := ""
        }
    }
}
