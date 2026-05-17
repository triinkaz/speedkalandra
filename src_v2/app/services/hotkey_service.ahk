; ============================================================
; HotkeyService - registers global hotkeys (Wave 6)
; ============================================================
;
; POST-DEMOLITION VERSION: simplified to 8 actions.
;
; SUPPORTED ACTIONS:
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
; CONSTRUCTION:
;   - bus       : EventBus
;   - headless  : bool, default false. Tests pass true.

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

    ; Actions that OPEN DIALOGS (change the active window focus). v17.14.
    ;
    ; Hotkeys with modifiers (^!s, ^!p) that change focus are the
    ; classic AHK "stuck modifier" bug scenario: the user presses
    ; Ctrl+Alt+S, the dialog opens, focus changes, and when the user
    ; releases Ctrl/Alt, the game does not receive the keyup because
    ; it has lost focus. Result: the game thinks Ctrl/Alt are still
    ; held down.
    ;
    ; Mitigation: right before publishing the command that opens the
    ; dialog, do Send "{Blind}{Ctrl up}{Alt up}{Shift up}". The
    ; {Blind} ensures AHK doesn't revert the up even if the user is
    ; still physically holding. The game gets a clean keyup.
    ;
    ; Does NOT include frequent hotkeys like StartPause (^3): those
    ; don't change focus and doing cleanup would break game combos
    ; (e.g. a user holding Ctrl between Ctrl+3 and another PoE2
    ; shortcut).
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
            throw TypeError("HotkeyService: 'bus' must be EventBus")
        this._bus      := bus
        this._headless := !!headless
        this._hotkeys  := Map()
        this._bound    := Map()
    }

    Hydrate(hotkeysMap)
    {
        if !(hotkeysMap is Map)
            throw TypeError("HotkeyService.Hydrate: 'hotkeysMap' must be Map")
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
                    OutputDebug("[HotkeyService] Registered: " actionName " -> " keyBind)
                }
                catch as err
                {
                    OutputDebug("[HotkeyService] FAILED to register " actionName " -> " keyBind ": " err.Message)
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

    ; Internal hotkey firing (v17.14).
    ; Does modifier cleanup ONLY for hotkeys that change focus
    ; (Settings, PlotRunStats). Details in FocusChangingActions above.
    _FireHotkey(commandName, actionName, isFocusChanging)
    {
        if isFocusChanging
        {
            ; Defensive Send: prevents AHK's stuck modifier bug when
            ; the hotkey changes the active window's focus. {Blind}
            ; avoids AHK's auto-revert even if the user is physically
            ; still holding.
            try Send "{Blind}{Ctrl up}{Alt up}{Shift up}{LWin up}{RWin up}"
        }
        this._bus.Publish(commandName, Map(
            "source", "hotkey",
            "action", actionName
        ))
    }
}
