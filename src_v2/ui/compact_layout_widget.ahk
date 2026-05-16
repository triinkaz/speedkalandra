; ============================================================
; CompactLayoutWidget - barra horizontal speedrun (Onda 4)
; ============================================================
;
; Substitui completamente o legado (que tinha 8 bandas + bossfight
; widget integrado, dependia de campaign/step/buffs/syncEngine).
;
; VERSAO POS-DEMOLICAO: minimalista, focada em speedrun puro.
;
; LAYOUT BASE (380x96 em scale=1.0):
;
;   +-------------------------------------------+
;   | [accent stripe 3px]                       |
;   | LINE 1 (3 zones): Ato 1 ·  Zona  · 00:00 / 00:00 |
;   | LINE 2 (3 zones): ✗ 2   | XP  | PB 00:00 / 00:00  |
;   | LINE 3 (stacked bar): [Mapa][Load][Cidade]|
;   +-------------------------------------------+
;
;   LINE 1 zone layout (v17.5 — antes era um text unico):
;     - act    (esquerda fixa):  "Ato X ·"  fonte FONT_LINE1
;     - zone   (centro variavel): nome da zona com fonte DINAMICA
;                                  (reduz se nao couber)
;     - zone_timer  (direita meio): "·  MM:SS"   cor dinamica baseada em zone PB
;     - run_timer   (direita fim):  "/  MM:SS"   cor dinamica baseada em run PB
;
;   Quando o nome do mapa eh longo, a fonte da zona reduz iterativamente
;   ate caber no espaco disponivel (em vez de empurrar os timers pra
;   direita ou cortar texto).
;
;   LINE 2 zone layout:
;     - Zona 1 (~quarter esquerda):  "✗ N" contador de mortes da run atual
;                                    (cor muted=cinza quando 0, warn=amber quando >=1).
;                                    Zera em RunStarted/Reset/Cancelled.
;                                    v17.13: substituiu o display "Lv X · Area Y".
;     - Zona 2 (~quarter centro):    "XP" (texto fixo, cor dinamica via
;                                    XpRules — verde/amber/vermelho/cinza)
;     - Zona 3 (half direita):       "PB MM:SS / MM:SS" (cor lavender suave
;                                    pra diferenciar dos outros indicadores;
;                                    primeiro = zone PB, segundo = run PB)
;
; PERSONAL BESTS (v17.13):
;   Os 2 timers da LINE 1 mudam de cor baseado em comparacao com PB:
;     timer_atual <= PB → good (verde dessaturado)
;     timer_atual >  PB → danger (vermelho dessaturado)
;     PB ausente       → text (branco)
;
;   PBs sao mantidos pelo PersonalBestService (carregados do INI no
;   startup, atualizados em RunCompleted pelo composition root).
;
;   RUN PB POR ATO (v17.13):
;     O Run timer agora compara contra o PB DO ATO ATUAL, nao um PB
;     global. Cada ato tem seu proprio PB (tempo total da run no
;     momento que aquele ato terminou). Quando o user muda de ato
;     durante a run, o overlay automaticamente compara com o PB do
;     novo ato — timer pode mudar de cor na hora.
;
;     PB DISPLAY (line2_pb): "PB ZONE_PB / ACT_PB" — segundo numero eh
;     o PB do ato atual (nao um PB global).
;
;   PRIMEIRO TIMER NA LINE 1 = tempo TOTAL na zona ativa durante a
;   run (soma todas as visitas + elapsed atual). NAO eh tempo desde
;   a ultima entrada — esse mostraria 00:00 toda vez que o pause
;   detection pausa/despausa (cada ciclo zera _startMs internamente).
;   Usa GetZoneTotalWithActive() pra robusto.
;
;   Largura base 380 (v17.4, era 500): User redimensiona via Ctrl+wheel
;   se precisar de mais largura. Zonas longas tem fonte reduzida
;   automaticamente.
;
; INDICADOR DE XP (v17.3):
;   xp_indicator eh um Text control fixo "XP" cuja COR muda conforme
;   o status calculado pelo XpRules. Texto sempre "XP" — nao mostra
;   o status textual (OK/LIMITE/PENALTY/?) por preferencia de UX.
;
;   Status -> cor (de XpRules):
;     ok       -> verde dessaturado (B8C7B0)
;     limit    -> amber (F59E0B)
;     penalty  -> vermelho dessaturado (F87171)
;     unknown  -> cinza (8B8B8B)
;
;   Text controls do AHK so suportam UMA cor por controle. A cor eh
;   atualizada via ctrl.SetFont quando o status XP muda (cache evita
;   repaint a cada tick).
;
; BOSS DEFEATED VERDE (REMOVIDO em v17.13):
;   Boss timer feature foi removida (voice lines de classe nao iam pra
;   Client.txt do PoE2, entao detection era inviavel pra maioria dos bosses).
;
; SCALE:
;   O widget INTEIRO escala por `_position.scale` (interativo via
;   Ctrl+wheel sobre o widget). _w/_h vem do LayoutWidgetBase.Show()
;   ja escalados, e _BuildGui propaga o scale em todas as dimensoes
;   internas (margens, posicoes de linha, font sizes, thresholds da
;   stacked bar).
;
;   Limites: [0.5, 3.0] (clamp em WidgetBase.SetScale).
;
;   STACKED BAR (paridade legado PerfWidget):
;     mapaMs   = max(0, runMs - loadingMs - townMs)
;     mapaPct  = 100 - loadPct - townPct    (garante soma = 100)
;     Cores: Mapa azul, Loading amarelo, Cidade roxo.
;     Texto inline (label + %) so quando segmento >= minLabelW de
;     largura escalada (~70px no scale 1.0).
;
; SUBSCRIPTIONS:
;   Events.Tick               -> refresh (300ms tipico)
;   Events.ZoneEntered        -> atualiza zona + ato
;   Events.CharacterLevelUp   -> refresh (afeta XP indicator)
;   Events.AreaLevelChanged   -> refresh (afeta XP indicator)
;   Events.DeathDetected      -> incrementa contador de mortes (v17.13)
;   Events.RunStarted         -> zera contador de mortes (v17.13)
;   Events.RunReset/Cancelled -> zera contador + volta a estado vazio
;
; DEPENDENCIAS:
;   timer         : TimerService    -> GetRunMs()
;   zoneTracker   : ZoneTrackingService -> GetActiveZone(), GetZoneTotalWithActive(),
;                                           GetTotalTownMs()
;   xp            : XpService       -> GetCharacterLevel(), GetCurrentAreaLevel(),
;                                       GetXpPenaltyInfo()
;   zonesCatalog  : ZonesCatalog (opcional) -> mapeia zona -> ato
;   loadingTotals : LoadingTotalsService (opcional) -> GetTotalMs() pro stacked bar
;   cfg           : AppSettings (opcional) -> vendorRegexes
;   pbService     : PersonalBestService (opcional) -> GetRunPbMs(), GetZonePbMs()
;
; CONSTRUCAO:
;   widget := CompactLayoutWidget(bus, position, onPersist,
;                                 timer, zoneTracker, xp,
;                                 zonesCatalog, loadingTotals, cfg,
;                                 pbService)

