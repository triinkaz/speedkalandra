; ============================================================
; MicroLayoutPlusWidget — Plus variant of the Micro layout
; ============================================================
;
; Opt-in via cfg.layoutVariant = "plus" (Settings > LAYOUTS BETA).
; Shares WIDGET_ID and base dimensions with MicroLayoutWidget so
; the persisted position carries across the toggle.
;
; LAYOUT (base 200×32 at scale=1.0):
;
;   +--------------------------------+
;   | 00:28  │  03:33  │   XP        |
;   +--------------------------------+
;
; Three blocks separated by 1 px vertical lines in `Theme.Color("line")`
; (3A3330) — no `/`, `;`, `·` glyphs (spec §4.3).
;
; DELTAS FROM CLASSIC:
;   - Removed: Lv N (Classic showed runTime + "Lv N" in a single
;     control; Plus shows zoneTime + runTime as two timers).
;   - Added: zone timer + per-act PB-based conditional color on
;     both timers. Implies new dependencies on zoneTracker /
;     zonesCatalog / personalBest (Classic only needed timer + xp).
;   - 1 px separators between blocks (Theme `line` color).
;
; XP CHIP:
;   The fixed "XP" text whose color communicates status. Same
;   convention as Steve Plus / Compact Plus — text never changes,
;   only the color tracks XpRules.
;
; CONSTRUCTION:
;   widget := MicroLayoutPlusWidget(
;       bus, position, onPersist,
;       timer, zoneTracker, xpService,
;       zonesCatalog, personalBest)


class MicroLayoutPlusWidget extends LayoutWidgetBase
{
    static WIDGET_ID := "microLayout"
    static DISPLAY_NAME := "Layout Micro+"

    ; BASE size matches Classic so the [Overlay] slot is shared.
    static FIXED_W := 200
    static FIXED_H := 32

    ; BASE layout (scale=1.0)
    static STRIPE_H  := 2
    static MARGIN_X  := 4
    static SEP_W     := 1      ; vertical separator width in px
    static SEP_Y_PAD := 4      ; vertical padding above/below separator
    static FONT_TIMER := 11    ; mono
    static FONT_XP    := 10    ; UI bold

    ; High-freq refresh — same justification as the larger Plus
    ; widgets: centiseconds visibly stutter on the default Tick
    ; (300 ms).
    static TIMER_REFRESH_MS := 50

    ; Services
    _timer        := ""
    _zoneTracker  := ""
    _xp           := ""
    _zonesCatalog := ""
    _pbService    := ""

    ; State
    _currentZone := ""
    _currentAct  := 0

    ; Render caches — skip SetFont / Value writes per tick.
    _lastZoneTimerText  := ""
    _lastZoneTimerColor := ""
    _lastRunTimerText   := ""
    _lastRunTimerColor  := ""
    _lastXpColor        := ""
    _lastRenderMs       := 0

    ; Handler refs — same closure passed to Subscribe / Unsubscribe.
    _handlerTick          := ""
    _handlerZoneEntered   := ""
    _handlerCharLevelUp   := ""
    _handlerAreaLevelChg  := ""
    _handlerRunStarted    := ""
    _handlerRunReset      := ""
    _handlerRunCancelled  := ""

    _highFreqTimerFn := ""

    __New(bus, position, onPersist, timer, zoneTracker, xp,
          zonesCatalog := "", pbService := "")
    {
        super.__New(MicroLayoutPlusWidget.WIDGET_ID,
                    MicroLayoutPlusWidget.DISPLAY_NAME,
                    bus, position, onPersist)
        this._timer        := timer
        this._zoneTracker  := zoneTracker
        this._xp           := xp
        this._zonesCatalog := zonesCatalog
        this._pbService    := pbService

        this._handlerTick         := (data) => this._OnTick(data)
        this._handlerZoneEntered  := (data) => this._OnZoneEntered(data)
        this._handlerCharLevelUp  := (data) => this._RefreshXp()
        this._handlerAreaLevelChg := (data) => this._RefreshXp()
        this._handlerRunStarted   := (data) => this._OnRunStateChange()
        this._handlerRunReset     := (data) => this._OnRunStateChange()
        this._handlerRunCancelled := (data) => this._OnRunStateChange()

        bus.Subscribe(Events.Tick,             this._handlerTick)
        bus.Subscribe(Events.ZoneEntered,      this._handlerZoneEntered)
        bus.Subscribe(Events.CharacterLevelUp, this._handlerCharLevelUp)
        bus.Subscribe(Events.AreaLevelChanged, this._handlerAreaLevelChg)
        bus.Subscribe(Events.RunStarted,       this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,         this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled,     this._handlerRunCancelled)
    }

