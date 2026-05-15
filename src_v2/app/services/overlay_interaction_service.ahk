; ============================================================
; OverlayInteractionService — Ctrl-drag + Ctrl-wheel resize + click-through
; ============================================================
;
; Comportamento:
;   - Sem Ctrl: cliques no overlay PASSAM DIRETO pra janela atras
;     (PoE2 recebe o click). Overlay nao bloqueia interacao com o jogo.
;   - Com Ctrl: overlay vira interativo.
;       * Click esquerdo numa Gui registrada inicia drag (move janela inteira).
;       * Roda do mouse sobre Gui registrada dispara onResize callback
;         (widget muda scale, escala tudo dentro).
;
; APPROACH (Item 2):
;   Usa WS_EX_LAYERED + WS_EX_TRANSPARENT setados na criacao do widget
;   (WidgetBase.Show / LayoutWidgetBase.Show). Esse approach funciona
;   CROSS-PROCESS — Windows roteia mouse messages pra janela abaixo
;   diretamente, ignorando processos.
;
;   Toggle dinamico: quando Ctrl flipa, este service adiciona/remove
;   o bit WS_EX_TRANSPARENT em cada Hwnd registrado:
;     - Sem Ctrl: TRANSPARENT on  -> click-through (PoE2 recebe)
;     - Com Ctrl: TRANSPARENT off -> widget interativo (drag/wheel funciona)
;
; FILOSOFIA:
;   - Singleton estatico (OverlayInteractionService.Instance) pra que
;     WidgetBase.Show()/LayoutWidgetBase.Show() registrem Hwnds.
;   - Drag manual via SetTimer 16ms (igual legado).
;   - Polling de Ctrl (50ms) atualiza _ctrlDown e dispara toggle do
;     bit TRANSPARENT em todos hwnds + publica Evt.CtrlStateChanged.
;   - Wheel: OnMessage WM_MOUSEWHEEL extrai delta (signed high word de
;     wParam), converte em "steps" (delta/120), chama onResize callback.
;
; CONSTRUCAO:
;   svc := OverlayInteractionService(bus, headless := false)
;   svc.Start()    ; instala SetTimer poll + OnMessage hooks
;   svc.RegisterHwnd(myGui.Hwnd, () => mySaveCb(), (steps) => myResizeCb(steps))
;   svc.UnregisterHwnd(myGui.Hwnd)
;   svc.Stop()
;
; HEADLESS:
;   headless=true: nao instala SetTimer/OnMessage real. Tests OK.

class OverlayInteractionService
{
    static Instance := ""

    ; Polling de Ctrl: 50ms (~20Hz) eh suficiente.
    static POLL_MS := 50

    ; Drag tick: 16ms (~60fps) pra movimento suave.
    static DRAG_TICK_MS := 16

    ; WS_EX_TRANSPARENT bit, usado pra toggle de click-through (Item 2).
    static WS_EX_TRANSPARENT := 0x20

    ; Opacity dinamica vinculada a HOVER do mouse (v17.14):
    ;   - Default (sem hover, sem Ctrl):       overlay 100% visivel
    ;   - Mouse hover sobre o overlay:         overlay ~10% (revela jogo embaixo)
    ;     -> permite ver/clicar items do jogo cobertos pelo overlay
    ;        sem precisar mover ou esconder o widget
    ;   - Ctrl pressionado:                    overlay 100% (override de hover)
    ;     -> garante visibilidade total durante drag/resize/click em V1/V2/V3
    ;
    ; Polling de hover roda no mesmo SetTimer do polling de Ctrl (50ms).
    ; Hit-test eh feito manualmente comparando MouseGetPos com WinGetPos
    ; de cada widget registrado — isso funciona mesmo com click-through ON
    ; (porque WinGetPos/MouseGetPos operam em coordenadas de tela, nao em
    ; hit-test de mouse messages).
    ;
    ; Tweaking: OPACITY_DIMMED eh em escala 0-255 (alpha do WinSetTransparent).
    ;   25  = ~10% (escolha atual, bem sutil)
    ;   51  = ~20% (mais legivel mas ainda discreto)
    ;   76  = ~30% (visivel)
    ;   128 = ~50%
    static OPACITY_DIMMED := 25
    static OPACITY_FULL   := 255

    ; Win32 message constants
    static WM_LBUTTONDOWN := 0x201
    static WM_MOUSEWHEEL  := 0x20A

    _bus       := ""
    _headless  := false
    _enabled   := false

