; ============================================================
; OverlayModeApplier - applies widget visibility per mode
; ============================================================
;
; Subscribes to Evt.OverlayModeChanged and, for each known widget,
; applies SetModeVisible(shouldShow). Does NOT touch the user's
; _position.visible.
;
; RULES:
;   COMPACT -> only "compactLayout" visible
;   MICRO   -> only "microLayout" visible
;
; Any other widget id goes to hidden — defense in depth in case the
; composition root accidentally registers an unexpected widget.
;
; CONSTRUCTION:
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
            throw TypeError("OverlayModeApplier: 'bus' must be EventBus")
        if !(widgets is Map)
            throw TypeError("OverlayModeApplier: 'widgets' must be Map<id, WidgetBase>")

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
    ; ApplyMode(mode) - applies visibility per widget
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
    ; ShouldShowInMode - pure function, testable without real widgets
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