    _GetFixedSize() => Map("w", MicroLayoutPlusWidget.FIXED_W, "h", MicroLayoutPlusWidget.FIXED_H)

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

        stripeH := Max(1, Round(MicroLayoutPlusWidget.STRIPE_H * s))
        marginX := Max(2, Round(MicroLayoutPlusWidget.MARGIN_X * s))
        sepW    := Max(1, Round(MicroLayoutPlusWidget.SEP_W * s))
        sepYPad := Max(2, Round(MicroLayoutPlusWidget.SEP_Y_PAD * s))

        fontTimer := Max(7, Round(MicroLayoutPlusWidget.FONT_TIMER * s))
        fontXp    := Max(7, Round(MicroLayoutPlusWidget.FONT_XP * s))

        ; Content area below the accent stripe; vertical space is
        ; nearly the whole widget height because there's no chip row
        ; or footer.
        contentY := stripeH + 1
        contentH := h - stripeH - 2

        ; Three blocks + two separators. The third block absorbs the
        ; rounding remainder so total widths sum to contentW exactly
        ; (Floor on the first two would leave 1-2 px unused otherwise).
        contentW  := w - 2 * marginX
        blockW    := Floor((contentW - 2 * sepW) / 3)
        thirdW    := contentW - 2 * blockW - 2 * sepW
        if (thirdW < 10)
            thirdW := 10   ; defensive: pathological tiny widget

        ; Background + accent stripe (shared signature).
        this._BuildKalandraBand(0, 0, w, h, "surface")
        this._BuildAccentStripe(0, 0, w, stripeH)

        ; --- Block 1: zone timer (left) ---
        x := marginX
        wg.SetFont("s" fontTimer " c" Theme.Color("text") " bold", Theme.FONT_MONO)
        this._ctrls["zone_timer"] := wg.Add("Text",
            "x" x " y" contentY
            " w" blockW " h" contentH
            " Center 0x200"
            " Background" Theme.Color("surface"),
            "")
        x += blockW

        ; --- Separator 1 (1 px vertical in line color) ---
        ; Progress with cForeground = Background renders a solid bar.
        ; Disabled so clicks pass straight through to the underlying
        ; controls / game (the widget is click-through anyway, but
        ; Disabled is the explicit signal).
        sep1Y := contentY + sepYPad
        sep1H := contentH - 2 * sepYPad
        if (sep1H < 4)
            sep1H := contentH    ; tiny scale: don't lose the separator
        wg.Add("Progress",
            "x" x " y" sep1Y " w" sepW " h" sep1H
            " Disabled c" Theme.Color("line") " Background" Theme.Color("line"),
            100)
        x += sepW

        ; --- Block 2: run timer (middle) ---
        wg.SetFont("s" fontTimer " c" Theme.Color("text") " bold", Theme.FONT_MONO)
        this._ctrls["run_timer"] := wg.Add("Text",
            "x" x " y" contentY
            " w" blockW " h" contentH
            " Center 0x200"
            " Background" Theme.Color("surface"),
            "")
        x += blockW

        ; --- Separator 2 ---
        wg.Add("Progress",
            "x" x " y" sep1Y " w" sepW " h" sep1H
            " Disabled c" Theme.Color("line") " Background" Theme.Color("line"),
            100)
        x += sepW

