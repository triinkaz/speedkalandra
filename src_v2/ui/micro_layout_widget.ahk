; ============================================================
; MicroLayoutWidget — micro-sized speedrun overlay (RUN + XP only)
; ============================================================
;
; Base size 200x32 at scale=1.0; the widget rescales via Ctrl+wheel
; and clamps to [0.5, 3.0] inside WidgetBase.SetScale.
;
; LAYOUT (base 200x32 at scale=1.0):
;
;   +--------------------------------+
;   |        03:33        |  XP      |
;   +--------------------------------+
;
; Two blocks: RUN timer (wide, mono) on the left + XP chip on the
; right, separated by a 1 px vertical line in `Theme.Color("line")`
; (3A3330) — no `/`, `;`, `·` glyphs.
;
; LAYOUT NOTES:
;   - RUN timer color tracks the per-act PB the same way the
;     larger widgets do, so the speedrun signal is preserved.
;   - 1 px separator between the two blocks (Theme `line` color).
;   - Zone-time block intentionally absent: the Compact layout
;     already surfaces zone time + PB, and duplicating that here
;     would make the Micro overlay redundant for users who run
;     Compact as the primary HUD.
;
; XP CHIP:
;   Fixed "XP" text whose color communicates status. Same
;   convention as the other layouts — text never changes, only
;   the color tracks XpRules.
;
; PB DISPLAY MODE (cfg.pbDisplayMode):
;   No literal PB chip in this layout — only the live-timer colour
;   uses the comparison target. cfg.pbDisplayMode = "avg5" swaps
;   the target from PB to the latest-5-run average, so the timer
;   colour reflects the same semantic as the larger widgets.
;   Hot-reloadable via Evt.PbDisplayModeChanged.
;
; CONSTRUCTION:
;   widget := MicroLayoutWidget(
;       bus, position, onPersist,
;       timer, zoneTracker, xpService,
;       zonesCatalog, personalBest, cfg, avgService)


class MicroLayoutWidget extends LayoutWidgetBase
{
    static WIDGET_ID := "microLayout"
    static DISPLAY_NAME := "Layout Micro"

    ; Base widget dimensions at scale=1.0.
    static FIXED_W := 200
    static FIXED_H := 32

    ; BASE layout (scale=1.0)
    static STRIPE_H  := 2
    static MARGIN_X  := 4
    static SEP_W     := 1      ; vertical separator width in px
    static SEP_Y_PAD := 4      ; vertical padding above/below separator
    static XP_W      := 40     ; fixed width of the right-side XP chip
                               ; (the RUN timer block absorbs the rest)
    static FONT_TIMER := 11    ; mono
    static FONT_XP    := 10    ; UI bold

    ; High-freq refresh — centiseconds visibly stutter on the
    ; default Tick (300 ms).
    static TIMER_REFRESH_MS := 50

    ; Services
    _timer        := ""
    _zoneTracker  := ""
    _xp           := ""
    _zonesCatalog := ""
    _pbService    := ""
    _cfg          := ""   ; AppSettings (optional, only used for pbDisplayMode)
    _avgService   := ""   ; RunAverageService (optional; required for cfg.pbDisplayMode = "avg5")

    ; State
    _currentZone := ""
    _currentAct  := 0

    ; Render caches — skip SetFont / Value writes per tick.
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
    _handlerPbDisplayMode := ""

    _highFreqTimerFn := ""

