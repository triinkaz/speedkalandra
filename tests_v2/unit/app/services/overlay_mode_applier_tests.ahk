; ============================================================
; OverlayModeApplierTests
; ============================================================
;
; OverlayModeApplier subscribes to OverlayModeChanged. For each
; registered widget (Map<id, widget>), calls
; widget.SetModeVisible(bool) with the result of
; ShouldShowInMode(id, mode):
;   compactLayout visible in mode=compact
;   microLayout   visible in mode=micro
;   steveLayout   visible in mode=steve
;
; Stub _OverlayApplierStubWidget has a `visible` field that tracks
; the last value passed to SetModeVisible.


class _OverlayApplierStubWidget
{
    visible := true
    setCount := 0

    SetModeVisible(shouldShow)
    {
        this.visible := !!shouldShow
        this.setCount += 1
    }
}


class OverlayModeApplierTests extends TestCase
{
    bus      := ""
    widgets  := ""
    applier  := ""

    Setup()
    {
        this.bus := Fixtures.MakeBus()
        this.widgets := Map(
            OverlayModeApplier.LAYOUT_COMPACT_ID, _OverlayApplierStubWidget(),
            OverlayModeApplier.LAYOUT_MICRO_ID,   _OverlayApplierStubWidget(),
            OverlayModeApplier.LAYOUT_STEVE_ID,   _OverlayApplierStubWidget()
        )
        this.applier := OverlayModeApplier(this.bus, this.widgets)
    }

    Teardown()
    {
        if IsObject(this.applier)
            this.applier.Dispose()
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_widgets_not_map",
        "constructor_subscribes_to_overlay_mode_changed",

        ; --- Static: ShouldShowInMode (pure) ---
        "should_show_compact_layout_in_compact_mode",
        "should_show_micro_layout_in_micro_mode",
        "should_show_steve_layout_in_steve_mode",
        "should_show_returns_false_for_unknown_widget",
        "should_show_compact_hidden_in_micro_mode",
        "should_show_micro_hidden_in_compact_mode",

        ; --- ApplyMode ---
        "apply_mode_compact_shows_only_compact_widget",
        "apply_mode_micro_shows_only_micro_widget",
        "apply_mode_steve_shows_only_steve_widget",
        "apply_mode_with_empty_string_no_op",
        "apply_mode_hides_unregistered_layout_ids",

        ; --- OverlayModeChanged subscriber ---
        "overlay_mode_changed_event_applies_mode",
        "overlay_mode_changed_with_non_object_ignored",
        "overlay_mode_changed_without_mode_key_ignored",

        ; --- Dispose ---
        "dispose_unsubscribes_handler",
        "dispose_is_idempotent"
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        w := this.widgets
        Assert.Throws(TypeError, () => OverlayModeApplier("not bus", w))
    }

    constructor_throws_when_widgets_not_map()
    {
        b := this.bus
        Assert.Throws(TypeError, () => OverlayModeApplier(b, "not map"))
        Assert.Throws(TypeError, () => OverlayModeApplier(b, []))
    }

