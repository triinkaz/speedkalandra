; ============================================================
; OverlayModeApplier - aplica visibility por modo (Onda 4)
; ============================================================
;
; VERSAO POS-DEMOLICAO: simplificada pra 2 modos (COMPACT/MICRO).
; Removidos widgets soltos / CUSTOM mode / position swap.
;
; Subscribe Evt.OverlayModeChanged e, pra cada widget conhecido,
; aplica SetModeVisible(shouldShow). NAO mexe em _position.visible
; do usuario.
;
; REGRAS:
;   COMPACT -> apenas "compactLayout" visivel
;   MICRO   -> apenas "microLayout" visivel
;
; Qualquer outro widget id vai pra hidden. Defesa em profundidade
; caso composition root registre algum widget legado por engano.
;
; CONSTRUCAO:
;   applier := OverlayModeApplier(bus, widgets)
;   applier.ApplyMode(initialMode)
;
;   widgets: Map<id, WidgetBase>

class OverlayModeApplier
{
    static LAYOUT_COMPACT_ID := "compactLayout"
    static LAYOUT_MICRO_ID   := "microLayout"
    static LAYOUT_STEVE_ID   := "steveLayout"   ; v17.14

    _bus     := ""
    _widgets := ""    ; Map<id, WidgetBase>
    _handlerModeChanged := ""

    __New(bus, widgets)
    {
        if !(bus is EventBus)
            throw TypeError("OverlayModeApplier: 'bus' deve ser EventBus")
        if !(widgets is Map)
            throw TypeError("OverlayModeApplier: 'widgets' deve ser Map<id, WidgetBase>")

        this._bus     := bus
        this._widgets := widgets

        this._handlerModeChanged := (data) => this._OnModeChanged(data)
        bus.Subscribe(Events.OverlayModeChanged, this._handlerModeChanged)
    }

    Dispose()
    {
        if (this._handlerModeChanged != "")
        {
            this._bus.Unsubscribe(Events.OverlayModeChanged, this._handlerModeChanged)
            this._handlerModeChanged := ""
        }
    }

    ; ============================================================
    ; ApplyMode(mode) - aplica visibility por widget
    ; ============================================================
    ApplyMode(mode)
    {
        if (mode = "")
            return
        for id, widget in this._widgets
        {
            shouldShow := OverlayModeApplier.ShouldShowInMode(id, mode)
            widget.SetModeVisible(shouldShow)
        }
    }

    ; ============================================================
    ; ShouldShowInMode - funcao pura, testavel sem widgets reais
    ; ============================================================
    static ShouldShowInMode(widgetId, mode)
    {
        if (widgetId = OverlayModeApplier.LAYOUT_COMPACT_ID)
            return (mode = OverlayModes.COMPACT)
        if (widgetId = OverlayModeApplier.LAYOUT_MICRO_ID)
            return (mode = OverlayModes.MICRO)
        if (widgetId = OverlayModeApplier.LAYOUT_STEVE_ID)
            return (mode = OverlayModes.STEVE)
        return false
    }

    _OnModeChanged(data)
    {
        if !IsObject(data) || !data.Has("mode")
            return
        this.ApplyMode(data["mode"])
    }
}
