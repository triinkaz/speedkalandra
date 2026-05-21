; ============================================================
; OverlayModeService - state machine for which layout is active
; ============================================================
;
; Three modes (mutually exclusive):
;
;   COMPACT - reduced layout with essential info. Default.
;   MICRO   - minimal bar. Toggle via Cmd.ToggleMicroLockRequested.
;   STEVE   - SteveTheHappyWhale layout. Toggle via
;             Cmd.ToggleSteveLockRequested.
;
; PHILOSOPHY:
;   - Service does NOT touch the GUI. It only changes state and
;     publishes Evt.OverlayModeChanged.
;   - Pure state machine: testable without a GUI.
;   - Toggle methods are mutually exclusive: turning one lock on
;     turns the other off, so the user can never end up in an
;     inconsistent "both locked" state from the UI.
;
; SUBSCRIPTIONS:
;   Cmd.ToggleMicroLockRequested -> ToggleMicroLock()
;   Cmd.ToggleSteveLockRequested -> ToggleSteveLock()
;   Cmd.SetOverlayModeRequested  -> SetMode(mode)
;
; PUBLISHES:
;   Evt.OverlayModeChanged { mode, prevMode, locked, steveLocked }
;
; CONSTRUCTION:
;   svc := OverlayModeService(bus, cfg)
;   svc.Hydrate()    ; reads window.{microLocked,steveLocked} from cfg

class OverlayModes
{
    static COMPACT := "compact"
    static MICRO   := "micro"
    static STEVE   := "steve"   ; SteveTheHappyWhale layout
}


class OverlayModeService
{
    _bus      := ""
    _settings := ""

    _mode         := ""
    _microLocked  := false
    _steveLocked  := false

    _handlerToggleMicroLock   := ""
    _handlerToggleSteveLock   := ""
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

        this._handlerToggleMicroLock   := (data) => this.ToggleMicroLock()
        this._handlerToggleSteveLock   := (data) => this.ToggleSteveLock()
        this._handlerSetOverlayMode    := (data) => this._OnSetModeRequested(data)

        bus.Subscribe(Commands.ToggleMicroLockRequested, this._handlerToggleMicroLock)
        bus.Subscribe(Commands.ToggleSteveLockRequested, this._handlerToggleSteveLock)
        bus.Subscribe(Commands.SetOverlayModeRequested,  this._handlerSetOverlayMode)
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
    ; steveLocked takes precedence over microLocked if both are true
    ; in the INI (manual edit accident). ToggleX guarantees only one
    ; is active at a time, but Hydrate is defensive.
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
            ; Enable micro: disable steve if it was on (modes are mutually exclusive).
            this._steveLocked := false
            this._microLocked := true
            this._mode        := OverlayModes.MICRO
        }
        this._SyncWindowFlags()
        this._PublishChange(prev)
        return true
    }

    ; ============================================================
    ; ToggleSteveLock - alternates COMPACT <-> STEVE LOCKED
    ;
    ; Modes micro and steve are MUTUALLY EXCLUSIVE: enabling steve
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
    ; Publishing
    ; ============================================================
    _PublishChange(prevMode)
    {
        this._bus.Publish(Events.OverlayModeChanged, Map(
            "mode",        this._mode,
            "prevMode",    prevMode,
            "locked",      this._microLocked,
            "steveLocked", this._steveLocked
        ))
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
}
