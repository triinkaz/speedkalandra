; AppSettings — general tracker settings, populated from the INI
; on boot and edited via the Settings dialog.
;
; INI sections:
;   [General]       ProfileName, GamePatch, LogFile
;   [Character]     Name, Class, Level
;   [CurrentArea]   Level, Code
;   [Rules]         AutoPauseOnFocus, DeathPenaltyEnabled, DeathPenaltyMs
;   [LoadingVisual] Enabled, PollMs, MinMs, MaxMs
;   [AutoFinalize]  Regex (PCRE, empty = disabled)
;   [AutoStart]     Regex (PCRE, empty = disabled)
;   [VendorRegexes] Slot1, Slot2, Slot3 (max 250 chars each)
;   [Diagnostics]   EventTracingEnabled (opt-in)
;   [Layouts]       Variant (classic | plus)
;   [Display]       PbMode (pb | avg5), ShowOutcomeBanner (bool)
;   [Disclaimer]    Acknowledged (do-not-show-again flag)
;   [Hotkeys]       <action> = keyBind
;   [Window]        → WindowState (composite)
;   [Overlay]       → OverlayLayout (composite)


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

    ; --- Death Penalty (plot + live timer) ---
    ; Optional extra bar in the run plot via
    ; RunStatsPlotBuilder._AddDeathDetails, rendered as
    ; (deathCount * deathPenaltyMs). Also gates the live timer
    ; penalty that LiveReconfigurationHandlers applies on each
    ; DeathDetected. Default false — the per-death overhead varies
    ; a lot by player (waypoint vs portal vs nearest checkpoint),
    ; so the estimate stays opt-in. 150_000 ms (2:30) is a rough
    ; PoE2 average for waypoint + traversal back to the death
    ; point; kept in the default so the value is sane the moment
    ; the user enables the flag in the Settings dialog.
    deathPenaltyEnabled := false
    deathPenaltyMs      := 150000

    ; --- Disclaimer ---
    ; "User has seen the disclaimer and ticked do-not-show-again."
    ; Default false — shown on every boot until the checkbox.
    disclaimerAcknowledged := false

    ; --- Diagnostics ---
    ; Opt-in flag for the EventTraceLogger interceptor on the
    ; EventBus. When true, every Publish is logged to
    ; speedkalandra.log, including payloads that carry raw Client.txt
    ; lines (via LogLineRead). Default false so a normal install
    ; never persists that data — user has to enable it explicitly
    ; for diagnostics.
    eventTracingEnabled := false

    ; --- Layouts (BETA) ---
    ; Selects between Classic (current widgets) and Plus (experimental
    ; variants with mono timer, percent-based reflow, resize-by-border).
    ; Read once at boot by the composition root; switching requires a
    ; restart. See PLUS_LAYOUTS_SPEC.md.
    layoutVariant := "classic"

    ; --- Display ---
    ; Toggles what the PB display surfaces show (Steve Plus bare
    ; value, Compact Plus block sub-label, Compact Classic line2
    ; chip) AND what the live-timer color compares against. Two
    ; values:
    ;   "pb"   — the all-time PersonalBestService values. Default.
    ;            Original behavior; widgets render "PB MM:SS" / a
    ;            bare teal value, and the live timer turns green
    ;            when current <= PB.
    ;   "avg5" — average across the latest five completed runs from
    ;            data\runs\*.ini, computed by RunAverageService.
    ;            Widgets render "AVG MM:SS" (or a tilde-prefixed
    ;            bare value for the Steve Plus chip) and the live
    ;            timer turns green when current <= avg5. "Below
    ;            target" still means green either way, so the
    ;            comparison semantics stay consistent across modes.
    ;
    ; Hot-reload: SettingsDialog publishes Evt.PbDisplayModeChanged
    ; on save; widgets subscribe and re-render without restart
    ; (unlike layoutVariant, which rebuilds widget GUIs).
    ;
    ; Defensive default: any value that isn't recognizably "avg5"
    ; normalizes to "pb" in FromMap and in SettingsRepository—so a
    ; hand-edited INI with a typo lands on the safe original
    ; behavior rather than an undefined runtime branch. See
    ; PLUS_LAYOUTS_SPEC.md §13 for the full feature spec.
    pbDisplayMode := "pb"

    ; Toggles the transient run-outcome banner (top-center, ~4 s)
    ; that surfaces after every Finalize / Cancel / Reset of an
    ; active run. Default true — the banner is opt-out so the
    ; "did it save?" feedback gap that prompted the feature is
    ; closed by default. Speedrunners who find the banner
    ; distracting can flip it off in Settings → DISPLAY. See
    ; RunOutcomeBannerWidget for the full lifecycle.
    showOutcomeBanner := true

    ; --- Auto-finalize ---
    autoFinalizeRegex := ""

    ; --- Auto-start ---
    ; The Wounded Man dialogue right at the start of the PoE2
    ; campaign. The log format is "Wounded Man: By the First Ones! ..."
    ; (NPC prefix + dialogue). PCRE `i)` flag for case-insensitivity
    ; in case the game logs minor variations. AutoStartService matches
    ; this against Evt.LogLineRead and publishes Cmd.NewRunRequested.
    ;
    ; PoE2 is localized — players on PT-BR / ES / DE / FR / etc. have
    ; this line translated in their log and this English default won't
    ; match. They can edit it via the Settings dialog (Auto-start regex)
    ; or leave it empty and rely on the manual hotkey (^!n by default).
    autoStartRegex := "i)Wounded Man: By the First Ones!"

    ; --- Vendor Regex Slots ---
    ; Three short strings (max 250 chars each) the user copies to the
    ; clipboard via V1/V2/V3 buttons in the compact overlay during a
    ; run. Typical use: a vendor-item regex for resistances, jewels
    ; with specific mods, sockets/links, etc. The 250-char cap matches
    ; the in-game vendor filter limit raised in PoE 0.x; enforced on
    ; Load and Save so a hand-edited INI can't break the invariant.
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

        ; --- Death Penalty ---
        cfg.deathPenaltyEnabled := AppSettings._GetBool(data, "deathPenaltyEnabled", cfg.deathPenaltyEnabled)
        if data.Has("deathPenaltyMs")
        {
            v := Integer(data["deathPenaltyMs"] + 0)
            cfg.deathPenaltyMs := v >= 0 ? v : 0
        }

        ; --- Disclaimer ---
        cfg.disclaimerAcknowledged := AppSettings._GetBool(data, "disclaimerAcknowledged", cfg.disclaimerAcknowledged)

        ; --- Diagnostics ---
        cfg.eventTracingEnabled := AppSettings._GetBool(data, "eventTracingEnabled", cfg.eventTracingEnabled)

        ; --- Layouts ---
        ; Any value that isn't exactly "plus" normalizes to "classic".
        ; A hand-edited INI with a typo ("Plus", "plus_v2", "") falls
        ; back to the safe default rather than entering an undefined
        ; runtime branch.
        if data.Has("layoutVariant")
        {
            v := String(data["layoutVariant"])
            cfg.layoutVariant := (v = "plus") ? "plus" : "classic"
        }

        ; --- Display (PB mode) ---
        ; Same normalization pattern as layoutVariant: anything that
        ; isn't recognizably "avg5" falls back to the safe "pb"
        ; default. AHK v2 `=` is case-insensitive, so "AVG5" / "Avg5"
        ; / "avg5" all load as the average mode (matching the
        ; tolerance applied to "plus" / "Plus" / "PLUS" above).
        if data.Has("pbDisplayMode")
        {
            v := String(data["pbDisplayMode"])
            cfg.pbDisplayMode := (v = "avg5") ? "avg5" : "pb"
        }

        ; --- Display (outcome banner) ---
        cfg.showOutcomeBanner := AppSettings._GetBool(data, "showOutcomeBanner", cfg.showOutcomeBanner)

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

    ; ---- Internal helpers ----

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
