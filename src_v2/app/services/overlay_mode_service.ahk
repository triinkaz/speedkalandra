; ============================================================
; OverlayModeService - state machine simplificada (Onda 4)
; ============================================================
;
; VERSAO POS-DEMOLICAO: removidos NORMAL e CUSTOM. Apenas dois modos:
;
;   COMPACT - layout reduzido com info essencial. Default.
;   MICRO   - barra minima, dois sub-modos:
;             - LOCKED : sempre micro (toggle via Cmd.ToggleMicroLockRequested)
;             - AUTO   : ativo enquanto pelo menos uma "panel key" segurada
;                        (i/v/c/g/p/u/m = paineis de PoE). Some quando
;                        soltar todas as keys.
;
; FILOSOFIA:
;   - Service NAO toca GUI. So muda state e publica Evt.OverlayModeChanged.
;   - State machine pura: testavel sem GUI.
;   - Auto-modo do MICRO eh entrada temporaria sobre COMPACT — sai e
;     volta pra COMPACT quando todas panels fecharem.
;
; SUBSCRIPTIONS:
;   Cmd.ToggleMicroLockRequested -> ToggleMicroLock()
;   Cmd.ToggleSteveLockRequested -> ToggleSteveLock()
;   Cmd.SetOverlayModeRequested  -> SetMode(mode)
;
;   v17.15 (Bug #31): subscribes a Cmd.PanelKeyPressed/Released
;   removidos — PanelKeyService foi desconectado em v17.2 e ja nao
;   ha publisher. Os metodos OnPanelKeyDown/Up + ClearHeldKeys ficam
;   no codigo (ainda chamaveis externamente se necessario) mas o
;   fluxo automatico via bus eh oficialmente morto. _heldKeys fica
;   sempre vazio.
;
; PUBLISHES:
;   Evt.OverlayModeChanged { mode, prevMode, locked, heldKeys }
;
; CONSTRUCAO:
;   svc := OverlayModeService(bus, cfg)
;   svc.Hydrate()    ; le window.microLocked do cfg

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
            throw TypeError("OverlayModeService: 'bus' deve ser EventBus")
        if !(cfg is AppSettings)
            throw TypeError("OverlayModeService: 'cfg' deve ser AppSettings")

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
        ; v17.15 (Bug #31): subscribes a Cmd.PanelKeyPressed/Released
        ; removidos — PanelKeyService desconectado em v17.2.
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
    ; Hydrate - carrega state inicial do AppSettings
    ;
    ; v17.14: steveLocked tem precedencia sobre microLocked se ambos
    ; estiverem true no INI (acidente de edicao manual). ToggleX garante
    ; que so um fica ativo de cada vez, mas Hydrate eh defensivo.
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
    ; ToggleMicroLock - alterna COMPACT <-> MICRO LOCKED
    ;
    ; Se Steve estiver ativo, desativa Steve antes (modos exclusivos).
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
            ; v17.14: ativa micro — desativa steve se estava ativo
            this._steveLocked := false
            this._microLocked := true
            this._mode        := OverlayModes.MICRO
        }
        this._SyncWindowFlags()
        this._PublishChange(prev)
        return true
    }

    ; ============================================================
    ; ToggleSteveLock - alterna COMPACT <-> STEVE LOCKED (v17.14)
    ;
    ; Modos micro e steve sao MUTUAMENTE EXCLUSIVOS — ativar steve
    ; desativa micro automaticamente. Idem ToggleMicroLock.
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

    ; Sincroniza flags no AppSettings.window pra persistir entre runs.
    _SyncWindowFlags()
    {
        if !IsObject(this._settings.window)
            return
        this._settings.window.microLocked := this._microLocked
        this._settings.window.steveLocked := this._steveLocked
    }

    ; ============================================================
    ; SetMode(target) - forca o modo
    ;
    ; target = COMPACT: limpa locks, _mode := COMPACT
    ; target = MICRO:   _microLocked := true, _mode := MICRO (limpa steve)
    ; target = STEVE:   _steveLocked := true, _mode := STEVE (limpa micro)
    ;
    ; Idempotente: chamar com modo atual eh no-op.
    ; ============================================================
    SetMode(target)
    {
        if (target != OverlayModes.COMPACT
           && target != OverlayModes.MICRO
           && target != OverlayModes.STEVE)
            throw ValueError("OverlayModeService.SetMode: target invalido: '" String(target) "'")

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
    ; Cada DOWN alterna o state da panel:
    ;   - key NAO em _heldKeys: panel "abriu" -> adiciona
    ;   - key JA em _heldKeys:  panel "fechou" -> remove
    ;
    ; Recomputa modo: Count > 0 -> MICRO AUTO; Count = 0 -> volta COMPACT.
    ; LOCKED: panel keys nao mudam mode (mas registram held set).
    ; Esc/focus loss limpam tudo via ClearHeldKeys.
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

        ; Qualquer lock ativo (micro ou steve, v17.14) ignora auto-mode
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
        ; TOGGLE semantics: UP eh no-op. Toggle acontece em DOWN.
        return false
    }

    ClearHeldKeys()
    {
        if (this._heldKeys.Count = 0)
            return false
        this._heldKeys := Map()
        ; v17.14: auto-mode so volta pra compact se nao tem nenhum lock
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
                try TrayTip("SpeedKalandra", "Modo: " label, "Mute")
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
