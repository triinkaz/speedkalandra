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
;   [Display]        PbMode (pb | avg5; toggles PB chip / live-timer color target), ShowOutcomeBanner (bool)
;   [Route]          WidgetVisible (bool; master visibility flag for RouteWidget), RowsVisible (int 3..10), NoteFontSize (int 6..16)
;   [Hotkeys]        <action> -> keyBind
;   [Window]         MicroLocked, SteveLocked
;   [Overlay]        <widgetId>.{left,top,scale,visible,centered} + hoverHide
;
; Orphan keys in old INIs (PanelOverlayKeys, GamePauseDetectionEnabled,
; Layouts.Variant) are not read or written, so they sit inert.
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
        this._LoadDisplay(cfg)
        this._LoadRoute(cfg)
        this._LoadHotkeys(cfg)
        cfg.window  := this._LoadWindow()
        cfg.overlay := this._LoadOverlay()
        return cfg
    }

    ; Save with best-effort rollback (NOT atomic — true atomicity
    ; would require a full in-memory rebuild + AtomicWriter flush,
    ; which is a deeper refactor of IniFile). Three guarantees:
    ;
    ;   1. BACKUP-FAIL-ABORT. If the .pre-save copy can't be
    ;      created, abort BEFORE touching the INI. Without a
    ;      backup, a mid-sequence failure would leave the file
    ;      half-written with no recovery point — worse than not
    ;      saving at all. Surfacing the error to the caller lets
    ;      the user retry (close whatever process is locking the
    ;      INI) instead of silently corrupting state.
    ;
    ;   2. PRESERVE-BACKUP-ON-RESTORE-FAIL. If a mid-sequence
    ;      save throws AND the subsequent FileCopy restore from
    ;      .pre-save also fails, KEEP the .pre-save on disk and
    ;      throw a COMPOSED error that names both failures and
    ;      the preserved backup path. The user (or a future boot)
    ;      can copy it back manually. Deleting the only known-
    ;      good copy because the restore failed would compound
    ;      the failure; suppressing the rollback error and re-
    ;      throwing the original save error would hide a more
    ;      serious condition than the user thinks they're seeing.
    ;
    ;   3. FRESH-INSTALL-CLEANUP. Fresh install (INI didn't exist
    ;      before this Save): a mid-sequence failure deletes the
    ;      partial INI bytes. Next boot lands on AppSettings
    ;      .Defaults() instead of parsing a half-formed file as
    ;      authoritative state.
    ;
    ; Trade-off: there's a small gap between FileCopy and the
    ; first IniWrite where a system crash (power loss) loses
    ; both. The dominant failure mode in practice is IniWrite
    ; throw mid-sequence (file lock, permissions, antivirus) and
    ; this path covers it.
    Save(cfg)
    {
        if !(cfg is AppSettings)
            throw TypeError("SettingsRepository.Save: 'cfg' must be AppSettings")

        iniPath := this._ini.path
        backupPath := iniPath . ".pre-save"
        hadFile := !!FileExist(iniPath)

        ; --- Guarantee 1: backup-fail-abort ---
        ; If the INI exists and we can't snapshot it, refuse to
        ; mutate it. The exception propagates to the caller, which
        ; in production (SettingsDialog._OnSave) shows a MsgBox.
        if hadFile
        {
            try
            {
                FileCopy(iniPath, backupPath, true)
            }
            catch as ex
            {
                throw Error("SettingsRepository.Save: pre-save backup failed (refusing to mutate INI without a recovery point): " . ex.Message)
            }
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
            this._SaveDisplay(cfg)
            this._SaveRoute(cfg)
            this._SaveHotkeys(cfg)
            this._SaveWindow(cfg.window)
            this._SaveOverlay(cfg.overlay)
        }
        catch as ex
        {
            if hadFile
            {
                ; --- Guarantee 2: preserve-backup-on-restore-fail ---
                ; Restore via _TryRestoreFromBackup (extracted for
                ; testability — the subclass in the test suite
                ; overrides it to force the restore-failure branch
                ; without needing to intercept FileCopy). Only
                ; delete the .pre-save after a confirmed-OK
                ; restore. If the restore also fails, the
                ; .pre-save stays on disk AND we throw a composed
                ; error so the caller knows both failures happened
                ; and where the backup is.
                if FileExist(backupPath)
                {
                    restoreResult := this._TryRestoreFromBackup(iniPath, backupPath)
                }
                else
                {
                    ; Defensive: backup vanished between FileCopy
                    ; and this point (e.g. another process raced
                    ; us). Guarantee 1 already aborted if backup
                    ; couldn't be created in the first place, so
                    ; this is an unusual second-failure path.
                    restoreResult := {restored: false,
                        error: Error("pre-save backup file missing at catch time")}
                }
                if restoreResult.restored
                {
                    try FileDelete(backupPath)
                    ; Restore succeeded — fall through to throw the
                    ; original save error so the caller sees the
                    ; familiar message.
                }
                else
                {
                    ; Restore also failed — compose an error that
                    ; names both failures and points at the
                    ; preserved .pre-save for manual recovery.
                    ; This branch matters because "save failed" is
                    ; an everyday condition the user is expected
                    ; to retry; "save failed AND rollback failed"
                    ; means the INI on disk is in an unknown state
                    ; and the user needs to act, not just retry.
                    throw Error(
                        "Settings save failed AND automatic rollback also failed. "
                        . "The pre-save backup was preserved at: " . backupPath
                        . " (restore manually by renaming over the INI). "
                        . "Save error: " . ex.Message
                        . " | Rollback error: " . restoreResult.error.Message)
                }
            }
            else
            {
                ; --- Guarantee 3: fresh-install-cleanup ---
                ; There was no INI before this Save, so any bytes
                ; on disk now are partial junk. Delete so the next
                ; boot lands on AppSettings.Defaults() rather than
                ; treating a half-formed file as authoritative.
                if FileExist(iniPath)
                {
                    try FileDelete(iniPath)
                }
            }
            ; Rethrow the original save error (the restore-failure
            ; branch above already threw a composed error and
            ; bypassed this point). SettingsDialog shows the error
            ; in a MsgBox and restores its in-memory snapshot;
            ; programmatic callers see the exception.
            throw ex
        }

        ; Success path — discard the backup.
        if FileExist(backupPath)
        {
            try FileDelete(backupPath)
        }
    }

    ; Restore from .pre-save backup. Extracted for testability:
    ; a test subclass overrides this to force the restore-failure
    ; branch (the alternative — intercepting AHK's FileCopy —
    ; isn't possible without monkey-patching, and the
    ; preserve-backup-on-restore-fail guarantee was previously
    ; review-only because of that gap).
    ;
    ; Returns an object with two fields:
    ;   restored - true if the FileCopy succeeded; false otherwise
    ;   error    - the caught exception when restored=false; ""
    ;              when restored=true
    ;
    ; Callers must check `restored` before assuming the INI bytes
    ; have been rolled back.
    _TryRestoreFromBackup(iniPath, backupPath)
    {
        try
        {
            FileCopy(backupPath, iniPath, true)
            return {restored: true, error: ""}
        }
        catch as ex
        {
            return {restored: false, error: ex}
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
    ; [Display]
    ;
    ; PbMode toggles what the PB display surfaces show AND what
    ; the live-timer colour comparison uses as a target. "pb"
    ; (default) keeps PersonalBestService-driven behaviour; "avg5"
    ; routes both through RunAverageService (average of the
    ; latest five runs in data\runs\). Any value other than
    ; "avg5" normalizes to "pb" so a typo lands on the safe
    ; branch. See AppSettings.pbDisplayMode.
    ; ============================================================
    _LoadDisplay(cfg)
    {
        v := this._ini.Read("Display", "PbMode", "pb")
        cfg.pbDisplayMode := (v = "avg5") ? "avg5" : "pb"

        ; ShowOutcomeBanner defaults to "1" so a fresh install —
        ; or any INI that predates this key — starts with the
        ; banner on, matching the AppSettings default. The opt-out
        ; lives here (not in a separate section) to keep the
        ; settings-dialog DISPLAY group cohesive: every "how does
        ; the overlay surface results to me?" flag is in [Display].
        cfg.showOutcomeBanner := this._ini.Read("Display", "ShowOutcomeBanner", "1") = "1"
    }

    _SaveDisplay(cfg)
    {
        v := (cfg.pbDisplayMode = "avg5") ? "avg5" : "pb"
        this._ini.Write(v, "Display", "PbMode")
        this._ini.Write(cfg.showOutcomeBanner ? 1 : 0, "Display", "ShowOutcomeBanner")
    }

    ; ============================================================
    ; [Route]
    ;
    ; Persists the master visibility flag for the route walkthrough
    ; widget (B4 Stage 2), the row count it renders, and the base
    ; font size of the per-zone note row. The route *definition*
    ; itself — the ordered list of zones — lives in a separate
    ; per-profile file at data/routes/<profile>.ini and is managed
    ; by RouteRepository, not by this settings file. The two layers
    ; are kept apart because the route definition is conceptually a
    ; piece of user content (like the run history INIs in data/runs/),
    ; shareable across runners via Import/Export, while these flags
    ; are UI preferences.
    ;
    ; Defaults:
    ;   WidgetVisible = 0  (invisible until the user opts in via
    ;                       the Ctrl+Click arrow on a timer widget)
    ;   RowsVisible   = 5  (clamped to [3, 10] in AppSettings.FromMap)
    ;   NoteFontSize  = 8  (clamped to [6, 16] in AppSettings.FromMap)
    ; ============================================================
    _LoadRoute(cfg)
    {
        ini := this._ini
        cfg.routeWidgetVisible := ini.Read("Route", "WidgetVisible", "0") = "1"

        ; RowsVisible has a bounded domain [3, 10]. Out-of-range
        ; values clamp to the nearest bound (not the default 5) —
        ; a hand-edited "99" clearly means "the user wanted max"
        ; and silently rewriting it to 5 would feel surprising.
        ; Non-numeric / empty values can't be clamped to anything
        ; meaningful and fall back to the default. Mirrors the
        ; AppSettings.FromMap policy so a fresh INI → cfg and
        ; FromMap → cfg paths land on the same value.
        raw := ini.Read("Route", "RowsVisible", "")
        if (raw != "" && IsNumber(raw))
        {
            n := Integer(raw + 0)
            if (n < 3)
                n := 3
            if (n > 10)
                n := 10
            cfg.routeRowsVisible := n
        }

        ; NoteFontSize has a bounded domain [6, 16]. Same
        ; clamp-to-nearest-bound policy as RowsVisible above. Sub-6
        ; pt is unreadable; over-16 pt swamps the widget on small
        ; overlays. The default 8 matches RouteWidget's pre-config
        ; NOTE_FONT_SIZE_BASE constant so a returning user sees no
        ; visual change until they touch the slider in Settings.
        rawFont := ini.Read("Route", "NoteFontSize", "")
        if (rawFont != "" && IsNumber(rawFont))
        {
            n := Integer(rawFont + 0)
            if (n < 6)
                n := 6
            if (n > 16)
                n := 16
            cfg.routeNoteFontSize := n
        }
    }

    _SaveRoute(cfg)
    {
        ini := this._ini
        ini.Write(cfg.routeWidgetVisible ? 1 : 0, "Route", "WidgetVisible")
        ini.Write(cfg.routeRowsVisible,           "Route", "RowsVisible")
        ini.Write(cfg.routeNoteFontSize,          "Route", "NoteFontSize")
    }

    ; ============================================================
    ; [Hotkeys]
    ;
    ; Load merges INI entries into the defaults from AppSettings
    ; (cfg.hotkeys already populated by AppSettings.Defaults).
    ; Three legacy actions are migrated to the unified CycleLayout
    ; so a returning user keeps the hotkey they were already pressing:
    ;
    ;   ToggleSteveLock  -> CycleLayout  (preferred source)
    ;   ToggleMicroLock  -> CycleLayout  (used only if Steve had no bind)
    ;   ToggleOverlay    -> discarded silently
    ;
    ; Save (_SaveHotkeys via _SyncMapSection) removes any INI key
    ; that isn't present in cfg.hotkeys, so the legacy keys disappear
    ; from disk on the next save — no stale state lingers.
    ; ============================================================
    _LoadHotkeys(cfg)
    {
        existing := this._ini.ReadSectionAsMap("Hotkeys")
        if (existing.Count = 0)
            return

        ; Read legacy entries first so we can decide the migration
        ; target before the main loop writes anything. Empty binds
        ; are ignored — a key bound to "" was effectively disabled
        ; and shouldn't shadow the default CycleLayout bind.
        legacySteve   := existing.Has("ToggleSteveLock") ? Trim(String(existing["ToggleSteveLock"])) : ""
        legacyMicro   := existing.Has("ToggleMicroLock") ? Trim(String(existing["ToggleMicroLock"])) : ""
        legacyCycle   := existing.Has("CycleLayout")     ? Trim(String(existing["CycleLayout"]))     : ""

        for action, binding in existing
        {
            ; ToggleOverlay was removed entirely; never restore.
            if (action = "ToggleOverlay")
                continue
            ; The two legacy lock actions are migrated below; skip
            ; the direct copy so the obsolete key doesn't survive
            ; in cfg.hotkeys (the save path mirrors cfg.hotkeys
            ; keys exactly, so leaving them here would write them
            ; back to disk).
            if (action = "ToggleSteveLock" || action = "ToggleMicroLock")
                continue
            cfg.hotkeys[action] := binding
        }

        ; Migration: if the user explicitly bound CycleLayout in
        ; their INI, that wins. Otherwise prefer the Steve bind
        ; (matches the default CycleLayout slot of ^F8 and the
        ; densest layout), then Micro, then leave the default in
        ; place. Bind strings are written verbatim — no AHK-syntax
        ; rewriting; HotkeyFormatter handles the display side.
        if (legacyCycle != "")
            cfg.hotkeys["CycleLayout"] := legacyCycle
        else if (legacySteve != "")
            cfg.hotkeys["CycleLayout"] := legacySteve
        else if (legacyMicro != "")
            cfg.hotkeys["CycleLayout"] := legacyMicro
        ; else: cfg.hotkeys["CycleLayout"] keeps the default from
        ; AppSettings._DefaultHotkeys (currently "^F8").
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
