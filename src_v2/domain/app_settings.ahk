; ============================================================
; AppSettings - configuracoes gerais do tracker (Onda 6)
; ============================================================
;
; VERSAO POS-DEMOLICAO:
;   - Removidos campos step-based: summariesAutoExportOnFinalize,
;     summariesScope, stepSummaryFile, runSummaryFile, plotMetrics.
;   - Removidas hotkeys de features extintas: ToggleCompact (sem Normal),
;     CompleteStep, PrevAct, NextAct, Targets, CampaignEditor,
;     ForceSyncZone, ReplayDialog, WidgetManager, Undo.
;   - Adicionado: autoFinalizeRegex, autoStartRegex (Ondas 6/7).
;
;   v17.15 (Bug #15): removidos campos de features desconectadas:
;     - panelOverlayKeys: PanelKeyService desconectado em v17.2
;     - gamePauseDetectionEnabled: GamePauseDetectionService desconectado em v17.5
;
;   v17.15.1: re-adicionados deathPenaltyEnabled/Ms apos descoberta
;   de que RunStatsPlotBuilder JA os consumia. Auditoria inicial
;   errou ao classificar como dead settings.
;
; SECOES DO INI:
;   [General]      ProfileName, GamePatch, LogFile
;   [Character]    Name, Class, Level
;   [CurrentArea]  Level, Code
;   [Rules]        AutoPauseOnFocus, DeathPenaltyEnabled, DeathPenaltyMs
;   [LoadingVisual] Enabled, PollMs, MinMs, MaxMs
;   [AutoFinalize] Regex (string PCRE — vazio = desligado)
;   [AutoStart]    Regex (string PCRE — vazio = desligado)
;   [VendorRegexes] Slot1, Slot2, Slot3 (max 50 chars cada)
;   [Hotkeys]      <action> -> keyBind
;   [Window]       -> WindowState (composto)
;   [Overlay]      -> OverlayLayout (composto)


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

    ; --- Auto-pause (foco) ---
    autoPauseOnFocus := true

    ; --- Death Penalty (plot) ---
    ; v17.15.1: re-adicionado apos #15 over-removal. Esses campos sao
    ; consumidos por RunStatsPlotBuilder._AddDeathDetails que renderiza
    ; a barra "Deaths" no run plot como (deathCount * deathPenaltyMs).
    ; Auditoria inicial errou ao classificar como dead settings.
    ;
    ; deathPenaltyMs = 150000 = 2 minutos e 30 segundos (default PoE2:
    ; tempo medio pra retornar ao ponto de morte considerando waypoint
    ; + travessia). Ajustavel no Settings dialog.
    deathPenaltyEnabled := true
    deathPenaltyMs      := 150000

    ; --- Disclaimer (v17.15.2) ---
    ; Flag "user ja viu o disclaimer e marcou nao-mostrar-mais".
    ; Default false = mostra a cada boot ate user marcar checkbox.
    ; Persistido em [Disclaimer].Acknowledged do speedkalandra.ini.
    disclaimerAcknowledged := false

    ; --- Auto-finalize (Onda 6) ---
    autoFinalizeRegex := ""

    ; --- Auto-start (Onda 6) ---
    ; Frase do Wounded Man no comecinho da campanha PoE2. O log do jogo
    ; sai com formato "Wounded Man: By the First Ones! ..." (prefixo do
    ; NPC + dialogo). Match case-insensitive via flag PCRE `i)` no
    ; comeco do padrao — resiliente a pequenas variacoes de caps no log.
    ; AutoStartService matcheia contra Evt.LogLineRead e publica
    ; Cmd.NewRunRequested.
    ;
    ; CAVEAT (Bug #11): PoE2 eh localizado. Jogadores PT-BR / ES / DE /
    ; FR / etc tem essa fala traduzida no log e o default em ingles nao
    ; bate. Esses jogadores podem editar via Settings dialog (Auto-start
    ; regex) com o equivalente do seu idioma, ou deixar vazio pra usar
    ; hotkey manual (^!n por default).
    autoStartRegex := "i)Wounded Man: By the First Ones!"

    ; --- Vendor Regex Slots (Onda 8) ---
    ; 3 strings curtas (max 50 chars cada) que o user pode copiar pra
    ; clipboard via botoes V1/V2/V3 no compact overlay durante a run.
    ; Tipico: regex de filtro de items em vendor NPCs (resistencias,
    ; jewels com mods especificos, sockets/links etc).
    ;
    ; Truncamento de 50 chars eh aplicado em Load e em Save pra
    ; garantir invariante mesmo se o INI for editado a mao.
    vendorRegexes := ["", "", ""]

    ; --- Hotkeys --- Map<actionName, keyBind>
    hotkeys := Map()

    ; --- Compostos ---
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
            throw TypeError("AppSettings.FromMap: 'data' deve ser Map")

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

        ; --- Death Penalty (v17.15.1: re-adicionado apos #15 over-removal) ---
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

        ; --- Hotkeys (merge defensivo) ---
        if data.Has("hotkeys") && IsObject(data["hotkeys"])
        {
            for k, v in data["hotkeys"]
                cfg.hotkeys[k] := String(v)
        }

        ; --- Window (composto) ---
        if data.Has("window") && IsObject(data["window"])
        {
            if (data["window"] is WindowState)
                cfg.window := data["window"]
            else
                cfg.window := WindowState.FromMap(data["window"])
        }

        ; --- Overlay (composto) ---
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
