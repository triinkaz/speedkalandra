; ============================================================
; MicroLayoutWidget - barra minima (Onda 4)
; ============================================================
;
; Versao ultra-reduzida do overlay. Aparece quando OverlayModeService
; entra em MICRO (ativado via Ctrl+F9 — lock manual). A v17.2 removeu
; o trigger AUTO via panel keys; agora MICRO so eh ativado manualmente.
;
; LAYOUT BASE (200x32 em scale=1.0):
;
;   +-----------------------+
;   | 01:24:17  Lv 47   XP  |
;   +-----------------------+
;
; Dois controles:
;   - main (esquerda): tempo total da run + char level
;   - xp_indicator (direita): texto fixo "XP" cuja COR comunica status
;                              (verde/amber/vermelho/cinza)
;
; INDICADOR DE XP (v17.3):
;   xp_indicator eh um Text control com texto FIXO "XP" cuja cor muda
;   conforme o status calculado pelo XpRules. Texto sempre "XP" — nao
;   mostra o status textual (OK/LIMITE/PENALTY/?) por preferencia de UX.
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
; BOSS TIMER (REMOVIDO em v17.13):
;   Feature de boss timer foi removida da app (voice lines de classe
;   nao iam pra Client.txt do PoE2, detection era inviavel pra maioria
;   dos bosses). Micro perdeu o "Boss MM:SS" / "✓ MM:SS" especial.
;
; SCALE:
;   Widget inteiro escala por _position.scale via Ctrl+wheel (mesma
;   infra do CompactLayoutWidget). _BuildGui le this._w/this._h (ja
;   escalados pelo Show) e propaga scale em font size + paddings.
;
; CONSTRUCAO:
;   widget := MicroLayoutWidget(bus, position, onPersist, timer, xp)

class MicroLayoutWidget extends LayoutWidgetBase
{
    static WIDGET_ID := "microLayout"
    static DISPLAY_NAME := "Layout Micro"

    ; Tamanho BASE (scale=1.0)
    static FIXED_W := 200
    static FIXED_H := 32

    ; Layout BASE (scale=1.0)
    static STRIPE_H  := 2
    static PADDING_X := 6
    static PADDING_Y := 6
    static FONT_MAIN := 11

    ; Largura reservada pro xp_indicator (alinhado direita).
    ; Como o texto eh fixo "XP" (~2 chars), 30px da margem confortavel
    ; em scale 1.0 e bastante folga em scales maiores.
    static XP_INDICATOR_W := 30

    _timer     := ""
    _xp        := ""

    _lastRenderMs := 0
    _lastXpColor   := ""    ; pra evitar SetFont desnecessario

    _handlerTick := ""

    __New(bus, position, onPersist, timer, xp)
    {
        super.__New(MicroLayoutWidget.WIDGET_ID,
                    MicroLayoutWidget.DISPLAY_NAME,
                    bus, position, onPersist)
        this._timer := timer
        this._xp    := xp

        this._handlerTick := (data) => this._OnTick(data)
        bus.Subscribe(Events.Tick, this._handlerTick)
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
        ; _w / _h ja vem escalados do LayoutWidgetBase.Show()
        w  := this._w
        h  := this._h
        s  := this._GetScale()

        ; Dimensoes escaladas
        stripeH := Max(1, Round(MicroLayoutWidget.STRIPE_H * s))
        padX    := Max(2, Round(MicroLayoutWidget.PADDING_X * s))
        padY    := Max(2, Round(MicroLayoutWidget.PADDING_Y * s))
        xpW     := Max(20, Round(MicroLayoutWidget.XP_INDICATOR_W * s))
        fontMain := Max(7, Round(MicroLayoutWidget.FONT_MAIN * s))

        ; Background
        this._BuildKalandraBand(0, 0, w, h, "surface")
        ; Accent stripe topo
        this._BuildAccentStripe(0, 0, w, stripeH)

        ; Altura util do texto (subindo um pouco pra respiro vertical)
        textH := h - 2*padY + Round(padY/3)

        ; --- main (esquerda): "01:24:17 Lv 47" ---
        ; Largura: total - 2*padX - largura do xp_indicator
        mainW := w - 2*padX - xpW
        this._SetFont(fontMain, "text", "")
        this._ctrls["main"] := wg.Add("Text",
            "x" padX " y" padY
            " w" mainW " h" textH
            " Left"
            " Background" Theme.Color("surface"),
            "")

        ; --- xp_indicator (direita): texto fixo "XP", cor dinamica ---
        this._SetFont(fontMain, "muted", "bold")
        this._ctrls["xp_indicator"] := wg.Add("Text",
            "x" (w - padX - xpW) " y" padY
            " w" xpW " h" textH
            " Right"
            " Background" Theme.Color("surface"),
            "")

        ; Reset cache pra forcar primeiro SetFont
        this._lastXpColor := ""

        this._Refresh()
    }

    _Refresh()
    {
        if !this._gui
            return

        ; Tempo total da run + char level
        runMs  := IsObject(this._timer) ? this._timer.GetRunMs() : 0
        charLv := IsObject(this._xp) ? this._xp.GetCharacterLevel() : 0
        mainText := this._FormatMs(runMs)
        if (charLv > 0)
            mainText .= "  Lv " charLv

        if this._ctrls.Has("main")
            try this._ctrls["main"].Value := mainText

        ; XP indicator com cor dinamica
        this._RefreshXpIndicator()
    }

    ; ============================================================
    ; _RefreshXpIndicator - atualiza COR do texto "XP" fixo
    ;
    ; Texto: sempre "XP" — nao mostra OK/LIMITE/PENALTY/? por
    ; preferencia de UX (apenas a cor comunica o status).
    ;
    ; Cor vem de XpRules.Calculate (via xpService.GetXpPenaltyInfo).
    ; Otimizacao: so chama SetFont quando a cor mudou.
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
            fontMain := Max(7, Round(MicroLayoutWidget.FONT_MAIN * this._GetScale()))
            try ctrl.SetFont("s" fontMain " c" color " bold", Theme.FONT_UI)
            this._lastXpColor := color
        }
        try ctrl.Value := "XP"
    }

    ; v0.1.2 (auditoria #19): consolidado em Duration.FormatMs.
    _FormatMs(ms) => Duration.FormatMs(ms)

    _OnTick(data)
    {
        nowMs := A_TickCount
        if (nowMs - this._lastRenderMs < 250)
            return
        this._lastRenderMs := nowMs
        this._Refresh()
    }

    Dispose()
    {
        if (this._handlerTick != "")
        {
            this._bus.Unsubscribe(Events.Tick, this._handlerTick)
            this._handlerTick := ""
        }
    }
}
