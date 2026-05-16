; ============================================================
; OverlayLayout tests - OverlayPosition + OverlayLayout
; ============================================================
;
; OverlayPosition: posicao de um widget
;   - left/top: float [0..95]      (clamp via property setter)
;   - scale:    float [0.5..3.0]   (clamp via FromMap._GetScale)
;   - visible:  bool
;   - centered: bool
;
; OverlayLayout: colecao Map<widgetId, OverlayPosition> + hoverHide
;   - Defaults com compactLayout e microLayout pre-populados
;   - HasWidget / GetPosition / SetPosition / RemovePosition / WidgetIds / Count
;   - FromMap aceita OverlayPosition instance OU Map (mixed input)

class OverlayPositionTests extends TestCase
{
    static Tests := [
        ; --- Defaults ---
        "defaults_left_top_are_zero",
        "defaults_scale_is_one",
        "defaults_visible_is_true",
        "defaults_centered_is_false",

        ; --- Setter left/top clamps ---
        "left_setter_clamps_below_zero_to_zero",
        "left_setter_clamps_above_95_to_95",
        "top_setter_clamps_below_zero_to_zero",
        "top_setter_clamps_above_95_to_95",
        "left_setter_accepts_value_in_range",
        "left_setter_treats_non_number_as_zero",

        ; --- FromMap ---
        "from_map_reads_all_fields",
        "from_map_clamps_scale_below_min",
        "from_map_clamps_scale_above_max",
        "from_map_clamps_left_top_to_safe_range",
        "from_map_throws_type_error_on_non_object",
        "from_map_uses_defaults_for_missing_keys",

        ; --- ToMap ---
        "to_map_serializes_all_fields",
        "to_map_from_map_roundtrip",
    ]

    ; ============================================================
    ; Defaults
    ; ============================================================

    defaults_left_top_are_zero()
    {
        op := OverlayPosition()
        Assert.Equal(0.0, op.left)
        Assert.Equal(0.0, op.top)
    }

    defaults_scale_is_one()
    {
        Assert.Equal(1.0, OverlayPosition().scale)
    }

    defaults_visible_is_true()
    {
        Assert.True(OverlayPosition().visible)
    }

    defaults_centered_is_false()
    {
        Assert.False(OverlayPosition().centered)
    }

    ; ============================================================
    ; Setter clamps
    ; ============================================================

    left_setter_clamps_below_zero_to_zero()
    {
        op := OverlayPosition()
        op.left := -10.0
        Assert.Equal(0.0, op.left)
    }

    left_setter_clamps_above_95_to_95()
    {
        op := OverlayPosition()
        op.left := 200.0
        Assert.Equal(95.0, op.left)
    }

    top_setter_clamps_below_zero_to_zero()
    {
        op := OverlayPosition()
        op.top := -5.0
        Assert.Equal(0.0, op.top)
    }

    top_setter_clamps_above_95_to_95()
    {
        op := OverlayPosition()
        op.top := 99.9
        Assert.Equal(95.0, op.top)
    }

    left_setter_accepts_value_in_range()
    {
        op := OverlayPosition()
        op.left := 47.5
        Assert.Equal(47.5, op.left)
    }

    left_setter_treats_non_number_as_zero()
    {
        op := OverlayPosition()
        op.left := "abc"
        Assert.Equal(0.0, op.left)
    }

    ; ============================================================
    ; FromMap
    ; ============================================================

    from_map_reads_all_fields()
    {
        op := OverlayPosition.FromMap(Map(
            "left",     50.0,
            "top",      30.0,
            "scale",    1.5,
            "visible",  false,
            "centered", true
        ))
        Assert.Equal(50.0, op.left)
        Assert.Equal(30.0, op.top)
        Assert.Equal(1.5,  op.scale)
        Assert.False(op.visible)
        Assert.True(op.centered)
    }

    from_map_clamps_scale_below_min()
    {
        op := OverlayPosition.FromMap(Map("scale", 0.1))
        Assert.Equal(0.5, op.scale, "Scale abaixo de MIN_SCALE clampa pra 0.5")
    }

    from_map_clamps_scale_above_max()
    {
        op := OverlayPosition.FromMap(Map("scale", 10.0))
        Assert.Equal(3.0, op.scale, "Scale acima de MAX_SCALE clampa pra 3.0")
    }

    from_map_clamps_left_top_to_safe_range()
    {
        op := OverlayPosition.FromMap(Map("left", 200.0, "top", -5.0))
        Assert.Equal(95.0, op.left)
        Assert.Equal(0.0,  op.top)
    }

    from_map_throws_type_error_on_non_object()
    {
        Assert.Throws(TypeError, () => OverlayPosition.FromMap("not a map"))
    }

    from_map_uses_defaults_for_missing_keys()
    {
        op := OverlayPosition.FromMap(Map())
        Assert.Equal(0.0, op.left)
        Assert.Equal(1.0, op.scale)
        Assert.True(op.visible)
    }

