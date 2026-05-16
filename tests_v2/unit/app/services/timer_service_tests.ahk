; ============================================================
; TimerServiceTests
; ============================================================
;
; TimerService: state machine 3-estados com clock + bus injetaveis.
;   - PARADO  : !_active
;   - RODANDO : _active && !_paused
;   - PAUSADO : _active && _paused
;
; Comandos: Start, Pause, Resume, Stop, Reset, Toggle, Hydrate
; Queries:  IsActive, IsRunning, IsPaused, GetRunMs
; Eventos:  TimerStarted/Paused/Resumed/Stopped/Reset (todos via bus)
;
; NOTA: variavel local `events` colide case-insensitively com a CLASSE
; `Events` (pitfall #4 do README). Usar `evtLog` em vez disso.
;
; Cobertura:
;   - Construtor (validacao clock/bus)
;   - Queries iniciais
;   - Cada transicao valida + evento publicado
;   - No-ops (comando em estado errado: retorna false, nao publica)
;   - GetRunMs em cada estado + apos pausa/resume
;   - Toggle (state machine)
;   - Reset (sempre publica)
;   - Hydrate (silencioso, 3 status hints, defensivos)


class TimerServiceTests extends TestCase
{
    bus       := ""
    stubClock := ""
    svc       := ""

    Setup()
    {
        this.bus       := Fixtures.MakeBus()
        this.stubClock := Fixtures.MakeFakeClock(1000)   ; initialMs=1000
        this.svc       := TimerService(this.stubClock, this.bus)
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Construtor ---
        "constructor_throws_when_clock_missing_now_ms",
        "constructor_throws_when_clock_is_string",
        "constructor_throws_when_bus_not_event_bus",
        "constructor_accepts_valid_clock_and_bus",

        ; --- Queries iniciais ---
        "is_active_false_initially",
        "is_running_false_initially",
        "is_paused_false_initially",
        "get_run_ms_zero_initially",

        ; --- Start ---
        "start_from_idle_activates_and_returns_true",
        "start_from_idle_publishes_timer_started_with_zero_run_ms",
        "start_when_already_running_returns_false",
        "start_when_already_running_does_not_publish",
        "start_when_paused_returns_false",

        ; --- GetRunMs durante RUNNING ---
        "get_run_ms_returns_zero_immediately_after_start",
        "get_run_ms_returns_clock_delta_while_running",
        "get_run_ms_increases_with_clock_advance",

        ; --- Pause ---
        "pause_from_running_returns_true",
        "pause_from_running_marks_as_paused",
        "pause_publishes_timer_paused_with_current_run_ms",
        "pause_when_idle_returns_false",
        "pause_when_already_paused_returns_false",

        ; --- GetRunMs durante PAUSED ---
        "get_run_ms_constant_while_paused_after_advance",
        "pause_commits_delta_to_base_ms",

        ; --- Resume ---
        "resume_from_paused_returns_true",
        "resume_marks_as_running_again",
        "resume_publishes_timer_resumed_with_run_ms",
        "resume_when_idle_returns_false",
        "resume_when_running_returns_false",
        "resume_continues_accumulating_after_pause",

        ; --- Stop ---
        "stop_from_running_deactivates",
        "stop_from_paused_deactivates",
        "stop_preserves_base_ms_in_get_run_ms",
        "stop_publishes_timer_stopped_with_base_ms",
        "stop_when_idle_returns_false",

        ; --- Reset ---
        "reset_zeroes_base_ms_and_state",
        "reset_publishes_timer_reset_with_scope_all",
        "reset_works_from_idle",
        "reset_works_from_running",
        "reset_works_from_paused",

        ; --- Toggle ---
        "toggle_idle_calls_start",
        "toggle_running_calls_pause",
        "toggle_paused_calls_resume",

        ; --- Hydrate ---
        "hydrate_default_status_is_stopped",
        "hydrate_running_sets_active_not_paused",
        "hydrate_paused_sets_active_and_paused",
        "hydrate_unknown_status_falls_back_to_stopped",
        "hydrate_running_accumulates_after_clock_advance",
        "hydrate_paused_keeps_run_ms_constant_after_advance",
        "hydrate_clamps_negative_to_zero",
        "hydrate_with_non_number_uses_zero",
        "hydrate_does_not_publish_any_event",

        ; --- AddPenaltyMs (v0.1.3 - death penalty no timer real-time) ---
        "add_penalty_ms_returns_true_with_positive_value",
        "add_penalty_ms_returns_false_with_zero",
        "add_penalty_ms_returns_false_with_negative",
        "add_penalty_ms_returns_false_with_non_number",
        "add_penalty_ms_increases_run_ms_when_running",
        "add_penalty_ms_increases_run_ms_when_paused",
        "add_penalty_ms_increases_run_ms_when_idle",
        "add_penalty_ms_does_not_freeze_running_timer",
        "add_penalty_ms_does_not_publish_any_event",
        "add_penalty_ms_coerces_float_to_int",
        "add_penalty_ms_can_be_applied_multiple_times",
        "add_penalty_ms_zero_does_not_modify_state",
        "add_penalty_ms_persists_through_pause_resume_cycle"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    ; Captura todos os eventos do timer em um array. Retorna o array.
    ; NOTA: handlers hardcoded em vez de loop pra evitar closure-in-loop
    ; bug (AHK v2 captura variavel local por referencia; loop com closure
    ; capturando `localName := nm` faz todos os 5 handlers verem o ultimo
    ; valor de `localName` = "TimerReset").
    _CaptureAllTimerEvents()
    {
        out := []
        this.bus.Subscribe(Events.TimerStarted,
            (data) => out.Push(Map("event", "TimerStarted", "data", data)))
        this.bus.Subscribe(Events.TimerPaused,
            (data) => out.Push(Map("event", "TimerPaused", "data", data)))
        this.bus.Subscribe(Events.TimerResumed,
            (data) => out.Push(Map("event", "TimerResumed", "data", data)))
        this.bus.Subscribe(Events.TimerStopped,
            (data) => out.Push(Map("event", "TimerStopped", "data", data)))
        this.bus.Subscribe(Events.TimerReset,
            (data) => out.Push(Map("event", "TimerReset", "data", data)))
        return out
    }

    ; ============================================================
    ; Construtor
    ; ============================================================

    constructor_throws_when_clock_missing_now_ms()
    {
        ; Objeto sem NowMs
        fakeClockNoMethod := { Now: () => "20260101000000" }
        Assert.Throws(TypeError, () => TimerService(fakeClockNoMethod, this.bus))
    }

    constructor_throws_when_clock_is_string()
    {
        Assert.Throws(TypeError, () => TimerService("not a clock", this.bus))
    }

    constructor_throws_when_bus_not_event_bus()
    {
        clk := this.stubClock
        Assert.Throws(TypeError, () => TimerService(clk, "not a bus"))
    }

    constructor_accepts_valid_clock_and_bus()
    {
        ; Setup ja cria o svc. Verifica que esta operacional.
        Assert.False(this.svc.IsActive())
    }

    ; ============================================================
    ; Queries iniciais
    ; ============================================================

    is_active_false_initially()  => Assert.False(this.svc.IsActive())
    is_running_false_initially() => Assert.False(this.svc.IsRunning())
    is_paused_false_initially()  => Assert.False(this.svc.IsPaused())
    get_run_ms_zero_initially()  => Assert.Equal(0, this.svc.GetRunMs())

    ; ============================================================
    ; Start
    ; ============================================================

    start_from_idle_activates_and_returns_true()
    {
        Assert.True(this.svc.Start())
        Assert.True(this.svc.IsActive())
        Assert.True(this.svc.IsRunning())
        Assert.False(this.svc.IsPaused())
    }

    start_from_idle_publishes_timer_started_with_zero_run_ms()
    {
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Start()
        Assert.Equal(1, evtLog.Length)
        Assert.Equal("TimerStarted", evtLog[1]["event"])
        Assert.Equal(0, evtLog[1]["data"]["runMs"])
    }

    start_when_already_running_returns_false()
    {
        this.svc.Start()
        Assert.False(this.svc.Start())
    }

    start_when_already_running_does_not_publish()
    {
        this.svc.Start()
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Start()
        Assert.Equal(0, evtLog.Length)
    }

    start_when_paused_returns_false()
    {
        this.svc.Start()
        this.svc.Pause()
        Assert.False(this.svc.Start(), "Start em PAUSADO eh no-op (use Resume)")
    }

    ; ============================================================
    ; GetRunMs durante RUNNING
    ; ============================================================

    get_run_ms_returns_zero_immediately_after_start()
    {
        this.svc.Start()
        Assert.Equal(0, this.svc.GetRunMs())
    }

    get_run_ms_returns_clock_delta_while_running()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(2500)
        Assert.Equal(2500, this.svc.GetRunMs())
    }

    get_run_ms_increases_with_clock_advance()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(1000)
        Assert.Equal(1000, this.svc.GetRunMs())
        this.stubClock.AdvanceMs(500)
        Assert.Equal(1500, this.svc.GetRunMs())
    }

    ; ============================================================
    ; Pause
    ; ============================================================

    pause_from_running_returns_true()
    {
        this.svc.Start()
        Assert.True(this.svc.Pause())
    }

    pause_from_running_marks_as_paused()
    {
        this.svc.Start()
        this.svc.Pause()
        Assert.True(this.svc.IsActive())
        Assert.False(this.svc.IsRunning())
        Assert.True(this.svc.IsPaused())
    }

    pause_publishes_timer_paused_with_current_run_ms()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(3000)
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Pause()
        Assert.Equal(1, evtLog.Length)
        Assert.Equal("TimerPaused", evtLog[1]["event"])
        Assert.Equal(3000, evtLog[1]["data"]["runMs"])
    }

    pause_when_idle_returns_false()
    {
        Assert.False(this.svc.Pause())
    }

    pause_when_already_paused_returns_false()
    {
        this.svc.Start()
        this.svc.Pause()
        Assert.False(this.svc.Pause())
    }

    ; ============================================================
    ; GetRunMs durante PAUSED
    ; ============================================================

    get_run_ms_constant_while_paused_after_advance()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(2000)
        this.svc.Pause()
        Assert.Equal(2000, this.svc.GetRunMs())

        ; Clock avanca mas paused: run ms nao muda
        this.stubClock.AdvanceMs(10000)
        Assert.Equal(2000, this.svc.GetRunMs())
    }

    pause_commits_delta_to_base_ms()
    {
        ; Apos pause, base_ms = delta acumulado. Mesmo se outro
        ; clock advance acontecer, GetRunMs continua igual.
        this.svc.Start()
        this.stubClock.AdvanceMs(5000)
        this.svc.Pause()
        Assert.Equal(5000, this.svc.GetRunMs())
    }

    ; ============================================================
    ; Resume
    ; ============================================================

    resume_from_paused_returns_true()
    {
        this.svc.Start()
        this.svc.Pause()
        Assert.True(this.svc.Resume())
    }

    resume_marks_as_running_again()
    {
        this.svc.Start()
        this.svc.Pause()
        this.svc.Resume()
        Assert.True(this.svc.IsActive())
        Assert.True(this.svc.IsRunning())
        Assert.False(this.svc.IsPaused())
    }

    resume_publishes_timer_resumed_with_run_ms()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(2000)
        this.svc.Pause()
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Resume()
        Assert.Equal(1, evtLog.Length)
        Assert.Equal("TimerResumed", evtLog[1]["event"])
        Assert.Equal(2000, evtLog[1]["data"]["runMs"])
    }

    resume_when_idle_returns_false()
    {
        Assert.False(this.svc.Resume())
    }

    resume_when_running_returns_false()
    {
        this.svc.Start()
        Assert.False(this.svc.Resume(), "Resume em RUNNING eh no-op (use Pause)")
    }

    resume_continues_accumulating_after_pause()
    {
        ; Start em t=1000, advance 2s, Pause (base=2000),
        ; advance 5s (sem efeito), Resume em t=8000,
        ; advance 1s => GetRunMs = 2000 + 1000 = 3000
        this.svc.Start()
        this.stubClock.AdvanceMs(2000)
        this.svc.Pause()
        this.stubClock.AdvanceMs(5000)
        this.svc.Resume()
        this.stubClock.AdvanceMs(1000)
        Assert.Equal(3000, this.svc.GetRunMs())
    }

    ; ============================================================
    ; Stop
    ; ============================================================

    stop_from_running_deactivates()
    {
        this.svc.Start()
        this.svc.Stop()
        Assert.False(this.svc.IsActive())
        Assert.False(this.svc.IsRunning())
        Assert.False(this.svc.IsPaused())
    }

    stop_from_paused_deactivates()
    {
        this.svc.Start()
        this.svc.Pause()
        this.svc.Stop()
        Assert.False(this.svc.IsActive())
    }

    stop_preserves_base_ms_in_get_run_ms()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(7000)
        this.svc.Stop()
        Assert.Equal(7000, this.svc.GetRunMs())
        ; Clock advance apos stop: nao muda
        this.stubClock.AdvanceMs(10000)
        Assert.Equal(7000, this.svc.GetRunMs())
    }

    stop_publishes_timer_stopped_with_base_ms()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(4000)
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Stop()
        Assert.Equal(1, evtLog.Length)
        Assert.Equal("TimerStopped", evtLog[1]["event"])
        Assert.Equal(4000, evtLog[1]["data"]["runMs"])
    }

    stop_when_idle_returns_false()
    {
        Assert.False(this.svc.Stop())
    }

    ; ============================================================
    ; Reset
    ; ============================================================

    reset_zeroes_base_ms_and_state()
    {
        this.svc.Start()
        this.stubClock.AdvanceMs(5000)
        this.svc.Reset()
        Assert.False(this.svc.IsActive())
        Assert.Equal(0, this.svc.GetRunMs())
    }

    reset_publishes_timer_reset_with_scope_all()
    {
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Reset()
        Assert.Equal(1, evtLog.Length)
        Assert.Equal("TimerReset", evtLog[1]["event"])
        Assert.Equal("all", evtLog[1]["data"]["scope"])
    }

    reset_works_from_idle()
    {
        ; Reset em IDLE sempre publica (sem condicao)
        Assert.True(this.svc.Reset())
    }

    reset_works_from_running()
    {
        this.svc.Start()
        Assert.True(this.svc.Reset())
        Assert.False(this.svc.IsActive())
    }

    reset_works_from_paused()
    {
        this.svc.Start()
        this.svc.Pause()
        Assert.True(this.svc.Reset())
        Assert.False(this.svc.IsActive())
    }

    ; ============================================================
    ; Toggle
    ; ============================================================

    toggle_idle_calls_start()
    {
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Toggle()
        Assert.Equal("TimerStarted", evtLog[1]["event"])
        Assert.True(this.svc.IsRunning())
    }

    toggle_running_calls_pause()
    {
        this.svc.Start()
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Toggle()
        Assert.Equal("TimerPaused", evtLog[1]["event"])
        Assert.True(this.svc.IsPaused())
    }

    toggle_paused_calls_resume()
    {
        this.svc.Start()
        this.svc.Pause()
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Toggle()
        Assert.Equal("TimerResumed", evtLog[1]["event"])
        Assert.True(this.svc.IsRunning())
    }

    ; ============================================================
    ; Hydrate (silencioso)
    ; ============================================================

    hydrate_default_status_is_stopped()
    {
        this.svc.Hydrate(5000)   ; default = "stopped"
        Assert.False(this.svc.IsActive())
        Assert.Equal(5000, this.svc.GetRunMs())
    }

    hydrate_running_sets_active_not_paused()
    {
        this.svc.Hydrate(5000, "running")
        Assert.True(this.svc.IsActive())
        Assert.True(this.svc.IsRunning())
        Assert.False(this.svc.IsPaused())
    }

    hydrate_paused_sets_active_and_paused()
    {
        this.svc.Hydrate(5000, "paused")
        Assert.True(this.svc.IsActive())
        Assert.False(this.svc.IsRunning())
        Assert.True(this.svc.IsPaused())
    }

    hydrate_unknown_status_falls_back_to_stopped()
    {
        this.svc.Hydrate(5000, "nonsense_status")
        Assert.False(this.svc.IsActive())
        Assert.Equal(5000, this.svc.GetRunMs())
    }

    hydrate_running_accumulates_after_clock_advance()
    {
        ; Apos hydrate "running", clock advance entra no GetRunMs.
        this.svc.Hydrate(5000, "running")
        Assert.Equal(5000, this.svc.GetRunMs())
        this.stubClock.AdvanceMs(2000)
        Assert.Equal(7000, this.svc.GetRunMs(), "5000 base + 2000 delta")
    }

    hydrate_paused_keeps_run_ms_constant_after_advance()
    {
        this.svc.Hydrate(5000, "paused")
        Assert.Equal(5000, this.svc.GetRunMs())
        this.stubClock.AdvanceMs(10000)
        Assert.Equal(5000, this.svc.GetRunMs(), "paused = base constante")
    }

    hydrate_clamps_negative_to_zero()
    {
        this.svc.Hydrate(-1000)
        Assert.Equal(0, this.svc.GetRunMs())
    }

    hydrate_with_non_number_uses_zero()
    {
        this.svc.Hydrate("not a number")
        Assert.Equal(0, this.svc.GetRunMs())
    }

    hydrate_does_not_publish_any_event()
    {
        evtLog := this._CaptureAllTimerEvents()
        this.svc.Hydrate(5000, "running")
        this.svc.Hydrate(7000, "paused")
        this.svc.Hydrate(3000, "stopped")
        Assert.Equal(0, evtLog.Length, "Hydrate eh silencioso por design")
    }

    ; ============================================================
    ; AddPenaltyMs (v0.1.3 — death penalty no timer real-time)
    ; ============================================================
    ;
    ; Contrato:
    ;   - Argumento positivo > 0 → adiciona ao _baseMs, retorna true
    ;   - Zero / negativo / non-number → no-op, retorna false
    ;   - Em RUNNING: commita delta atual antes de adicionar (preserva
    ;     o tempo decorrido até o momento da penalty); timer continua
    ;     contando após a adição.
    ;   - Em PAUSED ou IDLE: adição direta ao _baseMs.
    ;   - NUNCA publica eventos do bus (decisão de design: widgets
    ;     dão refresh no próximo Tick e mostram o novo runMs sem
    ;     precisar de evento dedicado).

    add_penalty_ms_returns_true_with_positive_value()
    {
        this.svc.Start()
        Assert.True(this.svc.AddPenaltyMs(150000))
    }

    add_penalty_ms_returns_false_with_zero()
    {
        this.svc.Start()
        Assert.False(this.svc.AddPenaltyMs(0),
            "Zero eh no-op (sem penalty efetiva)")
    }

    add_penalty_ms_returns_false_with_negative()
    {
        this.svc.Start()
        Assert.False(this.svc.AddPenaltyMs(-100))
        Assert.False(this.svc.AddPenaltyMs(-1))
    }

    add_penalty_ms_returns_false_with_non_number()
    {
        this.svc.Start()
        Assert.False(this.svc.AddPenaltyMs("abc"))
        Assert.False(this.svc.AddPenaltyMs(""))
        ; AHK v2 trata Map() como nao-numero
        Assert.False(this.svc.AddPenaltyMs(Map()))
    }

    add_penalty_ms_increases_run_ms_when_running()
    {
        ; Start em t=1000, advance 2s (runMs=2000), penalty 500ms
        ; → runMs deve virar 2500 imediatamente.
        this.svc.Start()
        this.stubClock.AdvanceMs(2000)
        Assert.Equal(2000, this.svc.GetRunMs())

        this.svc.AddPenaltyMs(500)
        Assert.Equal(2500, this.svc.GetRunMs(),
            "Penalty entra direto no runMs em RUNNING")
    }

    add_penalty_ms_increases_run_ms_when_paused()
    {
        ; Start, advance, Pause em runMs=3000, penalty 500
        ; → runMs vira 3500 e fica constante (paused).
        this.svc.Start()
        this.stubClock.AdvanceMs(3000)
        this.svc.Pause()
        Assert.Equal(3000, this.svc.GetRunMs())

        this.svc.AddPenaltyMs(500)
        Assert.Equal(3500, this.svc.GetRunMs())

        ; Clock advance em PAUSED: runMs nao deve mudar
        this.stubClock.AdvanceMs(10000)
        Assert.Equal(3500, this.svc.GetRunMs(),
            "Em PAUSED, runMs permanece com penalty incluida")
    }

    add_penalty_ms_increases_run_ms_when_idle()
    {
        ; Em IDLE, GetRunMs retorna _baseMs. AddPenaltyMs incrementa
        ; _baseMs incondicionalmente — caller (app handler) eh quem
        ; filtra com IsActive() check. O metodo em si nao rejeita.
        Assert.Equal(0, this.svc.GetRunMs())
        Assert.True(this.svc.AddPenaltyMs(500))
        Assert.Equal(500, this.svc.GetRunMs(),
            "Em IDLE, penalty adiciona ao _baseMs (caller filtra)")
    }

    add_penalty_ms_does_not_freeze_running_timer()
    {
        ; Importante: penalty nao para o timer. Clock continua
        ; acumulando normalmente apos AddPenaltyMs.
        ;   Start em t=1000
        ;   advance 2s → runMs=2000
        ;   penalty 500 → runMs=2500
        ;   advance 1s → runMs=3500 (timer ainda rodando)
        this.svc.Start()
        this.stubClock.AdvanceMs(2000)
        this.svc.AddPenaltyMs(500)
        Assert.Equal(2500, this.svc.GetRunMs())

        this.stubClock.AdvanceMs(1000)
        Assert.Equal(3500, this.svc.GetRunMs(),
            "Timer continua rodando apos penalty")

        Assert.True(this.svc.IsRunning(),
            "Estado RUNNING preservado apos penalty")
    }

    add_penalty_ms_does_not_publish_any_event()
    {
        ; Penalty muda runMs mas eh silenciosa — widgets dao refresh
        ; no proximo Tick. Garante que nenhum dos 5 eventos do timer
        ; eh publicado (Start/Pause/Resume/Stop/Reset).
        this.svc.Start()
        this.stubClock.AdvanceMs(1000)

        evtLog := this._CaptureAllTimerEvents()
        this.svc.AddPenaltyMs(500)
        this.svc.Pause()
        this.svc.AddPenaltyMs(500)
        this.svc.Resume()
        this.svc.AddPenaltyMs(500)

        ; Apenas Paused + Resumed devem ter aparecido — nenhum dos 3
        ; AddPenaltyMs publicou nada.
        Assert.Equal(2, evtLog.Length,
            "AddPenaltyMs nao publica eventos (apenas Pause/Resume devem aparecer)")
        Assert.Equal("TimerPaused",  evtLog[1]["event"])
        Assert.Equal("TimerResumed", evtLog[2]["event"])
    }

    add_penalty_ms_coerces_float_to_int()
    {
        ; Penalty floats devem ser truncados a int (consistente com
        ; o construtor de Duration e demais helpers do projeto).
        this.svc.Start()
        this.stubClock.AdvanceMs(1000)
        this.svc.AddPenaltyMs(500.7)
        Assert.Equal(1500, this.svc.GetRunMs(),
            "500.7 truncado pra 500")
    }

    add_penalty_ms_can_be_applied_multiple_times()
    {
        ; Cada chamada acumula. Cenario realista: jogador morre 3x na
        ; mesma run.
        this.svc.Start()
        this.stubClock.AdvanceMs(60000)   ; 1min na run

        this.svc.AddPenaltyMs(150000)     ; 1a morte
        this.svc.AddPenaltyMs(150000)     ; 2a morte
        this.svc.AddPenaltyMs(150000)     ; 3a morte

        ; 60s clock + 3 * 150s penalty = 60 + 450 = 510s = 510000ms
        Assert.Equal(510000, this.svc.GetRunMs())
    }

    add_penalty_ms_zero_does_not_modify_state()
    {
        ; Confirma que no-ops (return false) nao mexem em nada.
        this.svc.Start()
        this.stubClock.AdvanceMs(2000)
        before := this.svc.GetRunMs()

        this.svc.AddPenaltyMs(0)
        this.svc.AddPenaltyMs(-100)
        this.svc.AddPenaltyMs("abc")

        Assert.Equal(before, this.svc.GetRunMs(),
            "Nenhum dos no-ops alterou o estado")
    }

    add_penalty_ms_persists_through_pause_resume_cycle()
    {
        ; Cenario: morte durante RUNNING (penalty aplicada),
        ; jogador pausa pra ir ao banheiro, despausa e continua.
        ; A penalty deve estar costurada no _baseMs.
        ;   t=1000: Start
        ;   t=3000: advance 2s, runMs=2000
        ;   penalty 500: runMs=2500
        ;   Pause: commita, _baseMs=2500
        ;   advance 5s (sem efeito — paused)
        ;   Resume
        ;   advance 1s → runMs=3500
        this.svc.Start()
        this.stubClock.AdvanceMs(2000)
        this.svc.AddPenaltyMs(500)
        this.svc.Pause()
        Assert.Equal(2500, this.svc.GetRunMs())

        this.stubClock.AdvanceMs(5000)
        this.svc.Resume()
        this.stubClock.AdvanceMs(1000)
        Assert.Equal(3500, this.svc.GetRunMs(),
            "Penalty sobrevive ao Pause/Resume")
    }
}

TestRegistry.Register(TimerServiceTests)
