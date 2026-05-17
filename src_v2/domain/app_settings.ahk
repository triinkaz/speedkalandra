; ============================================================
; AppSettings - general tracker settings (Wave 6)
; ============================================================
;
; POST-DEMOLITION VERSION:
;   - Removed step-based fields: summariesAutoExportOnFinalize,
;     summariesScope, stepSummaryFile, runSummaryFile, plotMetrics.
;   - Removed hotkeys for extinct features: ToggleCompact (no Normal),
;     CompleteStep, PrevAct, NextAct, Targets, CampaignEditor,
;     ForceSyncZone, ReplayDialog, WidgetManager, Undo.
;   - Added: autoFinalizeRegex, autoStartRegex (Waves 6/7).
;
;   v17.15 (Bug #15): removed fields for disconnected features:
;     - panelOverlayKeys: PanelKeyService disconnected in v17.2
;     - gamePauseDetectionEnabled: GamePauseDetectionService disconnected in v17.5
;
;   v17.15.1: re-added deathPenaltyEnabled/Ms after discovering that
;   RunStatsPlotBuilder ALREADY consumed them. The initial audit
;   misclassified them as dead settings.
;
; INI SECTIONS:
;   [General]      ProfileName, GamePatch, LogFile
;   [Character]    Name, Class, Level
;   [CurrentArea]  Level, Code
;   [Rules]        AutoPauseOnFocus, DeathPenaltyEnabled, DeathPenaltyMs
;   [LoadingVisual] Enabled, PollMs, MinMs, MaxMs
;   [AutoFinalize] Regex (PCRE string — empty = disabled)
;   [AutoStart]    Regex (PCRE string — empty = disabled)
;   [VendorRegexes] Slot1, Slot2, Slot3 (max 50 chars each)
;   [Hotkeys]      <action> -> keyBind
;   [Window]       -> WindowState (composite)
;   [Overlay]      -> OverlayLayout (composite)


class AppSettings
{
    ; --- General ---
    profileName      := "Default"
    gamePatch        := "Unknown"
    logFile          := ""

    ; --- Character ---
    characterName    := ""
    characterClass   := ""
    characterLevel   := 0

    ; --- Current Area ---
    currentAreaLevel := 0
    currentAreaCode  := ""

    ; --- Loading Visual ---
    loadingVisualEnabled := true
    loadingVisualPollMs  := 25
    loadingVisualMinMs   := 250
    loadingVisualMaxMs   := 90000

    ; --- Auto-pause (focus) ---
    autoPauseOnFocus := true

    ; --- Death Penalty (plot) ---
    ; v17.15.1: re-added after #15 over-removal. These fields are
    ; consumed by RunStatsPlotBuilder._AddDeathDetails which renders
    ; the "Deaths" bar in the run plot as (deathCount * deathPenaltyMs).
    ; The initial audit misclassified them as dead settings.
    ;
    ; deathPenaltyMs = 150000 = 2 minutes and 30 seconds (PoE2 default:
    ; average time to return to death point considering waypoint +
    ; traversal). Adjustable in the Settings dialog.
    deathPenaltyEnabled := true
    deathPenaltyMs      := 150000

    ; --- Disclaimer (v17.15.2) ---
    ; Flag "user has seen the disclaimer and ticked do-not-show-again".
    ; Default false = shown on every boot until the user ticks the checkbox.
    ; Persisted in [Disclaimer].Acknowledged of speedkalandra.ini.
    disclaimerAcknowledged := false

    ; --- Auto-finalize (Wave 6) ---
    autoFinalizeRegex := ""

    ; --- Auto-start (Wave 6) ---
    ; Wounded Man phrase right at the start of the PoE2 campaign. The
    ; game log emits in the format "Wounded Man: By the First Ones! ..."
    ; (NPC prefix + dialogue). Case-insensitive match via the PCRE `i)`
    ; flag at the start of the pattern — resilient to small caps
    ; variations in the log. AutoStartService matches against
    ; Evt.LogLineRead and publishes Cmd.NewRunRequested.
    ;
    ; CAVEAT (Bug #11): PoE2 is localized. PT-BR / ES / DE / FR / etc.
    ; players have that line translated in the log and the English
    ; default will not match. Those players can edit it via the Settings
    ; dialog (Auto-start regex) with the equivalent in their language,
    ; or leave it empty to use the manual hotkey (^!n by default).
    autoStartRegex := "i)Wounded Man: By the First Ones!"

    ; --- Vendor Regex Slots (Wave 8) ---
    ; 3 short strings (max 50 chars each) that the user can copy to
    ; the clipboard via V1/V2/V3 buttons in the compact overlay during
    ; the run. Typical use: regex filter for items at vendor NPCs
    ; (resistances, jewels with specific mods, sockets/links etc.).
    ;
    ; 50-char truncation is applied on Load and Save to guarantee
    ; the invariant even if the INI is edited by hand.
    vendorRegexes := ["", "", ""]

    ; --- Hotkeys --- Map<actionName, keyBind>
    hotkeys := Map()

    ; --- Composites ---
    window  := ""    ; WindowState
    overlay := ""    ; OverlayLayout

    static Defaults()
    {
        cfg := AppSettings()
        cfg.window  := WindowState.Defaults()
        cfg.overlay := OverlayLayout.Defaults()
        cfg.hotkeys := AppSettings._DefaultHotkeys()
        return cfg
    }

    static FromMap(data)
    {
        if !IsObject(data)
            throw TypeError("AppSettings.FromMap: 'data' must be a Map")

        cfg := AppSettings.Defaults()

        ; --- General ---
        cfg.profileName := AppSettings._GetStr(data, "profileName", cfg.profileName)
        cfg.gamePatch   := AppSettings._GetStr(data, "gamePatch",   cfg.gamePatch)
        cfg.logFile     := AppSettings._GetStr(data, "logFile",     cfg.logFile)

        ; --- Character ---
        cfg.characterName  := AppSettings._GetStr(data, "characterName",  cfg.characterName)
        cfg.characterClass := AppSettings._GetStr(data, "characterClass", cfg.characterClass)
        cfg.characterLevel := AppSettings._GetNonNegInt(data, "characterLevel", cfg.characterLevel)

        ; --- Current Area ---
        cfg.currentAreaLevel := AppSettings._GetNonNegInt(data, "currentAreaLevel", cfg.currentAreaLevel)
        cfg.currentAreaCode  := AppSettings._GetStr(data, "currentAreaCode", cfg.currentAreaCode)

        ; --- Loading Visual ---
        cfg.loadingVisualEnabled := AppSettings._GetBool(data, "loadingVisualEnabled", cfg.loadingVisualEnabled)
        cfg.loadingVisualPollMs  := AppSettings._GetNonNegInt(data, "loadingVisualPollMs", cfg.loadingVisualPollMs)
        cfg.loadingVisualMinMs   := AppSettings._GetNonNegInt(data, "loadingVisualMinMs",  cfg.loadingVisualMinMs)
        cfg.loadingVisualMaxMs   := AppSettings._GetNonNegInt(data, "loadingVisualMaxMs",  cfg.loadingVisualMaxMs)

        ; --- Auto-pause ---
        cfg.autoPauseOnFocus := AppSettings._GetBool(data, "autoPauseOnFocus", cfg.autoPauseOnFocus)

        ; --- Death Penalty (v17.15.1: re-added after #15 over-removal) ---
        cfg.deathPenaltyEnabled := AppSettings._GetBool(data, "deathPenaltyEnabled", cfg.deathPenaltyEnabled)
        if data.Has("deathPenaltyMs")
        {
            v := Integer(data["deathPenaltyMs"] + 0)
            cfg.deathPenaltyMs := v >= 0 ? v : 0
        }

        ; --- Disclaimer (v17.15.2) ---
        cfg.disclaimerAcknowledged := AppSettings._GetBool(data, "disclaimerAcknowledged", cfg.disclaimerAcknowledged)

        ; --- Auto-finalize ---
        cfg.autoFinalizeRegex := AppSettings._GetStr(data, "autoFinalizeRegex", cfg.autoFinalizeRegex)

        ; --- Auto-start ---
        cfg.autoStartRegex := AppSettings._GetStrAllowEmpty(data, "autoStartRegex", cfg.autoStartRegex)

        ; --- Hotkeys (defensive merge) ---
        if data.Has("hotkeys") && IsObject(data["hotkeys"])
        {
            for k, v in data["hotkeys"]
                cfg.hotkeys[k] := String(v)
        }

        ; --- Window (composite) ---
        if data.Has("window") && IsObject(data["window"])
        {
            if (data["window"] is WindowState)
                cfg.window := data["window"]
            else
                cfg.window := WindowState.FromMap(data["window"])
        }

        ; --- Overlay (composite) ---
        if data.Has("overlay") && IsObject(data["overlay"])
        {
            if (data["overlay"] is OverlayLayout)
                cfg.overlay := data["overlay"]
            else
                cfg.overlay := OverlayLayout.FromMap(data["overlay"])
        }

        return cfg
    }

    HasHotkey(action) => this.hotkeys.Has(action)
    GetHotkey(action, default := "")
    {
        return this.hotkeys.Has(action) ? this.hotkeys[action] : default
    }

    static _DefaultHotkeys()
    {
        return Map(
            "ToggleOverlay",   "F8",
            "ToggleMicroLock", "^F9",
            "ToggleSteveLock", "^F8",
            "StartPause",      "^3",
            "NewRun",          "^!n",
            "ResetRun",        "^5",
            "FinalizeRun",     "^!f",
            "Settings",        "^!s",
            "PlotRunStats",    "^!p"
        )
    }

    ; ------------------------------------------------------------
    ; Internal helpers
    ; ------------------------------------------------------------
    static _GetStr(data, key, default)
    {
        if !data.Has(key)
            return default
        v := data[key]
        return v != "" ? String(v) : default
    }

    static _GetStrAllowEmpty(data, key, default)
    {
        if !data.Has(key)
            return default
        return String(data[key])
    }

    static _GetNonNegInt(data, key, default)
    {
        if !data.Has(key)
            return default
        v := data[key]
        if (v = "" || !IsNumber(v))
            return default
        n := Integer(v + 0)
        return n >= 0 ? n : 0
    }

    static _GetBool(data, key, default)
    {
        if !data.Has(key)
            return default
        return AppSettings._ToBool(data[key])
    }

    static _ToBool(v)
    {
        if (v = "" || v = 0 || v = "0" || v = false)
            return false
        if (v = 1 || v = "1" || v = true)
            return true
        return !!v
    }
}