    __New(bus, position, onPersist, timer, zoneTracker, xp,
          zonesCatalog := "", pbService := "", cfg := "", avgService := "")
    {
        super.__New(MicroLayoutWidget.WIDGET_ID,
                    MicroLayoutWidget.DISPLAY_NAME,
                    bus, position, onPersist)
        this._timer        := timer
        this._zoneTracker  := zoneTracker
        this._xp           := xp
        this._zonesCatalog := zonesCatalog
        this._pbService    := pbService
        this._cfg          := cfg
        this._avgService   := avgService

        this._handlerTick         := (data) => this._OnTick(data)
        this._handlerZoneEntered  := (data) => this._OnZoneEntered(data)
        this._handlerCharLevelUp  := (data) => this._RefreshXp()
        this._handlerAreaLevelChg := (data) => this._RefreshXp()
        this._handlerRunStarted   := (data) => this._OnRunStateChange()
        this._handlerRunReset     := (data) => this._OnRunStateChange()
        this._handlerRunCancelled := (data) => this._OnRunStateChange()
        this._handlerPbDisplayMode := (data) => this._OnPbDisplayModeChanged()

        bus.Subscribe(Events.Tick,             this._handlerTick)
        bus.Subscribe(Events.ZoneEntered,      this._handlerZoneEntered)
        bus.Subscribe(Events.CharacterLevelUp, this._handlerCharLevelUp)
        bus.Subscribe(Events.AreaLevelChanged, this._handlerAreaLevelChg)
        bus.Subscribe(Events.RunStarted,       this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,         this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled,     this._handlerRunCancelled)
        bus.Subscribe(Events.PbDisplayModeChanged, this._handlerPbDisplayMode)
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
        w  := this._w
        h  := this._h
        s  := this._GetScale()

        stripeH := Max(1, Round(MicroLayoutWidget.STRIPE_H * s))
        marginX := Max(2, Round(MicroLayoutWidget.MARGIN_X * s))
        sepW    := Max(1, Round(MicroLayoutWidget.SEP_W * s))
        sepYPad := Max(2, Round(MicroLayoutWidget.SEP_Y_PAD * s))

        fontTimer := Max(7, Round(MicroLayoutWidget.FONT_TIMER * s))
        fontXp    := Max(7, Round(MicroLayoutWidget.FONT_XP * s))

        ; Content area below the accent stripe; vertical space is
        ; nearly the whole widget height because there's no chip row
        ; or footer.
        contentY := stripeH + 1
        contentH := h - stripeH - 2

        ; Two-block layout: RUN timer takes the bulk of the width
        ; on the left, XP chip sits on the right with a 1 px
        ; separator between. xpW is anchored to a fixed pixel count
        ; (scaled) so the chip stays compact regardless of widget
        ; width; the run timer absorbs whatever's left.
        contentW   := w - 2 * marginX
        xpW        := Max(20, Round(MicroLayoutWidget.XP_W * s))
        runTimerW  := contentW - xpW - sepW
        if (runTimerW < 40)
            runTimerW := 40   ; defensive: pathological tiny widget

        ; Background + accent stripe.
        this._BuildKalandraBand(0, 0, w, h, "surface")
        this._BuildAccentStripe(0, 0, w, stripeH)

        ; --- Block 1: RUN timer (left, wide) ---
        x := marginX
        wg.SetFont("s" fontTimer " c" Theme.Color("text") " bold", Theme.FONT_MONO)
        this._ctrls["run_timer"] := wg.Add("Text",
            "x" x " y" contentY
            " w" runTimerW " h" contentH
            " Center 0x200"
            " Background" Theme.Color("surface"),
            "")
        x += runTimerW

        ; --- Separator (1 px vertical in line color) ---
        ; Progress with cForeground = Background renders a solid bar.
        ; Disabled so clicks pass straight through to the underlying
        ; controls / game (the widget is click-through anyway, but
        ; Disabled is the explicit signal).
        sepY := contentY + sepYPad
        sepH := contentH - 2 * sepYPad
        if (sepH < 4)
            sepH := contentH    ; tiny scale: don't lose the separator
        wg.Add("Progress",
            "x" x " y" sepY " w" sepW " h" sepH
            " Disabled c" Theme.Color("line") " Background" Theme.Color("line"),
            100)
        x += sepW

        ; --- Block 2: XP chip (right, color-only) ---
        wg.SetFont("s" fontXp " c" Theme.Color("muted") " bold", Theme.FONT_UI)
        this._ctrls["xp_chip"] := wg.Add("Text",
            "x" x " y" contentY
            " w" xpW " h" contentH
            " Center 0x200"
            " Background" Theme.Color("surface"),
            "XP")

        ; Resync state (handles mid-run widget swap). Still needed
        ; even without a zone timer because the RUN timer color
        ; resolution depends on _currentAct -> _GetRunPbMs.
        this._ResolveInitialActZone()

        ; Reset caches so the first render writes everything.
        this._lastRunTimerText   := ""
        this._lastRunTimerColor  := ""
        this._lastXpColor        := ""

        this._Refresh()

        this._highFreqTimerFn := this._OnHighFreqTimer.Bind(this)
        try SetTimer(this._highFreqTimerFn, MicroLayoutWidget.TIMER_REFRESH_MS)
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

    ; 50ms timer — only the live RUN timer (the XP chip color
    ; rarely changes, the Tick path handles it).
    _OnHighFreqTimer()
    {
        if !this._gui
            return
        if !this._modeVisible
            return
        this._RefreshRunTimer()
    }

    _Refresh()
    {
        if !this._gui
            return
        this._RefreshRunTimer()
        this._RefreshXp()
    }

    _RefreshRunTimer()
    {
        if !this._ctrls.Has("run_timer")
            return

        runMs := IsObject(this._timer) ? this._timer.GetRunMs() : 0
        text  := MicroLayoutWidget._FormatMs(runMs)
        color := MicroLayoutWidget._ResolveTimerColor(runMs, this._GetRunPbMs())

        ctrl := this._ctrls["run_timer"]
        if (color != this._lastRunTimerColor)
        {
            fontTimer := Max(7, Round(MicroLayoutWidget.FONT_TIMER * this._GetScale()))
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
            fontXp := Max(7, Round(MicroLayoutWidget.FONT_XP * this._GetScale()))
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

    ; Hot-reload of cfg.pbDisplayMode — only the live-timer colour
    ; cache depends on the mode (no literal PB chip).
    _OnPbDisplayModeChanged()
    {
        this._lastRunTimerColor := ""
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
    ; PB lookups. Only run-level PB is consulted: the zone-time
    ; block is absent from this layout, so _GetZonePbMs would have
    ; no caller — dropped along with it.
    ;
    ; cfg.pbDisplayMode = "avg5" routes the lookup through the
    ; RunAverageService instead, so the live-timer colour reflects
    ; the average rather than the PB — same semantics as the
    ; larger widgets.
    ; ============================================================

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

    ; ============================================================
    ; Static pure helpers — same shape as the larger widgets so
    ; each variant can be tested in isolation.
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
        if (this._handlerPbDisplayMode != "")
        {
            this._bus.Unsubscribe(Events.PbDisplayModeChanged, this._handlerPbDisplayMode)
            this._handlerPbDisplayMode := ""
        }
    }
}
