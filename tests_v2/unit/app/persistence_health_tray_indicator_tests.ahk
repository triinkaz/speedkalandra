; ============================================================
; PersistenceHealthTrayIndicatorTests
; ============================================================
;
; Verifies the bus-driven tray indicator that surfaces
; RunService's _persistenceDegraded state.
;
; The class itself is small: it subscribes to
; Evt.PersistenceHealthChanged and toggles a disabled tray menu
; item. The tests inject lambdas in place of the real tray
; helpers so we can assert the call sequence without touching
; A_TrayMenu.
;
; Coverage:
;   - constructor type checks (bus, addFn, removeFn)
;   - degraded=true -> addItem called
;   - degraded=false -> removeItem called
;   - idempotent add (repeated degraded=true doesn't double-add)
;   - idempotent remove (repeated degraded=false doesn't false-remove)
;   - degraded=false BEFORE any degraded=true is a no-op
;   - Dispose unsubscribes from the bus
;   - Dispose clears a lingering item (no tray cruft on Reload)
;   - Dispose on a never-shown indicator is a no-op (doesn't try
;     to remove an item that was never added)

class PersistenceHealthTrayIndicatorTests extends TestCase
{
    bus       := ""
    addCalls  := ""
    rmCalls   := ""
    indicator := ""

    Setup()
    {
        this.bus      := Fixtures.MakeBus()
        this.addCalls := []
        this.rmCalls  := []
        addCallsRef   := this.addCalls
        rmCallsRef    := this.rmCalls
        this.indicator := PersistenceHealthTrayIndicator(
            this.bus,
            (label) => addCallsRef.Push(label),
            (label) => rmCallsRef.Push(label)
        )
    }

    Teardown()
    {
        if IsObject(this.indicator)
            try this.indicator.Dispose()
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_add_not_callable",
        "constructor_throws_when_remove_not_callable",

        ; --- Event-driven toggling ---
        "degraded_true_calls_add_function_with_label",
        "degraded_false_calls_remove_function_with_label",
        "repeated_degraded_true_does_not_double_add",
        "repeated_degraded_false_does_not_double_remove",
        "degraded_false_before_any_true_is_noop",
        "degraded_true_after_false_recovery_adds_again",
        "is_indicator_shown_tracks_state",

        ; --- Dispose ---
        "dispose_unsubscribes_handler_from_bus",
        "dispose_removes_lingering_item_when_shown",
        "dispose_no_remove_when_not_shown",
        "dispose_is_idempotent",
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        Assert.Throws(TypeError,
            () => PersistenceHealthTrayIndicator("not a bus"))
        Assert.Throws(TypeError,
            () => PersistenceHealthTrayIndicator(Map()))
    }

    constructor_throws_when_add_not_callable()
    {
        bus := Fixtures.MakeBus()
        Assert.Throws(TypeError,
            () => PersistenceHealthTrayIndicator(bus, "not callable"))
        Assert.Throws(TypeError,
            () => PersistenceHealthTrayIndicator(bus, Map("not", "a func")))
        Assert.Throws(TypeError,
            () => PersistenceHealthTrayIndicator(bus, 42))
    }

    constructor_throws_when_remove_not_callable()
    {
        bus := Fixtures.MakeBus()
        addOk := (label) => 0
        Assert.Throws(TypeError,
            () => PersistenceHealthTrayIndicator(bus, addOk, "not callable"))
        Assert.Throws(TypeError,
            () => PersistenceHealthTrayIndicator(bus, addOk, 42))
    }

    ; ============================================================
    ; Event-driven toggling
    ; ============================================================

    degraded_true_calls_add_function_with_label()
    {
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", true))

        Assert.Equal(1, this.addCalls.Length,
            "degraded=true must call the add function exactly once")
        Assert.Equal(0, this.rmCalls.Length,
            "degraded=true must NOT call the remove function")
        Assert.Equal(PersistenceHealthTrayIndicator.ITEM_LABEL,
            this.addCalls[1],
            "add function must receive the canonical menu label")
    }

    degraded_false_calls_remove_function_with_label()
    {
        ; Need an add first so remove is meaningful (Indicator
        ; tracks state and skips no-op removes).
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", true))
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", false))

        Assert.Equal(1, this.rmCalls.Length,
            "degraded=false must call the remove function exactly once")
        Assert.Equal(PersistenceHealthTrayIndicator.ITEM_LABEL,
            this.rmCalls[1],
            "remove function must receive the canonical menu label")
    }

    repeated_degraded_true_does_not_double_add()
    {
        ; Cheap insurance against a future subscriber-order quirk
        ; that might cause a duplicate publish. RunService's
        ; current contract already guarantees one-publish-per-
        ; transition, but the indicator stays idempotent anyway.
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", true))
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", true))
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", true))

        Assert.Equal(1, this.addCalls.Length,
            "consecutive degraded=true must NOT add multiple times")
    }

    repeated_degraded_false_does_not_double_remove()
    {
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", true))
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", false))
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", false))

        Assert.Equal(1, this.rmCalls.Length,
            "consecutive degraded=false must NOT remove multiple times")
    }

    degraded_false_before_any_true_is_noop()
    {
        ; First-ever publish carrying degraded=false must NOT
        ; remove anything (there's nothing to remove). Otherwise a
        ; production "fresh boot, healthy" publish would call
        ; A_TrayMenu.Delete on a label that doesn't exist.
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", false))

        Assert.Equal(0, this.addCalls.Length,
            "first-ever degraded=false must not add")
        Assert.Equal(0, this.rmCalls.Length,
            "first-ever degraded=false must not remove (nothing to remove)")
    }

    degraded_true_after_false_recovery_adds_again()
    {
        ; Full cycle: degraded -> recovered -> degraded again. The
        ; indicator must add again on the second degraded=true,
        ; not be stuck in the "already added" state.
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", true))
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", false))
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", true))

        Assert.Equal(2, this.addCalls.Length,
            "degraded -> recovered -> degraded must add twice")
        Assert.Equal(1, this.rmCalls.Length,
            "the only recovery in this sequence is one remove")
    }

    is_indicator_shown_tracks_state()
    {
        Assert.False(this.indicator.IsIndicatorShown(),
            "initial state: indicator not shown")

        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", true))
        Assert.True(this.indicator.IsIndicatorShown(),
            "after degraded=true: indicator shown")

        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", false))
        Assert.False(this.indicator.IsIndicatorShown(),
            "after degraded=false: indicator not shown")
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_handler_from_bus()
    {
        ; After Dispose, publishes must not reach the indicator
        ; (subscriber gone).
        this.indicator.Dispose()
        this.indicator := ""   ; signal Teardown to skip a second Dispose

        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", true))
        Assert.Equal(0, this.addCalls.Length,
            "Dispose must unsubscribe; later publishes must not call add")
    }

    dispose_removes_lingering_item_when_shown()
    {
        ; Mark the indicator as shown, then Dispose. The lingering
        ; tray item must be cleaned up so a Reload doesn't carry
        ; visual cruft into the next instance.
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", true))
        Assert.True(this.indicator.IsIndicatorShown(), "precondition: shown")

        this.indicator.Dispose()
        this.indicator := ""

        Assert.Equal(1, this.rmCalls.Length,
            "Dispose with a shown indicator must remove the item")
        Assert.Equal(PersistenceHealthTrayIndicator.ITEM_LABEL,
            this.rmCalls[1])
    }

    dispose_no_remove_when_not_shown()
    {
        ; Dispose without ever having shown the indicator must
        ; NOT call remove (avoids A_TrayMenu.Delete on a missing
        ; item, which throws in production).
        this.indicator.Dispose()
        this.indicator := ""

        Assert.Equal(0, this.rmCalls.Length,
            "Dispose on a never-shown indicator must NOT call remove")
    }

    dispose_is_idempotent()
    {
        ; Calling Dispose twice must not crash or call remove twice.
        this.bus.Publish(Events.PersistenceHealthChanged, Map("degraded", true))
        this.indicator.Dispose()
        this.indicator.Dispose()

        Assert.Equal(1, this.rmCalls.Length,
            "second Dispose must not call remove again")
        this.indicator := ""
    }
}

TestRegistry.Register(PersistenceHealthTrayIndicatorTests)
