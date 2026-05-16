; ============================================================
; EventBus tests - cobertura completa
; ============================================================
;
; Cobre as propriedades documentadas no header do event_bus.ahk:
;
;   - Sincrono, FIFO em ordem de subscribe
;   - Handler que estoura nao impede outros (erro logado)
;   - Unsubscribe seguro durante Publish (clone-on-iterate)
;   - Subscribe durante Publish nao afeta dispatch atual (mesmo motivo)
;   - Bug #22: Unsubscribe do ultimo handler apaga a key do Map interno
;   - Subscribers(name) reflete estado em tempo real
;   - Publish em evento desconhecido retorna 0 e nao estoura
;   - Subscribe valida inputs (eventName vazio, callback nao-objeto)

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
        ; --- Publish/Subscribe basicos ---
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

        ; --- Comportamento durante Publish ---
        "throwing_handler_does_not_break_iteration",
        "subscribe_during_publish_does_not_affect_current_dispatch",
        "unsubscribe_during_publish_does_not_affect_current_dispatch",

        ; --- Integracao com logger ---
        "logger_records_handler_errors_at_error_level",
    ]

    ; ============================================================
    ; Publish/Subscribe basicos
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
        delivered := this.bus.Publish("nunca_subscrito")
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
        Assert.Equal(0, this.bus.Subscribers("event_que_nunca_existiu"))
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
        ; Documentado: Subscribe retorna a propria callback
        Assert.True(token = cb, "Token retornado deveria ser a callback")
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
            "Unsubscribe de callback nao-registrada deve retornar false")
    }

    unsubscribe_on_unknown_event_returns_false_no_throw()
    {
        cb := (data) => 0
        Assert.False(this.bus.Unsubscribe("nunca_existiu", cb))
    }

    unsubscribe_uses_callback_identity_not_equivalence()
    {
        out := this.calls
        ; Duas closures com mesma implementacao, mas objetos distintos.
        fn1 := (data) => out.Push("x")
        fn2 := (data) => out.Push("x")

        this.bus.Subscribe("foo", fn1)
        Assert.False(this.bus.Unsubscribe("foo", fn2),
            "Closures equivalentes mas distintas nao devem casar")
        Assert.Equal(1, this.bus.Subscribers("foo"))
    }

    ; Bug #22 (v17.15): ao fim de cada Stop/Start cycle, _subs nao podia
    ; crescer indefinidamente acumulando keys com array vazio.
    unsubscribing_last_handler_removes_key_from_internal_map()
    {
        cb := (data) => 0
        this.bus.Subscribe("foo", cb)
        Assert.Equal(1, this.bus.Subscribers("foo"))

        this.bus.Unsubscribe("foo", cb)
        Assert.Equal(0, this.bus.Subscribers("foo"))

        ; Verifica indiretamente que a key sumiu: ao resubscribe + publish,
        ; o caminho deve ser fresh (sem array vazio residual).
        cb2 := (data) => 0
        this.bus.Subscribe("foo", cb2)
        Assert.Equal(1, this.bus.Subscribers("foo"))
    }

    ; ============================================================
    ; Comportamento durante Publish
    ; ============================================================

    throwing_handler_does_not_break_iteration()
    {
        ; AHK v2: `throw` eh statement, nao expressao - nao cabe em arrow.
        ; Definimos o handler que estoura como funcao aninhada (nested).
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

        ; Quando chamado durante o Publish, registra um terceiro handler.
        ; Como Publish clona o array antes de iterar, esse "late_join"
        ; nao recebe o publish atual - so o proximo.
        DynamicSubscriber(data)
        {
            out.Push("first")
            bus.Subscribe("foo", (d) => out.Push("late_join"))
        }

        bus.Subscribe("foo", DynamicSubscriber)
        bus.Subscribe("foo", (data) => out.Push("second"))

        bus.Publish("foo")

        Assert.Equal(["first", "second"], this.calls,
            "late_join nao deve receber o publish em andamento")
        Assert.Equal(3, bus.Subscribers("foo"),
            "Mas o late_join ESTA registrado pro proximo publish")
    }

    unsubscribe_during_publish_does_not_affect_current_dispatch()
    {
        out := this.calls
        bus := this.bus
        middleCb := (data) => out.Push("middle")

        ; Esse handler unsubscreve middleCb durante o publish.
        ; Mas como o array foi clonado antes, middleCb AINDA recebe o
        ; publish atual (vem depois na ordem clonada).
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
            "middleCb ainda recebe esse publish porque o array foi clonado")
        Assert.Equal(3, bus.Subscribers("foo"),
            "Mas o middleCb saiu pro proximo publish")
    }

    ; ============================================================
    ; Integracao com logger
    ; ============================================================

    logger_records_handler_errors_at_error_level()
    {
        ; Convencao: `log` colide com global em algum arquivo do projeto.
        ; Usamos `memLog` em testes para InMemoryLogger.
        memLog := InMemoryLogger()
        bus := EventBus(memLog)

        Kaboom(data)
        {
            throw Error("specific kaboom message")
        }

        bus.Subscribe("foo", Kaboom)
        bus.Publish("foo")

        Assert.True(memLog.HasEntry("ERROR", "specific kaboom message"),
            "Logger deveria ter ERROR com a mensagem do throw")
    }
}

TestRegistry.Register(EventBusTests)
