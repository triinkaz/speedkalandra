; ============================================================
; SettingsRepository — AppSettings <-> INI
; ============================================================
;
; Sections (in load/save order):
;   [General]        ProfileName, GamePatch, LogFile
;   [Character]      Name, Class, Level
;   [CurrentArea]    Level, Code
;   [Rules]          AutoPauseOnFocus, DeathPenaltyEnabled, DeathPenaltyMs
;   [LoadingVisual]  Enabled, PollMs, MinMs, MaxMs
;   [AutoFinalize]   Regex
;   [AutoStart]      Regex
;   [VendorRegexes]  Slot1, Slot2, Slot3
;   [Disclaimer]     Acknowledged
;   [Diagnostics]    EventTracingEnabled (opt-in; off by default)
;   [Layouts]        Variant (classic | plus; opt-in BETA)
;   [Hotkeys]        <action> -> keyBind
;   [Window]         MicroLocked, SteveLocked
;   [Overlay]        <widgetId>.{left,top,scale,visible,centered} + hoverHide
;
; Orphan keys in old INIs (PanelOverlayKeys, GamePauseDetectionEnabled)
; are not read or written, so they sit inert.
;
; Construction:
;   ini  := IniFile(A_ScriptDir "\speedkalandra.ini")
;   repo := SettingsRepository(ini)
;
; Operations:
;   cfg := repo.Load()
;   repo.Save(cfg)


class SettingsRepository
{
    _ini := ""

    __New(iniFileObj)
    {
        if !(iniFileObj is IniFile)
            throw TypeError("SettingsRepository: 'iniFileObj' must be IniFile")
        this._ini := iniFileObj
    }

    Load()
    {
        cfg := AppSettings.Defaults()
        this._LoadGeneral(cfg)
        this._LoadCharacter(cfg)
        this._LoadCurrentArea(cfg)
        this._LoadRules(cfg)
        this._LoadLoadingVisual(cfg)
        this._LoadAutoFinalize(cfg)
        this._LoadAutoStart(cfg)
        this._LoadVendorRegexes(cfg)
        this._LoadDisclaimer(cfg)
        this._LoadDiagnostics(cfg)
        this._LoadLayouts(cfg)
        this._LoadHotkeys(cfg)
        cfg.window  := this._LoadWindow()
        cfg.overlay := this._LoadOverlay()
        return cfg
    }

    ; Save with backup-rollback. Sections are still serialized via
    ; sequential IniWrite calls; true atomicity would require a
    ; full in-memory rebuild + single AtomicWriter flush, which is
    ; a deeper refactor of IniFile. This path adds defense in depth:
    ; copy the existing INI to a .pre-save sibling before mutating,
    ; wrap the save sequence in try/catch, and restore the backup
    ; on any throw. The dominant failure mode in practice is a
    ; mid-sequence IniWrite throw (file lock, permissions, AV) and
    ; this covers it. The small gap between FileCopy and the first
    ; IniWrite (where a system crash could lose both) is accepted.
    Save(cfg)
    {
        if !(cfg is AppSettings)
            throw TypeError("SettingsRepository.Save: 'cfg' must be AppSettings")

        iniPath := this._ini.path
        backupPath := iniPath . ".pre-save"
        hadFile := !!FileExist(iniPath)

        if hadFile
        {
            try FileCopy(iniPath, backupPath, true)
        }

        try
        {
            this._SaveGeneral(cfg)
            this._SaveCharacter(cfg)
            this._SaveCurrentArea(cfg)
            this._SaveRules(cfg)
            this._SaveLoadingVisual(cfg)
            this._SaveAutoFinalize(cfg)
            this._SaveAutoStart(cfg)
            this._SaveVendorRegexes(cfg)
            this._SaveDisclaimer(cfg)
            this._SaveDiagnostics(cfg)
            this._SaveLayouts(cfg)
            this._SaveHotkeys(cfg)
            this._SaveWindow(cfg.window)
            this._SaveOverlay(cfg.overlay)
        }
        catch as ex
        {
            ; Restore pre-save bytes so the user's INI isn't left
            ; half-written. Best-effort: if the restore itself
            ; fails, the .pre-save file stays on disk so the user
            ; can recover it manually.
            if (hadFile && FileExist(backupPath))
            {
                try FileCopy(backupPath, iniPath, true)
            }
            try FileDelete(backupPath)
            ; Rethrow so the caller can react (SettingsDialog shows
            ; an error MsgBox; programmatic callers see the exception).
            throw ex
        }

        ; Success path — discard the backup.
        if FileExist(backupPath)
        {
            try FileDelete(backupPath)
        }
    }

