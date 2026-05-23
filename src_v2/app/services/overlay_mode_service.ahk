; ============================================================
; OverlayModeService - state machine for which layout is active
; ============================================================
;
; Three modes (mutually exclusive):
;
;   COMPACT - reduced layout with essential info. Default.
;   MICRO   - minimal bar.
;   STEVE   - SteveTheHappyWhale layout.
;
; PHILOSOPHY:
;   - Service does NOT touch the GUI. It only changes state and
;     publishes Evt.OverlayModeChanged.
;   - Pure state machine: testable without a GUI.
;   - The cycle hotkey gives the user a single action that walks
;     STEVE -> COMPACT -> MICRO -> STEVE (in that fixed order).
;     Two earlier toggles (ToggleMicroLock, ToggleSteveLock) were
;     collapsed into this single CycleLayout — see Commands.ahk
;     for the rationale. Mode flags (_microLocked / _steveLocked)
;     are kept on the service and on cfg.window so the persisted
;     "what layout did the user pick last" survives reloads and
;     stays mutually exclusive.
;
; SUBSCRIPTIONS:
;   Cmd.CycleOverlayLayoutRequested -> CycleLayout()
;   Cmd.SetOverlayModeRequested     -> SetMode(mode)
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

    _handlerCycleLayout      := ""
    _handlerSetOverlayMode   := ""

    __New(bus, cfg)
    {
        if !(bus is EventBus)
            throw TypeError("OverlayModeService: 'bus' must be EventBus")
        if !(cfg is AppSettings)
            throw TypeError("OverlayModeService: 'cfg' must be AppSettings")

        this._bus      := bus
        this._settings := cfg
        this._mode     := OverlayModes.COMPACT

        this._handlerCycleLayout    := (data) => this._OnCycleRequested(data)
        this._handlerSetOverlayMode := (data) => this._OnSetModeRequested(data)

        bus.Subscribe(Commands.CycleOverlayLayoutRequested, this._handlerCycleLayout)
        bus.Subscribe(Commands.SetOverlayModeRequested,     this._handlerSetOverlayMode)
    }

    Dispose()
    {
        if (this._handlerCycleLayout != "")
        {
            this._bus.Unsubscribe(Commands.CycleOverlayLayoutRequested, this._handlerCycleLayout)
            this._handlerCycleLayout := ""
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
    ; in the INI (manual edit accident). CycleLayout/SetMode keep
    ; them mutually exclusive at runtime; Hydrate is defensive.
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
    ; CycleLayout - walks STEVE -> COMPACT -> MICRO -> STEVE
    ;
    ; Single user-facing layout action. The order is fixed and
    ; intentionally mirrors the visual hierarchy from densest
    ; (STEVE = full SteveTheHappyWhale layout) to lightest (MICRO =
    ; minimal bar), passing through COMPACT in the middle. The
    ; speedrunner usually picks a layout pre-run and stays in it;
    ; this hotkey is for the rare mid-session swap, where pressing
    ; it 1-2 times lands them on the target. SetMode is still
    ; available for code that needs to go directly to a specific
    ; target (tests, the Hydrate path).
    ;
    ; Always changes mode (one of the three values), so always
    ; returns true and always publishes Evt.OverlayModeChanged.
    ; ============================================================
    CycleLayout()
    {
        prev := this._mode
        switch this._mode
        {
            case OverlayModes.STEVE:
                this._steveLocked := false
                this._microLocked := false
                this._mode        := OverlayModes.COMPACT
            case OverlayModes.COMPACT:
                this._steveLocked := false
                this._microLocked := true
                this._mode        := OverlayModes.MICRO
            case OverlayModes.MICRO:
                this._microLocked := false
                this._steveLocked := true
                this._mode        := OverlayModes.STEVE
            default:
                ; Defensive: corrupted in-memory mode that's not one
                ; of the three known values. Fall back to COMPACT
                ; (the safe default) rather than throw — the user
                ; pressed a hotkey, surfacing an error here would
                ; be worse UX than a silent recovery to a known mode.
                this._microLocked := false
                this._steveLocked := false
                this._mode        := OverlayModes.COMPACT
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
    ; SetMode(target) - forces the mode (programmatic API)
    ;
    ; target = COMPACT: clear locks, _mode := COMPACT
    ; target = MICRO:   _microLocked := true, _mode := MICRO (clear steve)
    ; target = STEVE:   _steveLocked := true, _mode := STEVE (clear micro)
    ;
    ; Idempotent: calling with the current mode is a no-op (returns
    ; false). Not used by the cycle hotkey — that path goes through
    ; CycleLayout. SetMode is retained for code that needs to land
    ; on a specific mode (tests, Hydrate flows, future programmatic
    ; entry points).
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

    ; Cycle command handler. Always advances; the user feedback
    ; (TrayTip with the new mode label) is the same one
    ; _OnSetModeRequested used to surface, so the visible behaviour
    ; doesn't drift between the two entry points.
    _OnCycleRequested(data)
    {
        this.CycleLayout()
        try
        {
            label := this.IsSteve() ? "STEVE"
                   : this.IsMicro() ? "MICRO"
                   : "COMPACT"
            try TrayTip("SpeedKalandra", "Mode: " label, "Mute")
        }
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
