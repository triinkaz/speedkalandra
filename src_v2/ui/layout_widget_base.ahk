; ============================================================
; LayoutWidgetBase — classe base dos LayoutWidgets (Fase A1)
; ============================================================
;
; Os LayoutWidgets (CompactLayoutWidget, MicroLayoutWidget) reproduzem
; visualmente os modos do legado com layouts containerizados FIXOS
; (em vez de 8 widgets soltos arrastaveis).
;
; CARACTERISTICAS:
;   - Tamanho BASE fixo (override _GetFixedSize na subclasse).
;     Ex: Compact = 500x96, Micro = 200x32.
;   - Tamanho REAL escalado por _position.scale.
;     Show() aplica: _w = Round(baseW * scale), _h = Round(baseH * scale).
;   - Position fixa (sem drag automatico), mas user pode mover via Ctrl+drag
;     e redimensionar via Ctrl+wheel (OverlayInteractionService).
;
; FILOSOFIA:
;   - Heranca de WidgetBase pra reaproveitar lifecycle (Show/Hide/
;     SetModeVisible/SetScale) e a position-ref.
;   - Subclasses overridem _BuildGui pra construir a estrutura visual,
;     e _GetFixedSize pra retornar Map("w", baseW, "h", baseH) com o
;     tamanho de referencia em scale=1.0.
;   - _BuildGui deve ler this._w / this._h (ja escalados pelo Show)
;     e this._position.scale pra escalar dimensoes internas (margens,
;     posicoes de linhas, font sizes). Nao deve chamar _GetFixedSize
;     de novo dentro de _BuildGui.
;
; HEADER OPCIONAL:
;   _BuildKalandraBand(x, y, w, h, surfaceName) cria uma banda Progress
;   colorida usada como background de seções (estilo legado).
;
; CONSTRUCAO:
;   class CompactLayoutWidget extends LayoutWidgetBase
;   {
;       __New(bus, position, onPersist, ...services)
;       {
;           super.__New("compactLayout", "Layout Compact", bus, position, onPersist)
;           ; ... captura services
;           ; subscribe eventos
;       }
;
;       _GetFixedSize() => Map("w", 500, "h", 96)
;
;       _BuildGui()
;       {
;           w := this._w           ; ja escalado pelo Show
;           h := this._h
;           s := this._position.scale
;           ; ... cria controles aplicando scale s em todas dimensoes
;       }
;   }


class LayoutWidgetBase extends WidgetBase
{
    ; ============================================================
    ; Override de Show: aplica scale do _position em cima do tamanho
    ; BASE de _GetFixedSize. Resultado em this._w / this._h fica
    ; disponivel pra _BuildGui da subclasse.
    ; ============================================================
    Show()
    {
        if !this._position.visible
            return
        if !this._modeVisible
            return
        if this._gui
            return

        wg := Gui("+ToolWindow +AlwaysOnTop -Caption +E0x08000000")
        wg.BackColor := Theme.Color("bg")
        wg.MarginX := 0
        wg.MarginY := 0
        this._gui := wg
        this._ctrls := Map()

        ; Tamanho BASE da subclasse + scale do _position.
        sz := this._GetFixedSize()
        if (!IsObject(sz) || !sz.Has("w") || !sz.Has("h"))
            throw Error("LayoutWidgetBase.Show: '" this.id "'._GetFixedSize() deve retornar Map(w,h)")

        scale := this._position.scale
        if (!IsNumber(scale) || scale <= 0)
            scale := 1.0
        this._w := Round(sz["w"] * scale)
        this._h := Round(sz["h"] * scale)

        ; Subclass preenche this._gui com bandas, headers, controles
        ; usando this._w / this._h (ja escalados) + this._position.scale
        ; pra dimensionar internamente.
        this._BuildGui()

        ; Item 1: cria borda de destaque (hidden) que aparece quando
        ; Ctrl esta segurado. Usa o mesmo helper de WidgetBase.
        this._BuildCtrlHighlight()

        ; Calcula posicao na tela (mesma logica do WidgetBase, mas com _w/_h escalados)
        monW := A_ScreenWidth
        monH := A_ScreenHeight
        if this._position.centered
            posX := Round((monW - this._w) / 2)
        else
            posX := Round((this._position.left / 100) * monW)
        posY := Round((this._position.top / 100) * monH)

        wg.Show("NoActivate X" posX " Y" posY " W" this._w " H" this._h)

        ; Item 2 (apos Show): adiciona LAYERED + alpha=255 + TRANSPARENT.
        ; Detalhes em WidgetBase.Show.
        try WinSetTransparent(255, "ahk_id " wg.Hwnd)
        try WinSetExStyle("+0x20", "ahk_id " wg.Hwnd)

        ; Smoke fix Turno 5 (Bug A): registra Hwnd no OverlayInteractionService
        ; pra que Ctrl+drag (mover) e Ctrl+wheel (resize) funcionem nos
        ; LayoutWidgets. Replica do bloco em WidgetBase.Show, ja que esse
        ; Show() override nao chama super.
        if (OverlayInteractionService.Instance != "")
            OverlayInteractionService.Instance.RegisterHwnd(
                this._gui.Hwnd,
                this._UpdatePositionFromGui.Bind(this),
                this._OnWheelResize.Bind(this)
            )
    }

