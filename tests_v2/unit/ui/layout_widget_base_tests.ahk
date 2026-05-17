; ============================================================
; LayoutWidgetBaseTests
; ============================================================
;
; LayoutWidgetBase extends WidgetBase with:
;   - Show() override that applies scale on top of _GetFixedSize()
;     (not testable in headless - creates real Gui)
;   - _OnWheelResize(steps) callback from OverlayInteractionService —
;     newScale = currentScale + steps*0.1, then SetScale
;     (clamp + persist)
;   - _GetFixedSize abstract — subclass override to return Map(w,h)
;   - Kalandra band construction helpers (private, require real Gui)
;
; Coverage here: _OnWheelResize + _GetFixedSize abstract.


class _LayoutWidgetBaseStub extends LayoutWidgetBase
{
    _GetFixedSize() => Map("w", 500, "h", 96)
    _BuildGui()
    {
        ; Stub: not called in tests that avoid Show
    }
}


class _LayoutWidgetBaseStubNoFixedSize extends LayoutWidgetBase
{
    ; NOT overriding _GetFixedSize — inherits from base, which throws
    _BuildGui()
    {
        ; empty
    }
}


class LayoutWidgetBaseTests extends TestCase
{
    bus      := ""
    position := ""
    persistCallCount := 0
    persistCb := ""
    widget   := ""

    Setup()
    {
        this.bus := Fixtures.MakeBus()
        this.position := OverlayPosition.FromMap(Map(
            "left", 10.0, "top", 20.0, "scale", 1.0,
            "visible", false, "centered", false
        ))
        this.persistCallCount := 0
        this.persistCb := ObjBindMethod(this, "_PersistCounter")
        this.widget := _LayoutWidgetBaseStub(
            "stub_layout", "Stub Layout", this.bus, this.position, this.persistCb
        )
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    _PersistCounter()
    {
        this.persistCallCount += 1
    }

    static Tests := [
        ; --- _GetFixedSize ---
        "get_fixed_size_throws_on_base_class",
        "get_fixed_size_returns_map_with_w_and_h_in_subclass",

        ; --- _OnWheelResize ---
        "wheel_resize_increases_scale_by_0_1_per_step_up",
        "wheel_resize_decreases_scale_by_0_1_per_step_down",
        "wheel_resize_multiple_steps_compound",
        "wheel_resize_clamps_to_min_0_5",
        "wheel_resize_clamps_to_max_3_0",
        "wheel_resize_ignores_non_number_steps",
        "wheel_resize_persists_on_change",
        "wheel_resize_no_op_when_step_zero",
        "wheel_resize_rounds_to_avoid_float_drift",
        "wheel_resize_uses_default_when_position_scale_invalid",

        ; --- Inherits WidgetBase API ---
        "inherits_set_visible",
        "inherits_set_position",
        "inherits_get_scale",
        "inherits_subscribes_to_ctrl_state_changed"
    ]

    ; ============================================================
    ; _GetFixedSize
    ; ============================================================

    get_fixed_size_throws_on_base_class()
    {
        ; Subclass instance without override — _GetFixedSize is not yet
        ; called (only called by Show). But calling the method directly
        ; throws.
        wgNoSize := _LayoutWidgetBaseStubNoFixedSize(
            "no_size", "No Size", this.bus, this.position
        )
        Assert.Throws(Error, () => wgNoSize._GetFixedSize())
    }

    get_fixed_size_returns_map_with_w_and_h_in_subclass()
    {
        sz := this.widget._GetFixedSize()
        Assert.True(sz is Map)
        Assert.Equal(500, sz["w"])
        Assert.Equal(96,  sz["h"])
    }

    ; ============================================================
    ; _OnWheelResize
    ; ============================================================

    wheel_resize_increases_scale_by_0_1_per_step_up()
    {
        this.position.scale := 1.0
        this.widget._OnWheelResize(1)
        Assert.Equal(1.1, this.position.scale)
    }

    wheel_resize_decreases_scale_by_0_1_per_step_down()
    {
        this.position.scale := 1.5
        this.widget._OnWheelResize(-1)
        Assert.Equal(1.4, this.position.scale)
    }

    wheel_resize_multiple_steps_compound()
    {
        this.position.scale := 1.0
        this.widget._OnWheelResize(3)
        Assert.Equal(1.3, this.position.scale)
    }

    wheel_resize_clamps_to_min_0_5()
    {
        this.position.scale := 0.6
        this.widget._OnWheelResize(-5)   ; 0.6 - 0.5 = 0.1 -> clamp 0.5
        Assert.Equal(0.5, this.position.scale)
    }

    wheel_resize_clamps_to_max_3_0()
    {
        this.position.scale := 2.8
        this.widget._OnWheelResize(5)   ; 2.8 + 0.5 = 3.3 -> clamp 3.0
        Assert.Equal(3.0, this.position.scale)
    }

    wheel_resize_ignores_non_number_steps()
    {
        this.position.scale := 1.0
        this.widget._OnWheelResize("not number")
        Assert.Equal(1.0, this.position.scale, "Invalid steps: no-op")
    }

    wheel_resize_persists_on_change()
    {
        this.position.scale := 1.0
        before := this.persistCallCount
        this.widget._OnWheelResize(1)
        Assert.Equal(before + 1, this.persistCallCount)
    }

    wheel_resize_no_op_when_step_zero()
    {
        this.position.scale := 1.0
        before := this.persistCallCount
        this.widget._OnWheelResize(0)
        Assert.Equal(1.0, this.position.scale)
        Assert.Equal(before, this.persistCallCount,
            "Step 0: scale doesn't change, doesn't persist")
    }

    wheel_resize_rounds_to_avoid_float_drift()
    {
        ; Without rounding: 1.0 + 0.1 + 0.1 + 0.1 != 1.3 (float)
        this.position.scale := 1.0
        this.widget._OnWheelResize(1)
        this.widget._OnWheelResize(1)
        this.widget._OnWheelResize(1)
        ; Manual rounding in _OnWheelResize: Round(scale * 10) / 10
        Assert.Equal(1.3, this.position.scale,
            "Rounding prevents float drift (0.1+0.1+0.1 without fix != 0.3)")
    }

    wheel_resize_uses_default_when_position_scale_invalid()
    {
        ; If scale is 0 or non-number, _OnWheelResize uses 1.0 as base
        this.position.scale := 0
        this.widget._OnWheelResize(1)
        Assert.Equal(1.1, this.position.scale,
            "Default 1.0 when scale invalid")
    }

    ; ============================================================
    ; WidgetBase inheritance
    ; ============================================================

    inherits_set_visible()
    {
        this.widget.SetVisible(true)
        Assert.True(this.position.visible)
    }

    inherits_set_position()
    {
        this.widget.SetPosition(50.0, 60.0)
        Assert.Equal(50.0, this.position.left)
        Assert.Equal(60.0, this.position.top)
    }

    inherits_get_scale()
    {
        this.position.scale := 1.5
        Assert.Equal(1.5, this.widget.GetScale())
    }

    inherits_subscribes_to_ctrl_state_changed()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.CtrlStateChanged))
    }
}

TestRegistry.Register(LayoutWidgetBaseTests)