    constructor_subscribes_to_overlay_mode_changed()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.OverlayModeChanged))
    }

    ; ============================================================
    ; Static: ShouldShowInMode
    ; ============================================================

    should_show_compact_layout_in_compact_mode()
    {
        Assert.True(OverlayModeApplier.ShouldShowInMode(
            OverlayModeApplier.LAYOUT_COMPACT_ID, OverlayModes.COMPACT))
    }

    should_show_micro_layout_in_micro_mode()
    {
        Assert.True(OverlayModeApplier.ShouldShowInMode(
            OverlayModeApplier.LAYOUT_MICRO_ID, OverlayModes.MICRO))
    }

    should_show_steve_layout_in_steve_mode()
    {
        Assert.True(OverlayModeApplier.ShouldShowInMode(
            OverlayModeApplier.LAYOUT_STEVE_ID, OverlayModes.STEVE))
    }

    should_show_returns_false_for_unknown_widget()
    {
        Assert.False(OverlayModeApplier.ShouldShowInMode(
            "unknown_widget", OverlayModes.COMPACT))
    }

    should_show_compact_hidden_in_micro_mode()
    {
        Assert.False(OverlayModeApplier.ShouldShowInMode(
            OverlayModeApplier.LAYOUT_COMPACT_ID, OverlayModes.MICRO))
    }

    should_show_micro_hidden_in_compact_mode()
    {
        Assert.False(OverlayModeApplier.ShouldShowInMode(
            OverlayModeApplier.LAYOUT_MICRO_ID, OverlayModes.COMPACT))
    }

    ; ============================================================
    ; ApplyMode
    ; ============================================================

    apply_mode_compact_shows_only_compact_widget()
    {
        this.applier.ApplyMode(OverlayModes.COMPACT)
        Assert.True(this.widgets[OverlayModeApplier.LAYOUT_COMPACT_ID].visible)
        Assert.False(this.widgets[OverlayModeApplier.LAYOUT_MICRO_ID].visible)
        Assert.False(this.widgets[OverlayModeApplier.LAYOUT_STEVE_ID].visible)
    }

    apply_mode_micro_shows_only_micro_widget()
    {
        this.applier.ApplyMode(OverlayModes.MICRO)
        Assert.False(this.widgets[OverlayModeApplier.LAYOUT_COMPACT_ID].visible)
        Assert.True(this.widgets[OverlayModeApplier.LAYOUT_MICRO_ID].visible)
        Assert.False(this.widgets[OverlayModeApplier.LAYOUT_STEVE_ID].visible)
    }

    apply_mode_steve_shows_only_steve_widget()
    {
        this.applier.ApplyMode(OverlayModes.STEVE)
        Assert.False(this.widgets[OverlayModeApplier.LAYOUT_COMPACT_ID].visible)
        Assert.False(this.widgets[OverlayModeApplier.LAYOUT_MICRO_ID].visible)
        Assert.True(this.widgets[OverlayModeApplier.LAYOUT_STEVE_ID].visible)
    }

    apply_mode_with_empty_string_no_op()
    {
        this.applier.ApplyMode("")
        Assert.Equal(0, this.widgets[OverlayModeApplier.LAYOUT_COMPACT_ID].setCount,
            "Empty mode: SetModeVisible not called")
    }

    apply_mode_hides_unregistered_layout_ids()
    {
        ; Adds a widget with an unknown id (defense in depth)
        unknownWidget := _OverlayApplierStubWidget()
        this.widgets["legacy_widget"] := unknownWidget
        this.applier.ApplyMode(OverlayModes.COMPACT)
        Assert.False(unknownWidget.visible,
            "Unknown widget id is always hidden")
    }

    ; ============================================================
    ; OverlayModeChanged subscriber
    ; ============================================================

    overlay_mode_changed_event_applies_mode()
    {
        this.bus.Publish(Events.OverlayModeChanged, Map("mode", OverlayModes.MICRO))
        Assert.True(this.widgets[OverlayModeApplier.LAYOUT_MICRO_ID].visible)
        Assert.False(this.widgets[OverlayModeApplier.LAYOUT_COMPACT_ID].visible)
    }

    overlay_mode_changed_with_non_object_ignored()
    {
        countBefore := this.widgets[OverlayModeApplier.LAYOUT_COMPACT_ID].setCount
        this.bus.Publish(Events.OverlayModeChanged, "not a map")
        Assert.Equal(countBefore, this.widgets[OverlayModeApplier.LAYOUT_COMPACT_ID].setCount)
    }

    overlay_mode_changed_without_mode_key_ignored()
    {
        countBefore := this.widgets[OverlayModeApplier.LAYOUT_COMPACT_ID].setCount
        this.bus.Publish(Events.OverlayModeChanged, Map("other", "value"))
        Assert.Equal(countBefore, this.widgets[OverlayModeApplier.LAYOUT_COMPACT_ID].setCount)
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_handler()
    {
        this.applier.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.OverlayModeChanged))
    }

    dispose_is_idempotent()
    {
        this.applier.Dispose()
        this.applier.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.OverlayModeChanged))
    }
}

TestRegistry.Register(OverlayModeApplierTests)
