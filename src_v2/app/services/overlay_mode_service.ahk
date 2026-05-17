; ============================================================
; OverlayModeService - simplified state machine (Wave 4)
; ============================================================
;
; POST-DEMOLITION VERSION: NORMAL and CUSTOM removed. Only two modes:
;
;   COMPACT - reduced layout with essential info. Default.
;   MICRO   - minimal bar, two sub-modes:
;             - LOCKED : always micro (toggle via Cmd.ToggleMicroLockRequested)
;             - AUTO   : active while at least one "panel key" is held
;                        (i/v/c/g/p/u/m = PoE panels). Disappears when
;                        all keys are released.
;
; PHILOSOPHY:
;   - Service does NOT touch the GUI. It only changes state and
;     publishes Evt.OverlayModeChanged.
;   - Pure state machine: testable without a GUI.
;   - MICRO auto-mode is a temporary entry over COMPACT — leaves and
;     returns to COMPACT when all panels close.
;
; SUBSCRIPTIONS:
;   Cmd.ToggleMicroLockRequested -> ToggleMicroLock()
;   Cmd.ToggleSteveLockRequested -> ToggleSteveLock()
;   Cmd.SetOverlayModeRequested  -> SetMode(mode)
;
;   v17.15 (Bug #31): subscribes to Cmd.PanelKeyPressed/Released
;   removed — PanelKeyService was disconnected in v17.2 and there is
;   no publisher anymore. The OnPanelKeyDown/Up + ClearHeldKeys
;   methods remain in the code (still callable externally if needed)
;   but the automatic bus-based flow is officially dead. _heldKeys
;   stays permanently empty.
;
; PUBLISHES:
;   Evt.OverlayModeChanged { mode, prevMode, locked, heldKeys }
;
; CONSTRUCTION:
;   svc := OverlayModeService(bus, cfg)
;   svc.Hydrate()    ; reads window.microLocked from cfg

class OverlayModes
{
    static COMPACT := "compact"
    static MICRO   := "micro"
    static STEVE   := "steve"   ; v17.14 — SteveTheHappyWhale
}


class OverlayModeService
{
    _bus      := ""
    _settings := ""

    _mode         := ""
    _microLocked  := false
    _steveLocked  := false    ; v17.14
    _heldKeys     := ""    ; Map<keyName, true>

    _handlerToggleMicroLock   := ""
    _handlerToggleSteveLock   := ""   ; v17.14
    _handlerSetOverlayMode    := ""

    __New(bus, cfg)
    {
        if !(bus is EventBus)
            throw TypeError("OverlayModeService: 'bus' must be EventBus")
        if !(cfg is AppSettings)
            throw TypeError("OverlayModeService: 'cfg' must be AppSettings")

        this._bus      := bus
        this._settings := cfg
        this._mode     := OverlayModes.COMPACT
        this._heldKeys := Map()

        this._handlerToggleMicroLock   := (data) => this.ToggleMicroLock()
        this._handlerToggleSteveLock   := (data) => this.ToggleSteveLock()
        this._handlerSetOverlayMode    := (data) => this._OnSetModeRequested(data)

        bus.Subscribe(Commands.ToggleMicroLockRequested, this._handlerToggleMicroLock)
        bus.Subscribe(Commands.ToggleSteveLockRequested, this._handlerToggleSteveLock)
        bus.Subscribe(Commands.SetOverlayModeRequested,  this._handlerSetOverlayMode)
        ; v17.15 (Bug #31): subscribes to Cmd.PanelKeyPressed/Released
        ; removed — PanelKeyService disconnected in v17.2.
    }

    Dispose()
    {
        if (this._handlerToggleMicroLock != "")
        {
            this._bus.Unsubscribe(Commands.ToggleMicroLockRequested, this._handlerToggleMicroLock)
            this._handlerToggleMicroLock := ""
        }
        if (this._handlerToggleSteveLock != "")
        {
            this._bus.Unsubscribe(Commands.ToggleSteveLockRequested, this._handlerToggleSteveLock)
            this._handlerToggleSteveLock := ""
        }
        if (this._handlerSetOverlayMode != "")
        {
            this._bus.Unsubscribe(Commands.SetOverlayModeRequested, this._handlerSetOverlayMode)
            this._handlerSetOverlayMode := ""
        }
    }

    ; ============================================================
    ; Hydrate - loads initial state from AppSettings
    ;
    ; v17.14: steveLocked takes precedence over microLocked if both
    ; are true in the INI (manual edit accident). ToggleX guarantees
    ; only one is active at a time, but Hydrate is defensive.
    ; ============================================================
    Hydrate()
    {
        cfg := this._settings
        if IsObject(cfg.window)
        {
            this._steveLocked := !!cfg.window.steveLocked
            this._microLocked := !this._steveLocked && !!cfg.window.microLocked
        }
        else
        {
            this._steveLocked := false
            this._microLocked := false
        }
        if this._steveLocked
            this._mode := OverlayModes.STEVE
        else if this._microLocked
            this._mode := OverlayModes.MICRO
        else
            this._mode := OverlayModes.COMPACT
    }

    ; ============================================================
    ; State queries
    ; ============================================================
    GetMode()         => this._mode
    IsCompact()       => (this._mode = OverlayModes.COMPACT)
    IsMicro()         => (this._mode = OverlayModes.MICRO)
    IsSteve()         => (this._mode = OverlayModes.STEVE)
    IsMicroLocked()   => this._microLocked
    IsSteveLocked()   => this._steveLocked
    IsMicroAuto()     => (this.IsMicro() && !this._microLocked)
    GetHeldKeyCount() => this._heldKeys.Count
    HasHeldKey(key)   => this._heldKeys.Has(OverlayModeService._NormKey(key))

    ; ============================================================
    ; ToggleMicroLock - alternates COMPACT <-> MICRO LOCKED
    ;
    ; If Steve is active, deactivates Steve first (modes are exclusive).
    ; ============================================================
    ToggleMicroLock()
    {
        prev := this._mode
        if this._microLocked
        {
            this._microLocked := false
            this._mode        := OverlayModes.COMPACT
        }
        else
        {
            ; v17.14: enable micro — disable steve if it was on
            this._steveLocked := false
            this._microLocked := true
            this._mode        := OverlayModes.MICRO
        }
        this._SyncWindowFlags()
        this._PublishChange(prev)
        return true
    }

    ; ============================================================
    ; ToggleSteveLock - alternates COMPACT <-> STEVE LOCKED (v17.14)
    ;
    ; Modes micro and steve are MUTUALLY EXCLUSIVE — enabling steve
    ; automatically disables micro. Same for ToggleMicroLock.
    ; ============================================================
    ToggleSteveLock()
    {
        prev := this._mode
        if this._steveLocked
        {
            this._steveLocked := false
            this._mode        := OverlayModes.COMPACT
        }
        else
        {
            this._microLocked := false
            this._steveLocked := true
            this._mode        := OverlayModes.STEVE
        }
        this._SyncWindowFlags()
        this._PublishChange(prev)
        return true
    }

    ; Syncs flags on AppSettings.window to persist across runs.
    _SyncWindowFlags()
    {
        if !IsObject(this._settings.window)
            return
        this._settings.window.microLocked := this._microLocked
        this._settings.window.steveLocked := this._steveLocked
    }

    ; ============================================================
    ; SetMode(target) - forces the mode
    ;
    ; target = COMPACT: clear locks, _mode := COMPACT
    ; target = MICRO:   _microLocked := true, _mode := MICRO (clear steve)
    ; target = STEVE:   _steveLocked := true, _mode := STEVE (clear micro)
    ;
    ; Idempotent: calling with the current mode is a no-op.
    ; ============================================================
    SetMode(target)
    {
        if (target != OverlayModes.COMPACT
           && target != OverlayModes.MICRO
           && target != OverlayModes.STEVE)
            throw ValueError("OverlayModeService.SetMode: invalid target: '" String(target) "'")

        prev            := this._mode
        prevMicroLocked := this._microLocked
        prevSteveLocked := this._steveLocked

        if (target = OverlayModes.MICRO)
        {
            this._steveLocked := false
            this._microLocked := true
            this._mode        := OverlayModes.MICRO
        }
        else if (target = OverlayModes.STEVE)
        {
            this._microLocked := false
            this._steveLocked := true
            this._mode        := OverlayModes.STEVE
        }
        else
        {
            this._microLocked := false
            this._steveLocked := false
            this._mode        := OverlayModes.COMPACT
        }

        this._SyncWindowFlags()

        if (prev = this._mode
           && prevMicroLocked = this._microLocked
           && prevSteveLocked = this._steveLocked)
            return false
        this._PublishChange(prev)
        return true
    }

    ; ============================================================
    ; OnPanelKeyDown - TOGGLE semantics
    ;
    ; Each DOWN toggles the panel state:
    ;   - key NOT in _heldKeys: panel "opened" -> add
    ;   - key ALREADY in _heldKeys: panel "closed" -> remove
    ;
    ; Recomputes mode: Count > 0 -> MICRO AUTO; Count = 0 -> back to COMPACT.
    ; LOCKED: panel keys do not change mode (but register the held set).
    ; Esc/focus loss clear everything via ClearHeldKeys.
    ; ============================================================
    OnPanelKeyDown(keyName)
    {
        key := OverlayModeService._NormKey(keyName)
        if (key = "")
            return false

        wasOpen := this._heldKeys.Has(key)
        if wasOpen
            this._heldKeys.Delete(key)
        else
            this._heldKeys[key] := true

        ; Any active lock (micro or steve, v17.14) ignores auto-mode
        if (this._microLocked || this._steveLocked)
            return false

        wantMicro := this._heldKeys.Count > 0
        prev      := this._mode

        if (wantMicro && !this.IsMicro())
        {
            this._mode := OverlayModes.MICRO
            this._PublishChange(prev)
            return true
        }
        else if (!wantMicro && this.IsMicroAuto())
        {
            this._mode := OverlayModes.COMPACT
            this._PublishChange(prev)
            return true
        }
        return false
    }

    OnPanelKeyUp(keyName)
    {
        ; TOGGLE semantics: UP is a no-op. Toggle happens on DOWN.
        return false
    }

    ClearHeldKeys()
    {
        if (this._heldKeys.Count = 0)
            return false
        this._heldKeys := Map()
        ; v17.14: auto-mode only returns to compact if there is no lock
        if (!this._microLocked && !this._steveLocked && this.IsMicroAuto())
        {
            prev := this._mode
            this._mode := OverlayModes.COMPACT
            this._PublishChange(prev)
        }
        return true
    }

    ; ============================================================
    ; Publishing
    ; ============================================================
    _PublishChange(prevMode)
    {
        this._bus.Publish(Events.OverlayModeChanged, Map(
            "mode",        this._mode,
            "prevMode",    prevMode,
            "locked",      this._microLocked,
            "steveLocked", this._steveLocked,
            "heldKeys",    this._heldKeysArray()
        ))
    }

    _heldKeysArray()
    {
        out := []
        for k, _ in this._heldKeys
            out.Push(k)
        return out
    }

    _OnPanelKeyData(data, isDown)
    {
        if !IsObject(data)
            return
        keyName := data.Has("key") ? data["key"] : ""
        if (keyName = "")
            return
        isDown ? this.OnPanelKeyDown(keyName) : this.OnPanelKeyUp(keyName)
    }

    _OnSetModeRequested(data)
    {
        if !IsObject(data)
            return
        mode := data.Has("mode") ? data["mode"] : ""
        if (mode = "")
            return
        try
        {
            changed := this.SetMode(mode)
            if changed
            {
                label := this.IsSteve() ? "STEVE"
                       : this.IsMicro() ? "MICRO"
                       : "COMPACT"
                try TrayTip("SpeedKalandra", "Mode: " label, "Mute")
            }
        }
    }

    static _NormKey(keyName)
    {
        if (keyName = "")
            return ""
        return StrLower(Trim(String(keyName)))
    }
}
