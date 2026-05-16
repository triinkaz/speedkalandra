; ============================================================
; FocusAutoPauseServiceTests
; ============================================================
;
; Service hibrido (v0.1.1): subscribe a Evt.WindowFocusChanged (caminho
; rapido via Client.txt do PoE2) E Evt.Tick (polling backup a 300ms via
; WinActive). Ambos os caminhos disparam o mesmo handler
; _OnWindowFocusChanged que eh idempotente.
;
; ESTRATEGIA DE TEST: subclasse stub override `_IsGameActive` com flag
; in-memory. Isso evita dependencia de janela real do PoE2 nos testes,
; mantendo o codigo de produção intacto.


class _FocusAutoPauseStubService extends FocusAutoPauseService
{
    _stubGameActive := true   ; default: jogo ativo

    SetStubGameActive(isActive)
    {
        this._stubGameActive := !!isActive
    }

    _IsGameActive()
    {
        return this._stubGameActive
    }
}


class FocusAutoPauseServiceTests extends TestCase
{
    bus       := ""
    stubClock := ""
    timerSvc  := ""
    cfg       := ""
    svc       := ""

    Setup()
    {
        this.bus       := Fixtures.MakeBus()
        this.stubClock := Fixtures.MakeFakeClock(10000)
        this.timerSvc  := TimerService(this.stubClock, this.bus)
        this.cfg       := AppSettings.Defaults()
        this.cfg.autoPauseOnFocus := true
        this.svc       := _FocusAutoPauseStubService(this.bus, this.timerSvc, this.cfg)
    }

    Teardown()
    {
        if IsObject(this.svc)
            this.svc.Stop()
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Construtor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_timer_svc_not_timer_service",
        "constructor_throws_when_cfg_not_app_settings",
        "constructor_does_not_subscribe_until_start",
        "constructor_is_enabled_false",

        ; --- Start / Stop ---
        "start_subscribes_to_window_focus_changed",
        "start_subscribes_to_tick",
        "start_sets_is_enabled_true",
        "start_is_idempotent",
        "stop_unsubscribes_all",
        "stop_sets_is_enabled_false",
        "stop_is_idempotent",
        "stop_clears_paused_by_focus_flag",

        ; --- Lost focus event ---
        "lost_focus_pauses_running_timer",
        "lost_focus_sets_paused_by_focus_flag",
        "lost_focus_no_op_when_timer_stopped",
        "lost_focus_no_op_when_timer_paused",
        "lost_focus_no_op_when_setting_disabled",
        "lost_focus_no_op_when_service_stopped",

        ; --- Gained focus event ---
        "gained_focus_resumes_when_paused_by_focus",
        "gained_focus_clears_paused_by_focus_flag",
        "gained_focus_no_op_when_not_paused_by_focus",
        "gained_focus_no_op_when_timer_running",
        "gained_focus_does_not_resume_manually_paused_timer",

        ; --- Event payload edge cases ---
        "event_with_unknown_state_ignored",
        "event_with_non_object_data_ignored",
        "event_missing_state_key_ignored",

        ; --- Tick polling (backup) ---
        "tick_detects_focus_loss_via_polling",
        "tick_detects_focus_gain_via_polling",
        "tick_no_op_when_no_state_change",
        "tick_no_op_when_setting_disabled",
        "tick_no_op_when_service_stopped",

        ; --- Idempotencia: log+polling combinado ---
        "log_and_polling_combined_idempotent_for_loss",
        "log_and_polling_combined_idempotent_for_gain"
    ]