        ; --- Block 3: XP chip (right, color-only) ---
        wg.SetFont("s" fontXp " c" Theme.Color("muted") " bold", Theme.FONT_UI)
        this._ctrls["xp_chip"] := wg.Add("Text",
            "x" x " y" contentY
            " w" thirdW " h" contentH
            " Center 0x200"
            " Background" Theme.Color("surface"),
            "XP")

        ; Resync state (handles mid-run widget swap)
        this._ResolveInitialActZone()

        ; Reset caches so the first render writes everything.
        this._lastZoneTimerText  := ""
        this._lastZoneTimerColor := ""
        this._lastRunTimerText   := ""
        this._lastRunTimerColor  := ""
        this._lastXpColor        := ""

        this._Refresh()

        this._highFreqTimerFn := this._OnHighFreqTimer.Bind(this)
        try SetTimer(this._highFreqTimerFn, MicroLayoutPlusWidget.TIMER_REFRESH_MS)
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

    ; 50ms timer — only the two timers (the XP chip color rarely
    ; changes, the Tick path handles it).
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
        this._RefreshZoneTimer()
        this._RefreshRunTimer()
        this._RefreshXp()
    }

    _RefreshZoneTimer()
    {
        if !this._ctrls.Has("zone_timer")
            return

        zoneMs := IsObject(this._zoneTracker) && this._currentZone != ""
                  ? this._zoneTracker.GetZoneTotalWithActive(this._currentZone)
                  : 0
        text  := MicroLayoutPlusWidget._FormatMs(zoneMs)
        color := MicroLayoutPlusWidget._ResolveTimerColor(zoneMs, this._GetZonePbMs())

        ctrl := this._ctrls["zone_timer"]
        if (color != this._lastZoneTimerColor)
        {
            fontTimer := Max(7, Round(MicroLayoutPlusWidget.FONT_TIMER * this._GetScale()))
            try ctrl.SetFont("s" fontTimer " c" color " bold", Theme.FONT_MONO)
            this._lastZoneTimerColor := color
        }
        if (text != this._lastZoneTimerText)
        {
            try ctrl.Value := text
            this._lastZoneTimerText := text
        }
    }

    _RefreshRunTimer()
    {
        if !this._ctrls.Has("run_timer")
            return

        runMs := IsObject(this._timer) ? this._timer.GetRunMs() : 0
        text  := MicroLayoutPlusWidget._FormatMs(runMs)
        color := MicroLayoutPlusWidget._ResolveTimerColor(runMs, this._GetRunPbMs())

        ctrl := this._ctrls["run_timer"]
        if (color != this._lastRunTimerColor)
        {
            fontTimer := Max(7, Round(MicroLayoutPlusWidget.FONT_TIMER * this._GetScale()))
            try ctrl.SetFont("s" fontTimer " c" color " bold", Theme.FONT_MONO)
            this._lastRunTimerColor := color
        }
        if (text != this._lastRunTimerText)
        {
            try ctrl.Value := text
            this._lastRunTimerText := text
        }
    }

    _RefreshXp()
    {
        if !this._ctrls.Has("xp_chip") || !IsObject(this._xp)
            return

        info := this._xp.GetXpPenaltyInfo()
        color := info.color

        ctrl := this._ctrls["xp_chip"]
        if (color != this._lastXpColor)
        {
            fontXp := Max(7, Round(MicroLayoutPlusWidget.FONT_XP * this._GetScale()))
            try ctrl.SetFont("s" fontXp " c" color " bold", Theme.FONT_UI)
            this._lastXpColor := color
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

    _OnRunStateChange()
    {
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
    ; PB lookups — mirror Steve Plus / Compact Plus.
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
    ; Static pure helpers — same shape as the larger Plus widgets
    ; so each variant can be tested in isolation.
    ; ============================================================

    static _ResolveTimerColor(currentMs, pbMs)
    {
        if (pbMs <= 0 || currentMs <= 0)
            return Theme.Color("text")
        if (currentMs <= pbMs)
            return Theme.Color("goodStrong")
        return Theme.Color("danger")
    }

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
    }
}
