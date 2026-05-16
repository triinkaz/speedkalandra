; ============================================================
; WidgetBaseTests
; ============================================================
;
; WidgetBase eh classe base de todos os widgets. Testavel logica:
;   - Construtor validations
;   - Subscribe automatico a Evt.CtrlStateChanged
;   - Queries (IsVisible/IsRendered/IsModeVisible/GetPosition/GetScale/GetSize)
;   - Mutators (SetVisible/SetModeVisible/SetActivePosition/SetScale/SetPosition)
;     com clamp e callback _Persist
;   - _OnCtrlStateChanged handler
;
; NAO TESTAVEL EM HEADLESS: Show/Hide/ReRender (criam Gui real, chamam
; WinSetTransparent etc). Tests evitam tocar nesses caminhos mantendo
; position.visible=false (ReRender vira no-op).
;
; STUB: _WidgetBaseStub extends WidgetBase implementa _BuildGui minimal
; pra satisfazer o template method abstrato.


class _WidgetBaseStub extends WidgetBase
{
    _BuildGui()
    {
        this._w := 100
        this._h := 50
    }
}


class WidgetBaseTests extends TestCase
{
    bus      := ""
    position := ""
    persistCallCount := 0
    persistCb := ""
    widget   := ""

    Setup()
    {
        this.bus := Fixtures.MakeBus()
        ; Posicao com visible=false pra evitar Show real durante mutators
        this.position := OverlayPosition.FromMap(Map(
            "left",     10.0,
            "top",      20.0,
            "scale",    1.0,
            "visible",  false,
            "centered", false
        ))
        this.persistCallCount := 0
        this.persistCb := ObjBindMethod(this, "_PersistCounter")
        this.widget := _WidgetBaseStub(
            "stub", "Stub Widget", this.bus, this.position, this.persistCb
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
        ; --- Construtor ---
        "constructor_throws_when_id_empty",
        "constructor_throws_when_name_empty",
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_position_not_overlay_position",
        "constructor_throws_when_on_persist_not_callable",
        "constructor_accepts_empty_on_persist",
        "constructor_subscribes_to_ctrl_state_changed",
        "constructor_stores_id_and_name",

        ; --- Queries initial state ---
        "is_visible_reads_from_position",
        "is_rendered_false_initially",
        "is_mode_visible_true_initially",
        "get_position_returns_ref",
        "get_scale_reads_from_position",
        "get_size_returns_zero_zero_before_render",

        ; --- SetVisible ---
        "set_visible_true_updates_position",
        "set_visible_false_updates_position",
        "set_visible_coerces_truthy",
        "set_visible_persists_on_change",
        "set_visible_no_op_when_same",
        "set_visible_does_not_persist_when_same",

        ; --- SetModeVisible ---
        "set_mode_visible_true_updates_flag",
        "set_mode_visible_false_updates_flag",
        "set_mode_visible_no_op_when_same",
        "set_mode_visible_does_not_persist",

        ; --- SetActivePosition ---
        "set_active_position_throws_on_non_overlay_position",
        "set_active_position_swaps_ref",
        "set_active_position_no_op_when_same_object",

        ; --- SetScale ---
        "set_scale_updates_position_scale",
        "set_scale_clamps_to_min_0_5",
        "set_scale_clamps_to_max_3_0",
        "set_scale_throws_on_zero",
        "set_scale_throws_on_negative",
        "set_scale_throws_on_non_number",
        "set_scale_persists_on_change",
        "set_scale_no_op_when_same",

        ; --- SetPosition ---
        "set_position_updates_left_and_top",
        "set_position_sets_centered_flag",
        "set_position_clamps_left_to_min_0",
        "set_position_clamps_left_to_max_95",
        "set_position_clamps_top_to_min_0",
        "set_position_clamps_top_to_max_95",
        "set_position_throws_on_non_number_left",
        "set_position_throws_on_non_number_top",
        "set_position_persists",

        ; --- _OnCtrlStateChanged ---
        "ctrl_state_changed_event_received",
        "ctrl_state_changed_with_non_object_no_crash",
        "ctrl_state_changed_without_active_key_no_crash"
    ]

    ; ============================================================
    ; Construtor
    ; ============================================================

    constructor_throws_when_id_empty()
    {
        b := this.bus
        p := this.position
        Assert.Throws(ValueError, () => _WidgetBaseStub("", "Name", b, p))
    }

    constructor_throws_when_name_empty()
    {
        b := this.bus
        p := this.position
        Assert.Throws(ValueError, () => _WidgetBaseStub("id", "", b, p))
    }

    constructor_throws_when_bus_not_event_bus()
    {
        p := this.position
        Assert.Throws(TypeError, () => _WidgetBaseStub("id", "Name", "not bus", p))
    }

    constructor_throws_when_position_not_overlay_position()
    {
        b := this.bus
        Assert.Throws(TypeError, () => _WidgetBaseStub("id", "Name", b, "not pos"))
    }

    constructor_throws_when_on_persist_not_callable()
    {
        b := this.bus
        p := this.position
        Assert.Throws(TypeError, () => _WidgetBaseStub("id", "Name", b, p, "not callable"))
    }

    constructor_accepts_empty_on_persist()
    {
        b := this.bus
        p := this.position
        ; Sem onPersist (string vazia eh OK)
        wg := _WidgetBaseStub("id", "Name", b, p, "")
        Assert.Equal("id", wg.id)
    }

    constructor_subscribes_to_ctrl_state_changed()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.CtrlStateChanged))
    }

    constructor_stores_id_and_name()
    {
        Assert.Equal("stub", this.widget.id)
        Assert.Equal("Stub Widget", this.widget.name)
    }

    ; ============================================================
    ; Queries
    ; ============================================================

    is_visible_reads_from_position()
    {
        Assert.False(this.widget.IsVisible(), "position.visible=false")
        this.position.visible := true
        Assert.True(this.widget.IsVisible())
    }

    is_rendered_false_initially()
    {
        Assert.False(this.widget.IsRendered())
    }

    is_mode_visible_true_initially()
    {
        Assert.True(this.widget.IsModeVisible())
    }

    get_position_returns_ref()
    {
        ; Ref nao copia
        p := this.widget.GetPosition()
        Assert.Equal(this.position, p)
        p.scale := 2.5   ; muta via ref
        Assert.Equal(2.5, this.position.scale)
    }

    get_scale_reads_from_position()
    {
        this.position.scale := 1.5
        Assert.Equal(1.5, this.widget.GetScale())
    }

    get_size_returns_zero_zero_before_render()
    {
        sz := this.widget.GetSize()
        Assert.Equal(0, sz["w"])
        Assert.Equal(0, sz["h"])
    }

    ; ============================================================
    ; SetVisible
    ; ============================================================

    set_visible_true_updates_position()
    {
        this.widget.SetVisible(true)
        Assert.True(this.position.visible)
    }

    set_visible_false_updates_position()
    {
        this.position.visible := true   ; setup pra ter algo pra mudar
        this.widget.SetVisible(false)
        Assert.False(this.position.visible)
    }

    set_visible_coerces_truthy()
    {
        this.widget.SetVisible(1)
        Assert.True(this.position.visible)
        Assert.True(this.position.visible is Integer, "Coercao pra bool primitivo (true=1)")
    }

    set_visible_persists_on_change()
    {
        before := this.persistCallCount
        this.widget.SetVisible(true)
        Assert.Equal(before + 1, this.persistCallCount)
    }

    set_visible_no_op_when_same()
    {
        ; position.visible ja eh false
        before := this.persistCallCount
        this.widget.SetVisible(false)
        Assert.Equal(before, this.persistCallCount, "Mesmo valor: no-op")
    }

    set_visible_does_not_persist_when_same()
    {
        this.position.visible := true
        before := this.persistCallCount
        this.widget.SetVisible(true)
        Assert.Equal(before, this.persistCallCount)
    }

    ; ============================================================
    ; SetModeVisible
    ; ============================================================

    set_mode_visible_true_updates_flag()
    {
        this.widget._modeVisible := false
        this.widget.SetModeVisible(true)
        Assert.True(this.widget.IsModeVisible())
    }

    set_mode_visible_false_updates_flag()
    {
        this.widget.SetModeVisible(false)
        Assert.False(this.widget.IsModeVisible())
    }

    set_mode_visible_no_op_when_same()
    {
        ; _modeVisible default eh true
        this.widget.SetModeVisible(true)
        Assert.True(this.widget.IsModeVisible())
    }

    set_mode_visible_does_not_persist()
    {
        before := this.persistCallCount
        this.widget.SetModeVisible(false)
        Assert.Equal(before, this.persistCallCount,
            "SetModeVisible NAO persiste (flag temporario do modo)")
    }

    ; ============================================================
    ; SetActivePosition
    ; ============================================================

    set_active_position_throws_on_non_overlay_position()
    {
        w := this.widget
        Assert.Throws(TypeError, () => w.SetActivePosition("not pos"))
        Assert.Throws(TypeError, () => w.SetActivePosition(Map()))
    }

    set_active_position_swaps_ref()
    {
        newPos := OverlayPosition.FromMap(Map(
            "left", 50.0, "top", 60.0, "scale", 2.0, "visible", true, "centered", false
        ))
        this.widget.SetActivePosition(newPos)
        Assert.Equal(newPos, this.widget.GetPosition())
    }

    set_active_position_no_op_when_same_object()
    {
        before := this.persistCallCount
        this.widget.SetActivePosition(this.position)
        Assert.Equal(before, this.persistCallCount,
            "Mesma ref: no-op (e SetActivePosition nao persiste mesmo quando muda)")
    }

    ; ============================================================
    ; SetScale
    ; ============================================================

    set_scale_updates_position_scale()
    {
        this.widget.SetScale(1.5)
        Assert.Equal(1.5, this.position.scale)
    }

    set_scale_clamps_to_min_0_5()
    {
        this.widget.SetScale(0.1)
        Assert.Equal(0.5, this.position.scale)
    }

    set_scale_clamps_to_max_3_0()
    {
        this.widget.SetScale(5.0)
        Assert.Equal(3.0, this.position.scale)
    }

    set_scale_throws_on_zero()
    {
        w := this.widget
        Assert.Throws(ValueError, () => w.SetScale(0))
    }

    set_scale_throws_on_negative()
    {
        w := this.widget
        Assert.Throws(ValueError, () => w.SetScale(-1.0))
    }

    set_scale_throws_on_non_number()
    {
        w := this.widget
        Assert.Throws(ValueError, () => w.SetScale("not number"))
    }

    set_scale_persists_on_change()
    {
        before := this.persistCallCount
        this.widget.SetScale(2.0)
        Assert.Equal(before + 1, this.persistCallCount)
    }

    set_scale_no_op_when_same()
    {
        ; scale eh 1.0 inicialmente
        before := this.persistCallCount
        this.widget.SetScale(1.0)
        Assert.Equal(before, this.persistCallCount)
    }

    ; ============================================================
    ; SetPosition
    ; ============================================================

    set_position_updates_left_and_top()
    {
        this.widget.SetPosition(50.0, 60.0)
        Assert.Equal(50.0, this.position.left)
        Assert.Equal(60.0, this.position.top)
    }

    set_position_sets_centered_flag()
    {
        this.widget.SetPosition(50.0, 60.0, true)
        Assert.True(this.position.centered)
    }

    set_position_clamps_left_to_min_0()
    {
        this.widget.SetPosition(-10.0, 20.0)
        Assert.Equal(0, this.position.left)
    }

    set_position_clamps_left_to_max_95()
    {
        this.widget.SetPosition(150.0, 20.0)
        Assert.Equal(95, this.position.left)
    }

    set_position_clamps_top_to_min_0()
    {
        this.widget.SetPosition(20.0, -10.0)
        Assert.Equal(0, this.position.top)
    }

    set_position_clamps_top_to_max_95()
    {
        this.widget.SetPosition(20.0, 150.0)
        Assert.Equal(95, this.position.top)
    }

    set_position_throws_on_non_number_left()
    {
        w := this.widget
        Assert.Throws(TypeError, () => w.SetPosition("not num", 20.0))
    }

    set_position_throws_on_non_number_top()
    {
        w := this.widget
        Assert.Throws(TypeError, () => w.SetPosition(20.0, "not num"))
    }

    set_position_persists()
    {
        before := this.persistCallCount
        this.widget.SetPosition(50.0, 60.0)
        Assert.Equal(before + 1, this.persistCallCount)
    }

    ; ============================================================
    ; _OnCtrlStateChanged
    ; ============================================================

    ctrl_state_changed_event_received()
    {
        ; So testa que nao crasha quando publish com payload valido.
        ; Internamente o handler chama _SetCtrlHighlightVisible que eh
        ; no-op se !_gui (caso atual: nao renderizado).
        this.bus.Publish(Events.CtrlStateChanged, Map("active", true))
        Assert.True(true, "Handler tolerou evento sem crashar")
    }

    ctrl_state_changed_with_non_object_no_crash()
    {
        this.bus.Publish(Events.CtrlStateChanged, "not a map")
        Assert.True(true)
    }

    ctrl_state_changed_without_active_key_no_crash()
    {
        this.bus.Publish(Events.CtrlStateChanged, Map("other", "value"))
        Assert.True(true)
    }
}

TestRegistry.Register(WidgetBaseTests)
