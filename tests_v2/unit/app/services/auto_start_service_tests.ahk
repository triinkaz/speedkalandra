; ============================================================
; AutoStartServiceTests
; ============================================================
;
; AutoStartService subscribe a LogLineRead + lifecycle. Quando uma
; linha bate com cfg.autoStartRegex E nao ha run ativa, publica
; Cmd.NewRunRequested. Tolerante a regex invalida.
;
; Construtor opcional: terceiro arg `runService` permite query do
; estado inicial (Bug #4 v17.15: pos-reload com run em andamento,
; sem isso AutoStart disparava NewRun ao re-ler linhas do log).


class AutoStartServiceTests extends TestCase
{
    bus := ""
    cfg := ""
    svc := ""

    Setup()
    {
        this.bus := Fixtures.MakeBus()
        this.cfg := AppSettings.Defaults()
        this.cfg.autoStartRegex := "By the First Ones"   ; gatilho canonico
        this.svc := AutoStartService(this.bus, this.cfg)
    }

    Teardown()
    {
        if IsObject(this.svc)
            this.svc.Dispose()
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Construtor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_cfg_not_app_settings",
        "constructor_subscribes_to_log_line_read",
        "constructor_subscribes_to_all_run_lifecycle",
        "constructor_run_active_false_when_no_run_service_provided",
        "constructor_queries_run_service_when_provided",
        "constructor_ignores_run_service_without_is_active_method",

        ; --- LogLine handler: precondicoes ---
        "log_line_ignored_when_run_active",
        "log_line_ignored_when_data_non_object",
        "log_line_ignored_when_line_key_missing",
        "log_line_ignored_when_line_empty",
        "log_line_ignored_when_regex_empty",

        ; --- LogLine handler: match ---
        "log_line_match_publishes_new_run_requested",
        "log_line_no_match_publishes_nothing",
        "log_line_match_event_includes_source_auto",
        "log_line_match_sets_run_active_to_true",

        ; --- Regex invalida (tolerancia) ---
        "log_line_with_invalid_regex_does_not_crash",
        "log_line_with_invalid_regex_does_not_publish",

        ; --- Dedup ---
        "second_match_during_same_run_does_not_publish_again",

        ; --- RunStarted handler ---
        "run_started_sets_run_active_true",

        ; --- RunReset / Cancelled / Completed handlers ---
        "run_reset_clears_run_active",
        "run_cancelled_clears_run_active",
        "run_completed_clears_run_active",

        ; --- Fluxo completo ---
        "after_run_ended_next_match_publishes_again",

        ; --- Dispose ---
        "dispose_unsubscribes_all_handlers",
        "dispose_is_idempotent"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _CaptureEvents(eventName)
    {
        capturedEvents := []
        this.bus.Subscribe(eventName, (data) => capturedEvents.Push(data))
        return capturedEvents
    }

    ; ============================================================
    ; Construtor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        c := this.cfg
        Assert.Throws(TypeError, () => AutoStartService("not bus", c))
    }

    constructor_throws_when_cfg_not_app_settings()
    {
        b := this.bus
        Assert.Throws(TypeError, () => AutoStartService(b, "not cfg"))
    }

