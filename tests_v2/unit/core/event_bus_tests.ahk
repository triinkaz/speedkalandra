; ============================================================
; EventBus tests - full coverage
; ============================================================
;
; Covers the properties documented in the event_bus.ahk header:
;
;   - Synchronous, FIFO in subscribe order
;   - A handler that throws does not block others (error is logged)
;   - Safe Unsubscribe during Publish (clone-on-iterate)
;   - Subscribe during Publish does not affect the current dispatch (same reason)
;   - Bug #22: Unsubscribe of the last handler removes the key from the internal Map
;   - Subscribers(name) reflects state in real-time
;   - Publish on unknown event returns 0 and does not throw
;   - Subscribe validates inputs (empty eventName, non-object callback)

class EventBusTests extends TestCase
{
    bus   := ""
    calls := ""

    Setup()
    {
        this.bus   := Fixtures.MakeBus()
        this.calls := []
    }

    static Tests := [
        ; --- Basic Publish/Subscribe ---
        "publish_calls_subscribers_in_FIFO_order",
        "publish_passes_data_payload_to_handlers",
        "publish_with_no_data_passes_empty_string_default",
        "publish_returns_count_of_handlers_called",
        "publishing_unknown_event_returns_zero_and_does_not_throw",
        "publishing_to_one_event_does_not_call_handlers_of_another",
        "same_callback_subscribed_twice_is_called_twice",

        ; --- Subscribers / Clear ---
        "subscribers_count_reflects_state",
        "subscribers_returns_zero_for_unknown_event",
        "clear_removes_all_subscribers",

        ; --- Subscribe / Unsubscribe ---
        "subscribe_returns_callback_as_unsubscribe_token",
        "subscribe_validates_inputs",
        "unsubscribe_removes_callback",
        "unsubscribe_returns_true_when_callback_found",
        "unsubscribe_returns_false_when_callback_not_found",
        "unsubscribe_on_unknown_event_returns_false_no_throw",
        "unsubscribe_uses_callback_identity_not_equivalence",
        "unsubscribing_last_handler_removes_key_from_internal_map",

        ; --- Behavior during Publish ---
        "throwing_handler_does_not_break_iteration",
        "subscribe_during_publish_does_not_affect_current_dispatch",
        "unsubscribe_during_publish_does_not_affect_current_dispatch",

        ; --- Logger integration ---
        "logger_records_handler_errors_at_error_level",
    ]

    ; ============================================================
    ; Basic Publish/Subscribe
    ; ============================================================

    publish_calls_subscribers_in_FIFO_order()
    {
        out := this.calls
        this.bus.Subscribe("foo", (data) => out.Push("a"))
        this.bus.Subscribe("foo", (data) => out.Push("b"))
        this.bus.Subscribe("foo", (data) => out.Push("c"))

        this.bus.Publish("foo")

        Assert.Equal(["a", "b", "c"], this.calls)
    }

    publish_passes_data_payload_to_handlers()
    {
        out := this.calls
        this.bus.Subscribe("withPayload", (data) => out.Push(data))

        this.bus.Publish("withPayload", "hello")
        this.bus.Publish("withPayload", 42)

        Assert.Equal(["hello", 42], this.calls)
    }

    publish_with_no_data_passes_empty_string_default()
    {
        out := this.calls
        this.bus.Subscribe("foo", (data) => out.Push(data))
        this.bus.Publish("foo")
        Assert.Equal([""], this.calls)
    }

    publish_returns_count_of_handlers_called()
    {
        this.bus.Subscribe("foo", (data) => 0)
        this.bus.Subscribe("foo", (data) => 0)
        this.bus.Subscribe("foo", (data) => 0)

        Assert.Equal(3, this.bus.Publish("foo"))
    }

    publishing_unknown_event_returns_zero_and_does_not_throw()
    {
        delivered := this.bus.Publish("never_subscribed")
        Assert.Equal(0, delivered)
    }

