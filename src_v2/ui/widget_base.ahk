; ============================================================
; WidgetBase — classe base de todos os widgets do overlay
; ============================================================
;
; Responsabilidades:
;   - Lifecycle: Show/Hide/ReRender/Destroy.
;   - Helpers compartilhados: _BuildHeader (barra título + X decorativo).
;   - Mutators de posição/escala/visibilidade que persistem via callback.
;
; NÃO faz nesta fase (vem em sub-fases futuras):
;   - Drag/resize via mouse (planejado p/ pós-Fase 6 ou WidgetManager).
;   - Close button click handler (X é decorativo agora).
;   - Hover-hide transparency.
;
; Filosofia:
;   - Cada widget concreto extends WidgetBase e implementa _BuildGui()
;     que preenche this._gui com controles e seta this._w / this._h.
;   - WidgetBase nao conhece TimerService/RunService/etc. Subclasses
;     recebem refs por construtor. WidgetBase só sabe sobre tema,
;     posição, e ciclo de vida da Gui.
;
; Construção:
;   class TimerWidget extends WidgetBase
;   {
;       __New(bus, position, onPersist, timerService, analytics)
;       {
;           super.__New("timer", "Timer (Run/Etapa)", bus, position, onPersist)
;           this._timer := timerService
;           ; ... outras deps
;       }
;       _BuildGui() { ... cria controles ..., seta this._w, this._h }
;   }
;
;   widget := TimerWidget(bus, position, () => settingsRepo.Save(cfg), timer, analytics)
;   widget.Show()
;
; Sobre 'position':
;   É uma referência mutável para uma OverlayPosition (parte de
;   AppSettings.overlay.widgets["timer"]). WidgetBase muta inline
;   campos (visible, scale, leftPct, topPct, centered) e chama
;   onPersist() depois — composition root injeta callback que chama
;   settingsRepo.Save(appSettings).


class WidgetBase
{
    ; --- Identidade ---
    id   := ""    ; "timer", "zone", etc.
    name := ""    ; "Timer (Run/Etapa)" — display name

    ; --- Dependências ---
    _bus       := ""    ; EventBus (subclasses subscrevem nele)
    _position  := ""    ; OverlayPosition (mutável, compartilhada com AppSettings)
    _onPersist := ""    ; callable opcional ou "" (chamado após mutações)

    ; --- Estado de render ---
    _gui    := ""        ; Gui ou ""
    _ctrls  := Map()     ; Map<key, GuiControl> populado por _BuildGui
    _w      := 0         ; largura calculada por _BuildGui
    _h      := 0         ; altura calculada por _BuildGui

    ; --- Mode-driven visibility (Fase 9.7) ---
    ; Flag NAO persistente, controlada por OverlayModeApplier conforme
    ; o modo atual (NORMAL/COMPACT/MICRO). Show() exige tanto
    ; _position.visible (preferencia do usuario, persistida) quanto
    ; _modeVisible (filtro temporario por modo) = true.
    _modeVisible := true

    __New(idStr, nameStr, bus, position, onPersist := "")
    {
        if (idStr = "")
            throw ValueError("WidgetBase: 'idStr' nao pode ser vazio")
        if (nameStr = "")
            throw ValueError("WidgetBase: 'nameStr' nao pode ser vazio")
        if !(bus is EventBus)
            throw TypeError("WidgetBase: 'bus' deve ser EventBus")
        if !(position is OverlayPosition)
            throw TypeError("WidgetBase: 'position' deve ser OverlayPosition")
        ; onPersist pode ser "" (sem persistência) ou callable
        if (onPersist != "" && !IsObject(onPersist))
            throw TypeError("WidgetBase: 'onPersist' deve ser callable ou string vazia")

        this.id        := idStr
        this.name      := nameStr
        this._bus      := bus
        this._position := position
        this._onPersist := onPersist

        ; Item 1 (overlay refinement): subscreve mudancas de Ctrl pra
        ; mostrar/esconder borda de destaque (feedback visual de
        ; "agora esta clicavel/arrastavel"). Tolerante a Show ainda
        ; nao chamado — _SetCtrlHighlightVisible eh no-op se ctrls vazios.
        this._bus.Subscribe(Events.CtrlStateChanged, (data) => this._OnCtrlStateChanged(data))
    }

    ; ============================================================
    ; Queries
    ; ============================================================