class CompactLayoutWidget extends LayoutWidgetBase
{
    static WIDGET_ID := "compactLayout"
    static DISPLAY_NAME := "Layout Compact"

    ; Dimensoes BASE (scale=1.0). Show() aplica scale em cima.
    static FIXED_W := 380
    static FIXED_H := 96

    ; Layout BASE (scale=1.0). _BuildGui multiplica por scale em runtime.
    static MARGIN_X := 12
    static STRIPE_H := 3
    static LINE1_Y  := 10
    static LINE1_H  := 28
    static LINE2_Y  := 42
    static LINE2_H  := 20
    static BAR_Y    := 68
    static BAR_H    := 18

    ; Vendor clipboard buttons (v17.12): 3 quadrados discretos na
    ; LATERAL DIREITA, empilhados verticalmente e centrados na altura.
    ; Click (com Ctrl ativo) copia cfg.vendorRegexes[i] pra A_Clipboard.
    ;
    ; A coluna ocupa BTN_COL_W px do lado direito; o conteudo principal
    ; (LINE 1/2/3) eh re-largura-calculado pra contentW = w - BTN_COL_W.
    ; Banda surface e accent stripe continuam usando w completo — os
    ; botoes ficam visualmente "dentro" do widget, com bg surface3 sobre
    ; surface.
    static BTN_COL_W      := 22    ; largura da coluna lateral (btn + margem direita)
    static BTN_SIZE       := 18    ; lado do quadrado
    static BTN_VGAP       := 3     ; gap vertical entre botoes
    static BTN_MARGIN_R   := 4     ; margem entre botao e borda direita do widget