    ; State
    _ctrlDown    := false
    _hoveredHwnd := 0      ; hwnd atualmente sob o cursor (0 = nenhum). v17.14
    ; Array<Map<"hwnd"|"onDragEnd"|"onResize">>
    _widgets   := ""

    ; Drag state
    _dragHwnd          := 0
    _dragStartMouseX   := 0
    _dragStartMouseY   := 0
    _dragStartWinX     := 0
    _dragStartWinY     := 0
    _dragTickFn        := ""

    ; Polling Ctrl state (BoundFunc estavel)
    _pollFn := ""

    ; OnMessage handlers (BoundFunc estaveis)
    _onLButtonDownFn := ""
    _onMouseWheelFn  := ""

    __New(bus, headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("OverlayInteractionService: 'bus' deve ser EventBus")
        this._bus      := bus
        this._headless := !!headless
        this._widgets  := []

        this._dragTickFn      := this._DragTick.Bind(this)
        this._pollFn          := this._Poll.Bind(this)
        this._onLButtonDownFn := this._OnLButtonDown.Bind(this)
        this._onMouseWheelFn  := this._OnMouseWheel.Bind(this)

        OverlayInteractionService.Instance := this
    }

    ; ============================================================
    ; Lifecycle
    ; ============================================================

    Start()
    {
        if this._enabled
            return
        this._enabled := true
        if this._headless
            return

        ; Polling de Ctrl
        SetTimer(this._pollFn, OverlayInteractionService.POLL_MS)

        ; OnMessage WM_LBUTTONDOWN (0x201) — captura cliques quando Ctrl pressed,
        ; pra iniciar drag. So chega quando widget tem WS_EX_TRANSPARENT off
        ; (i.e., Ctrl pressed faz o service remover TRANSPARENT, widget recebe
        ; clicks normalmente).
        OnMessage(OverlayInteractionService.WM_LBUTTONDOWN, this._onLButtonDownFn)

        ; OnMessage WM_MOUSEWHEEL (0x20A) — captura wheel quando Ctrl pressed,
        ; pra disparar resize. Mesmo gating de TRANSPARENT.
        OnMessage(OverlayInteractionService.WM_MOUSEWHEEL, this._onMouseWheelFn)

        OutputDebug("OverlayInteractionService: Start() OK")
    }

    Stop()
    {
        if !this._enabled
            return
        this._enabled := false

        ; Para drag em andamento se houver
        this._dragHwnd := 0
        try SetTimer(this._dragTickFn, 0)

        if this._headless
            return

        try SetTimer(this._pollFn, 0)
        try OnMessage(OverlayInteractionService.WM_LBUTTONDOWN, this._onLButtonDownFn, 0)
        try OnMessage(OverlayInteractionService.WM_MOUSEWHEEL, this._onMouseWheelFn, 0)
    }

    IsEnabled() => this._enabled
    IsCtrlDown() => this._ctrlDown

    ; ============================================================
    ; Public API: Register/Unregister
    ;
    ;   onDragEnd : callable() ou "" — disparado quando user solta LButton
    ;               apos drag (use pra persistir nova posicao do widget)
    ;   onResize  : callable(steps) ou "" — disparado em Ctrl+wheel
    ;               (steps = +1 wheel pra cima, -1 pra baixo, etc)
    ; ============================================================

    RegisterHwnd(hwnd, onDragEnd := "", onResize := "")
    {
        if (hwnd = 0)
            return
        for w in this._widgets
        {
            if (w["hwnd"] = hwnd)
                return
        }
        this._widgets.Push(Map(
            "hwnd",      hwnd,
            "onDragEnd", onDragEnd,
            "onResize",  onResize
        ))
        OutputDebug("OverlayInteractionService: RegisterHwnd " hwnd " (total=" this._widgets.Length ")")

        ; Aplica estado visual atual (click-through + opacity) no hwnd
        ; recem-registrado. Antes (Item 2) so aplicava quando Ctrl ja
        ; estava pressionado; agora aplica sempre pra que o overlay nasca
        ; com opacity dimmed corretamente quando Ctrl esta solto (default).
        this._ApplyVisualState(hwnd)
    }

    UnregisterHwnd(hwnd)
    {
        if (hwnd = 0)
            return
        if (this._dragHwnd = hwnd)
        {
            this._dragHwnd := 0
            try SetTimer(this._dragTickFn, 0)
        }
        for i, w in this._widgets
        {
            if (w["hwnd"] = hwnd)
            {
                this._widgets.RemoveAt(i)
                OutputDebug("OverlayInteractionService: UnregisterHwnd " hwnd " (total=" this._widgets.Length ")")
                return
            }
        }
    }