    IsVisible()  => this._position.visible        ; preferencia do usuario
    IsRendered() => this._gui != ""                ; realmente renderizado na tela
    IsModeVisible() => this._modeVisible           ; filtro de modo (Fase 9.7)
    GetPosition() => this._position
    GetScale()    => this._position.scale
    GetSize()     => Map("w", this._w, "h", this._h)

    ; ============================================================
    ; Lifecycle
    ; ============================================================

    ; Cria a Gui e mostra na tela. No-op se:
    ;   - position.visible = false (widget marcado como invisível)
    ;   - _modeVisible = false (modo atual esconde esse widget) [Fase 9.7]
    ;   - já está renderizado
    Show()
    {
        if !this._position.visible
            return
        if !this._modeVisible
            return
        if this._gui
            return

        ; Item 2 (click-through fix v2): LAYERED + TRANSPARENT setados
        ; APOS criacao da Gui via WinSetTransparent + WinSetExStyle.
        ;
        ; Por que nao no flag de criacao da Gui? Em AHK v2, criar a Gui
        ; com `+E0x80020` (LAYERED + TRANSPARENT) faz a janela nascer
        ; com LAYERED mas sem LWA_ALPHA configurado. WinSetTransparent
        ; chamado depois nao sempre seta alpha corretamente — widget
        ; fica invisivel (alpha=0).
        ;
        ; Approach correto: Gui nasce normal (so NOACTIVATE), depois
        ; WinSetTransparent(255) ADICIONA LAYERED + alpha=255 via
        ; SetLayeredWindowAttributes (que AHK gerencia). Depois
        ; WinSetExStyle("+0x20") adiciona TRANSPARENT.
        ;
        ; Toggle DINAMICO do bit TRANSPARENT pelo OverlayInteractionService
        ; quando Ctrl flipa: sem Ctrl click passa, com Ctrl widget interativo.
        wg := Gui("+ToolWindow +AlwaysOnTop -Caption +E0x08000000")
        wg.BackColor := Theme.Color("bg")
        wg.MarginX := 0
        wg.MarginY := 0
        this._gui := wg
        this._ctrls := Map()
        this._w := 0
        this._h := 0

        ; Subclass preenche controles e seta this._w / this._h
        this._BuildGui()

        if (this._w <= 0 || this._h <= 0)
            throw Error("WidgetBase.Show: '" this.id "'._BuildGui nao setou _w/_h corretamente")

        ; Item 1: cria 4 Progress controls como borda de destaque
        ; (hidden inicialmente). Mostradas/escondidas via
        ; Evt.CtrlStateChanged. Adicionadas APOS _BuildGui pra ficarem
        ; no topo da z-order (renderizadas sobre o conteudo).
        this._BuildCtrlHighlight()

        ; Calcula posição na tela
        monW := A_ScreenWidth
        monH := A_ScreenHeight
        if this._position.centered
            posX := Round((monW - this._w) / 2)
        else
            posX := Round((this._position.left / 100) * monW)
        posY := Round((this._position.top / 100) * monH)

        wg.Show("NoActivate X" posX " Y" posY " W" this._w " H" this._h)

        ; Item 2 (apos Show): WinSetTransparent ADICIONA LAYERED + alpha=255
        ; (totalmente opaco) via SetLayeredWindowAttributes. Mais confiavel
        ; que setar LAYERED na Gui flag.
        try WinSetTransparent(255, "ahk_id " wg.Hwnd)
        ; Item 2: WS_EX_TRANSPARENT (0x20) adiciona click-through cross-process.
        ; OverlayInteractionService toggles esse bit quando Ctrl flipa.
        try WinSetExStyle("+0x20", "ahk_id " wg.Hwnd)

        ; Smoke fix Turno 2: registra Hwnd no OverlayInteractionService
        ; pra ter click-through (default) + Ctrl drag (interativo).
        ; Singleton estatico setado pelo composition root no Start().
        ; Em headless ou se service nao subiu, e' no-op silencioso.
        if (OverlayInteractionService.Instance != "")
            OverlayInteractionService.Instance.RegisterHwnd(
                this._gui.Hwnd,
                this._UpdatePositionFromGui.Bind(this)
            )
    }