    ; LINE 1 zone widths (v17.5) — BASE em scale=1.0
    ; Reserva espaco fixo pra "Ato X ·" (esquerda) e timers (direita).
    ; Zona ocupa o que sobrar entre eles e tem fonte dinamica.
    ; Em v17.13 o timer block foi SUBDIVIDIDO em zone_timer + run_timer
    ; pra ter cores independentes baseadas em PB. LINE1_TIMER_W eh a
    ; soma das duas.
    static LINE1_ACT_W        := 60    ; "Ato 1 ·"  ate "Ato 99 ·"
    static LINE1_ZONE_TIMER_W := 80    ; "·  MM:SS"  ate "·  1:23:45"
    static LINE1_RUN_TIMER_W  := 70    ; "/  MM:SS"  ate "/  1:23:45"
    static LINE1_TIMER_W      := 150   ; soma das duas — mantida pra calcs legados

    ; Font sizes BASE (escaladas por _position.scale em runtime)
    ; FONT_LINE1 reduzido de 13 -> 11 em v17.13 pra evitar overlap entre
    ; zone label longo e os 2 timers separados (zone_timer + run_timer).
    static FONT_LINE1 := 11
    static FONT_LINE2 := 9
    static FONT_BAR   := 8
    static FONT_BTN   := 8    ; v17.12: tamanho dos labels 1/2/3 nos quadrados laterais

    ; Minimum font size pro nome da zona (apos shrinking). Em scale=1.0,
    ; font 7 ainda eh legivel. Mais menor que isso vira ilegivel —
    ; melhor truncar do que ler.
    static FONT_ZONE_MIN := 7

    ; Thresholds BASE pro label da stacked bar (em scale=1.0).
    static LABEL_MIN_W      := 70    ; >= isto: mostra "Mapa 70%"
    static LABEL_MIN_PCT_W  := 30    ; >= isto: mostra "70%" so

    ; Cores do stacked bar (paridade com RunStatsPlotBuilder.SegmentDefinitions)
    static COLOR_MAPA    := "38BDF8"    ; azul
    static COLOR_LOADING := "FACC15"    ; amarelo
    static COLOR_CIDADE  := "A78BFA"    ; roxo

    ; Cor do display de PB (LINE 2 zone 3). Teal-400 (v17.13c) — pink
    ; F472B6 ainda compartilhava componente azul-violeta com a cor
    ; "Cidade" (A78BFA, violet-400), parecendo similar em monitores.
    ; Teal foge completamente desse espectro: verde-azulado, distinto
    ; de tudo na paleta:
    ;   - 2DD4BF (R:45 G:212 B:191) - teal
    ;   - A78BFA (R:167 G:139 B:250) - violet cidade
    ;   - 38BDF8 (R:56 G:189 B:248) - sky mapa
    ;   - 4ADE80 (R:74 G:222 B:128) - green goodStrong
    ;   - FACC15 (R:250 G:204 B:21) - yellow loading
    static PB_COLOR := "2DD4BF"

    ; --- Deps ---
    _timer         := ""
    _zoneTracker   := ""
    _xp            := ""
    _zonesCatalog  := ""
    _loadingTotals := ""
    _cfg           := ""    ; AppSettings (Onda 8 — usado pelos botoes V1/V2/V3)
    _pbService     := ""    ; PersonalBestService (v17.13)