    ; ============================================================
    ; Polling state (Ctrl + hover) — 50ms
    ; ============================================================

    _Poll()
    {
        this.SetCtrlState(!!GetKeyState("Ctrl", "P"))
        this._UpdateHoverState()
    }

    ; ============================================================
    ; _UpdateHoverState (v17.14)
    ;
    ; Detecta qual widget esta sob o cursor (se algum) e atualiza
    ; _hoveredHwnd. Disparado a cada poll (50ms).
    ;
    ; Hit-test manual via comparacao de coordenadas — funciona mesmo
    ; com click-through ativo (porque WinGetPos/MouseGetPos operam em
    ; geometria de tela, nao em hit-test de mouse messages).
    ;
    ; Se Ctrl esta pressionado, hover eh IGNORADO (Ctrl override garante
    ; 100% opacity pra leitura/drag/resize sem distração).
    ; ============================================================
    _UpdateHoverState()
    {
        if this._ctrlDown
        {
            ; Ctrl override: forca hover off pra que opacity nao seja
            ; dimmada por engano. Se _hoveredHwnd estava setado, limpa
            ; (proximo ApplyVisualState volta opacity pra full).
            this._SetHoveredHwnd(0)
            return
        }

        mx := 0, my := 0
        try MouseGetPos(&mx, &my)

        hoveredHwnd := 0
        for w in this._widgets
        {
            hw := w["hwnd"]
            wx := 0, wy := 0, ww := 0, wh := 0
            try
            {
                WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hw)
                if (mx >= wx && mx < wx + ww && my >= wy && my < wy + wh)
                {
                    hoveredHwnd := hw
                    break
                }
            }
        }