    publishing_to_one_event_does_not_call_handlers_of_another()
    {
        out := this.calls
        this.bus.Subscribe("foo", (data) => out.Push("foo_handler"))
        this.bus.Subscribe("bar", (data) => out.Push("bar_handler"))

        this.bus.Publish("foo")

        Assert.Equal(["foo_handler"], this.calls)
    }

    same_callback_subscribed_twice_is_called_twice()
    {
        out := this.calls
        cb := (data) => out.Push("hit")
        this.bus.Subscribe("foo", cb)
        this.bus.Subscribe("foo", cb)
        Assert.Equal(2, this.bus.Subscribers("foo"))

        this.bus.Publish("foo")

        Assert.Equal(["hit", "hit"], this.calls)
    }

    ; ============================================================
    ; Subscribers / Clear
    ; ============================================================

    subscribers_count_reflects_state()
    {
        cb1 := (data) => 0
        cb2 := (data) => 0

        Assert.Equal(0, this.bus.Subscribers("foo"))

        this.bus.Subscribe("foo", cb1)
        Assert.Equal(1, this.bus.Subscribers("foo"))

        this.bus.Subscribe("foo", cb2)
        Assert.Equal(2, this.bus.Subscribers("foo"))

        this.bus.Unsubscribe("foo", cb1)
        Assert.Equal(1, this.bus.Subscribers("foo"))
    }

    subscribers_returns_zero_for_unknown_event()
    {
        Assert.Equal(0, this.bus.Subscribers("event_that_never_existed"))
    }

    clear_removes_all_subscribers()
    {
        this.bus.Subscribe("a", (data) => 0)
        this.bus.Subscribe("a", (data) => 0)
        this.bus.Subscribe("b", (data) => 0)

        this.bus.Clear()

        Assert.Equal(0, this.bus.Subscribers("a"))
        Assert.Equal(0, this.bus.Subscribers("b"))
        Assert.Equal(0, this.bus.Publish("a"))
    }

    ; ============================================================
    ; Subscribe / Unsubscribe
    ; ============================================================

    subscribe_returns_callback_as_unsubscribe_token()
    {
        cb := (data) => 0
        token := this.bus.Subscribe("foo", cb)
        ; Documented: Subscribe returns the callback itself
        Assert.True(token = cb, "Returned token should be the callback")
    }

    subscribe_validates_inputs()
    {
        bus := this.bus
        Assert.Throws(ValueError, () => bus.Subscribe("", (data) => 0))
        Assert.Throws(TypeError, () => bus.Subscribe("foo", "not a callable"))
        Assert.Throws(TypeError, () => bus.Subscribe("foo", 42))
    }

    unsubscribe_removes_callback()
    {
        out := this.calls
        cb  := (data) => out.Push("kept")
        cb2 := (data) => out.Push("removed")

        this.bus.Subscribe("foo", cb)
        this.bus.Subscribe("foo", cb2)
        this.bus.Unsubscribe("foo", cb2)

        this.bus.Publish("foo")

        Assert.Equal(["kept"], this.calls)
    }

    unsubscribe_returns_true_when_callback_found()
    {
        cb := (data) => 0
        this.bus.Subscribe("foo", cb)
        Assert.True(this.bus.Unsubscribe("foo", cb))
    }

    unsubscribe_returns_false_when_callback_not_found()
    {
        cb1 := (data) => 0
        cb2 := (data) => 0
        this.bus.Subscribe("foo", cb1)
        Assert.False(this.bus.Unsubscribe("foo", cb2),
            "Unsubscribe of an unregistered callback must return false")
    }

    unsubscribe_on_unknown_event_returns_false_no_throw()
    {
        cb := (data) => 0
        Assert.False(this.bus.Unsubscribe("never_existed", cb))
    }

    unsubscribe_uses_callback_identity_not_equivalence()
    {
        out := this.calls
        ; Two closures with the same implementation but distinct objects.
        fn1 := (data) => out.Push("x")
        fn2 := (data) => out.Push("x")

        this.bus.Subscribe("foo", fn1)
        Assert.False(this.bus.Unsubscribe("foo", fn2),
            "Equivalent but distinct closures must not match")
        Assert.Equal(1, this.bus.Subscribers("foo"))
    }