    ; Cache de state pra render
    _currentZone     := ""
    _currentAct      := 0
    _deathCount      := 0    ; v17.13 — contador de mortes da run atual
    _lastRenderMs    := 0
    _lastXpColor     := ""   ; pra evitar SetFont desnecessario (perf)
    _lastZoneTimerColor := ""   ; idem pra line1_zone_timer
    _lastRunTimerColor  := ""   ; idem pra line1_run_timer
    _lastDeathColor  := ""   ; idem pra line2_left (death counter)
    _lastPbText      := ""   ; cache do texto PB pra evitar repaint
    _lastZoneFontSize := 0   ; idem pro line1_zone font dinamica
    _lastZoneText    := ""   ; cache do texto da zona pra evitar recompute

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
    ; _GetScale - le scale atual, com fallback defensivo
    ; ============================================================
    _GetScale()
    {
        s := this._position.scale
        if (!IsNumber(s) || s <= 0)
            return 1.0
        return s
    }

    ; ============================================================
    ; _BuildGui - constroi controles aplicando scale
    ; ============================================================
    _BuildGui()
    {
        wg := this._gui
        w  := this._w           ; ja escalado pelo Show()
        h  := this._h
        s  := this._GetScale()

        ; --- Dimensoes escaladas (px) ---
        marginX := Max(1, Round(CompactLayoutWidget.MARGIN_X * s))
        stripeH := Max(1, Round(CompactLayoutWidget.STRIPE_H * s))
        line1Y  := Round(CompactLayoutWidget.LINE1_Y * s)
        line1H  := Max(8, Round(CompactLayoutWidget.LINE1_H * s))
        line2Y  := Round(CompactLayoutWidget.LINE2_Y * s)
        line2H  := Max(8, Round(CompactLayoutWidget.LINE2_H * s))
        barY    := Round(CompactLayoutWidget.BAR_Y * s)
        barH    := Max(4, Round(CompactLayoutWidget.BAR_H * s))

        ; LINE 1 zone widths escalados
        line1ActW       := Max(20, Round(CompactLayoutWidget.LINE1_ACT_W        * s))
        line1ZoneTimerW := Max(40, Round(CompactLayoutWidget.LINE1_ZONE_TIMER_W * s))
        line1RunTimerW  := Max(35, Round(CompactLayoutWidget.LINE1_RUN_TIMER_W  * s))
        line1TimerW     := line1ZoneTimerW + line1RunTimerW

        ; --- Font sizes (clamp minimo pra legibilidade) ---
        fontL1  := Max(7, Round(CompactLayoutWidget.FONT_LINE1 * s))
        fontL2  := Max(6, Round(CompactLayoutWidget.FONT_LINE2 * s))
        fontBar := Max(6, Round(CompactLayoutWidget.FONT_BAR   * s))

        ; Coluna lateral pros botoes vendor (v17.12). contentW eh a
        ; largura util pra LINE 1/2/3 (conteudo principal); a banda
        ; surface e a accent stripe ainda usam w completo (cobrem
        ; widget inteiro pra que os botoes fiquem visualmente dentro).
        btnColW  := Round(CompactLayoutWidget.BTN_COL_W * s)
        contentW := w - btnColW

        ; Background surface principal (banda cobrindo tudo)
        this._BuildKalandraBand(0, 0, w, h, "surface")

        ; Accent stripe topo
        this._BuildAccentStripe(0, 0, w, stripeH)

        ; --- LINE 1: 4 controles separados ---
        ; line1_act:         "Ato X ·"        (esquerda fixa)
        ; line1_zone:        nome da zona     (centro, fonte dinamica)
        ; line1_zone_timer:  "· MM:SS"        (direita-meio, cor dinamica vs zone PB)
        ; line1_run_timer:   "/ MM:SS"        (direita-fim,  cor dinamica vs run PB)

        ; line1_act (esquerda, alinhado esquerda)
        this._SetFont(fontL1, "text", "")
        this._ctrls["line1_act"] := wg.Add("Text",
            "x" marginX " y" line1Y
            " w" line1ActW " h" line1H
            " Left Background" Theme.Color("surface"),
            "")

        ; line1_zone (centro, alinhado esquerda, fonte dinamica)
        ; Posicao: apos act, antes dos timers
        zoneX := marginX + line1ActW
        zoneW := contentW - 2*marginX - line1ActW - line1TimerW
        if (zoneW < 20)
            zoneW := 20   ; defensivo: width minima
        this._SetFont(fontL1, "text", "")
        this._ctrls["line1_zone"] := wg.Add("Text",
            "x" zoneX " y" line1Y
            " w" zoneW " h" line1H
            " Left Background" Theme.Color("surface"),
            "")

        ; line1_zone_timer (direita-meio, right-aligned, cor dinamica)
        zoneTimerX := contentW - marginX - line1TimerW
        this._SetFont(fontL1, "text", "")
        this._ctrls["line1_zone_timer"] := wg.Add("Text",
            "x" zoneTimerX " y" line1Y
            " w" line1ZoneTimerW " h" line1H
            " Right Background" Theme.Color("surface"),
            "")

        ; line1_run_timer (direita-fim, right-aligned, cor dinamica)
        runTimerX := zoneTimerX + line1ZoneTimerW
        this._SetFont(fontL1, "text", "")
        this._ctrls["line1_run_timer"] := wg.Add("Text",
            "x" runTimerX " y" line1Y
            " w" line1RunTimerW " h" line1H
            " Right Background" Theme.Color("surface"),
            "")

        ; --- LINE 2: 3 zonas ---
        ; Zone 1: "Lv 47 · Area 10" (alinhado esquerda)
        ; Zone 2: "XP" (texto fixo, centralizado, cor dinamica)
        ; Zone 3: "PB MM:SS / MM:SS" (cor lavender suave — PB display, v17.13)
        halfW := contentW / 2
        quarterW := contentW / 4

        ; LINE 2 zone 1 esquerda: char/area level
        this._SetFont(fontL2, "muted", "")
        ctrlLine2Left := wg.Add("Text",
            "x" marginX " y" line2Y
            " w" (quarterW - marginX) " h" line2H
            " Background" Theme.Color("surface"),
            "")
        this._ctrls["line2_left"] := ctrlLine2Left

        ; LINE 2 zone 2 centro: XP indicator (cor dinamica setada no Refresh)
        ; Texto fixo "XP" — so a cor muda baseada no status.
        this._SetFont(fontL2, "muted", "bold")
        ctrlXpIndicator := wg.Add("Text",
            "x" quarterW " y" line2Y
            " w" (halfW - quarterW) " h" line2H
            " Center Background" Theme.Color("surface"),
            "")
        this._ctrls["xp_indicator"] := ctrlXpIndicator

        ; LINE 2 zone 3 direita: PB display (v17.13).
        ; Texto: "PB ZZ:ZZ / TT:TT" — primeiro = zone PB, segundo = run PB.
        ; Fallback: "—" pra valores ausentes (zona nova ou primeiro start do app).
        ; Cor: lavender dessaturado (PB_COLOR) right-aligned.
        wg.SetFont("s" fontL2 " c" CompactLayoutWidget.PB_COLOR " bold", Theme.FONT_UI)
        ctrlLine2Pb := wg.Add("Text",
            "x" halfW " y" line2Y
            " w" (halfW - marginX) " h" line2H
            " Right Background" Theme.Color("surface"),
            "")
        this._ctrls["line2_pb"] := ctrlLine2Pb

        ; --- LINE 3: STACKED BAR (Mapa / Loading / Cidade) ---
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

        ; --- LATERAL DIREITA: VENDOR CLIPBOARD BUTTONS (v17.12) ---
        ; 3 quadrados discretos empilhados verticalmente. Click com Ctrl
        ; ativo copia cfg.vendorRegexes[i] pra A_Clipboard.
        this._BuildVendorButtons(s)

        ; Reset caches pra forcar primeiro SetFont
        this._lastXpColor       := ""
        this._lastZoneTimerColor := ""
        this._lastRunTimerColor  := ""
        this._lastPbText        := ""
        this._lastZoneFontSize  := 0
        this._lastZoneText      := ""

        this._Refresh()
    }

