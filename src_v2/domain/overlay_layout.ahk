; ============================================================
; OverlayLayout - overlay widget positions
; ============================================================
;
; One position per widget. OverlayModeService decides which widget is
; visible at any given moment, but each widget's position is
; persisted independently.
;
; INI MAPPING:
;   [Overlay]
;   compactLayout.left=10
;   compactLayout.top=2
;   compactLayout.scale=1
;   compactLayout.visible=1
;   compactLayout.centered=0
;   microLayout.left=80
;   microLayout.top=90
;   ...
;   hoverHide=1
;
; STRUCTURE:
;   OverlayLayout
;       .positions  : Map<widgetId, OverlayPosition>
;       .hoverHide  : bool (global, inherited)
;
;   OverlayPosition (value object, with clamps in property setters)
;       .left, .top   : float [0..95]    (percent of resolution, MAX_PCT_SAFE=95)
;       .scale        : float [0.5..3.0]
;       .visible      : bool
;       .centered     : bool


; ------------------------------------------------------------
; OverlayPosition - position of an individual widget
; ------------------------------------------------------------
class OverlayPosition
{
    _left    := 0.0
    _top     := 0.0
    scale    := 1.0
    visible  := true
    centered := false

    static MIN_SCALE    := 0.5
    static MAX_SCALE    := 3.0
    static MIN_PCT      := 0.0
    static MAX_PCT      := 100.0
    static MAX_PCT_SAFE := 95.0

    left
    {
        get => this._left
        set => this._left := OverlayPosition._ClampSafePercent(value)
    }

    top
    {
        get => this._top
        set => this._top := OverlayPosition._ClampSafePercent(value)
    }

    static Defaults() => OverlayPosition()

    static FromMap(data)
    {
        if !IsObject(data)
            throw TypeError("OverlayPosition.FromMap: 'data' must be a Map")

        op := OverlayPosition()
        op.left     := OverlayPosition._GetPercent(data, "left",  op.left)
        op.top      := OverlayPosition._GetPercent(data, "top",   op.top)
        op.scale    := OverlayPosition._GetScale(data, "scale",   op.scale)
        op.visible  := OverlayPosition._GetBool(data, "visible",  op.visible)
        op.centered := OverlayPosition._GetBool(data, "centered", op.centered)
        return op
    }

    ToMap()
    {
        return Map(
            "left",     this.left,
            "top",      this.top,
            "scale",    this.scale,
            "visible",  this.visible,
            "centered", this.centered
        )
    }

    static _ClampSafePercent(v)
    {
        if (v = "" || !IsNumber(v))
            return 0.0
        n := v + 0.0
        if (n < OverlayPosition.MIN_PCT)
            return OverlayPosition.MIN_PCT
        if (n > OverlayPosition.MAX_PCT_SAFE)
            return OverlayPosition.MAX_PCT_SAFE
        return n
    }

    static _GetPercent(data, key, default)
    {
        if !data.Has(key)
            return default
        v := data[key]
        if (v = "" || !IsNumber(v))
            return default
        return v + 0.0
    }

    static _GetScale(data, key, default)
    {
        if !data.Has(key)
            return default
        v := data[key]
        if (v = "" || !IsNumber(v))
            return default
        n := v + 0.0
        if (n < OverlayPosition.MIN_SCALE)
            return OverlayPosition.MIN_SCALE
        if (n > OverlayPosition.MAX_SCALE)
            return OverlayPosition.MAX_SCALE
        return n
    }

    static _GetBool(data, key, default)
    {
        if !data.Has(key)
            return default
        v := data[key]
        if (v = "" || v = 0 || v = "0" || v = false)
            return false
        if (v = 1 || v = "1" || v = true)
            return true
        return !!v
    }
}


; ------------------------------------------------------------
; OverlayLayout - collection of OverlayPosition by widget
; ------------------------------------------------------------
class OverlayLayout
{
    positions := Map()    ; widgetId -> OverlayPosition
    hoverHide := true

    static Defaults()
    {
        ol := OverlayLayout()
        ; Defaults for the two layouts whose position the user is
        ; most likely to want pre-positioned out of the box. The
        ; third layout (steveLayout) is intentionally omitted here
        ; and falls back to OverlayPosition() defaults (top-left,
        ; scale 1.0) the first time the widget is constructed; the
        ; user-tweaked position is then persisted to [Overlay] like
        ; any other widget. Adding it here would only override that
        ; first-visit fallback with a hardcoded preset, which has
        ; no clear right answer.
        compact := OverlayPosition()
        compact.left    := 10.0
        compact.top     := 1.5
        compact.visible := true
        ol.positions["compactLayout"] := compact

        micro := OverlayPosition()
        micro.left    := 75.0
        micro.top     := 92.0
        micro.visible := true
        ol.positions["microLayout"] := micro

        ol.hoverHide := true
        return ol
    }

    static FromMap(data)
    {
        if !IsObject(data)
            throw TypeError("OverlayLayout.FromMap: 'data' must be a Map")

        ol := OverlayLayout.Defaults()
        ; Merge: defaults first, FromMap overrides
        if data.Has("positions") && IsObject(data["positions"])
        {
            for widgetId, raw in data["positions"]
            {
                if (widgetId = "")
                    continue
                if (raw is OverlayPosition)
                    ol.positions[widgetId] := raw
                else if IsObject(raw)
                    ol.positions[widgetId] := OverlayPosition.FromMap(raw)
            }
        }
        if data.Has("hoverHide")
            ol.hoverHide := OverlayLayout._GetBool(data, "hoverHide", ol.hoverHide)
        return ol
    }

    HasWidget(widgetId) => this.positions.Has(widgetId)

    GetPosition(widgetId)
    {
        return this.positions.Has(widgetId) ? this.positions[widgetId] : ""
    }

    SetPosition(widgetId, position)
    {
        if (widgetId = "")
            throw ValueError("OverlayLayout.SetPosition: empty widgetId")
        if !(position is OverlayPosition)
            throw TypeError("OverlayLayout.SetPosition: 'position' must be an OverlayPosition")
        this.positions[widgetId] := position
    }

    RemovePosition(widgetId)
    {
        if this.positions.Has(widgetId)
            this.positions.Delete(widgetId)
    }

    WidgetIds()
    {
        ids := []
        for widgetId, _ in this.positions
            ids.Push(widgetId)
        return ids
    }

    Count() => this.positions.Count

    ToMap()
    {
        serialized := Map()
        for widgetId, op in this.positions
            serialized[widgetId] := op.ToMap()
        return Map(
            "positions", serialized,
            "hoverHide", this.hoverHide
        )
    }

    static _GetBool(data, key, default)
    {
        if !data.Has(key)
            return default
        v := data[key]
        if (v = "" || v = 0 || v = "0" || v = false)
            return false
        if (v = 1 || v = "1" || v = true)
            return true
        return !!v
    }
}
