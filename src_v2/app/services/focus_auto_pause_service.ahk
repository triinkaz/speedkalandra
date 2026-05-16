; ============================================================
; FocusAutoPauseService — pausa automatica por foco (event-driven)
; ============================================================
;
; Pausa o timer automaticamente quando PoE2 perde foco (alt-tab pra
; wiki, browser, discord, etc.) e retoma quando ganha foco de volta.
;
; ARQUITETURA (v0.1.1 — hybrid log+polling):
;   PRIMARY: Service consome Evt.WindowFocusChanged publicado pelo
;   LogMonitorService quando ele parsa "[WINDOW] Lost focus" /
;   "[WINDOW] Gained focus" no Client.txt do PoE2. Resposta instantanea
;   quando o log funciona.
;
;   BACKUP (v0.1.1 fix Bug Lechtansi): subscreve tambem a Evt.Tick e
;   polleia WinActive a cada ~300ms. PoE2 EA atual NAO emite "Gained
;   focus" no log de forma confiavel — sem o polling, o timer ficava
;   pausado indefinidamente quando o usuario voltava pro jogo.
;
;   Ambos os caminhos chamam o MESMO handler (_OnWindowFocusChanged)
;   que eh idempotente (Pause em paused = no-op, Resume em running =
;   no-op). Log fires fast, polling catches up dentro de ~300ms.
;
; SUBSTRING MATCH BUG (resolvido por ahk_exe):
;   Versao anterior usava polling com WinActive("Path of Exile 2"). Em
;   AHK v2 o TitleMatchMode default eh substring — janelas com "Path of
;   Exile 2" no titulo (browser com wiki, Discord #path-of-exile-2)
;   causavam falso positivo. Solucao agora: WinActive("ahk_exe XXX.exe")
;   eh match exato por nome do executavel.
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
;   service.Start()    ; subscribe ao Evt.WindowFocusChanged + Tick
;   service.Stop()     ; unsubscribe ambos
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
    _lastGameActive := true   ; v0.1.1: cache pra detectar transicoes via polling

    _handlerFocusChanged := ""
    _handlerTick         := ""   ; v0.1.1: backup polling via Tick

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
        this._handlerTick         := (data) => this._OnTick(data)
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
        ; Snapshot inicial do estado de foco pro polling detectar transicoes.
        this._lastGameActive := this._IsGameActive()
        this._bus.Subscribe(Events.WindowFocusChanged, this._handlerFocusChanged)
        this._bus.Subscribe(Events.Tick, this._handlerTick)
    }

    Stop()
    {
        if !this._enabled
            return
        this._enabled := false
        this._pausedByFocus := false
        try this._bus.Unsubscribe(Events.WindowFocusChanged, this._handlerFocusChanged)
        try this._bus.Unsubscribe(Events.Tick, this._handlerTick)
    }

    IsEnabled()         => this._enabled
    WasPausedByFocus()  => this._pausedByFocus

    ; ============================================================
    ; Handler de Evt.Tick (v0.1.1) — polling backup
    ;
    ; PoE2 EA nao emite "Gained focus" no Client.txt confiavelmente.
    ; Polleia WinActive a cada Tick (~300ms) e, quando detecta mudanca
    ; de estado, simula o evento de focus correspondente chamando o
    ; mesmo _OnWindowFocusChanged que o caminho log-based usa.
    ;
    ; Idempotencia garantida: timer.Pause() em paused = no-op, idem
    ; Resume() em running. Mesmo que o log dispare antes (caminho rapido),
    ; o tick subsequente que detectar a mesma transicao eh benigno.
    ; ============================================================
    _OnTick(data)
    {
        if !this._enabled
            return
        if !this._settings.autoPauseOnFocus
        {
            this._lastGameActive := this._IsGameActive()   ; mantem snapshot
            this._pausedByFocus := false
            return
        }

        isActive := this._IsGameActive()
        if (isActive = this._lastGameActive)
            return   ; sem mudanca, no-op
        this._lastGameActive := isActive

        ; Dispara o mesmo handler que o log-based usa.
        this._OnWindowFocusChanged(Map("state", isActive ? "gained" : "lost"))
    }

    ; ============================================================
    ; _IsGameActive (v0.1.1)
    ;
    ; Detecta se a janela do PoE2 esta atualmente focada. Match estrito
    ; por ahk_exe pra evitar falsos positivos do substring match
    ; (browsers/Discord com "Path of Exile 2" no titulo).
    ;
    ; Cobre nomes conhecidos do executavel:
    ;   PoE2 EA Steam:    PathOfExile2Steam.exe, PathOfExile_x64Steam.exe
    ;   PoE2 EA Standalone: PathOfExile2_x64.exe, PathOfExile2.exe
    ;   Compat PoE1 names: PathOfExile_x64.exe, PathOfExile.exe
    ;
    ; Se nenhum casar (versao futura com nome diferente), retorna false
    ; — polling nao age, mas log-based detection continua funcionando.
    ; ============================================================
    _IsGameActive()
    {
        return WinActive("ahk_exe PathOfExile2Steam.exe")
            || WinActive("ahk_exe PathOfExile2_x64.exe")
            || WinActive("ahk_exe PathOfExile2.exe")
            || WinActive("ahk_exe PathOfExile_x64Steam.exe")
            || WinActive("ahk_exe PathOfExile_x64.exe")
            || WinActive("ahk_exe PathOfExile.exe")
    }

    ; ============================================================
    ; Handler de Evt.WindowFocusChanged
    ;
    ; Payload esperado: Map("state", "lost" | "gained")
    ;
    ; Idempotente — handlers duplicados ou estados redundantes nao
    ; causam efeito colateral (Pause em timer ja pausado eh no-op).
    ;
    ; Chamado tanto pelo log-based path (subscribe a Evt.WindowFocusChanged)
    ; quanto pelo polling backup (_OnTick).
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
