; ============================================================
; HotkeyService - registra hotkeys globais (Onda 6)
; ============================================================
;
; VERSAO POS-DEMOLICAO: simplificado pra 8 actions.
;
; ACTIONS SUPORTADAS:
;   StartPause       -> Cmd.TimerToggleRequested
;   NewRun           -> Cmd.NewRunRequested
;   ResetRun         -> Cmd.ResetRunRequested
;   FinalizeRun      -> Cmd.FinalizeRunRequested
;   Settings         -> Cmd.OpenSettingsRequested
;   ToggleOverlay    -> Cmd.ToggleOverlayRequested
;   ToggleMicroLock  -> Cmd.ToggleMicroLockRequested
;   PlotRunStats     -> Cmd.OpenRunStatsPlotRequested
;
; LIFECYCLE:
;   service := HotkeyService(bus, headless := false)
;   service.Hydrate(appSettings.hotkeys)
;   service.Start()
;   service.Stop()
;
; CONSTRUCAO:
;   - bus       : EventBus
;   - headless  : bool, default false. Em testes passa true.

class HotkeyService
{
    static ActionToCommand := Map(
        "StartPause",      Commands.TimerToggleRequested,
        "NewRun",          Commands.NewRunRequested,
        "ResetRun",        Commands.ResetRunRequested,
        "FinalizeRun",     Commands.FinalizeRunRequested,
        "Settings",        Commands.OpenSettingsRequested,
        "ToggleOverlay",   Commands.ToggleOverlayRequested,
        "ToggleMicroLock", Commands.ToggleMicroLockRequested,
        "ToggleSteveLock", Commands.ToggleSteveLockRequested,
        "PlotRunStats",    Commands.OpenRunStatsPlotRequested
    )

    ; Actions que ABREM DIALOG (mudam foco da janela ativa). v17.14.
    ;
    ; Hotkeys com modifier (^!s, ^!p) que mudam foco sao o cenario
    ; classico do bug "stuck modifier" do AHK: o user pressiona
    ; Ctrl+Alt+S, o dialog abre, foco muda, e quando o user solta
    ; o Ctrl/Alt, o jogo nao recebe o keyup porque ja perdeu o foco.
    ; Resultado: jogo acha que Ctrl/Alt continua pressionado.
    ;
    ; Mitigacao: imediatamente antes de publicar o command que abre o
    ; dialog, fazer Send "{Blind}{Ctrl up}{Alt up}{Shift up}". O
    ; {Blind} garante que o AHK nao reverte o up mesmo se o user
    ; ainda esta fisicamente segurando. O jogo recebe keyup limpo.
    ;
    ; NAO inclui hotkeys frequentes como StartPause (^3): essas nao
    ; mudam foco e fazer cleanup quebraria combos do jogo (ex: usuario
    ; que segura Ctrl entre Ctrl+3 e outro shortcut do PoE2).
    static FocusChangingActions := Map(
        "Settings",     true,
        "PlotRunStats", true
    )

    _bus      := ""
    _headless := false
    _hotkeys  := ""    ; Map<actionName, keyBind>
    _bound    := ""    ; Map<keyBind, BoundFunc>
    _running  := false

    __New(bus, headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("HotkeyService: 'bus' deve ser EventBus")
        this._bus      := bus
        this._headless := !!headless
        this._hotkeys  := Map()
        this._bound    := Map()
    }

    Hydrate(hotkeysMap)
    {
        if !(hotkeysMap is Map)
            throw TypeError("HotkeyService.Hydrate: 'hotkeysMap' deve ser Map")
        this._hotkeys := Map()
        for actionName, keyBind in hotkeysMap
            this._hotkeys[actionName] := String(keyBind)
    }

    Start()
    {
        if this._running
            return
        for actionName, keyBind in this._hotkeys
        {
            if !HotkeyService.ActionToCommand.Has(actionName)
                continue
            if (keyBind = "")
                continue
            commandName := HotkeyService.ActionToCommand[actionName]
            handler := this._MakePublisher(commandName, actionName)
            if !this._headless
            {
                try
                {
                    Hotkey(keyBind, handler, "On")
                    OutputDebug("[HotkeyService] Registrado: " actionName " -> " keyBind)
                }
                catch as err
                {
                    OutputDebug("[HotkeyService] FALHA ao registrar " actionName " -> " keyBind ": " err.Message)
                    continue
                }
            }
            this._bound[keyBind] := handler
        }
        this._running := true
    }

    Stop()
    {
        if !this._running
            return
        for keyBind, _ in this._bound
        {
            if !this._headless
                try Hotkey(keyBind, "Off")
        }
        this._bound := Map()
        this._running := false
    }

    IsRunning() => this._running

    GetBoundKeys()
    {
        out := Map()
        for k, _ in this._bound
            out[k] := true
        return out
    }

    Count() => this._bound.Count

    TriggerAction(actionName)
    {
        if !HotkeyService.ActionToCommand.Has(actionName)
            return false
        commandName := HotkeyService.ActionToCommand[actionName]
        this._bus.Publish(commandName, Map(
            "source", "hotkey",
            "action", actionName
        ))
        return true
    }

    _MakePublisher(commandName, actionName)
    {
        isFocusChanging := HotkeyService.FocusChangingActions.Has(actionName)
                           && HotkeyService.FocusChangingActions[actionName]
        return (*) => this._FireHotkey(commandName, actionName, isFocusChanging)
    }

    ; Disparador interno da hotkey (v17.14).
    ; Faz cleanup de modifier APENAS pra hotkeys que mudam foco
    ; (Settings, PlotRunStats). Detalhes em FocusChangingActions acima.
    _FireHotkey(commandName, actionName, isFocusChanging)
    {
        if isFocusChanging
        {
            ; Defensive Send: previne stuck modifier bug do AHK quando
            ; a hotkey muda foco da janela ativa. {Blind} evita o
            ; auto-revert do AHK mesmo se user esta fisicamente segurando.
            try Send "{Blind}{Ctrl up}{Alt up}{Shift up}{LWin up}{RWin up}"
        }
        this._bus.Publish(commandName, Map(
            "source", "hotkey",
            "action", actionName
        ))
    }
}