    ; ============================================================
    ; Refresh - le state dos services e atualiza controles
    ; ============================================================
    _Refresh()
    {
        if !this._gui
            return

        ; --- LINE 1: 4 controles separados ---
        ; line1_act:         "Ato X ·"
        ; line1_zone:        nome da zona (com fonte dinamica)
        ; line1_zone_timer:  "·  MM:SS"  (cor vs zone PB)
        ; line1_run_timer:   "/  MM:SS"  (cor vs run PB)
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
        this._RefreshZoneText(zoneStr)   ; cuida da fonte dinamica

        ; --- LINE 2 zone 1: contador de mortes ---
        this._RefreshDeathCount()

        ; --- LINE 2 zone 2: XP indicator com cor dinamica ---
        this._RefreshXpIndicator()

        ; --- LINE 2 zone 3: PB display ---
        this._RefreshPbDisplay()

        ; --- LINE 3: stacked bar ---
        this._RefreshBar(runMs)
    }

    ; ============================================================
    ; _RefreshTimerColors - aplica cor dinamica nos 2 timers da LINE 1
    ;
    ; Regra (independente pra cada timer):
    ;   - PB ausente (0):              cor = text (branco)
    ;   - timer_atual <= PB:           cor = good (verde dessaturado)
    ;   - timer_atual >  PB:           cor = danger (vermelho dessaturado)
    ;
    ; Edge case: durante uma run em curso, comparar runMs (que cresce
    ; continuamente) com runPB faz sentido — indica visualmente se voce
    ; ainda esta abaixo do tempo recorde.
    ;
    ; Cache _lastZoneTimerColor / _lastRunTimerColor evitam SetFont a
    ; cada tick quando a cor nao mudou.
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

