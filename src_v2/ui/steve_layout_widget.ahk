; ============================================================
; SteveLayoutWidget - layout with highlighted timer
; ============================================================
;
; "SteveTheHappyWhale" mode — named by the user who suggested it via
; Discord feedback. Layout between Compact (380x96, rich info) and
; Micro (200x32, minimal info):
;
;   +-------------------------------------------------------+
;   | Act 1 · The Riverbank              02:31.234         |  <- line 1 (32px)
;   +-------------------------------------------------------+
;   | ✗ 0    XP    [████████████████████]                  |  <- line 2 (16px)
;   +-------------------------------------------------------+
;
; PHILOSOPHY:
;   Run timer in visual focus (large font + visible ms for continuous
;   motion perception), context info compressed. Ideal for streamers/
;   runners who want the most readable clock without losing data on
;   zone/deaths/distribution.
;
; MILLISECONDS:
;   Timer shows "MM:SS.mmm" (3 digits). Refresh every 50ms (20fps) via
;   internal SetTimer — the standard Evt.Tick (300ms) would be too
;   slow to perceive ms running. Only the timer text updates at high
;   frequency; other fields (zone, deaths, XP) update on the normal
;   tick.
;
; DYNAMIC COLORS (same as Compact):
;   - Timer below the current act's PB: goodStrong (#4ADE80 vivid green)
;   - Timer above PB:                   danger (#F87171 red)
;   - No PB or timer at 0:              text (off-white)
;   - Deaths: muted when 0, warn (amber) when >=1
;   - XP: status color via XpRules
;
; CONSTRUCTION:
;   widget := SteveLayoutWidget(bus, position, onPersist, timer,
;                               zoneTracker, xp, zonesCatalog,
;                               pbService)


class SteveLayoutWidget extends LayoutWidgetBase
{
    static WIDGET_ID := "steveLayout"
    static DISPLAY_NAME := "Layout Steve"

    ; BASE size (scale=1.0)
    static FIXED_W := 380
    static FIXED_H := 64

    ; BASE layout (scale=1.0)
    static STRIPE_H  := 2

    ; Line 1: act/zone + highlighted timer
    static LINE1_Y       := 6
    static LINE1_H       := 32
    static MARGIN_X      := 10
    static TIMER_W       := 210   ; wide enough to fit MM:SS.mmm for runs >= 1h without cropping
    static ACT_ZONE_GAP  := 8     ; margin between act-zone and timer

    ; Line 2: deaths + XP
    static LINE2_Y       := 42
    static LINE2_H       := 18
    static DEATHS_W      := 36
    static XP_W          := 22
    static GAP_LINE2     := 6     ; space between line 2 elements

    ; BASE fonts (scale=1.0)
    static FONT_ACT_ZONE := 10
    static FONT_TIMER    := 28   ; visual highlight — soul of Steve mode
    static FONT_LINE2    := 8

    ; High-frequency timer refresh (to show running ms).
    ; 50ms = 20fps. Enough for visually smooth motion without CPU
    ; stress. Only the timer text updates at this rate.
    static TIMER_REFRESH_MS := 50

    ; Services
    _timer         := ""
    _zoneTracker   := ""
    _xp            := ""
    _zonesCatalog  := ""
    _pbService     := ""

    ; State (replicated from Compact for robust PB resolution)
    _currentZone   := ""
    _currentAct    := 0
    _deathCount    := 0

    ; Cache to avoid repaint
    _lastTimerText  := ""
    _lastTimerColor := ""
    _lastActZoneText := ""
    _lastDeathsText  := ""
    _lastDeathsColor := ""
    _lastXpColor     := ""
    _lastRenderMs    := 0

    _handlerTick           := ""
    _handlerZoneEntered    := ""
    _handlerCharLevelUp    := ""
    _handlerDeathDetected  := ""
    _handlerRunStarted     := ""
    _handlerRunReset       := ""
    _handlerRunCancelled   := ""

    ; Internal SetTimer for high-frequency timer refresh.
    _highFreqTimerFn := ""

    __New(bus, position, onPersist, timer, zoneTracker, xp,
          zonesCatalog := "", pbService := "")
    {
        super.__New(SteveLayoutWidget.WIDGET_ID,
                    SteveLayoutWidget.DISPLAY_NAME,
                    bus, position, onPersist)
        this._timer         := timer
        this._zoneTracker   := zoneTracker
        this._xp            := xp
        this._zonesCatalog  := zonesCatalog
        this._pbService     := pbService

        this._handlerTick           := (data) => this._OnTick(data)
        this._handlerZoneEntered    := (data) => this._OnZoneEntered(data)
        this._handlerCharLevelUp    := (data) => this._Refresh()
        this._handlerDeathDetected  := (data) => this._OnDeathDetected(data)
        this._handlerRunStarted     := (data) => this._OnRunStateChange()
        this._handlerRunReset       := (data) => this._OnRunStateChange()
        this._handlerRunCancelled   := (data) => this._OnRunStateChange()

        bus.Subscribe(Events.Tick,            this._handlerTick)
        bus.Subscribe(Events.ZoneEntered,     this._handlerZoneEntered)
        bus.Subscribe(Events.CharacterLevelUp, this._handlerCharLevelUp)
        bus.Subscribe(Events.DeathDetected,   this._handlerDeathDetected)
        bus.Subscribe(Events.RunStarted,      this._handlerRunStarted)
        bus.Subscribe(Events.RunReset,        this._handlerRunReset)
        bus.Subscribe(Events.RunCancelled,    this._handlerRunCancelled)
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
        w := this._w
        h := this._h
        s := this._GetScale()

        ; Scaled dimensions
        stripeH := Max(1, Round(SteveLayoutWidget.STRIPE_H * s))
        marginX := Max(4, Round(SteveLayoutWidget.MARGIN_X * s))
        timerW  := Max(80, Round(SteveLayoutWidget.TIMER_W * s))
        gapL2   := Max(2, Round(SteveLayoutWidget.GAP_LINE2 * s))

        line1Y := Round(SteveLayoutWidget.LINE1_Y * s)
        line1H := Round(SteveLayoutWidget.LINE1_H * s)
        line2Y := Round(SteveLayoutWidget.LINE2_Y * s)
        line2H := Round(SteveLayoutWidget.LINE2_H * s)

        deathsW := Round(SteveLayoutWidget.DEATHS_W * s)
        xpW     := Round(SteveLayoutWidget.XP_W * s)

        fontActZone := Max(7, Round(SteveLayoutWidget.FONT_ACT_ZONE * s))
        fontTimer   := Max(12, Round(SteveLayoutWidget.FONT_TIMER * s))
        fontLine2   := Max(6, Round(SteveLayoutWidget.FONT_LINE2 * s))

        ; Background
        this._BuildKalandraBand(0, 0, w, h, "surface")
        this._BuildAccentStripe(0, 0, w, stripeH)

        contentX := marginX

        ; ============ LINE 1: act+zone | highlighted timer ============
        actZoneW := w - contentX - marginX - timerW - SteveLayoutWidget.ACT_ZONE_GAP

        ; act+zone (left)
        this._SetFont(fontActZone, "text", "")
        this._ctrls["line1_act_zone"] := wg.Add("Text",
            "x" contentX " y" line1Y
            " w" actZoneW " h" line1H
            " Left"
            " Background" Theme.Color("surface"),
            "")

        ; Highlighted timer (right) — BOLD, large font, dynamic color.
        ; Occupies FULL HEIGHT (line 1 + line 2). Style 0x200
        ; (SS_CENTERIMAGE) centers the text vertically within the
        ; control.
        timerH := line2Y + line2H - line1Y
        this._SetFont(fontTimer, "text", "bold")
        this._ctrls["line1_timer"] := wg.Add("Text",
            "x" (w - marginX - timerW) " y" line1Y
            " w" timerW " h" timerH
            " Right 0x200"
            " Background" Theme.Color("surface"),
            "")

        ; ============ LINE 2: deaths + xp ============
        x := contentX

        ; deaths (left)
        this._SetFont(fontLine2, "muted", "bold")
        this._ctrls["line2_deaths"] := wg.Add("Text",
            "x" x " y" line2Y
            " w" deathsW " h" line2H
            " Left"
            " Background" Theme.Color("surface"),
            "")
        x += deathsW + gapL2

        ; XP indicator (fixed text, dynamic color)
        this._SetFont(fontLine2, "muted", "bold")
        this._ctrls["line2_xp"] := wg.Add("Text",
            "x" x " y" line2Y
            " w" xpW " h" line2H
            " Left"
            " Background" Theme.Color("surface"),
            "XP")

        ; Initial state resync via zonesCatalog/zoneTracker
        this._ResolveInitialActZone()

        ; Initial render
        this._lastTimerText  := ""
        this._lastTimerColor := ""
        this._lastActZoneText := ""
        this._lastDeathsText  := ""
        this._lastDeathsColor := ""
        this._lastXpColor     := ""
        this._Refresh()

        ; Starts internal SetTimer for high-frequency timer refresh.
        ; Without this, ms do not update (default Evt.Tick is 300ms).
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

    ; High-frequency refresh (50ms) — ONLY updates the timer.
    ; Silent skip when widget is not visible, to save CPU.
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
    }

    _RefreshActZone()
    {
        if !this._ctrls.Has("line1_act_zone")
            return

        actStr := this._currentAct > 0 ? ("Act " this._currentAct) : ("Act " Chr(0x2014))
        zoneStr := this._currentZone != "" ? this._currentZone : Chr(0x2014)
        text := actStr " " Chr(0x00B7) " " zoneStr

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
        text := this._FormatMsWithMillis(runMs)

        ; Color: compared with the current act's PB
        pbMs := this._GetRunPbMs()
        color := SteveLayoutWidget._ResolveTimerColor(runMs, pbMs)

        ctrl := this._ctrls["line1_timer"]

        if (color != this._lastTimerColor)
        {
            fontTimer := Max(12, Round(SteveLayoutWidget.FONT_TIMER * this._GetScale()))
            try ctrl.SetFont("s" fontTimer " c" color " bold", Theme.FONT_UI)
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
            fontLine2 := Max(6, Round(SteveLayoutWidget.FONT_LINE2 * this._GetScale()))
            try ctrl.SetFont("s" fontLine2 " c" color " bold", Theme.FONT_UI)
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
            fontLine2 := Max(6, Round(SteveLayoutWidget.FONT_LINE2 * this._GetScale()))
            try ctrl.SetFont("s" fontLine2 " c" color " bold", Theme.FONT_UI)
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
        ; Fallback: derive act via catalog
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

    ; Initial resync — when widget is shown, picks up active zone/act
    ; from the zoneTracker if there's a run in progress.
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
    ; Helpers
    ; ============================================================

    ; Safe queries to the PB service (same pattern as Compact).
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

    ; Formats ms as "MM:SS.cc" or "H:MM:SS". In runs >= 1h the
    ; hundredths are hidden because "H:MM:SS.cc" was cropping on the
    ; left edge of this layout; sub-1h runs keep the hundredths to
    ; give a sense of continuous motion at the 50ms refresh rate.
    _FormatMsWithMillis(ms)
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
        ; Stops the internal SetTimer
        if (this._highFreqTimerFn != "")
        {
            try SetTimer(this._highFreqTimerFn, 0)
            this._highFreqTimerFn := ""
        }

        ; Unsubscribe events
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