    ; ============================================================
    ; ToMap
    ; ============================================================

    to_map_serializes_all_fields()
    {
        op := OverlayPosition()
        op.left     := 10.0
        op.top      := 20.0
        op.scale    := 1.5
        op.visible  := false
        op.centered := true

        m := op.ToMap()
        Assert.Equal(10.0,  m["left"])
        Assert.Equal(20.0,  m["top"])
        Assert.Equal(1.5,   m["scale"])
        Assert.Equal(false, m["visible"])
        Assert.Equal(true,  m["centered"])
    }

    to_map_from_map_roundtrip()
    {
        original := OverlayPosition()
        original.left     := 42.5
        original.top      := 13.7
        original.scale    := 2.0
        original.visible  := false
        original.centered := true

        recovered := OverlayPosition.FromMap(original.ToMap())
        Assert.Equal(original.left,     recovered.left)
        Assert.Equal(original.top,      recovered.top)
        Assert.Equal(original.scale,    recovered.scale)
        Assert.Equal(original.visible,  recovered.visible)
        Assert.Equal(original.centered, recovered.centered)
    }
}


class OverlayLayoutTests extends TestCase
{
    static Tests := [
        ; --- Defaults ---
        "defaults_has_compact_and_micro_widgets",
        "defaults_compact_position_is_top_left",
        "defaults_micro_position_is_bottom_right",
        "defaults_hover_hide_is_true",

        ; --- HasWidget / GetPosition ---
        "has_widget_true_for_existing",
        "has_widget_false_for_unknown",
        "get_position_returns_widget_position",
        "get_position_returns_empty_string_for_unknown",

        ; --- SetPosition ---
        "set_position_stores_new_widget",
        "set_position_overwrites_existing_widget",
        "set_position_throws_on_empty_widget_id",
        "set_position_throws_on_non_overlay_position",

        ; --- RemovePosition ---
        "remove_position_deletes_widget",
        "remove_position_is_no_op_for_unknown_widget",

        ; --- WidgetIds / Count ---
        "widget_ids_returns_all_keys",
        "count_returns_number_of_positions",

        ; --- FromMap ---
        "from_map_merges_with_defaults",
        "from_map_accepts_overlay_position_instance",
        "from_map_accepts_position_as_map",
        "from_map_ignores_empty_widget_id",
        "from_map_throws_type_error_on_non_object",
        "from_map_reads_hover_hide",

        ; --- ToMap ---
        "to_map_serializes_positions_via_to_map",
        "to_map_roundtrip_preserves_state",
    ]

    ; ============================================================
    ; Defaults
    ; ============================================================

    defaults_has_compact_and_micro_widgets()
    {
        ol := OverlayLayout.Defaults()
        Assert.True(ol.HasWidget("compactLayout"))
        Assert.True(ol.HasWidget("microLayout"))
        Assert.Equal(2, ol.Count())
    }

    defaults_compact_position_is_top_left()
    {
        ol := OverlayLayout.Defaults()
        pos := ol.GetPosition("compactLayout")
        Assert.Equal(10.0, pos.left)
        Assert.Equal(1.5,  pos.top)
        Assert.True(pos.visible)
    }

    defaults_micro_position_is_bottom_right()
    {
        ol := OverlayLayout.Defaults()
        pos := ol.GetPosition("microLayout")
        Assert.Equal(75.0, pos.left)
        Assert.Equal(92.0, pos.top)
        Assert.True(pos.visible)
    }

    defaults_hover_hide_is_true()
    {
        Assert.True(OverlayLayout.Defaults().hoverHide)
    }

    ; ============================================================
    ; HasWidget / GetPosition
    ; ============================================================

    has_widget_true_for_existing()
    {
        ol := OverlayLayout.Defaults()
        Assert.True(ol.HasWidget("compactLayout"))
    }

    has_widget_false_for_unknown()
    {
        ol := OverlayLayout.Defaults()
        Assert.False(ol.HasWidget("nonexistent"))
    }

    get_position_returns_widget_position()
    {
        ol := OverlayLayout.Defaults()
        pos := ol.GetPosition("compactLayout")
        Assert.IsType(OverlayPosition, pos)
    }

    get_position_returns_empty_string_for_unknown()
    {
        ol := OverlayLayout.Defaults()
        Assert.Equal("", ol.GetPosition("nonexistent"))
    }

    ; ============================================================
    ; SetPosition
    ; ============================================================

    set_position_stores_new_widget()
    {
        ol := OverlayLayout.Defaults()
        newPos := OverlayPosition()
        newPos.left := 50.0
        ol.SetPosition("steveLayout", newPos)

        Assert.True(ol.HasWidget("steveLayout"))
        Assert.Equal(50.0, ol.GetPosition("steveLayout").left)
    }