    ; ============================================================
    ; Construtor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        t := this.timerSvc
        c := this.cfg
        Assert.Throws(TypeError, () => FocusAutoPauseService("not bus", t, c))
    }

    constructor_throws_when_timer_svc_not_timer_service()
    {
        b := this.bus
        c := this.cfg
        Assert.Throws(TypeError, () => FocusAutoPauseService(b, "not timer", c))
    }

    constructor_throws_when_cfg_not_app_settings()
    {
        b := this.bus
        t := this.timerSvc
        Assert.Throws(TypeError, () => FocusAutoPauseService(b, t, "not cfg"))
    }

    constructor_does_not_subscribe_until_start()
    {
        ; Sem Start(), nada subscribed
        Assert.Equal(0, this.bus.Subscribers(Events.WindowFocusChanged))
        Assert.Equal(0, this.bus.Subscribers(Events.Tick))
    }

    constructor_is_enabled_false()
    {
        Assert.False(this.svc.IsEnabled())
    }

    ; ============================================================
    ; Start / Stop
    ; ============================================================

    start_subscribes_to_window_focus_changed()
    {
        this.svc.Start()
        Assert.Equal(1, this.bus.Subscribers(Events.WindowFocusChanged))
    }

    start_subscribes_to_tick()
    {
        this.svc.Start()
        Assert.Equal(1, this.bus.Subscribers(Events.Tick))
    }

    start_sets_is_enabled_true()
    {
        this.svc.Start()
        Assert.True(this.svc.IsEnabled())
    }

    start_is_idempotent()
    {
        this.svc.Start()
        this.svc.Start()
        Assert.Equal(1, this.bus.Subscribers(Events.WindowFocusChanged))
    }

    stop_unsubscribes_all()
    {
        this.svc.Start()
        this.svc.Stop()
        Assert.Equal(0, this.bus.Subscribers(Events.WindowFocusChanged))
        Assert.Equal(0, this.bus.Subscribers(Events.Tick))
    }

    stop_sets_is_enabled_false()
    {
        this.svc.Start()
        this.svc.Stop()
        Assert.False(this.svc.IsEnabled())
    }

    stop_is_idempotent()
    {
        this.svc.Stop()   ; sem Start antes
        this.svc.Stop()
        Assert.False(this.svc.IsEnabled())
    }

    stop_clears_paused_by_focus_flag()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.True(this.svc.WasPausedByFocus())
        this.svc.Stop()
        Assert.False(this.svc.WasPausedByFocus())
    }

    ; ============================================================
    ; Lost focus event
    ; ============================================================

    lost_focus_pauses_running_timer()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.True(this.timerSvc.IsPaused())
    }

    lost_focus_sets_paused_by_focus_flag()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.True(this.svc.WasPausedByFocus())
    }

    lost_focus_no_op_when_timer_stopped()
    {
        ; Timer parado: lost focus nao deve fazer nada
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.False(this.svc.WasPausedByFocus(),
            "Timer parado: nao seta flag pausedByFocus")
    }

    lost_focus_no_op_when_timer_paused()
    {
        this.timerSvc.Start()
        this.timerSvc.Pause()   ; user pausou manualmente
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.False(this.svc.WasPausedByFocus(),
            "Timer ja pausado pelo user: nao reivindica pausa")
    }

    lost_focus_no_op_when_setting_disabled()
    {
        this.cfg.autoPauseOnFocus := false
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.True(this.timerSvc.IsRunning(),
            "Setting desabilitada: timer continua rodando")
    }

    lost_focus_no_op_when_service_stopped()
    {
        this.timerSvc.Start()
        ; service nunca foi Start-ado
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.True(this.timerSvc.IsRunning())
    }

    ; ============================================================
    ; Gained focus event
    ; ============================================================

    gained_focus_resumes_when_paused_by_focus()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "gained"))
        Assert.True(this.timerSvc.IsRunning())
        Assert.False(this.timerSvc.IsPaused())
    }

    gained_focus_clears_paused_by_focus_flag()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "gained"))
        Assert.False(this.svc.WasPausedByFocus())
    }

    gained_focus_no_op_when_not_paused_by_focus()
    {
        this.timerSvc.Start()
        this.svc.Start()
        ; Sem lost focus antes — gained sozinho nao deve fazer nada
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "gained"))
        Assert.True(this.timerSvc.IsRunning())
    }

    gained_focus_no_op_when_timer_running()
    {
        this.timerSvc.Start()
        this.svc.Start()
        ; Timer rodando, gained: continua rodando
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "gained"))
        Assert.True(this.timerSvc.IsRunning())
    }

    gained_focus_does_not_resume_manually_paused_timer()
    {
        this.timerSvc.Start()
        this.svc.Start()
        ; lost focus pausa
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.True(this.svc.WasPausedByFocus())
        ; User pausa/resume manualmente DURANTE o alt-tab — flag fica pendurada
        ; ate gained ou Stop(). O importante eh: se user faz Resume manual,
        ; o gained subsequente nao quebra estado. (Cenario:
        ;   lost -> auto-pause -> user vai pra wiki -> volta -> user da resume
        ;   manual antes do gained chegar -> gained event resume um timer
        ;   ja running, no-op.)
        this.timerSvc.Resume()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "gained"))
        Assert.True(this.timerSvc.IsRunning())
        Assert.False(this.svc.WasPausedByFocus())
    }

    ; ============================================================
    ; Event payload edge cases
    ; ============================================================

    event_with_unknown_state_ignored()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "unknown"))
        Assert.True(this.timerSvc.IsRunning())
        Assert.False(this.svc.WasPausedByFocus())
    }

    event_with_non_object_data_ignored()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, "not a map")
        Assert.True(this.timerSvc.IsRunning())
    }

    event_missing_state_key_ignored()
    {
        this.timerSvc.Start()
        this.svc.Start()
        this.bus.Publish(Events.WindowFocusChanged, Map("other", "value"))
        Assert.True(this.timerSvc.IsRunning())
    }

    ; ============================================================
    ; Tick polling (backup, v0.1.1)
    ; ============================================================

    tick_detects_focus_loss_via_polling()
    {
        this.timerSvc.Start()
        ; Setup: jogo comeca ativo
        this.svc.SetStubGameActive(true)
        this.svc.Start()   ; snapshot inicial = true
        ; Simulando: jogo perdeu foco (user alt-tab)
        this.svc.SetStubGameActive(false)
        ; Tick polling deteca
        this.bus.Publish(Events.Tick, Map("now", 10500))
        Assert.True(this.timerSvc.IsPaused(),
            "Polling detectou perda de foco e pausou")
        Assert.True(this.svc.WasPausedByFocus())
    }

    tick_detects_focus_gain_via_polling()
    {
        this.timerSvc.Start()
        this.svc.SetStubGameActive(false)
        this.svc.Start()   ; snapshot inicial = false
        ; Pretende que timer foi pausado por foco (via lost path)
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        ; Mas timer ja estava running antes... vamos forcar via lost focus.
        ; Cenario completo: foco perdido -> pausou via log path, agora ganha foco
        this.svc.SetStubGameActive(true)
        this.bus.Publish(Events.Tick, Map("now", 11000))
        Assert.True(this.timerSvc.IsRunning(),
            "Polling detectou ganho de foco e resumiu")
    }

    tick_no_op_when_no_state_change()
    {
        this.timerSvc.Start()
        this.svc.SetStubGameActive(true)
        this.svc.Start()
        ; Sem mudanca, Tick eh no-op
        this.bus.Publish(Events.Tick, Map("now", 10500))
        Assert.True(this.timerSvc.IsRunning())
        Assert.False(this.svc.WasPausedByFocus())
    }

    tick_no_op_when_setting_disabled()
    {
        this.cfg.autoPauseOnFocus := false
        this.timerSvc.Start()
        this.svc.SetStubGameActive(true)
        this.svc.Start()
        ; Setting off: Tick nao faz nada
        this.svc.SetStubGameActive(false)
        this.bus.Publish(Events.Tick, Map("now", 10500))
        Assert.True(this.timerSvc.IsRunning())
    }

    tick_no_op_when_service_stopped()
    {
        this.timerSvc.Start()
        ; Service nunca foi Start
        this.bus.Publish(Events.Tick, Map("now", 10500))
        Assert.True(this.timerSvc.IsRunning())
    }

    ; ============================================================
    ; Idempotencia (log+polling combinado)
    ; ============================================================

    log_and_polling_combined_idempotent_for_loss()
    {
        ; v0.1.1: ambos os caminhos chamam mesmo handler.
        ; Log dispara primeiro -> Polling detecta mesma transicao -> no-op
        this.timerSvc.Start()
        this.svc.SetStubGameActive(true)
        this.svc.Start()

        ; Log dispara perda de foco (caminho rapido)
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        Assert.True(this.timerSvc.IsPaused())

        ; Polling deteca mesma perda — deve ser no-op (timer ja pausado)
        this.svc.SetStubGameActive(false)
        this.bus.Publish(Events.Tick, Map("now", 11000))
        Assert.True(this.timerSvc.IsPaused(),
            "Pause de timer ja pausado eh no-op (idempotente)")
    }

    log_and_polling_combined_idempotent_for_gain()
    {
        this.timerSvc.Start()
        this.svc.SetStubGameActive(true)
        this.svc.Start()

        ; Lost path
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
        this.svc.SetStubGameActive(false)
        this.bus.Publish(Events.Tick, Map("now", 11000))

        ; Gain via log
        this.svc.SetStubGameActive(true)
        this.bus.Publish(Events.WindowFocusChanged, Map("state", "gained"))
        Assert.True(this.timerSvc.IsRunning())

        ; Tick subsequente com mesmo state — no-op (timer ja running)
        this.bus.Publish(Events.Tick, Map("now", 12000))
        Assert.True(this.timerSvc.IsRunning())
    }
}

TestRegistry.Register(FocusAutoPauseServiceTests)
