; ============================================================
; SettingsRepository - AppSettings <-> INI (Wave 6, simplified)
; ============================================================
;
; POST-DEMOLITION VERSION: aligned with the minimalist AppSettings/
; OverlayLayout/WindowState.
;
; v17.15 (Bug #15): removed handling of disconnected fields:
;   [General].PanelOverlayKeys, [Rules].GamePauseDetectionEnabled.
;   Legacy keys in old INIs are orphaned but inert — they are not
;   read, not written, and do not affect behavior.
;
; v17.15.1: re-added [Rules].DeathPenaltyEnabled + DeathPenaltyMs
; after discovering that RunStatsPlotBuilder ALREADY consumed them.
; Old INIs with those keys are respected.
;
; SUPPORTED SECTIONS:
;   [General]      ProfileName, GamePatch, LogFile
;   [Character]    Name, Class, Level
;   [CurrentArea]  Level, Code
;   [Rules]        AutoPauseOnFocus, DeathPenaltyEnabled, DeathPenaltyMs
;   [LoadingVisual] Enabled, PollMs, MinMs, MaxMs
;   [AutoFinalize] Regex
;   [AutoStart]    Regex
;   [VendorRegexes] Slot1, Slot2, Slot3
;   [Hotkeys]      <action> -> keyBind
;   [Window]       MicroLocked
;   [Overlay]      <widgetId>.{left,top,scale,visible,centered} + hoverHide
;
; CONSTRUCTION:
;   ini  := IniFile(A_ScriptDir "\poe2_tracker.ini")
;   repo := SettingsRepository(ini)
;
; OPERATIONS:
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
        this._LoadHotkeys(cfg)
        cfg.window  := this._LoadWindow()
        cfg.overlay := this._LoadOverlay()
        return cfg
    }

    Save(cfg)
    {
        if !(cfg is AppSettings)
            throw TypeError("SettingsRepository.Save: 'cfg' must be AppSettings")
        this._SaveGeneral(cfg)
        this._SaveCharacter(cfg)
        this._SaveCurrentArea(cfg)
        this._SaveRules(cfg)
        this._SaveLoadingVisual(cfg)
        this._SaveAutoFinalize(cfg)
        this._SaveAutoStart(cfg)
        this._SaveVendorRegexes(cfg)
        this._SaveDisclaimer(cfg)
        this._SaveHotkeys(cfg)
        this._SaveWindow(cfg.window)
        this._SaveOverlay(cfg.overlay)
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
        cfg.deathPenaltyEnabled := ini.Read("Rules", "DeathPenaltyEnabled", "1") = "1"
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
    ; [VendorRegexes] (Wave 8)
    ;
    ; Persists 3 short regex slots (max 50 chars each) used by the
    ; V1/V2/V3 buttons of CompactLayoutWidget for copy-to-clipboard
    ; during the run.
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
            if (StrLen(v) > 50)
                v := SubStr(v, 1, 50)
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
            if (StrLen(v) > 50)
                v := SubStr(v, 1, 50)
            ; v0.1.4: use WriteVerbatim to preserve leading/trailing
            ; double-quotes (common in PoE2 vendor filters like
            ; '"!(uiv)" "melee|mov"'). Regular Write loses outer quotes
            ; on the next reload due to IniRead's quote-stripping.
            ini.WriteVerbatim(v, "VendorRegexes", "Slot" i)
        }
    }

    ; ============================================================
    ; [Disclaimer] (v17.15.2)
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
    ; ============================================================
    _LoadWindow()
    {
        ini := this._ini
        return WindowState.FromMap(Map(
            "microLocked", ini.Read("Window", "MicroLocked", "0") = "1"
        ))
    }

    _SaveWindow(ws)
    {
        if !(ws is WindowState)
            throw TypeError("SettingsRepository._SaveWindow: 'ws' must be WindowState")
        this._ini.Write(ws.microLocked ? 1 : 0, "Window", "MicroLocked")
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