    set_position_overwrites_existing_widget()
    {
        ol := OverlayLayout.Defaults()
        replacement := OverlayPosition()
        replacement.left := 88.0
        ol.SetPosition("compactLayout", replacement)

        Assert.Equal(88.0, ol.GetPosition("compactLayout").left)
        Assert.Equal(2, ol.Count(), "Conta nao muda em overwrite")
    }

    set_position_throws_on_empty_widget_id()
    {
        ol := OverlayLayout.Defaults()
        pos := OverlayPosition()
        Assert.Throws(ValueError, () => ol.SetPosition("", pos))
    }

    set_position_throws_on_non_overlay_position()
    {
        ol := OverlayLayout.Defaults()
        Assert.Throws(TypeError, () => ol.SetPosition("foo", "not a position"))
        Assert.Throws(TypeError, () => ol.SetPosition("foo", Map()))
    }

    ; ============================================================
    ; RemovePosition
    ; ============================================================

    remove_position_deletes_widget()
    {
        ol := OverlayLayout.Defaults()
        ol.RemovePosition("microLayout")
        Assert.False(ol.HasWidget("microLayout"))
        Assert.Equal(1, ol.Count())
    }

    remove_position_is_no_op_for_unknown_widget()
    {
        ol := OverlayLayout.Defaults()
        ol.RemovePosition("nonexistent")
        Assert.Equal(2, ol.Count())
    }

    ; ============================================================
    ; WidgetIds / Count
    ; ============================================================

    widget_ids_returns_all_keys()
    {
        ol := OverlayLayout.Defaults()
        ids := ol.WidgetIds()
        Assert.Equal(2, ids.Length)
        Assert.Contains("compactLayout", ids)
        Assert.Contains("microLayout",   ids)
    }

    count_returns_number_of_positions()
    {
        ol := OverlayLayout.Defaults()
        Assert.Equal(2, ol.Count())

        extra := OverlayPosition()
        ol.SetPosition("steveLayout", extra)
        Assert.Equal(3, ol.Count())
    }

    ; ============================================================
    ; FromMap
    ; ============================================================

    from_map_merges_with_defaults()
    {
        ; FromMap aplica defaults primeiro; chaves do payload sobrescrevem
        ol := OverlayLayout.FromMap(Map(
            "positions", Map("compactLayout", Map("left", 99.0))
        ))
        Assert.True(ol.HasWidget("compactLayout"))
        Assert.True(ol.HasWidget("microLayout"),
            "microLayout veio dos defaults (merge)")
        Assert.Equal(95.0, ol.GetPosition("compactLayout").left,
            "99 fora do range, clampado para 95")
    }

    from_map_accepts_overlay_position_instance()
    {
        existing := OverlayPosition()
        existing.left := 25.0
        ol := OverlayLayout.FromMap(Map(
            "positions", Map("compactLayout", existing)
        ))
        Assert.Equal(25.0, ol.GetPosition("compactLayout").left)
    }

    from_map_accepts_position_as_map()
    {
        ol := OverlayLayout.FromMap(Map(
            "positions", Map("compactLayout", Map("left", 33.0, "top", 44.0))
        ))
        pos := ol.GetPosition("compactLayout")
        Assert.Equal(33.0, pos.left)
        Assert.Equal(44.0, pos.top)
    }

    from_map_ignores_empty_widget_id()
    {
        ol := OverlayLayout.FromMap(Map(
            "positions", Map("", Map("left", 50.0))
        ))
        Assert.False(ol.HasWidget(""))
    }

    from_map_throws_type_error_on_non_object()
    {
        Assert.Throws(TypeError, () => OverlayLayout.FromMap("not a map"))
    }

    from_map_reads_hover_hide()
    {
        ol := OverlayLayout.FromMap(Map("hoverHide", false))
        Assert.False(ol.hoverHide)
    }

    ; ============================================================
    ; ToMap
    ; ============================================================

    to_map_serializes_positions_via_to_map()
    {
        ol := OverlayLayout.Defaults()
        m := ol.ToMap()
        Assert.True(IsObject(m["positions"]))
        Assert.True(m["positions"].Has("compactLayout"))
        ; Cada position serializada e' um Map (nao OverlayPosition)
        compact := m["positions"]["compactLayout"]
        Assert.False(compact is OverlayPosition,
            "ToMap deve serializar cada position como Map")
        Assert.Equal(10.0, compact["left"])
    }

    to_map_roundtrip_preserves_state()
    {
        original := OverlayLayout.Defaults()
        custom := OverlayPosition()
        custom.left  := 33.3
        custom.scale := 2.0
        original.SetPosition("steveLayout", custom)
        original.hoverHide := false

        recovered := OverlayLayout.FromMap(original.ToMap())
        Assert.Equal(3, recovered.Count())
        Assert.Equal(33.3, recovered.GetPosition("steveLayout").left)
        Assert.Equal(2.0,  recovered.GetPosition("steveLayout").scale)
        Assert.False(recovered.hoverHide)
    }
}

TestRegistry.Register(OverlayPositionTests)
TestRegistry.Register(OverlayLayoutTests)
