; ============================================================
; FocusAutoPauseService — pausa automatica por foco (event-driven)
; ============================================================
;
; Pausa o timer automaticamente quando PoE2 perde foco (alt-tab pra
; wiki, browser, discord, etc.) e retoma quando ganha foco de volta.
;
; ARQUITETURA (v17.14 — event-driven):
;   Service consome Evt.WindowFocusChanged publicado pelo LogMonitorService
;   quando ele parsa "[WINDOW] Lost focus" / "[WINDOW] Gained focus" no
;   Client.txt do PoE2. Nada de polling de WinActive — o jogo loga
;   o evento de foco canonicamente, basta consumir.
;
;   Versao anterior fazia polling de 250ms com WinActive("Path of Exile 2").
;   Tinha bug: em AHK v2 o TitleMatchMode default eh substring, entao
;   janelas com "Path of Exile 2" no titulo (browser com wiki, Discord
;   com canal #path-of-exile-2, etc.) causavam falso positivo — Alt+Tab
;   pra elas nao pausava o timer.
;
; Comportamento:
;   - Se settings.autoPauseOnFocus = false: noop (handler nao age)
;   - Lost focus + timer RODANDO: pause + flag pausedByFocus
;   - Gained focus + pausedByFocus: resume + zera flag
;   - Se usuario fizer pause/resume manual entre os dois, a flag
;     pausedByFocus eh preservada/respeitada (nao re-resume o que
;     usuario manualmente pausou)
;
; Construcao:
;   service := FocusAutoPauseService(bus, timerService, appSettings)
;   service.Start()    ; subscribe ao Evt.WindowFocusChanged
;   service.Stop()     ; unsubscribe
;
; Para testes:
;   service := FocusAutoPauseService(bus, timer, settings)
;   service.Start()
;   bus.Publish(Events.WindowFocusChanged, Map("state", "lost"))
;   ; ... verifica timer.IsPaused() etc


class FocusAutoPauseService
{
    _bus      := ""
    _timer    := ""    ; TimerService
    _settings := ""    ; AppSettings

    _enabled        := false
    _pausedByFocus  := false

    _handlerFocusChanged := ""

    __New(bus, timerSvc, cfg)
    {
        if !(bus is EventBus)
            throw TypeError("FocusAutoPauseService: 'bus' deve ser EventBus")
        if !(timerSvc is TimerService)
            throw TypeError("FocusAutoPauseService: 'timerSvc' deve ser TimerService")
        if !(cfg is AppSettings)
            throw TypeError("FocusAutoPauseService: 'cfg' deve ser AppSettings")

        this._bus      := bus
        this._timer    := timerSvc
        this._settings := cfg

        this._handlerFocusChanged := (data) => this._OnWindowFocusChanged(data)
    }

    ; ============================================================
    ; Lifecycle
    ; ============================================================

    Start()
    {
        if this._enabled
            return
        this._enabled := true
        this._pausedByFocus := false
        this._bus.Subscribe(Events.WindowFocusChanged, this._handlerFocusChanged)
    }

    Stop()
    {
        if !this._enabled
            return
        this._enabled := false
        this._pausedByFocus := false
        try this._bus.Unsubscribe(Events.WindowFocusChanged, this._handlerFocusChanged)
    }

    IsEnabled()         => this._enabled
    WasPausedByFocus()  => this._pausedByFocus

    ; ============================================================
    ; Handler de Evt.WindowFocusChanged
    ;
    ; Payload esperado: Map("state", "lost" | "gained")
    ;
    ; Idempotente — handlers duplicados ou estados redundantes nao
    ; causam efeito colateral (Pause em timer ja pausado eh no-op).
    ; ============================================================
    _OnWindowFocusChanged(data)
    {
        if !this._enabled
            return
        if !this._settings.autoPauseOnFocus
        {
            ; Setting desabilitada — zera flag pra nao deixar pendurada
            ; caso usuario reabilite no meio.
            this._pausedByFocus := false
            return
        }
        if !IsObject(data)
            return

        state := data.Has("state") ? String(data["state"]) : ""

        if (state = "lost")
        {
            ; Pausa apenas se timer estava RODANDO (nao se ja parado/pausado).
            if this._timer.IsRunning()
            {
                this._timer.Pause()
                this._pausedByFocus := true
            }
            return
        }

        if (state = "gained")
        {
            ; Resume apenas se NOS pausamos (nao se usuario pausou
            ; manualmente durante o alt-tab).
            if (this._pausedByFocus && this._timer.IsPaused())
                this._timer.Resume()
            this._pausedByFocus := false
            return
        }

        ; State desconhecido — ignora silenciosamente.
    }
}