    ; Destroi a Gui se visível. Idempotente.
    Hide()
    {
        if !this._gui
            return
        ; Smoke fix Turno 2: desregistra do OverlayInteractionService
        ; ANTES de Destroy() pra evitar que callback de drag entre
        ; com Hwnd zumbi.
        if (OverlayInteractionService.Instance != "")
        {
            try OverlayInteractionService.Instance.UnregisterHwnd(this._gui.Hwnd)
        }
        try this._gui.Destroy()
        this._gui := ""
        this._ctrls := Map()
        this._w := 0
        this._h := 0
    }

    ; Re-cria a Gui (útil após mudança de scale).
    ; Se posição.visible = false ou !_modeVisible, apenas garante que
    ; não há Gui (Show() interno faz a checagem).
    ReRender()
    {
        if this._gui
            this.Hide()
        if (this._position.visible && this._modeVisible)
            this.Show()
    }

    ; Alias semântico para limpeza final.
    Destroy() => this.Hide()

    ; ============================================================
    ; Mutators (chamados pelo WidgetManager ou pelo composition root)
    ; ============================================================

    ; Liga/desliga visibilidade. Persiste e mostra/esconde a Gui.
    SetVisible(value)
    {
        newVal := !!value
        if (this._position.visible = newVal)
            return
        this._position.visible := newVal
        this._Persist()
        if newVal
            this.Show()
        else
            this.Hide()
    }

    ; Liga/desliga visibilidade temporaria por modo (Fase 9.7).
    ; NAO persiste — eh filtro do modo atual aplicado pelo
    ; OverlayModeApplier ao receber Evt.OverlayModeChanged.
    ;
    ; - Mostrar (true): chama Show() que ainda checa _position.visible;
    ;   se usuario desabilitou o widget, fica oculto mesmo com modo true.
    ; - Esconder (false): chama Hide() incondicional.
    SetModeVisible(value)
    {
        newVal := !!value
        if (this._modeVisible = newVal)
            return
        this._modeVisible := newVal
        if newVal
            this.Show()
        else
            this.Hide()
    }

    ; Troca a referencia da OverlayPosition usada pelo widget (Fase 9.10).
    ; NAO persiste — eh apenas swap pra apontar pro layout do modo atual
    ; (OverlayModeApplier consulta OverlayLayout.GetPositionForMode e
    ; passa o resultado aqui antes de SetModeVisible).
    ;
    ; Comportamento:
    ;   - Se newPos == _position atual: no-op silencioso
    ;   - Se renderizado, faz Hide() + Show() pra refletir nova posicao/scale
    ;   - Validacao de tipo: TypeError se nao for OverlayPosition
    ;
    ; Notavel: NAO chama _Persist(). Os arquivos do INI sao escritos
    ; via SetVisible/SetScale/SetPosition que mexem em this._position
    ; — e a referencia atual aponta pro layout do modo. Drag/resize
    ; do usuario vai persistir no modo ativo (que eh o comportamento
    ; desejado do design ambicioso).
    SetActivePosition(newPos)
    {
        if !(newPos is OverlayPosition)
            throw TypeError("WidgetBase.SetActivePosition: 'newPos' deve ser OverlayPosition")
        if (this._position == newPos)
            return
        this._position := newPos
        ; Re-renderiza com a nova posicao se estava visivel.
        ; ReRender soh remostra se _position.visible && _modeVisible.
        if this._gui
            this.ReRender()
    }

    ; Muda escala. Clamp em [0.5, 3.0] (mesmo range do OverlayPosition).
    ; Re-renderiza se atualmente visível.
    SetScale(value)
    {
        if (!IsNumber(value) || value <= 0)
            throw ValueError("WidgetBase.SetScale: scale deve ser número positivo")
        if (value < 0.5)
            value := 0.5
        if (value > 3.0)
            value := 3.0
        if (this._position.scale = value)
            return
        this._position.scale := value
        this._Persist()
        this.ReRender()
    }

    ; Muda posicao percentual. Clamp em [0, 95] (alinhado com OverlayPosition.MAX_PCT_SAFE
    ; pra evitar widget off-screen). centered=true ignora left.
    SetPosition(leftPct, topPct, centered := false)
    {
        if (!IsNumber(leftPct) || !IsNumber(topPct))
            throw TypeError("WidgetBase.SetPosition: leftPct/topPct devem ser numero")
        if (leftPct < 0)
            leftPct := 0
        if (leftPct > 95)
            leftPct := 95
        if (topPct < 0)
            topPct := 0
        if (topPct > 95)
            topPct := 95
        this._position.left     := leftPct
        this._position.top      := topPct
        this._position.centered := !!centered
        this._Persist()
        this.ReRender()
    }