    ; Bug #22: at the end of each Stop/Start cycle, _subs could
    ; not grow indefinitely accumulating keys with an empty array.
    unsubscribing_last_handler_removes_key_from_internal_map()
    {
        cb := (data) => 0
        this.bus.Subscribe("foo", cb)
        Assert.Equal(1, this.bus.Subscribers("foo"))

        this.bus.Unsubscribe("foo", cb)
        Assert.Equal(0, this.bus.Subscribers("foo"))

        ; Indirectly verifies the key is gone: on resubscribe + publish,
        ; the path must be fresh (no residual empty array).
        cb2 := (data) => 0
        this.bus.Subscribe("foo", cb2)
        Assert.Equal(1, this.bus.Subscribers("foo"))
    }

    ; ============================================================
    ; Behavior during Publish
    ; ============================================================

    throwing_handler_does_not_break_iteration()
    {
        ; AHK v2: `throw` is a statement, not an expression - it
        ; doesn't fit in an arrow. We define the throwing handler as
        ; a nested function.
        out := this.calls
        BoomHandler(data)
        {
            throw Error("boom from handler")
        }

        this.bus.Subscribe("foo", (data) => out.Push("before"))
        this.bus.Subscribe("foo", BoomHandler)
        this.bus.Subscribe("foo", (data) => out.Push("after"))

        this.bus.Publish("foo")

        Assert.Equal(["before", "after"], this.calls)
    }

    subscribe_during_publish_does_not_affect_current_dispatch()
    {
        out := this.calls
        bus := this.bus

        ; When called during Publish, registers a third handler.
        ; Since Publish clones the array before iterating, that
        ; "late_join" does not receive the current publish - only the next.
        DynamicSubscriber(data)
        {
            out.Push("first")
            bus.Subscribe("foo", (d) => out.Push("late_join"))
        }

        bus.Subscribe("foo", DynamicSubscriber)
        bus.Subscribe("foo", (data) => out.Push("second"))

        bus.Publish("foo")

        Assert.Equal(["first", "second"], this.calls,
            "late_join must not receive the in-progress publish")
        Assert.Equal(3, bus.Subscribers("foo"),
            "But late_join IS registered for the next publish")
    }

    unsubscribe_during_publish_does_not_affect_current_dispatch()
    {
        out := this.calls
        bus := this.bus
        middleCb := (data) => out.Push("middle")

        ; This handler unsubscribes middleCb during the publish. But
        ; since the array was cloned before, middleCb STILL receives
        ; the current publish (comes later in the cloned order).
        Unsubber(data)
        {
            out.Push("unsubber")
            bus.Unsubscribe("foo", middleCb)
        }

        bus.Subscribe("foo", (data) => out.Push("first"))
        bus.Subscribe("foo", Unsubber)
        bus.Subscribe("foo", middleCb)
        bus.Subscribe("foo", (data) => out.Push("last"))

        bus.Publish("foo")

        Assert.Equal(["first", "unsubber", "middle", "last"], this.calls,
            "middleCb still receives this publish because the array was cloned")
        Assert.Equal(3, bus.Subscribers("foo"),
            "But middleCb is gone for the next publish")
    }

    ; ============================================================
    ; Logger integration
    ; ============================================================

    logger_records_handler_errors_at_error_level()
    {
        ; Convention: `log` collides with a global in some project file.
        ; We use `memLog` in tests for InMemoryLogger.
        memLog := InMemoryLogger()
        bus := EventBus(memLog)

        Kaboom(data)
        {
            throw Error("specific kaboom message")
        }

        bus.Subscribe("foo", Kaboom)
        bus.Publish("foo")

        Assert.True(memLog.HasEntry("ERROR", "specific kaboom message"),
            "Logger should have ERROR with the throw's message")
    }
}

TestRegistry.Register(EventBusTests)
