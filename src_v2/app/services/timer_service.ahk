; ============================================================
; TimerService - mecanica de timer single-scope (Onda 6)
; ============================================================
;
; VERSAO POS-DEMOLICAO: single-scope (runMs apenas). Sem act, sem
; segment, sem carry. Mecanica pura: start/pause/resume/stop/reset.
;
; ESTADOS:
;   PARADO    !_active                (boot, apos Stop, apos Reset)
;   RODANDO    _active && !_paused
;   PAUSADO    _active && _paused
;
; CALCULO:
;   Em RODANDO: runMs = _baseMs + (clock.NowMs() - _startTick)
;   Em PAUSADO: runMs = _baseMs    (trecho atual ja foi commitado)
;
; EVENTOS PUBLICADOS (via bus):
;   Evt.TimerStarted  -> {runMs}     (Start em PARADO)
;   Evt.TimerPaused   -> {runMs}     (Pause em RODANDO)
;   Evt.TimerResumed  -> {runMs}     (Resume de PAUSADO)
;   Evt.TimerStopped  -> {runMs}     (Stop em qualquer estado != PARADO)
;   Evt.TimerReset    -> {scope: "all"}  (Reset)
;
; CONSTRUCAO:
;   timer := TimerService(clock, bus)
;
; HYDRATE (boot com state persistido):
;   timer.Hydrate(runBaseMs)                  ; PARADO (default)
;   timer.Hydrate(runBaseMs, "running")       ; RODANDO (auto-resume mid-run)
;   timer.Hydrate(runBaseMs, "paused")        ; PAUSADO (usuario despausa)
;
;   Em "running": _active=true, _paused=false, _startTick=NowMs. Como
;   _baseMs ja tem o tempo acumulado, GetRunMs continua de onde parou
;   + delta novo. NAO publica TimerStarted (eh restauracao, nao novo
;   inicio — subscribers nao devem reagir como se fosse uma run nova).


class TimerService
{
    _clock := ""
    _bus   := ""

    _active    := false
    _paused    := false
    _startTick := 0
    _baseMs    := 0

    __New(clock, bus)
    {
        if !IsObject(clock) || !clock.HasMethod("NowMs")
            throw TypeError("TimerService: 'clock' deve implementar NowMs()")
        if !(bus is EventBus)
            throw TypeError("TimerService: 'bus' deve ser EventBus")
        this._clock := clock
        this._bus   := bus
    }

    ; ============================================================
    ; Queries
    ; ============================================================
    IsActive()  => this._active
    IsRunning() => this._active && !this._paused
    IsPaused()  => this._active && this._paused

    GetRunMs()
    {
        if (!this._active)
            return this._baseMs
        if this._paused
            return this._baseMs
        return this._baseMs + Max(0, this._clock.NowMs() - this._startTick)
    }

    ; ============================================================
    ; Hydrate - restaura state vindo do disco
    ;
    ; statusHint controla em que estado o timer fica apos hydrate:
    ;   "stopped" (default): timer PARADO. _baseMs preserved mas GetRunMs
    ;     retorna constante. Usuario precisa Start/Toggle pra retomar.
    ;   "running": timer RODANDO. GetRunMs continua de _baseMs + delta.
    ;     Usado em crash recovery quando state.IsRunning() no disco.
    ;   "paused":  timer PAUSADO. GetRunMs retorna _baseMs. Usuario
    ;     dá Toggle pra Resume.
    ;
    ; Hidratacao eh SILENCIOSA (nao publica TimerStarted/Resumed/Paused).
    ; Eh restauracao, nao transicao real — outros services devem consultar
    ; IsRunning/IsPaused diretamente pra saber estado pos-boot.
    ; ============================================================
    Hydrate(runBaseMs, statusHint := "stopped")
    {
        if !IsNumber(runBaseMs)
            runBaseMs := 0
        this._baseMs := Integer(runBaseMs)
        if (this._baseMs < 0)
            this._baseMs := 0

        hint := StrLower(String(statusHint))
        if (hint = "running")
        {
            this._active    := true
            this._paused    := false
            this._startTick := this._clock.NowMs()
        }
        else if (hint = "paused")
        {
            this._active    := true
            this._paused    := true
            this._startTick := 0
        }
        else
        {
            ; stopped (default)
            this._active    := false
            this._paused    := false
            this._startTick := 0
        }
    }

    ; ============================================================
    ; Start - inicia a partir de PARADO
    ;
    ; Em RODANDO/PAUSADO: no-op (use Resume pra retomar pause).
    ; ============================================================
    Start()
    {
        if this._active
            return false
        this._active    := true
        this._paused    := false
        this._startTick := this._clock.NowMs()
        this._bus.Publish(Events.TimerStarted, Map("runMs", this.GetRunMs()))
        return true
    }

    ; ============================================================
    ; Pause - commita trecho atual em _baseMs
    ; ============================================================
    Pause()
    {
        if !this._active
            return false
        if this._paused
            return false
        this._CommitDelta()
        this._paused := true
        this._bus.Publish(Events.TimerPaused, Map("runMs", this.GetRunMs()))
        return true
    }

    ; ============================================================
    ; Resume - sai de PAUSADO
    ; ============================================================
    Resume()
    {
        if !this._active
            return false
        if !this._paused
            return false
        this._paused    := false
        this._startTick := this._clock.NowMs()
        this._bus.Publish(Events.TimerResumed, Map("runMs", this.GetRunMs()))
        return true
    }

    ; ============================================================
    ; Stop - encerra rodada (preserva _baseMs)
    ; ============================================================
    Stop()
    {
        if !this._active
            return false
        if !this._paused
            this._CommitDelta()
        this._active := false
        this._paused := false
        this._bus.Publish(Events.TimerStopped, Map("runMs", this._baseMs))
        return true
    }

    ; ============================================================
    ; Reset - zera estado completo
    ; ============================================================
    Reset()
    {
        this._active    := false
        this._paused    := false
        this._startTick := 0
        this._baseMs    := 0
        this._bus.Publish(Events.TimerReset, Map("scope", "all"))
        return true
    }

    ; ============================================================
    ; Toggle - StartPause hotkey-friendly
    ;   PARADO -> Start
    ;   RODANDO -> Pause
    ;   PAUSADO -> Resume
    ; ============================================================
    Toggle()
    {
        if !this._active
            return this.Start()
        if this._paused
            return this.Resume()
        return this.Pause()
    }

    ; ============================================================
    ; _CommitDelta - converte (NowMs - startTick) em baseMs
    ; ============================================================
    _CommitDelta()
    {
        if (this._startTick = 0)
            return
        delta := Max(0, this._clock.NowMs() - this._startTick)
        this._baseMs    += delta
        this._startTick := this._clock.NowMs()
    }
}