    ; ============================================================
    ; Subclass overrides
    ; ============================================================

    ; Template method: subclasses preenchem this._gui com controles
    ; (usando this._gui.Add(...) e helpers como _BuildHeader) e
    ; setam this._w / this._h (largura/altura totais do widget).
    _BuildGui()
    {
        throw Error("WidgetBase._BuildGui deve ser overridden por subclasse")
    }

    ; ============================================================
    ; Helpers protegidos (subclass usa em _BuildGui)
    ; ============================================================

    ; Cria header padronizado: accent stripe (3px) + barra de titulo
    ; com titulo a esquerda e botao X (decorativo) a direita.
    ; Retorna headerH (altura TOTAL: stripe + barra de titulo).
    ;
    ; A accent stripe (3px laranja queimado) eh assinatura visual do
    ; tema Kalandra (espelhada do CompactLayoutWidget). Da identidade
    ; visual coerente entre widgets soltos e layout containers.
    ;
    ; Args:
    ;   title    : string mostrada uppercase (ex: "Timer")
    ;   contentW : largura total do widget (px)
    ;
    ; Adiciona em this._ctrls:
    ;   "accent" -> Progress control da stripe (decorativa, value=100)
    ;   "header" -> Text control da barra
    ;   "close"  -> Text control do X
    _BuildHeader(title, contentW)
    {
        s       := this._position.scale
        stripeH := Theme.Size(s, 3)
        titleH  := Theme.Size(s, 18)
        tSz     := Theme.Size(s, 7)
        cSz     := Theme.Size(s, 11)
        cBtnW   := Theme.Size(s, 20)
        tW      := contentW - cBtnW

        wg := this._gui

        ; Accent stripe (3px laranja, full width, decorativa).
        accent := wg.Add(
            "Progress",
            "x0 y0 w" contentW " h" stripeH
                . " c" Theme.Color("accent") " Background" Theme.Color("surface3"),
            100
        )
        this._ctrls["accent"] := accent

        ; Barra de titulo (logo abaixo da stripe).
        wg.SetFont("s" tSz " c" Theme.Color("subtle") " bold", Theme.FONT_UI)
        hdr := wg.Add(
            "Text",
            "x0 y" stripeH " w" tW " h" titleH " Background" Theme.Color("surface2") " 0x200",
            "  " StrUpper(title)
        )
        this._ctrls["header"] := hdr

        wg.SetFont("s" cSz " c" Theme.Color("subtle"), Theme.FONT_UI)
        closeBtn := wg.Add(
            "Text",
            "x" tW " y" stripeH " w" cBtnW " h" titleH
                . " Background" Theme.Color("surface2") " Center 0x200",
            "X"
        )
        this._ctrls["close"] := closeBtn

        return stripeH + titleH
    }

    ; Atualiza texto de um control existente. Tolerante:
    ;   - No-op se !rendered
    ;   - No-op se ctrl não existe
    ;   - Try-catch ao redor da escrita (controle pode ter sido destruído entre check e set)
    ;
    ; Usado por handlers de Tick/event para atualizar valores sem checar
    ; nada manualmente em cada chamada.
    _TrySetText(ctrlKey, text)
    {
        if !this._gui
            return
        if !this._ctrls.Has(ctrlKey)
            return
        try this._ctrls[ctrlKey].Text := text
    }

    ; Atualiza cor da fonte de um control. Tolerante (mesma semântica).
    ;   colorName: nome válido em Theme.Color (ex: "green", "amber")
    _TrySetFontColor(ctrlKey, colorName)
    {
        if !this._gui
            return
        if !this._ctrls.Has(ctrlKey)
            return
        try this._ctrls[ctrlKey].SetFont("c" Theme.Color(colorName))
    }