        this._SetHoveredHwnd(hoveredHwnd)
    }

    ; Atualiza _hoveredHwnd e reaplica visual state nos widgets afetados.
    ; Idempotente: se hwnd nao mudou, no-op.
    _SetHoveredHwnd(hwnd)
    {
        if (hwnd = this._hoveredHwnd)
            return

        prev := this._hoveredHwnd
        this._hoveredHwnd := hwnd

        ; Restaura opacity do widget anterior (saiu do hover)
        if (prev != 0)
            this._ApplyVisualState(prev)

        ; Aplica dim no widget novo (entrou em hover)
        if (hwnd != 0)
            this._ApplyVisualState(hwnd)
    }

    ; ============================================================
    ; SetCtrlState(isDown) — atualiza estado Ctrl e publica evento
    ; ============================================================
    SetCtrlState(isDown)
    {
        newVal := !!isDown
        if (newVal = this._ctrlDown)
            return false
        this._ctrlDown := newVal
        OutputDebug("OverlayInteractionService: ctrlDown=" (newVal ? "true" : "false"))

        ; Item 2 + v17.14: toggle WS_EX_TRANSPARENT E opacity em todos hwnds
        ; registrados (sincronizado com state de Ctrl).
        this._ApplyVisualStateToAll()

        try this._bus.Publish(Events.CtrlStateChanged, Map("active", newVal))
        return true
    }

    ; ============================================================
    ; Visual state: click-through (WS_EX_TRANSPARENT) + opacity
    ; (v17.14) — calcula state combinando Ctrl + hover:
    ;
    ;   Ctrl=on:                          click-through OFF, opacity FULL
    ;     -> widget interativo (drag/wheel/V1V2V3), visibilidade total
    ;
    ;   Ctrl=off + hover sobre widget:    click-through ON,  opacity DIMMED
    ;     -> mouse passou em cima — reveal jogo embaixo
    ;
    ;   Ctrl=off + sem hover (default):   click-through ON,  opacity FULL
    ;     -> widget visivel mas clicks passam pro jogo
    ; ============================================================

    _ApplyVisualState(hwnd)
    {
        transparent := !this._ctrlDown
        hovered     := !this._ctrlDown && this._hoveredHwnd = hwnd

        ; Click-through bit (depende SO de Ctrl)
        op := transparent ? "+0x20" : "-0x20"
        try WinSetExStyle(op, "ahk_id " hwnd)

        ; Opacity (alpha): dimmed se hover (e sem Ctrl), full caso contrario
        alpha := hovered
            ? OverlayInteractionService.OPACITY_DIMMED
            : OverlayInteractionService.OPACITY_FULL
        try WinSetTransparent(alpha, "ahk_id " hwnd)
    }

    _ApplyVisualStateToAll()
    {
        for w in this._widgets
            this._ApplyVisualState(w["hwnd"])
    }

    ; ============================================================
    ; OnMessage WM_LBUTTONDOWN — drag manual
    ; ============================================================

    _OnLButtonDown(wParam, lParam, msg, hwnd)
    {
        ; So inicia drag se Ctrl pressionado E a Gui esta registrada.
        if !this._ctrlDown
            return
        if !this._IsRegistered(hwnd)
            return

        OutputDebug("OverlayInteractionService: drag start hwnd=" hwnd)

        this._dragHwnd := hwnd
        try
        {
            MouseGetPos(&mx, &my)
            this._dragStartMouseX := mx
            this._dragStartMouseY := my
            WinGetPos(&wx, &wy, , , "ahk_id " hwnd)
            this._dragStartWinX := wx
            this._dragStartWinY := wy
        }
        try SetTimer(this._dragTickFn, OverlayInteractionService.DRAG_TICK_MS)

        ; return 0 = suprime click pra que botoes nao ativem durante drag.
        return 0
    }

    ; ============================================================
    ; OnMessage WM_MOUSEWHEEL — resize via Ctrl+wheel
    ;
    ;   Estrutura do wParam (Win32):
    ;     high word (bits 16..31) = wheel delta (SIGNED int16)
    ;     low word  (bits 0..15)  = key flags (MK_CONTROL etc)
    ;
    ;   delta tipico: +120 (wheel pra cima) ou -120 (pra baixo).
    ;   Convertemos em "steps" dividindo por 120 e arredondando.
    ;
    ;   Gating: precisa de Ctrl pressionado E hwnd registrado E onResize
    ;   callback definida no register. Caso contrario, ignora silenciosamente
    ;   (deixa a wheel propagar normalmente, ex: scroll de ListView).
    ; ============================================================
    _OnMouseWheel(wParam, lParam, msg, hwnd)
    {
        if !this._ctrlDown
            return
        if !this._IsRegistered(hwnd)
            return

        ; Extrai delta (signed 16-bit) do high word de wParam.
        ; wParam eh unsigned 64-bit; precisamos converter o high word
        ; em signed pra distinguir up (positivo) de down (negativo).
        rawDelta := (wParam >> 16) & 0xFFFF
        if (rawDelta & 0x8000)    ; bit de sinal
            rawDelta -= 0x10000
        if (rawDelta = 0)
            return

        ; Steps: tipicamente ±1 por click de roda.
        steps := Round(rawDelta / 120)
        if (steps = 0)
            steps := rawDelta > 0 ? 1 : -1

        ; Procura callback do widget.
        for w in this._widgets
        {
            if (w["hwnd"] != hwnd)
                continue
            cb := w.Has("onResize") ? w["onResize"] : ""
            if IsObject(cb)
            {
                try cb.Call(steps)
                OutputDebug("OverlayInteractionService: wheel resize hwnd=" hwnd " steps=" steps)
            }
            return 0    ; suprime — evita scroll inadvertido pro processo de baixo
        }
    }

    _IsRegistered(hwnd)
    {
        for w in this._widgets
        {
            if (w["hwnd"] = hwnd)
                return true
        }
        return false
    }

    ; ============================================================
    ; Drag tick (16ms = ~60fps, igual legado)
    ; ============================================================

    _DragTick()
    {
        if (this._dragHwnd = 0)
        {
            try SetTimer(this._dragTickFn, 0)
            return
        }

        if !GetKeyState("LButton", "P")
        {
            finishedHwnd := this._dragHwnd
            this._dragHwnd := 0
            try SetTimer(this._dragTickFn, 0)
            OutputDebug("OverlayInteractionService: drag end hwnd=" finishedHwnd)
            this._FireOnDragEnd(finishedHwnd)
            return
        }

        try
        {
            MouseGetPos(&cx, &cy)
            dx := cx - this._dragStartMouseX
            dy := cy - this._dragStartMouseY
            newX := this._dragStartWinX + dx
            newY := this._dragStartWinY + dy
            WinMove(newX, newY, , , "ahk_id " this._dragHwnd)
        }
    }

    _FireOnDragEnd(hwnd)
    {
        for w in this._widgets
        {
            if (w["hwnd"] = hwnd)
            {
                if IsObject(w["onDragEnd"])
                    try w["onDragEnd"].Call()
                return
            }
        }
    }
}