    ; Resolve cor pra um timer baseado em comparacao com PB.
    ;
    ; v17.13: usa "goodStrong" (4ADE80, vibrante) em vez de "good"
    ; (B8C7B0, dessaturado) pra que o verde "abaixo do PB" seja
    ; visualmente mais forte e contrastante com o vermelho.
    _ResolveTimerColor(currentMs, pbMs)
    {
        ; PB ausente ou timer ainda em 0: cor neutra
        if (pbMs <= 0 || currentMs <= 0)
            return Theme.Color("text")
        if (currentMs <= pbMs)
            return Theme.Color("goodStrong")
        return Theme.Color("danger")
    }

    ; Queries seguras pro PB service (tolera _pbService = "" sem deps).
    ;
    ; v17.13: GetRunPbMs agora retorna PB DO ATO ATUAL em vez de PB
    ; global. Quando o user muda de ato durante a run, o valor muda
    ; automaticamente — _currentAct eh atualizado por _OnZoneEntered
    ; e refresh recalcula a cada tick.
    ;
    ; ROBUSTEZ (v17.13b): se _currentAct=0 (ZoneEntered ainda nao foi
    ; disparado ou veio sem actIndex), tenta derivar do _zonesCatalog
    ; usando _currentZone como fallback. Evita PB ficar vazio durante
    ; uma run em curso so porque o widget perdeu o ZoneEntered inicial.
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