    ; ============================================================
    ; Ctrl highlight border (Item 1) — feedback visual de Ctrl ativo
    ; ============================================================
    ;
    ; Cria 4 Progress controls de 3px na cor accent ('D8492F' laranja),
    ; um em cada borda (top/bottom/left/right). Hidden por default.
    ; Tornados visiveis quando OverlayInteractionService publica
    ; Evt.CtrlStateChanged { active: true } e re-escondidos quando
    ; active=false.
    ;
    ; Por que Progress e nao Picture/Border? Progress aceita cor de
    ; foreground (`c`) e background (`Background`) com value=100, e
    ; renderiza como retangulo solido. Mesmo padrao usado pelo
    ; LayoutWidgetBase._BuildAccentStripe. Disabled garante que cliques
    ; passem pelos controles abaixo (importante pra interacao normal
    ; quando highlight esta ligado).
    ;
    ; Z-order: chamado APOS _BuildGui no Show(), entao renderiza
    ; SOBRE o conteudo do widget. As bordas top/bottom/left/right
    ; cobrem 3px do conteudo do widget — pra widgets com header
    ; (accent stripe ja existente em y=0..3) o overlap eh visualmente
    ; consistente (mesma cor).
    ;
    ; Sync inicial: se OverlayInteractionService.Instance esta up e
    ; Ctrl ja esta pressionado quando widget eh mostrado, mostra
    ; highlight imediatamente (em vez de esperar proximo flip do poll).
    ; ============================================================

    static _CTRL_HIGHLIGHT_KEYS := ["__ctrlHl_top", "__ctrlHl_bot", "__ctrlHl_lef", "__ctrlHl_rig"]
    static _CTRL_HIGHLIGHT_THICKNESS := 3

    _BuildCtrlHighlight()
    {
        if !this._gui
            return
        if (this._w <= 0 || this._h <= 0)
            return

        wg      := this._gui
        accent  := Theme.Color("accent")
        bw      := WidgetBase._CTRL_HIGHLIGHT_THICKNESS
        w       := this._w
        h       := this._h

        ; Hidden Disabled = invisivel inicial, click-through (cliques
        ; passam pros controles abaixo). +0x4000000 = WS_EX_TRANSPARENT
        ; nao aplicavel a controles, usamos so Disabled.
        opts := " Hidden Disabled c" accent " Background" accent

        top := wg.Add("Progress", "x0 y0 w" w " h" bw . opts, 100)
        bot := wg.Add("Progress", "x0 y" (h - bw) " w" w " h" bw . opts, 100)
        lef := wg.Add("Progress", "x0 y0 w" bw " h" h . opts, 100)
        rig := wg.Add("Progress", "x" (w - bw) " y0 w" bw " h" h . opts, 100)

        this._ctrls["__ctrlHl_top"] := top
        this._ctrls["__ctrlHl_bot"] := bot
        this._ctrls["__ctrlHl_lef"] := lef
        this._ctrls["__ctrlHl_rig"] := rig

        ; Sync inicial: se Ctrl ja esta segurado no momento do Show.
        try
        {
            if (OverlayInteractionService.Instance != ""
                && OverlayInteractionService.Instance.IsCtrlDown())
                this._SetCtrlHighlightVisible(true)
        }
    }

    ; Liga/desliga as 4 bordas. No-op se controles nao existem (widget
    ; nao renderizado, ou _BuildCtrlHighlight ainda nao chamado).
    _SetCtrlHighlightVisible(visible)
    {
        if !this._gui
            return
        v := !!visible
        for _, k in WidgetBase._CTRL_HIGHLIGHT_KEYS
        {
            if !this._ctrls.Has(k)
                continue
            try this._ctrls[k].Visible := v
        }
    }

    ; Handler do Evt.CtrlStateChanged. Tolerante a payload malformado.
    _OnCtrlStateChanged(data)
    {
        if !IsObject(data)
            return
        if !data.Has("active")
            return
        this._SetCtrlHighlightVisible(data["active"])
    }

    ; ============================================================
    ; Helpers privados
    ; ============================================================

    ; Smoke fix Turno 2: callback chamado pelo OverlayInteractionService
    ; quando user termina drag (LButton up). Lê posicao real da Gui via
    ; WinGetPos, converte pra percentual em relação à tela e persiste
    ; em this._position. Define centered=false (user moveu manualmente).
    _UpdatePositionFromGui()
    {
        if !this._gui
            return
        try
        {
            WinGetPos(&x, &y, , , "ahk_id " this._gui.Hwnd)
            monW := A_ScreenWidth
            monH := A_ScreenHeight
            if (monW > 0 && monH > 0)
            {
                this._position.left     := Round((x / monW) * 100, 2)
                this._position.top      := Round((y / monH) * 100, 2)
                this._position.centered := false
                this._Persist()
            }
        }
    }

    ; Chama onPersist se foi configurado.
    ; Tolerante a falhas: se persistência falhar, não derruba o widget.
    _Persist()
    {
        if !IsObject(this._onPersist)
            return
        try this._onPersist.Call()
    }
}