    ; ============================================================
    ; [General]
    ; ============================================================
    _LoadGeneral(cfg)
    {
        ini := this._ini
        cfg.profileName := ini.Read("General", "ProfileName", cfg.profileName)
        cfg.gamePatch   := ini.Read("General", "GamePatch",   cfg.gamePatch)
        cfg.logFile     := ini.Read("General", "LogFile",     cfg.logFile)
    }

    _SaveGeneral(cfg)
    {
        ini := this._ini
        ini.Write(cfg.profileName, "General", "ProfileName")
        ini.Write(cfg.gamePatch,   "General", "GamePatch")
        ini.Write(cfg.logFile,     "General", "LogFile")
    }

    ; ============================================================
    ; [Character]
    ; ============================================================
    _LoadCharacter(cfg)
    {
        ini := this._ini
        cfg.characterName  := ini.Read("Character", "Name",  cfg.characterName)
        cfg.characterClass := ini.Read("Character", "Class", cfg.characterClass)
        cfg.characterLevel := SettingsRepository._ReadInt(ini, "Character", "Level", cfg.characterLevel)
    }

    _SaveCharacter(cfg)
    {
        ini := this._ini
        ini.Write(cfg.characterName,  "Character", "Name")
        ini.Write(cfg.characterClass, "Character", "Class")
        ini.Write(cfg.characterLevel, "Character", "Level")
    }

    ; ============================================================
    ; [CurrentArea]
    ; ============================================================
    _LoadCurrentArea(cfg)
    {
        ini := this._ini
        cfg.currentAreaLevel := SettingsRepository._ReadInt(ini, "CurrentArea", "Level", cfg.currentAreaLevel)
        cfg.currentAreaCode  := ini.Read("CurrentArea", "Code", cfg.currentAreaCode)
    }

    _SaveCurrentArea(cfg)
    {
        ini := this._ini
        ini.Write(cfg.currentAreaLevel, "CurrentArea", "Level")
        ini.Write(cfg.currentAreaCode,  "CurrentArea", "Code")
    }

    ; ============================================================
    ; [Rules]
    ; ============================================================
    _LoadRules(cfg)
    {
        ini := this._ini
        cfg.autoPauseOnFocus    := ini.Read("Rules", "AutoPauseOnFocus", "1") = "1"
        ; Death penalty default mirrors AppSettings.deathPenaltyEnabled (false).
        ; Both defaults must stay in sync — changing only one creates a
        ; silent split between Defaults() and a freshly-loaded INI.
        cfg.deathPenaltyEnabled := ini.Read("Rules", "DeathPenaltyEnabled", "0") = "1"
        cfg.deathPenaltyMs      := SettingsRepository._ReadInt(ini, "Rules", "DeathPenaltyMs", cfg.deathPenaltyMs)
    }

    _SaveRules(cfg)
    {
        ini := this._ini
        ini.Write(cfg.autoPauseOnFocus    ? 1 : 0, "Rules", "AutoPauseOnFocus")
        ini.Write(cfg.deathPenaltyEnabled ? 1 : 0, "Rules", "DeathPenaltyEnabled")
        ini.Write(cfg.deathPenaltyMs,              "Rules", "DeathPenaltyMs")
    }

    ; ============================================================
    ; [LoadingVisual]
    ; ============================================================
    _LoadLoadingVisual(cfg)
    {
        ini := this._ini
        cfg.loadingVisualEnabled := ini.Read("LoadingVisual", "Enabled", "1") = "1"
        cfg.loadingVisualPollMs  := SettingsRepository._ReadInt(ini, "LoadingVisual", "PollMs", cfg.loadingVisualPollMs)
        cfg.loadingVisualMinMs   := SettingsRepository._ReadInt(ini, "LoadingVisual", "MinMs",  cfg.loadingVisualMinMs)
        cfg.loadingVisualMaxMs   := SettingsRepository._ReadInt(ini, "LoadingVisual", "MaxMs",  cfg.loadingVisualMaxMs)
    }

    _SaveLoadingVisual(cfg)
    {
        ini := this._ini
        ini.Write(cfg.loadingVisualEnabled ? 1 : 0, "LoadingVisual", "Enabled")
        ini.Write(cfg.loadingVisualPollMs,           "LoadingVisual", "PollMs")
        ini.Write(cfg.loadingVisualMinMs,            "LoadingVisual", "MinMs")
        ini.Write(cfg.loadingVisualMaxMs,            "LoadingVisual", "MaxMs")
    }

    ; ============================================================
    ; [AutoFinalize]
    ; ============================================================
    _LoadAutoFinalize(cfg)
    {
        cfg.autoFinalizeRegex := this._ini.Read("AutoFinalize", "Regex", cfg.autoFinalizeRegex)
    }

    _SaveAutoFinalize(cfg)
    {
        this._ini.Write(cfg.autoFinalizeRegex, "AutoFinalize", "Regex")
    }