    constructor_subscribes_to_log_line_read()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.LogLineRead))
    }

    constructor_subscribes_to_all_run_lifecycle()
    {
        Assert.Equal(1, this.bus.Subscribers(Events.RunStarted))
        Assert.Equal(1, this.bus.Subscribers(Events.RunReset))
        Assert.Equal(1, this.bus.Subscribers(Events.RunCancelled))
        Assert.Equal(1, this.bus.Subscribers(Events.RunCompleted))
    }

    constructor_run_active_false_when_no_run_service_provided()
    {
        Assert.False(this.svc.IsRunActive())
    }

    constructor_queries_run_service_when_provided()
    {
        ; Stub runService que retorna IsActive=true.
        ; AHK passa `this` implicito quando chamado como metodo — a arrow
        ; precisa aceitar 1 parametro pra nao estourar "Too many parameters".
        stubRunSvc := { IsActive: (self) => true }
        svc2 := AutoStartService(this.bus, this.cfg, stubRunSvc)
        Assert.True(svc2.IsRunActive(),
            "Bug #4 v17.15: query runService no boot pra evitar dispatching apos hydrate")
        svc2.Dispose()
    }

    constructor_ignores_run_service_without_is_active_method()
    {
        ; Defensivo: runService sem IsActive nao quebra
        emptyObj := { foo: (self) => 0 }
        svc2 := AutoStartService(this.bus, this.cfg, emptyObj)
        Assert.False(svc2.IsRunActive())
        svc2.Dispose()
    }

    ; ============================================================
    ; LogLine handler: precondicoes
    ; ============================================================

    log_line_ignored_when_run_active()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))   ; ativa run
        capturedEvents := this._CaptureEvents(Commands.NewRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "By the First Ones! You're alive!"))
        Assert.Equal(0, capturedEvents.Length, "Run ativa: nao dispara")
    }

    log_line_ignored_when_data_non_object()
    {
        capturedEvents := this._CaptureEvents(Commands.NewRunRequested)
        this.bus.Publish(Events.LogLineRead, "not a map")
        Assert.Equal(0, capturedEvents.Length)
    }

    log_line_ignored_when_line_key_missing()
    {
        capturedEvents := this._CaptureEvents(Commands.NewRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("other", "value"))
        Assert.Equal(0, capturedEvents.Length)
    }

    log_line_ignored_when_line_empty()
    {
        capturedEvents := this._CaptureEvents(Commands.NewRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", ""))
        Assert.Equal(0, capturedEvents.Length)
    }

    log_line_ignored_when_regex_empty()
    {
        this.cfg.autoStartRegex := ""
        capturedEvents := this._CaptureEvents(Commands.NewRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "Anything goes"))
        Assert.Equal(0, capturedEvents.Length)
    }

    ; ============================================================
    ; LogLine handler: match
    ; ============================================================

    log_line_match_publishes_new_run_requested()
    {
        capturedEvents := this._CaptureEvents(Commands.NewRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "By the First Ones! You're alive!"))
        Assert.Equal(1, capturedEvents.Length)
    }

    log_line_no_match_publishes_nothing()
    {
        capturedEvents := this._CaptureEvents(Commands.NewRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "Some other log line"))
        Assert.Equal(0, capturedEvents.Length)
    }

    log_line_match_event_includes_source_auto()
    {
        capturedEvents := this._CaptureEvents(Commands.NewRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "By the First Ones!"))
        Assert.Equal("auto", capturedEvents[1]["source"])
    }

    log_line_match_sets_run_active_to_true()
    {
        ; Apos match, IsRunActive=true (otimisticamente — RunStarted vai confirmar)
        this.bus.Publish(Events.LogLineRead, Map("line", "By the First Ones!"))
        Assert.True(this.svc.IsRunActive(),
            "Marca otimisticamente apos publish, evita re-dispatch")
    }

    ; ============================================================
    ; Regex invalida (tolerancia)
    ; ============================================================

    log_line_with_invalid_regex_does_not_crash()
    {
        ; Regex com pattern invalido (parentese nao fechado)
        this.cfg.autoStartRegex := "(unclosed"
        ; Nao deve estourar; o test passa se chegou aqui
        this.bus.Publish(Events.LogLineRead, Map("line", "(unclosed"))
        Assert.True(true, "Sobreviveu a regex invalida")
    }

    log_line_with_invalid_regex_does_not_publish()
    {
        this.cfg.autoStartRegex := "(unclosed"
        capturedEvents := this._CaptureEvents(Commands.NewRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "(unclosed"))
        Assert.Equal(0, capturedEvents.Length, "Regex invalida nao dispara")
    }

    ; ============================================================
    ; Dedup
    ; ============================================================

    second_match_during_same_run_does_not_publish_again()
    {
        capturedEvents := this._CaptureEvents(Commands.NewRunRequested)
        this.bus.Publish(Events.LogLineRead, Map("line", "By the First Ones!"))
        this.bus.Publish(Events.LogLineRead, Map("line", "By the First Ones! again!"))
        Assert.Equal(1, capturedEvents.Length,
            "_runActive=true apos primeiro match impede repeticao")
    }

    ; ============================================================
    ; Lifecycle handlers
    ; ============================================================

    run_started_sets_run_active_true()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        Assert.True(this.svc.IsRunActive())
    }

    run_reset_clears_run_active()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.RunReset, Map("runId", "x"))
        Assert.False(this.svc.IsRunActive())
    }

    run_cancelled_clears_run_active()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.RunCancelled, Map("runId", "x"))
        Assert.False(this.svc.IsRunActive())
    }

    run_completed_clears_run_active()
    {
        this.bus.Publish(Events.RunStarted, Map("runId", "x"))
        this.bus.Publish(Events.RunCompleted, Map("runId", "x"))
        Assert.False(this.svc.IsRunActive())
    }

    ; ============================================================
    ; Fluxo completo
    ; ============================================================

    after_run_ended_next_match_publishes_again()
    {
        capturedEvents := this._CaptureEvents(Commands.NewRunRequested)
        ; Run 1
        this.bus.Publish(Events.LogLineRead, Map("line", "By the First Ones!"))
        Assert.Equal(1, capturedEvents.Length)
        ; Run 1 acaba
        this.bus.Publish(Events.RunCompleted, Map())
        ; Run 2 — match dispara de novo
        this.bus.Publish(Events.LogLineRead, Map("line", "By the First Ones!"))
        Assert.Equal(2, capturedEvents.Length)
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_all_handlers()
    {
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.LogLineRead))
        Assert.Equal(0, this.bus.Subscribers(Events.RunStarted))
        Assert.Equal(0, this.bus.Subscribers(Events.RunReset))
        Assert.Equal(0, this.bus.Subscribers(Events.RunCancelled))
        Assert.Equal(0, this.bus.Subscribers(Events.RunCompleted))
    }

    dispose_is_idempotent()
    {
        this.svc.Dispose()
        this.svc.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.LogLineRead))
    }
}

TestRegistry.Register(AutoStartServiceTests)
