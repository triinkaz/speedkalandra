; ============================================================
; SteveLayoutWidget - layout com timer DESTACADO (v17.14)
; ============================================================
;
; Modo "SteveTheHappyWhale" \u2014 nomeado pelo user que sugeriu via
; Discord feedback. Layout intermediario entre Compact (380x96, info
; rica) e Micro (200x32, info minima):
;
;   +-------------------------------------------------------+
;   | Act 1 \u00b7 The Riverbank              02:31.234        |  <- linha 1 (32px)
;   +-------------------------------------------------------+
;   | \u2717 0    XP    [\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588]                |  <- linha 2 (16px)
;   +-------------------------------------------------------+
;
; FILOSOFIA:
;   Timer da run em destaque visual (font grande + ms visiveis pra
;   percepcao de movimento continuo), info de contexto comprimida.
;   Ideal pra streamers/runners que querem o cronometro mais legivel
;   sem perder dados de zona/deaths/distribuicao.
;
; MILISSEGUNDOS:
;   Timer mostra "MM:SS.mmm" (3 digitos). Refresh em 50ms (20fps) via
;   SetTimer interno \u2014 o Evt.Tick padrao (300ms) seria lento demais
;   pra perceber ms correndo. Apenas o text do timer atualiza em alta
;   frequencia; outros campos (zona, deaths, XP, bar) atualizam no
;   tick normal.
;
; CORES DINAMICAS (igual Compact):
;   - Timer abaixo do PB do ato atual: goodStrong (#4ADE80 verde vivo)
;   - Timer acima do PB:                danger (#F87171 vermelho)
;   - Sem PB ou timer em 0:             text (branco-creme)
;   - Deaths: muted quando 0, warn (amber) quando >=1
;   - XP: status color via XpRules
;
; CONSTRUCAO:
;   widget := SteveLayoutWidget(bus, position, onPersist, timer,
;                               zoneTracker, xp, zonesCatalog,
;                               loadingTotals, pbService)


class SteveLayoutWidget extends LayoutWidgetBase
{
    static WIDGET_ID := "steveLayout"
    static DISPLAY_NAME := "Layout Steve"

    ; Tamanho BASE (scale=1.0)
    static FIXED_W := 380
    static FIXED_H := 64

    ; Layout BASE (scale=1.0)
    static STRIPE_H  := 2

    ; Linha 1: act/zona + timer destacado
    static LINE1_Y       := 6
    static LINE1_H       := 32
    static MARGIN_X      := 10
    static TIMER_W       := 210   ; v17.15.3: 170->210 evita corte em runs >= 1h
    static ACT_ZONE_GAP  := 8     ; margem entre act-zone e timer
    static BAR_TIMER_GAP := 12    ; espaco horizontal entre fim da bar e timer

    ; Linha 2: deaths + XP + bar (bar cheia altura pra ficar visivel)
    static LINE2_Y       := 42
    static LINE2_H       := 18
    static DEATHS_W      := 36
    static XP_W          := 22
    static GAP_LINE2     := 6     ; espaco entre elementos linha 2

    ; Fonts BASE (scale=1.0)
    static FONT_ACT_ZONE := 10
    static FONT_TIMER    := 28   ; destaque visual — alma do modo Steve
    static FONT_LINE2    := 8

    ; Refresh do timer em alta frequencia (pra mostrar ms correndo).
    ; 50ms = 20fps. Suficiente pra movimento visualmente suave sem
    ; stress de CPU. Apenas o text do timer atualiza nesse rate.
    static TIMER_REFRESH_MS := 50

    ; Bar (linha 2) — mesma paleta do Compact pra consistencia
    static COLOR_MAPA    := "38BDF8"
    static COLOR_LOADING := "FACC15"
    static COLOR_CIDADE  := "A78BFA"

    ; Baleia decorativa (mascote do modo) — v17.14b.
    ; Imagem opcional no canto esquerdo do widget. Se nao existir,
    ; layout volta ao normal sem ela.
    static WHALE_IMG_PATH := A_ScriptDir "\assets\whale_steve.png"
    static WHALE_X := 4
    static WHALE_Y := 8
    static WHALE_W := 48
    static WHALE_H := 48
    static WHALE_GAP := 4   ; espaco entre baleia e conteudo a direita

    ; Flag de runtime: true se a imagem carregou com sucesso no _BuildGui.
    ; Usada pra decidir se desloca o conteudo pra direita ou nao.
    _whaleLoaded := false

    ; Services
    _timer         := ""
    _zoneTracker   := ""
    _xp            := ""
    _zonesCatalog  := ""
    _loadingTotals := ""
    _pbService     := ""

    ; State (replicado do Compact pra resolucao robusta de PB)
    _currentZone   := ""
    _currentAct    := 0
    _deathCount    := 0

    ; Cache pra evitar repaint
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

    ; SetTimer interno pro refresh de alta frequencia do timer.
    _highFreqTimerFn := ""

    __New(bus, position, onPersist, timer, zoneTracker, xp,
          zonesCatalog := "", loadingTotals := "", pbService := "")
    {
        super.__New(SteveLayoutWidget.WIDGET_ID,
                    SteveLayoutWidget.DISPLAY_NAME,
                    bus, position, onPersist)
        this._timer         := timer
        this._zoneTracker   := zoneTracker
        this._xp            := xp
        this._zonesCatalog  := zonesCatalog
        this._loadingTotals := loadingTotals
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

        ; Dimensoes escaladas
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

        ; v17.15.3: baleia decorativa removida (feedback minimalist).
        ; contentX agora sempre na margem padrao.
        this._whaleLoaded := false
        contentX := marginX

        ; ============ LINHA 1: act+zona | timer destacado ============
        actZoneW := w - contentX - marginX - timerW - SteveLayoutWidget.ACT_ZONE_GAP

        ; act+zona (esquerda)
        this._SetFont(fontActZone, "text", "")
        this._ctrls["line1_act_zone"] := wg.Add("Text",
            "x" contentX " y" line1Y
            " w" actZoneW " h" line1H
            " Left"
            " Background" Theme.Color("surface"),
            "")

        ; Timer destacado (direita) — BOLD, font grande, cor dinamica.
        ; Ocupa ALTURA COMPLETA (linha 1 + linha 2): a bar da linha 2 para
        ; antes do timer (BAR_TIMER_GAP), deixando esse "L" de espaco pro
        ; timer crescer verticalmente. Style 0x200 (SS_CENTERIMAGE)
        ; centraliza o texto verticalmente dentro do control.
        timerH := line2Y + line2H - line1Y
        this._SetFont(fontTimer, "text", "bold")
        this._ctrls["line1_timer"] := wg.Add("Text",
            "x" (w - marginX - timerW) " y" line1Y
            " w" timerW " h" timerH
            " Right 0x200"
            " Background" Theme.Color("surface"),
            "")

        ; ============ LINHA 2: deaths + xp ============
        ; v17.15.3 (feedback minimalist): bar Mapa/Loading/Cidade
        ; removida do layout Steve. Linha 2 fica so com deaths + XP.
        x := contentX

        ; deaths (esquerda)
        this._SetFont(fontLine2, "muted", "bold")
        this._ctrls["line2_deaths"] := wg.Add("Text",
            "x" x " y" line2Y
            " w" deathsW " h" line2H
            " Left"
            " Background" Theme.Color("surface"),
            "")
        x += deathsW + gapL2

        ; XP indicator (texto fixo, cor dinamica)
        this._SetFont(fontLine2, "muted", "bold")
        this._ctrls["line2_xp"] := wg.Add("Text",
            "x" x " y" line2Y
            " w" xpW " h" line2H
            " Left"
            " Background" Theme.Color("surface"),
            "XP")

        ; Resync state inicial via zonesCatalog/zoneTracker
        this._ResolveInitialActZone()

        ; Render inicial
        this._lastTimerText  := ""
        this._lastTimerColor := ""
        this._lastActZoneText := ""
        this._lastDeathsText  := ""
        this._lastDeathsColor := ""
        this._lastXpColor     := ""
        this._Refresh()

        ; Inicia SetTimer interno pra refresh do timer em alta frequencia.
        ; Sem isso, ms nao atualizam (Evt.Tick padrao eh 300ms).
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

    ; Refresh em alta frequencia (50ms) \u2014 SO atualiza o timer.
    ; Skip silencioso quando widget nao esta visivel pra economizar CPU.
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
        ; v17.15.3: _RefreshBar removido (bar Mapa/Loading/Cidade fora
        ; do layout Steve agora).
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

        ; Cor: comparada com PB do ato atual
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

    ; v17.15.3: _RefreshBar removido. A bar empilhada Mapa/Loading/Cidade
    ; estava na linha 2 mas nao se encaixava no espirito minimalista do
    ; modo Steve (feedback Steve/Trinka via Discord). Compact layout
    ; ainda tem essa bar pra quem quer distribuicao visivel.

    ; ============================================================
    ; Event handlers de state
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
        ; Fallback: deriva ato via catalog
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

    ; Resync inicial \u2014 quando widget eh mostrado, ja pega zona/ato ativos
    ; do zoneTracker se houver run em andamento.
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

    ; Queries seguras pro PB service (mesmo padrao do Compact).
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

    ; Formata ms em "MM:SS.cc" ou "H:MM:SS".
    ; v17.15.3 (feedback Trinka/Steve): em runs >= 1h, esconde os
    ; centesimos. Motivo: "H:MM:SS.cc" cortava pela esquerda no
    ; layout Steve. Em runs sub-1h, centesimos visiveis pra dar
    ; sensacao de movimento continuo a 50ms de refresh.
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
        ; Para o SetTimer interno
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
