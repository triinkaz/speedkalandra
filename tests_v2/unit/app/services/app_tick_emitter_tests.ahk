; ============================================================
; AppTickEmitterTests
; ============================================================
;
; AppTickEmitter é deliberadamente simples:
;   - bus + intervalMs no construtor
;   - Start/Stop usam SetTimer real (OS hook)
;   - Pulse() é test-friendly: publica Events.Tick UMA vez sem
;     usar SetTimer. Usamos Pulse() pra verificar comportamento
;     de pulse sem timing real.
;
; Cobertura:
;   - Construtor: validações (bus tipo, intervalMs > 0, integer)
;   - Queries: GetIntervalMs / IsRunning / default interval
;   - Pulse: publica Events.Tick, idempotência, não afeta state
;   - Start/Stop: state changes + idempotência
;
; NOTA: NÃO testamos SetTimer real. O teste seria flaky e lento.
; Idempotência é verificada via state field, não via emission count.


class AppTickEmitterTests extends TestCase
{
    bus := ""

    Setup()
    {
        this.bus := Fixtures.MakeBus()
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Construtor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_on_zero_interval",
        "constructor_throws_on_negative_interval",
        "constructor_throws_on_non_integer_interval",
        "constructor_accepts_valid_bus_and_interval",

        ; --- Queries ---
        "default_interval_is_300_ms",
        "get_interval_ms_returns_constructor_arg",
        "is_running_false_by_default",

        ; --- Pulse ---
        "pulse_publishes_tick_event",
        "pulse_publishes_with_empty_data_payload",
        "pulse_can_be_called_multiple_times",
        "pulse_does_not_change_running_state",

        ; --- Start/Stop ---
        "start_sets_is_running_true",
        "stop_sets_is_running_false",
        "start_is_idempotent_when_already_running",
        "stop_is_idempotent_when_already_stopped",
        "multiple_start_stop_cycles_are_safe"
    ]

    ; ============================================================
    ; Construtor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        Assert.Throws(TypeError, () => AppTickEmitter("not a bus"))
    }

    constructor_throws_on_zero_interval()
    {
        emitterBus := this.bus
        Assert.Throws(ValueError, () => AppTickEmitter(emitterBus, 0))
    }

    constructor_throws_on_negative_interval()
    {
        emitterBus := this.bus
        Assert.Throws(ValueError, () => AppTickEmitter(emitterBus, -100))
    }

    constructor_throws_on_non_integer_interval()
    {
        emitterBus := this.bus
        Assert.Throws(ValueError, () => AppTickEmitter(emitterBus, "abc"))
    }

    constructor_accepts_valid_bus_and_interval()
    {
        emitter := AppTickEmitter(this.bus, 500)
        Assert.Equal(500, emitter.GetIntervalMs())
    }

    ; ============================================================
    ; Queries
    ; ============================================================

    default_interval_is_300_ms()
    {
        emitter := AppTickEmitter(this.bus)
        Assert.Equal(300, emitter.GetIntervalMs())
    }

    get_interval_ms_returns_constructor_arg()
    {
        emitter := AppTickEmitter(this.bus, 1000)
        Assert.Equal(1000, emitter.GetIntervalMs())
    }

    is_running_false_by_default()
    {
        emitter := AppTickEmitter(this.bus, 300)
        Assert.False(emitter.IsRunning())
    }

    ; ============================================================
    ; Pulse
    ; ============================================================

    pulse_publishes_tick_event()
    {
        out := []
        this.bus.Subscribe(Events.Tick, (data) => out.Push("tick"))
        emitter := AppTickEmitter(this.bus, 300)
        emitter.Pulse()
        Assert.Equal(1, out.Length)
    }

    pulse_publishes_with_empty_data_payload()
    {
        out := []
        this.bus.Subscribe(Events.Tick, (data) => out.Push(data))
        emitter := AppTickEmitter(this.bus, 300)
        emitter.Pulse()
        ; EventBus.Publish sem data passa "" como default (vide Wave 1)
        Assert.Equal([""], out)
    }

    pulse_can_be_called_multiple_times()
    {
        out := []
        this.bus.Subscribe(Events.Tick, (data) => out.Push("tick"))
        emitter := AppTickEmitter(this.bus, 300)
        emitter.Pulse()
        emitter.Pulse()
        emitter.Pulse()
        Assert.Equal(3, out.Length)
    }

    pulse_does_not_change_running_state()
    {
        emitter := AppTickEmitter(this.bus, 300)
        emitter.Pulse()
        Assert.False(emitter.IsRunning(),
            "Pulse manual nao deve marcar emitter como rodando")
    }

    ; ============================================================
    ; Start/Stop
    ; ============================================================

    start_sets_is_running_true()
    {
        emitter := AppTickEmitter(this.bus, 300)
        emitter.Start()
        try
            Assert.True(emitter.IsRunning())
        finally
            emitter.Stop()    ; cleanup SetTimer real
    }

    stop_sets_is_running_false()
    {
        emitter := AppTickEmitter(this.bus, 300)
        emitter.Start()
        emitter.Stop()
        Assert.False(emitter.IsRunning())
    }

    start_is_idempotent_when_already_running()
    {
        emitter := AppTickEmitter(this.bus, 300)
        emitter.Start()
        try
        {
            ; Segundo Start nao deve quebrar nem mudar state
            emitter.Start()
            Assert.True(emitter.IsRunning())
        }
        finally
            emitter.Stop()
    }

    stop_is_idempotent_when_already_stopped()
    {
        emitter := AppTickEmitter(this.bus, 300)
        ; Stop em estado parado: no-op
        emitter.Stop()
        Assert.False(emitter.IsRunning())
    }

    multiple_start_stop_cycles_are_safe()
    {
        emitter := AppTickEmitter(this.bus, 300)
        emitter.Start()
        emitter.Stop()
        emitter.Start()
        emitter.Stop()
        Assert.False(emitter.IsRunning())
    }
}

TestRegistry.Register(AppTickEmitterTests)