    ; ============================================================
    ; _OnWheelResize - callback chamado pelo OverlayInteractionService
    ;   quando user gira a roda do mouse com Ctrl segurado sobre o widget.
    ;
    ;   steps: +N (roda pra cima = aumenta) ou -N (pra baixo = diminui)
    ;
    ;   Cada step = +- 0.1 no scale. SetScale herdado de WidgetBase
    ;   faz clamp [0.5, 3.0] + Persist + ReRender automaticamente.
    ; ============================================================
    _OnWheelResize(steps)
    {
        if !IsNumber(steps)
            return
        currentScale := this._position.scale
        if (!IsNumber(currentScale) || currentScale <= 0)
            currentScale := 1.0
        newScale := currentScale + (steps * 0.1)
        ; Arredonda pra evitar drift de float (0.1+0.1+0.1 != 0.3 etc)
        newScale := Round(newScale * 10) / 10
        this.SetScale(newScale)
    }

    ; ============================================================
    ; Subclass overrides
    ; ============================================================

    ; Retorna Map("w", larguraBase, "h", alturaBase) com tamanho BASE
    ; do widget em scale=1.0. Subclasse DEVE override. O Show() aplica
    ; scale em cima desses valores.
    _GetFixedSize()
    {
        throw Error("LayoutWidgetBase._GetFixedSize deve ser overridden por subclasse")
    }

    ; ============================================================
    ; Helpers protegidos para construcao de layouts estilo Kalandra
    ; ============================================================

    ; Cria uma banda Progress como background colorido. Usa cores
    ; do tema Kalandra: surface (mais claro), surface2, surface3 (mais
    ; escuro). Retorna o control criado.
    ;
    ; surfaceName: "surface" | "surface2" | "surface3"
    ;
    ; +Disabled garante que cliques passem direto pros controles em
    ; cima da banda (importante pro MicroLayoutWidget que tem botoes
    ; sobre o background).
    _BuildKalandraBand(x, y, w, h, surfaceName := "surface")
    {
        wg := this._gui
        bgColor := Theme.Color(surfaceName)
        ; Progress com cor=bg e Background=bg fica como retangulo solido.
        return wg.Add("Progress",
            "x" x " y" y " w" w " h" h " Disabled c" bgColor " Background" bgColor,
            100)
    }

    ; Cria a "accent stripe" laranja (3px de altura) que fica no topo
    ; das bandas no legado. Cor: accent (D8492F).
    _BuildAccentStripe(x, y, w, h := 3)
    {
        wg := this._gui
        accent := Theme.Color("accent")
        return wg.Add("Progress",
            "x" x " y" y " w" w " h" h " c" accent " Background" Theme.Color("surface3"),
            100)
    }

    ; Cria um header de banda (texto pequeno em uppercase, cor subtle, bold).
    ; Estilo legado: "MAPA", "OBJETIVO", "RECOMPENSAS", etc.
    _BuildBandHeader(x, y, w, text)
    {
        wg := this._gui
        wg.SetFont("s8 c" Theme.Color("subtle") " bold", Theme.FONT_UI)
        return wg.Add("Text", "x" x " y" y " w" w, text)
    }

    ; Cria um divisor horizontal accent (linha laranja fina).
    _BuildDivider(x, y, w, h := 2)
    {
        wg := this._gui
        accent := Theme.Color("accent")
        return wg.Add("Progress",
            "x" x " y" y " w" w " h" h " Disabled c" accent " Background" Theme.Color("surface3"),
            100)
    }

    ; Aplica fonte do tema com tamanho/cor/peso. Helper conciso pra
    ; substituir o boilerplate de wg.SetFont em sequencia de Add()s.
    _SetFont(size, colorName, weight := "")
    {
        opts := "s" size " c" Theme.Color(colorName)
        if (weight != "")
            opts .= " " weight
        this._gui.SetFont(opts, Theme.FONT_UI)
    }
}
