; ============================================================
; AppTickEmitter — pulso periódico de Events.Tick
; ============================================================
;
; Responsabilidade: publicar Events.Tick a cada N milissegundos
; enquanto está rodando. Subscribers (widgets do overlay) reagem
; consultando services e atualizando seus controles.
;
; Por que existir?
;   Widgets precisam atualizar valores em tempo real (run timer,
;   step timer, percentages). Em vez de cada widget ter seu próprio
;   SetTimer, centralizamos em um pulso único — todos atualizam em
;   sincronia, sem multiplicar timers.
;
; Por que sem payload?
;   Decisão de arquitetura (Opção A da Fase 6): widgets consultam
;   services direto via refs do construtor. O Tick é apenas o sinal
;   "atualize agora". Mantém o emitter simples e desacoplado de
;   quais services existem.
;
; Lifecycle:
;   emitter := AppTickEmitter(bus, 300)    ; 300ms default
;   emitter.Start()                          ; começa a pulsar
;   emitter.Pulse()                          ; pulso manual (testes)
;   emitter.Stop()                           ; para o SetTimer
;
; Idempotência:
;   Start() em estado rodando = no-op
;   Stop() em estado parado = no-op
;   Múltiplos Start/Stop são seguros


class AppTickEmitter
{
    static DEFAULT_INTERVAL_MS := 300

    _bus            := ""
    _intervalMs     := 0
    _running        := false
    _timerCallback  := ""    ; BoundFunc, mantida pra evitar GC

    __New(bus, intervalMs := AppTickEmitter.DEFAULT_INTERVAL_MS)
    {
        if !(bus is EventBus)
            throw TypeError("AppTickEmitter: 'bus' deve ser EventBus")
        if (!IsInteger(intervalMs) || intervalMs <= 0)
            throw ValueError("AppTickEmitter: 'intervalMs' deve ser inteiro positivo")

        this._bus           := bus
        this._intervalMs    := intervalMs
        ; Bind uma vez. Necessário porque SetTimer precisa de callable
        ; estável (mesmo objeto) pra Stop conseguir cancelar.
        this._timerCallback := this._Pulse.Bind(this)
    }

    ; ============================================================
    ; Comandos
    ; ============================================================

    ; Inicia o pulso periódico. No-op se já rodando.
    Start()
    {
        if this._running
            return
        this._running := true
        SetTimer(this._timerCallback, this._intervalMs)
    }

    ; Para o pulso. No-op se já parado.
    Stop()
    {
        if !this._running
            return
        SetTimer(this._timerCallback, 0)
        this._running := false
    }

    ; Pulso manual (publica Events.Tick uma vez). Útil em testes
    ; para evitar dependência de SetTimer real, e em prod para
    ; forçar refresh imediato após mudança de estado relevante.
    Pulse() => this._Pulse()

    ; ============================================================
    ; Queries
    ; ============================================================

    IsRunning()     => this._running
    GetIntervalMs() => this._intervalMs

    ; ============================================================
    ; Helpers privados
    ; ============================================================

    _Pulse()
    {
        this._bus.Publish(Events.Tick)
    }
}