    ; ============================================================
    ; [AutoStart]
    ; ============================================================
    _LoadAutoStart(cfg)
    {
        cfg.autoStartRegex := this._ini.Read("AutoStart", "Regex", cfg.autoStartRegex)
    }

    _SaveAutoStart(cfg)
    {
        this._ini.Write(cfg.autoStartRegex, "AutoStart", "Regex")
    }

    ; ============================================================
    ; [VendorRegexes]
    ;
    ; Persists 3 short regex slots (max 250 chars each) used by the
    ; V1/V2/V3 buttons of CompactLayoutWidget for copy-to-clipboard
    ; during the run. Cap raised from 50→250 in PoE 0.x to match
    ; the in-game vendor filter limit.
    ;
    ; Defensive truncation applied in both Load and Save: guarantees
    ; the invariant even if the INI is hand-edited with a long string.
    ; ============================================================
    _LoadVendorRegexes(cfg)
    {
        ini := this._ini
        out := ["", "", ""]
        Loop 3
        {
            i := A_Index
            v := ini.Read("VendorRegexes", "Slot" i, "")
            if (StrLen(v) > 250)
                v := SubStr(v, 1, 250)
            out[i] := v
        }
        cfg.vendorRegexes := out
    }

    _SaveVendorRegexes(cfg)
    {
        ini := this._ini
        Loop 3
        {
            i := A_Index
            v := (IsObject(cfg.vendorRegexes) && cfg.vendorRegexes.Has(i))
                 ? String(cfg.vendorRegexes[i])
                 : ""
            if (StrLen(v) > 250)
                v := SubStr(v, 1, 250)
            ; Use WriteVerbatim to preserve leading/trailing
            ; double-quotes (common in PoE2 vendor filters like
            ; '"!(uiv)" "melee|mov"'). Regular Write loses the outer
            ; quotes on the next reload due to IniRead's quote-stripping.
            ini.WriteVerbatim(v, "VendorRegexes", "Slot" i)
        }
    }

    ; ============================================================
    ; [Disclaimer]
    ;
    ; Persists the acknowledgment flag of the disclaimer dialog shown
    ; on boot. False = shown on each boot; true = silenced (user
    ; ticked "don't show again").
    ; ============================================================
    _LoadDisclaimer(cfg)
    {
        cfg.disclaimerAcknowledged := this._ini.Read("Disclaimer", "Acknowledged", "0") = "1"
    }

    _SaveDisclaimer(cfg)
    {
        this._ini.Write(cfg.disclaimerAcknowledged ? 1 : 0, "Disclaimer", "Acknowledged")
    }

    ; ============================================================
    ; [Diagnostics]
    ;
    ; Opt-in flag for the EventTraceLogger interceptor. When true,
    ; every EventBus Publish is appended to speedkalandra.log along
    ; with the full payload (which includes raw Client.txt lines via
    ; the LogLineRead event). Default false — a normal install never
    ; persists that data unless the user explicitly enables it for
    ; diagnostics. See app_settings.ahk for the field declaration.
    ; ============================================================
    _LoadDiagnostics(cfg)
    {
        cfg.eventTracingEnabled := this._ini.Read("Diagnostics", "EventTracingEnabled", "0") = "1"
    }

    _SaveDiagnostics(cfg)
    {
        this._ini.Write(cfg.eventTracingEnabled ? 1 : 0, "Diagnostics", "EventTracingEnabled")
    }

    ; ============================================================
    ; [Layouts]
    ;
    ; Selects between Classic (default) and Plus overlay variants.
    ; Read once at boot by the composition root; switching requires
    ; a restart. Any value other than the literal "plus" normalizes
    ; to "classic" so a typo in a hand-edited INI lands on the safe
    ; branch. See PLUS_LAYOUTS_SPEC.md §1.
    ; ============================================================
    _LoadLayouts(cfg)
    {
        v := this._ini.Read("Layouts", "Variant", "classic")
        cfg.layoutVariant := (v = "plus") ? "plus" : "classic"
    }

    _SaveLayouts(cfg)
    {
        v := (cfg.layoutVariant = "plus") ? "plus" : "classic"
        this._ini.Write(v, "Layouts", "Variant")
    }

    ; ============================================================
    ; [Hotkeys]
    ; ============================================================
    _LoadHotkeys(cfg)
    {
        existing := this._ini.ReadSectionAsMap("Hotkeys")
        if (existing.Count = 0)
            return
        for action, binding in existing
            cfg.hotkeys[action] := binding
    }

    _SaveHotkeys(cfg)
    {
        this._SyncMapSection("Hotkeys", cfg.hotkeys, (v) => v)
    }