    ; Resolve o ato atual usando fallbacks em cascata (v17.13b):
    ;   1. this._currentAct (setado por _OnZoneEntered)
    ;   2. derivar de _currentZone via _zonesCatalog.GetActOfName
    ;   3. consultar zona ativa do _zoneTracker + catalog
    ;
    ; Util pra resiliencia em situacoes tipo:
    ;   - App startou com run hidratada (sem ZoneEntered novo)
    ;   - ZoneEntered veio com actIndex=0 (zona nao catalogada)
    _ResolveCurrentAct()
    {
        if (this._currentAct > 0)
            return this._currentAct

        ; Fallback 1: usa _currentZone se temos
        if (this._currentZone != "" && IsObject(this._zonesCatalog))
        {
            act := this._zonesCatalog.GetActOfName(this._currentZone)
            if (act > 0)
            {
                this._currentAct := act    ; cacheia pra proximos ticks
                return act
            }
        }

        ; Fallback 2: consulta zone tracker (caso _currentZone esteja vazio)
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
    ; _RefreshPbDisplay - atualiza texto do line2_pb
    ;
    ; Formato: "PB ZZ:ZZ / TT:TT"  (ambos disponiveis)
    ;          "PB — / TT:TT"     (zone PB ausente)
    ;          "PB ZZ:ZZ / —"     (run PB ausente)
    ;          "PB — / —"       (ambos ausentes)
    ;
    ; v17.13b: sempre exibe o display (mesmo com ambos PBs ausentes),
    ; pra que o user saiba ONDE o PB apareceria — evita parecer que o
    ; feature nao esta funcionando quando ainda nao ha PBs salvos.
    ;
    ; Cache _lastPbText evita escrita repetida no ctrl.
    ; Cor eh fixa (PB_COLOR) e setada em _BuildGui — nao precisa re-aplicar.
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
    ; _RefreshZoneText - texto da zona com fonte que reduz se necessario
    ;
    ; Quando o nome do mapa eh longo (e.g. "Cemetery of the Eternals"),
    ; nao queremos cortar texto nem empurrar os timers. Em vez disso,
    ; reduzimos a fonte iterativamente ate caber no espaco disponivel.
    ;
    ; Estimativa de largura: chars × fontSize × 0.6 (Segoe UI). Nao eh
    ; precisa em pixels mas funciona pra decidir "cabe ou nao cabe".
    ;
    ; Cache _lastZoneFontSize evita SetFont desnecessario quando a
    ; mesma zona renderiza repetidamente.
    ; ============================================================
    _RefreshZoneText(zoneStr)
    {
        if !this._ctrls.Has("line1_zone")
            return
        ctrl := this._ctrls["line1_zone"]

        s := this._GetScale()
        baseSize := Max(7, Round(CompactLayoutWidget.FONT_LINE1 * s))
        minSize  := Max(6, Round(CompactLayoutWidget.FONT_ZONE_MIN * s))

        ; Espaco disponivel pra zona (mesma conta do _BuildGui)
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

        ; Encontra a maior fonte que cabe (top-down)
        sizeFound := baseSize
        while (sizeFound > minSize)
        {
            estW := CompactLayoutWidget._EstimateTextW(zoneStr, sizeFound)
            if (estW <= zoneAvailW)
                break
            sizeFound--
        }

        ; Aplica fonte so se mudou
        if (sizeFound != this._lastZoneFontSize)
        {
            try ctrl.SetFont("s" sizeFound " c" Theme.Color("text"), Theme.FONT_UI)
            this._lastZoneFontSize := sizeFound
        }

        ; Aplica texto so se mudou
        if (zoneStr != this._lastZoneText)
        {
            try ctrl.Value := zoneStr
            this._lastZoneText := zoneStr
        }
    }

    ; ============================================================
    ; _EstimateTextW - estima largura de texto em pixels (Segoe UI)
    ;
    ; Aproximacao: chars × fontSize × 0.6. Segoe UI tem chars variaveis
    ; (M largo, i estreito) mas a media gira em torno disso.
    ;
    ; Conservador (subestima ligeiramente): chars largos podem exceder
    ; estimativa. Em compensacao, controles em AHK truncam graciosamente
    ; sem quebrar layout.
    ; ============================================================
    static _EstimateTextW(text, fontSize)
    {
        return Round(StrLen(text) * fontSize * 0.6)
    }

    ; ============================================================
    ; _RefreshXpIndicator - atualiza COR do texto "XP" fixo
    ;
    ; Texto: sempre "XP" — nao mostra OK/LIMITE/PENALTY/? por
    ; preferencia de UX (apenas a cor comunica o status).
    ;
    ; Cor vem de XpRules.Calculate (via xpService.GetXpPenaltyInfo):
    ;   ok      -> good (verde dessaturado)
    ;   limit   -> warn (amber)
    ;   penalty -> danger (vermelho dessaturado)
    ;   unknown -> COLOR_UNKNOWN (cinza)
    ;
    ; Otimizacao: so chama SetFont quando a cor mudou (evita repaint
    ; desnecessario a cada tick).
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
    ; _RefreshBar - calcula pcts e ajusta os 3 segments
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
    ; Vendor clipboard buttons (lateral direita, v17.12)
    ; ============================================================
    ;
    ; Cria 3 controles Text quadrados (BTN_SIZE x BTN_SIZE) com Background
    ; surface3, empilhados verticalmente na lateral direita e centrados
    ; verticalmente no widget (descontando a accent stripe do topo).
    ;
    ; LABELS:
    ;   Preenchido: numero ("1"/"2"/"3") em cor 'muted' (cinza dessaturado)
    ;   Vazio:      ponto medio ("·") em cor 'subtle' (cinza mais fraco)
    ;
    ; CLICK-THROUGH:
    ;   O widget tem WS_EX_TRANSPARENT setado por default (cliques passam
    ;   pro jogo). OverlayInteractionService remove esse bit enquanto
    ;   Ctrl esta pressionado. Ou seja: os botoes so respondem com Ctrl
    ;   ativo — mesmo comportamento de drag/resize do overlay.
    ;
    ; CLOSURE CAPTURE:
    ;   _BindVendorButton eh um metodo helper isolado porque a arrow
    ;   function precisa capturar slotIdx por VALOR. Como slotIdx eh
    ;   parametro do metodo, cada chamada cria escopo novo e o closure
    ;   captura corretamente. Se inlinassemos o lambda dentro do Loop
    ;   usando A_Index ou i diretamente, capturaria por referencia e
    ;   todos os 3 botoes acionariam o ultimo slot.
    ; ============================================================
    _BuildVendorButtons(s)
    {
        wg      := this._gui
        btnSize := Max(10, Round(CompactLayoutWidget.BTN_SIZE * s))
        vGap    := Max(1, Round(CompactLayoutWidget.BTN_VGAP * s))
        mRight  := Max(1, Round(CompactLayoutWidget.BTN_MARGIN_R * s))
        fontBtn := Max(7, Round(CompactLayoutWidget.FONT_BTN * s))
        stripeH := Max(1, Round(CompactLayoutWidget.STRIPE_H * s))

        ; Posicao X: alinhado a direita do widget
        btnX := this._w - mRight - btnSize

        ; Empilhamento vertical centralizado abaixo do accent stripe
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

    ; Helper isolado pra garantir captura de slotIdx por valor (escope
    ; novo a cada chamada). Ver doc do _BuildVendorButtons.
    _BindVendorButton(btn, slotIdx)
    {
        btn.OnEvent("Click", (*) => this._OnVendorClick(slotIdx))
    }

    ; Handler de click. Le cfg.vendorRegexes[slotIdx]; se vazio, mostra
    ; TrayTip orientando o user pra Settings. Se preenchido, copia pra
    ; A_Clipboard e mostra TrayTip com preview (primeiros 30 chars).
    ;
    ; Tolerante: cfg pode ser "" (sem deps injetadas) — no-op silencioso.
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
    ; Helpers de formato
    ; ============================================================

    _FormatAct()
    {
        if (this._currentAct > 0)
            return "Act " this._currentAct
        return "Act —"
    }

    ; v0.1.2 (auditoria #19): consolidado em Duration.FormatMs.
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
    ; _OnRunRestart - zera contador de mortes quando a run reinicia
    ;
    ; Subscrito em 3 eventos: RunStarted, RunReset, RunCancelled.
    ; Sempre que a run entra em um estado "comeco do zero", o contador
    ; volta a 0. RunCompleted NAO eh tratado aqui — quando o user
    ; finaliza a run, os dados ficam preservados ate a proxima Reset/Start
    ; (pra eventual review/plot post-run).
    ; ============================================================
    _OnRunRestart(data)
    {
        this._deathCount := 0
        this._Refresh()
    }

    ; ============================================================
    ; _OnDeathDetected - incrementa contador local
    ;
    ; Subscrito em Evt.DeathDetected (publicado por XpService quando
    ; detecta penalty negativa no log, ou outra fonte). Cada disparo
    ; conta como uma morte da run atual.
    ; ============================================================
    _OnDeathDetected(data)
    {
        this._deathCount += 1
        this._Refresh()
    }

    ; ============================================================
    ; _RefreshDeathCount - atualiza texto e cor do line2_left
    ;
    ; Formato: "✗ N" onde N = _deathCount.
    ; Cor dinamica:
    ;   - 0 mortes:    muted (cinza dessaturado) — estado normal
    ;   - >= 1 mortes: warn  (amber)             — ja morreu, sinal sutil
    ;
    ; Cache _lastDeathColor evita SetFont desnecessario quando a cor
    ; nao mudou (a maior parte dos ticks, ja que mortes sao raras).
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