    ; ============================================================
    ; [Window]
    ;
    ; Two independent locks, one per layout that can be locked
    ; (Compact has no lock — it's the default mode). Defaults to
    ; "0" for both so a fresh install boots into Compact mode
    ; regardless of which key the WindowState class defaults to.
    ; ============================================================
    _LoadWindow()
    {
        ini := this._ini
        return WindowState.FromMap(Map(
            "microLocked", ini.Read("Window", "MicroLocked", "0") = "1",
            "steveLocked", ini.Read("Window", "SteveLocked", "0") = "1"
        ))
    }

    _SaveWindow(ws)
    {
        if !(ws is WindowState)
            throw TypeError("SettingsRepository._SaveWindow: 'ws' must be WindowState")
        this._ini.Write(ws.microLocked ? 1 : 0, "Window", "MicroLocked")
        this._ini.Write(ws.steveLocked ? 1 : 0, "Window", "SteveLocked")
    }

    ; ============================================================
    ; [Overlay]
    ; ============================================================
    _LoadOverlay()
    {
        ini := this._ini
        ol := OverlayLayout.Defaults()
        ol.hoverHide := ini.Read("Overlay", "hoverHide", "1") = "1"

        keys := ini.KeysIn("Overlay")
        if (keys.Length = 0)
            return ol

        buckets := Map()
        for _, key in keys
        {
            if (key = "hoverHide")
                continue
            dotPos := InStr(key, ".")
            if (dotPos < 2)
                continue
            widgetId := SubStr(key, 1, dotPos - 1)
            propName := SubStr(key, dotPos + 1)
            if (widgetId = "" || propName = "")
                continue
            if InStr(propName, ".")
                continue
            if !buckets.Has(widgetId)
                buckets[widgetId] := Map()
            buckets[widgetId][propName] := ini.Read("Overlay", key, "")
        }

        for widgetId, props in buckets
        {
            posData := SettingsRepository._BuildPositionData(props)
            position := OverlayPosition.FromMap(posData)
            ol.SetPosition(widgetId, position)
        }
        return ol
    }

    _SaveOverlay(ol)
    {
        if !(ol is OverlayLayout)
            throw TypeError("SettingsRepository._SaveOverlay: 'ol' must be OverlayLayout")

        ini := this._ini

        keepKeys := Map()
        keepKeys["hoverHide"] := true
        for widgetId, _ in ol.positions
        {
            keepKeys[widgetId ".left"]     := true
            keepKeys[widgetId ".top"]      := true
            keepKeys[widgetId ".scale"]    := true
            keepKeys[widgetId ".visible"]  := true
            keepKeys[widgetId ".centered"] := true
        }

        for _, existingKey in ini.KeysIn("Overlay")
        {
            if !keepKeys.Has(existingKey)
                ini.Delete("Overlay", existingKey)
        }

        ini.Write(ol.hoverHide ? 1 : 0, "Overlay", "hoverHide")
        for widgetId, op in ol.positions
        {
            ini.Write(Format("{:0.2f}", op.left),  "Overlay", widgetId ".left")
            ini.Write(Format("{:0.2f}", op.top),   "Overlay", widgetId ".top")
            ini.Write(Format("{:0.2f}", op.scale), "Overlay", widgetId ".scale")
            ini.Write(op.visible  ? 1 : 0,         "Overlay", widgetId ".visible")
            ini.Write(op.centered ? 1 : 0,         "Overlay", widgetId ".centered")
        }
    }

    ; ============================================================
    ; Private helpers
    ; ============================================================
    static _BuildPositionData(propsMap)
    {
        posData := Map()
        if propsMap.Has("left") && propsMap["left"] != ""
            posData["left"] := propsMap["left"] + 0.0
        if propsMap.Has("top") && propsMap["top"] != ""
            posData["top"] := propsMap["top"] + 0.0
        if propsMap.Has("scale") && propsMap["scale"] != ""
            posData["scale"] := propsMap["scale"] + 0.0
        if propsMap.Has("visible")
            posData["visible"] := propsMap["visible"] = "1"
        if propsMap.Has("centered")
            posData["centered"] := propsMap["centered"] = "1"
        return posData
    }

    _SyncMapSection(section, mapData, serializer)
    {
        ini := this._ini
        for _, existingKey in ini.KeysIn(section)
        {
            if !mapData.Has(existingKey)
                ini.Delete(section, existingKey)
        }
        for k, v in mapData
            ini.Write(serializer(v), section, k)
    }

    static _ReadInt(ini, section, key, default)
    {
        v := ini.Read(section, key, "")
        if (v = "" || !IsNumber(v))
            return default
        return Integer(v + 0)
    }

    static _JoinList(arr)
    {
        if !IsObject(arr) || arr.Length = 0
            return ""
        out := ""
        for i, v in arr
            out .= (i > 1 ? "," : "") . v
        return out
    }
}
