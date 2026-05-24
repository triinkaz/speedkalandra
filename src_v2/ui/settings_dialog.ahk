; SettingsDialog — lets the user edit the persisted AppSettings.
; Subscribes to Cmd.OpenSettingsRequested to open. The composition
; root constructs it; the dialog calls SettingsRepository.Save on
; OK and publishes the granular change events the runtime needs
; (LogFilePathChanged, HotkeysChanged, VendorRegexesChanged) so
; services can hot-reload without a full app restart.
;
; Sections in the GUI:
;   General           ProfileName, LogFile path
;   AutoStart         Regex (PoE2 is localized — user configures per language)
;   AutoFinalize      Regex
;   VendorRegexes     3 slots (max 250 chars each) for V1/V2/V3 shortcuts
;   Rules             AutoPauseOnFocus, DeathPenaltyEnabled + seconds
;   Layouts (BETA)    LayoutVariant (classic | plus)
;   Display           PbDisplayMode (pb | avg5; live-reloadable), ShowOutcomeBanner (live-reloadable)
;   Route             Per-profile zone list (listbox + ▲▼ reorder + Remove +
;                     non-town dropdown + Add + Visible rows slider +
;                     Import/Export). Rendered only when routeRepo,
;                     routeService and zonesCatalog are all wired; the
;                     dialog accepts those three as optional ctor args so
;                     headless tests that don't care about the route surface
;                     keep working unchanged. The route is loaded from
;                     cfg.profileName at Open() time and edits operate on
;                     an in-memory buffer (_routeZones) until Save persists
;                     via routeRepo.Save + routeService.Refresh.
;
;                     Limitation: the dialog reads cfg.profileName ONCE on
;                     Open. If the user changes the Build field and saves,
;                     the route persists under the NEW profile name; if
;                     they change the Build but don't save, the route
;                     editing buffer is still tied to the OLD profile.
;                     Documented over implementing a live-reload because
;                     this is rare (the user normally settles on a Build
;                     before authoring routes) and the alternative would
;                     require a confirmation flow that's busier than the
;                     edge case warrants.
;   Hotkeys           Every action registered in cfg.hotkeys
;
; AHK v2 gotcha on Gui.Add: "s<size>" and "c<hex>" inline options are
; rejected on Edit (and most input controls). Set font + color via
; g.SetFont(...) BEFORE the Add and the control inherits both. Inline
; "c<hex>" IS accepted on Text/Link/Checkbox/Radio/Button/GroupBox/
; Slider/Tab; inline "s<size>" works on none of them. _AddEdit
; centralizes this contract.


class SettingsDialog
{
    static WINDOW_W := 560
    static WINDOW_H := 620

    _bus           := ""
    _settingsRepo  := ""
    _cfg           := ""
    _headless      := false
    _log           := ""   ; Logger (NullLogger by default). Used to record save failures.
    _gui           := ""
    _ctrls         := ""    ; Map<key, GuiControl>
    _isOpen        := false
    _hotkeyActions := ""    ; Array<actionName> ordered

    ; Route-tab dependencies — optional so legacy / headless test
    ; setups that don't care about the route surface keep working.
    ; All three must be wired together for the ROUTE section to
    ; render and persist; missing any one falls back to "section
    ; hidden, route persistence skipped".
    _routeRepo     := ""    ; RouteRepository — Load/Save route per profile
    _routeService  := ""    ; RouteService    — Refresh() after route save
    _zonesCatalog  := ""    ; ZonesCatalog    — supplies the non-town dropdown
    _routeZones    := ""    ; Array<String>   — in-memory editing buffer

    __New(bus, settingsRepo, cfg, headless := false, log := "",
          routeRepo := "", routeSvc := "", zonesCat := "")
    {
        if !(bus is EventBus)
            throw TypeError("SettingsDialog: 'bus' must be EventBus")
        if !(settingsRepo is SettingsRepository)
            throw TypeError("SettingsDialog: 'settingsRepo' must be SettingsRepository")
        if !(cfg is AppSettings)
            throw TypeError("SettingsDialog: 'cfg' must be AppSettings")

        ; Route deps validated ONLY when provided. Each is independently
        ; optional but if you wire one you must wire all three — the
        ; section won't render without the trio. Mixing in only some
        ; would silently degrade (e.g. listbox loaded but Add button
        ; would have no source for the non-town dropdown), so the
        ; validation is all-or-nothing.
        ; Param names follow the case-collision convention documented in
        ; CLAUDE.md §3: `routeService` would shadow the `RouteService`
        ; class in `is RouteService` checks here (and `zonesCatalog` /
        ; `ZonesCatalog` would collide the same way). The shorter
        ; `routeSvc` / `zonesCat` form is the project convention.
        ; `routeRepo` is fine as-is — it doesn't share the lowercase
        ; form with `RouteRepository`.
        if (routeRepo != "" && !(routeRepo is RouteRepository))
            throw TypeError("SettingsDialog: 'routeRepo' must be RouteRepository")
        if (routeSvc != "" && !(routeSvc is RouteService))
            throw TypeError("SettingsDialog: 'routeService' must be RouteService")
        if (zonesCat != "" && !(zonesCat is ZonesCatalog))
            throw TypeError("SettingsDialog: 'zonesCatalog' must be ZonesCatalog")

        this._bus          := bus
        this._settingsRepo := settingsRepo
        this._cfg          := cfg
        this._headless     := !!headless
        ; Logger is optional (tests construct without one and existing
        ; call sites pre-date the `log` param). Default to NullLogger
        ; so the save-failure warn path is a safe no-op in those
        ; callers. Production wires the real LogService.
        this._log          := (log = "" || !IsObject(log)) ? NullLogger() : log
        this._routeRepo    := routeRepo
        this._routeService := routeSvc
        this._zonesCatalog := zonesCat
        this._routeZones   := []
        this._ctrls        := Map()
        this._hotkeyActions := []

        bus.Subscribe(Commands.OpenSettingsRequested, (data) => this.Open())
    }

    ; True when the trio of route dependencies is wired. Single
    ; predicate used by both _BuildGui (rendering decision) and
    ; _OnSave (persistence decision), so they can't drift apart.
    _HasRouteWiring()
    {
        return IsObject(this._routeRepo)
            && IsObject(this._routeService)
            && IsObject(this._zonesCatalog)
    }

    IsOpen() => this._isOpen

    Open()
    {
        if this._headless
        {
            ; Headless mode still loads the route buffer so tests
            ; can drive Move/Add/Remove/Save without a real GUI.
            this._LoadRouteZonesFromRepo()
            this._isOpen := true
            return true
        }
        if this._isOpen && this._gui
        {
            try this._gui.Show()
            return true
        }
        this._LoadRouteZonesFromRepo()
        this._BuildGui()
        this._isOpen := true
        return true
    }

    Close()
    {
        if this._gui
        {
            try this._gui.Destroy()
            this._gui := ""
            this._ctrls := Map()
        }
        this._isOpen := false
    }

    _BuildGui()
    {
        ; +Resize enabled so the user can stretch the window when
        ; the contents exceed the screen height. The previous fixed
        ; size traded DWM repaint cost during overlay drags for the
        ; window-always-fits guarantee, but once the ROUTE section
        ; (B4 Commit 3) pushed total height past ~1080px on most
        ; displays, close/min/Save/Cancel buttons started landing
        ; outside the viewport. Resize is the lesser cost.
        g := Gui("+AlwaysOnTop +Resize", "SpeedKalandra " . Version.STRING . " - Settings")
        g.BackColor := Theme.Color("bg")
        g.MarginX := 16
        g.MarginY := 14
        g.OnEvent("Close", (*) => this.Close())
        g.OnEvent("Escape", (*) => this.Close())
        this._gui := g

        ; ============ Header ============
        g.SetFont("s12 bold c" Theme.Color("text"), Theme.FONT_UI)
        g.Add("Text", "x16 y14 w520", "SpeedKalandra Settings")

        ; ============ General ============
        y := 50
        this._SectionHeader(g, y, "GENERAL")
        y += 22

        ; UI label is "Build": the persisted field in AppSettings is
        ; still `profileName` (and the ctrl key stays "profileName" so
        ; _OnSave keeps writing to cfg.profileName). The rename is a
        ; vocabulary shift towards the PoE-player audience — a "build"
        ; is the recognizable label for what they pick. AppSettings
        ; / SettingsRepository / DeathLogRepository are unaffected.
        this._Label(g, y, "Build")
        this._ctrls["profileName"] := this._AddEdit(g, 180, y, 360, this._cfg.profileName)
        y += 26

        ; cfg.gamePatch isn't editable in the dialog — it's preserved
        ; internally (default "Unknown") for back-compat with old
        ; saved runs but the user no longer maintains it.

        this._Label(g, y, "PoE2 log (Client.txt)")
        this._ctrls["logFile"] := this._AddEdit(g, 180, y, 280, this._cfg.logFile)
        btnBrowse := g.Add("Button", "x466 y" (y - 2) " w74 h22", "Browse...")
        btnBrowse.OnEvent("Click", (*) => this._OnBrowseLog())
        y += 32

        ; ============ AutoStart ============
        this._SectionHeader(g, y, "AUTO-START (starts run when regex matches in log)")
        y += 22
        this._Label(g, y, "Regex (empty = off)")
        this._ctrls["autoStartRegex"] := this._AddEdit(g, 180, y, 360, this._cfg.autoStartRegex)
        y += 32

        ; ============ AutoFinalize ============
        this._SectionHeader(g, y, "AUTO-FINALIZE (finalizes run when regex matches in log)")
        y += 22
        this._Label(g, y, "Regex (empty = off)")
        this._ctrls["autoFinalizeRegex"] := this._AddEdit(g, 180, y, 360, this._cfg.autoFinalizeRegex)
        y += 32

        ; ============ Vendor Regex Slots ============
        ; Edits limited to 250 chars via "Limit250" (PoE 0.x raised
        ; the in-game vendor filter cap from 50 to 250). V1/V2/V3
        ; buttons in CompactLayoutWidget copy each slot to clipboard
        ; via Ctrl+click.
        this._SectionHeader(g, y, "VENDOR SHORTCUTS (clipboard via V1/V2/V3 in overlay, max 250 chars)")
        y += 22
        Loop 3
        {
            i := A_Index
            this._Label(g, y, "Slot V" i)
            val := (IsObject(this._cfg.vendorRegexes) && this._cfg.vendorRegexes.Has(i))
                   ? this._cfg.vendorRegexes[i]
                   : ""
            this._ctrls["vendorRegex" i] := this._AddEdit(g, 180, y, 360, val, "Limit250")
            y += 26
        }
        y += 6

        ; ============ Rules ============
        this._SectionHeader(g, y, "RULES")
        y += 22
        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        this._ctrls["autoPauseOnFocus"] := g.Add("Checkbox",
            "x180 y" y (this._cfg.autoPauseOnFocus ? " Checked" : ""),
            "Pause when PoE2 loses focus")
        y += 24
        ; Death penalty: UI shows seconds for friendliness;
        ; conversion to ms happens on save. The flag gates both the
        ; live-timer adjustment (LiveReconfigurationHandlers) and the
        ; "Deaths" bar in the post-run plot (RunStatsPlotBuilder), so
        ; the label mentions both surfaces.
        this._ctrls["deathPenaltyEnabled"] := g.Add("Checkbox",
            "x180 y" y (this._cfg.deathPenaltyEnabled ? " Checked" : ""),
            "Apply death penalty to timer and run plot")
        y += 26
        this._Label(g, y, "Penalty (seconds)")
        penaltySec := Round(this._cfg.deathPenaltyMs / 1000)
        this._ctrls["deathPenaltySec"] := this._AddEdit(g, 180, y, 120, penaltySec, "Number")
        y += 36

        ; ============ Layouts (BETA) ============
        ; Opt-in switch between the Classic widgets (default) and the
        ; experimental Plus variants. Read once at boot — a change
        ; here requires a restart, surfaced via SpeedKalandraMsgBox in
        ; _OnSave. See PLUS_LAYOUTS_SPEC.md §1.
        this._SectionHeader(g, y, "LAYOUTS (BETA)")
        y += 22
        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        this._ctrls["layoutVariantPlus"] := g.Add("Checkbox",
            "x180 y" y (this._cfg.layoutVariant = "plus" ? " Checked" : ""),
            'Use experimental "Plus" layouts (requires restart)')
        y += 32

        ; ============ Display ============
        ; Toggle between the all-time PB and the latest-5-run
        ; average for every widget that surfaces a PB-related
        ; value. Hot-reloadable via Evt.PbDisplayModeChanged on
        ; save — no restart, unlike layoutVariant.
        this._SectionHeader(g, y, "DISPLAY")
        y += 22
        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        this._ctrls["pbDisplayModeAvg5"] := g.Add("Checkbox",
            "x180 y" y (this._cfg.pbDisplayMode = "avg5" ? " Checked" : ""),
            "Show average of last 5 runs instead of PB")
        y += 24
        ; Opt-out for the transient run-outcome banner. Default
        ; checked so the "did it save?" feedback gap is closed for
        ; new users; speedrunners who find the banner distracting
        ; flip it off here. Live-reloadable via
        ; Evt.ShowOutcomeBannerChanged on save — no restart.
        this._ctrls["showOutcomeBanner"] := g.Add("Checkbox",
            "x180 y" y (this._cfg.showOutcomeBanner ? " Checked" : ""),
            "Show run-outcome banner after each run")
        y += 32

        ; ============ Route ============
        ; The section renders only when routeRepo + routeService +
        ; zonesCatalog are all wired (production composition root
        ; provides them; old headless test setups don't). When
        ; skipped, HOTKEYS follows immediately after DISPLAY with
        ; no visible gap — the y cursor flows straight through.
        if this._HasRouteWiring()
            y := this._BuildRouteSection(g, y)

        ; ============ Hotkeys ============
        this._SectionHeader(g, y, "HOTKEYS")
        y += 22

        ; Hint about the capture UX — the Edit field is ReadOnly;
        ; the user only interacts via Capture + Clear buttons.
        g.SetFont("s8 c" Theme.Color("muted"), Theme.FONT_UI)
        g.Add("Text", "x16 y" y " w520",
            "Click 'Capture' to record a key combo (Esc cancels). 'Clear' to unbind.")
        y += 18

        ; Sort actions alphabetically
        this._hotkeyActions := []
        for action, _ in this._cfg.hotkeys
            this._hotkeyActions.Push(action)
        this._SortArray(this._hotkeyActions)

        for _, action in this._hotkeyActions
        {
            this._Label(g, y, action)
            ; Edit is ReadOnly. Display in human format ("Ctrl+Alt+F")
            ; via HotkeyFormatter; interaction only through Capture/
            ; Clear. _OnSave converts back to AHK syntax ("^!f") at
            ; persist time.
            displayVal := HotkeyFormatter.ToHuman(this._cfg.GetHotkey(action))
            this._ctrls["hk_" action] := this._AddEdit(g, 180, y, 200, displayVal, "ReadOnly")

            ; Capture: grabs the next combo via InputHook.
            g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
            btnCap := g.Add("Button", "x384 y" (y-1) " w60 h22", "Capture")
            btnCap.OnEvent("Click", this._MakeCaptureHandler(action))
            this._ctrls["btn_capture_" action] := btnCap

            ; Clear: unbinds the hotkey (empty edit).
            btnClr := g.Add("Button", "x448 y" (y-1) " w50 h22", "Clear")
            btnClr.OnEvent("Click", this._MakeClearHandler(action))
            this._ctrls["btn_clear_" action] := btnClr

            y += 24
        }
        y += 12

        ; ============ Buttons ============
        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        btnSave := g.Add("Button", "x180 y" y " w120 h28", "Save")
        btnSave.OnEvent("Click", (*) => this._OnSave())
        btnCancel := g.Add("Button", "x310 y" y " w120 h28", "Cancel")
        btnCancel.OnEvent("Click", (*) => this.Close())

        finalH := y + 50
        ; Cap at screen height minus a margin for taskbar + window
        ; decorations. Without this, finalH can exceed the display
        ; height (the ROUTE section pushed B4 Commit 3 right up to
        ; the boundary) and Windows places the window with its
        ; bottom — or top, if the user later moves it — outside the
        ; viewport, hiding either Save/Cancel or close/minimize.
        ; +Resize on the Gui (set in _BuildGui header) lets the user
        ; stretch back if the cap clipped useful content.
        maxH := A_ScreenHeight - 80
        if (finalH > maxH)
            finalH := maxH
        ; Center forces the window to start centered on the active
        ; monitor instead of Windows' default top-left placement,
        ; which on a maxed-out finalH means controls below the
        ; centerline are at risk regardless of placement — but
        ; centering at least guarantees the title bar is visible.
        g.Show("Center w" SettingsDialog.WINDOW_W " h" finalH)
    }

    ; Sets the font (Theme.InputFont) before adding the Edit so the
    ; control inherits it — the inline "s<size>" / "c<hex>" options
    ; that AHK v2 rejects on Edit are never passed here.
    ;
    ; extraOpts accepts options valid for Edit ("Number", "ReadOnly",
    ; "Multi", "Password", etc.). NEVER pass s<n> or c<hex>.
    ;
    ; Height is fixed at h22 so a long value (like a full Steam path
    ; in logFile) doesn't make the Edit auto-expand into multiple
    ; lines and overlap the field below.
    _AddEdit(g, x, y, w, value, extraOpts := "")
    {
        g.SetFont(Theme.InputFont(), Theme.FONT_UI)
        opts := "x" x " y" y " w" w " h22 " Theme.InputBg()
        if (extraOpts != "")
            opts .= " " extraOpts
        return g.Add("Edit", opts, value)
    }

    _SectionHeader(g, y, text)
    {
        g.SetFont("s9 bold c" Theme.Color("subtle"), Theme.FONT_UI)
        g.Add("Text", "x16 y" y " w520", text)
    }

    _Label(g, y, text)
    {
        g.SetFont("s9 c" Theme.Color("muted"), Theme.FONT_UI)
        g.Add("Text", "x32 y" (y + 2) " w140", text)
    }

    _OnBrowseLog()
    {
        try
        {
            ; Local `file` collides case-insensitively with the
            ; built-in `File` class; use `selectedFile`.
            selectedFile := FileSelect(1, this._cfg.logFile, "Select Client.txt", "Logs (*.txt)")
            if (selectedFile != "")
                this._ctrls["logFile"].Value := selectedFile
        }
    }

    _OnSave()
    {
        ; Snapshot the in-memory cfg BEFORE mutating any field. If
        ; the save fails, _PersistAndPublishCfg restores from this
        ; snapshot so the in-memory this._cfg matches what's on
        ; disk — services that hold a reference to this._cfg won't
        ; observe ghost values that never landed on disk.
        snapshot := SettingsDialog._SnapshotMutableCfg(this._cfg)

        cfg := this._cfg
        cfg.profileName := this._ctrls["profileName"].Value
        ; gamePatch keeps whatever was already in cfg (default
        ; "Unknown" on a fresh install); the dialog doesn't expose it.

        cfg.logFile           := this._ctrls["logFile"].Value
        cfg.autoStartRegex    := this._ctrls["autoStartRegex"].Value
        cfg.autoFinalizeRegex := this._ctrls["autoFinalizeRegex"].Value

        ; Vendor regex slots — defensive 250-char clamp matches the
        ; Edit's Limit250.
        vrOut := ["", "", ""]
        Loop 3
        {
            i := A_Index
            if this._ctrls.Has("vendorRegex" i)
            {
                v := this._ctrls["vendorRegex" i].Value
                if (StrLen(v) > 250)
                    v := SubStr(v, 1, 250)
                vrOut[i] := v
            }
        }
        cfg.vendorRegexes := vrOut

        cfg.autoPauseOnFocus := this._ctrls["autoPauseOnFocus"].Value = 1

        ; Death penalty: UI uses seconds, persists as ms. Empty or
        ; invalid input falls back to the 150 s default.
        cfg.deathPenaltyEnabled := this._ctrls["deathPenaltyEnabled"].Value = 1
        try
        {
            secs := Integer(this._ctrls["deathPenaltySec"].Value + 0)
            cfg.deathPenaltyMs := secs >= 0 ? secs * 1000 : 0
        }
        catch
            cfg.deathPenaltyMs := 150000

        ; Layout variant (BETA opt-in). Defensive ternary: anything
        ; other than a checked box maps to "classic". AppSettings and
        ; SettingsRepository both normalize on load too, so a typo
        ; here would round-trip through "classic" anyway, but staying
        ; defensive keeps the in-memory cfg unambiguous.
        cfg.layoutVariant := (this._ctrls.Has("layoutVariantPlus")
            && this._ctrls["layoutVariantPlus"].Value = 1) ? "plus" : "classic"

        ; Display mode: "avg5" when the box is checked, "pb"
        ; otherwise. Same defensive ternary pattern as above so an
        ; un-built dialog (headless) lands on the safe default.
        cfg.pbDisplayMode := (this._ctrls.Has("pbDisplayModeAvg5")
            && this._ctrls["pbDisplayModeAvg5"].Value = 1) ? "avg5" : "pb"

        ; Outcome banner opt-out: defaults to true on a headless
        ; (no-ctrls) save so a programmatic caller doesn't silently
        ; flip the user's preference off. Same defensive pattern.
        cfg.showOutcomeBanner := this._ctrls.Has("showOutcomeBanner")
            ? (this._ctrls["showOutcomeBanner"].Value = 1)
            : cfg.showOutcomeBanner

        ; Route rows visible: read from slider, clamp [3,10]
        ; defensively. Same fallback-to-existing pattern as the
        ; checkboxes above so a headless save (no GUI built) doesn't
        ; clobber the value with a hardcoded default.
        if this._ctrls.Has("routeRowsVisible")
            cfg.routeRowsVisible := this._ClampRows(
                this._ctrls["routeRowsVisible"].Value)

        ; Hotkeys: user types in human format ("Ctrl+Alt+F");
        ; HotkeyFormatter.ToAhk converts to internal syntax ("^!f")
        ; before persisting. Old-format input passes through as-is.
        for _, action in this._hotkeyActions
        {
            ctrlKey := "hk_" action
            if this._ctrls.Has(ctrlKey)
            {
                rawVal := Trim(this._ctrls[ctrlKey].Value)
                cfg.hotkeys[action] := HotkeyFormatter.ToAhk(rawVal)
            }
        }

        ; Persist + publish. On failure, _PersistAndPublishCfg
        ; restores this._cfg from the snapshot, logs, shows a
        ; MsgBox, and returns false — no change events published,
        ; no success TrayTip, dialog stays open.
        this._PersistAndPublishCfg(cfg, snapshot)
    }

    ; ============================================================
    ; Snapshot / Restore / PersistAndPublish
    ; ============================================================
    ;
    ; Extracted from _OnSave to isolate the parts that don't depend
    ; on this._ctrls (GUI-bound, populated only after _BuildGui).
    ; Headless tests construct the dialog with headless=true — the
    ; GUI isn't built, but these three methods stay reachable.
    ;
    ; Contract:
    ;   - _SnapshotMutableCfg(cfg) returns a Map carrying the fields
    ;     that _OnSave mutates (deep-copying the Array/Map ones so a
    ;     later mutation in this._cfg doesn't leak through the
    ;     reference).
    ;   - _RestoreCfgFromSnapshot(snapshot) overwrites this._cfg's
    ;     mutable fields with the snapshot values. Used by
    ;     _PersistAndPublishCfg on save failure.
    ;   - _PersistAndPublishCfg(cfg, snapshot) saves via the repo;
    ;     on success publishes the diff events vs snapshot and
    ;     returns true; on failure restores from snapshot, logs +
    ;     MsgBox, and returns false (no event publishes, no success
    ;     TrayTip, dialog stays open).

    static _SnapshotMutableCfg(cfg)
    {
        ; Deep-copies vendorRegexes (Array) and hotkeys (Map);
        ; primitives don't need copying. layoutVariant captured
        ; here too so the success path's MsgBox is driven from
        ; the snapshot, not from a re-read of cfg (which might
        ; have been restored mid-flight).
        return Map(
            "profileName",          cfg.profileName,
            "logFile",              cfg.logFile,
            "autoStartRegex",       cfg.autoStartRegex,
            "autoFinalizeRegex",    cfg.autoFinalizeRegex,
            "vendorRegexes",        SettingsDialog._CloneStringArray(cfg.vendorRegexes),
            "autoPauseOnFocus",     cfg.autoPauseOnFocus,
            "deathPenaltyEnabled",  cfg.deathPenaltyEnabled,
            "deathPenaltyMs",       cfg.deathPenaltyMs,
            "layoutVariant",        cfg.layoutVariant,
            "pbDisplayMode",        cfg.pbDisplayMode,
            "showOutcomeBanner",    cfg.showOutcomeBanner,
            "routeRowsVisible",     cfg.routeRowsVisible,
            "hotkeys",              SettingsDialog._CloneStringMap(cfg.hotkeys)
        )
    }

    _RestoreCfgFromSnapshot(snapshot)
    {
        cfg := this._cfg
        cfg.profileName         := snapshot["profileName"]
        cfg.logFile             := snapshot["logFile"]
        cfg.autoStartRegex      := snapshot["autoStartRegex"]
        cfg.autoFinalizeRegex   := snapshot["autoFinalizeRegex"]
        cfg.vendorRegexes       := snapshot["vendorRegexes"]    ; the deep clone from snapshot
        cfg.autoPauseOnFocus    := snapshot["autoPauseOnFocus"]
        cfg.deathPenaltyEnabled := snapshot["deathPenaltyEnabled"]
        cfg.deathPenaltyMs      := snapshot["deathPenaltyMs"]
        cfg.layoutVariant       := snapshot["layoutVariant"]
        cfg.pbDisplayMode       := snapshot["pbDisplayMode"]
        cfg.showOutcomeBanner   := snapshot["showOutcomeBanner"]
        cfg.routeRowsVisible    := snapshot["routeRowsVisible"]
        cfg.hotkeys             := snapshot["hotkeys"]          ; the deep clone from snapshot
    }

    _PersistAndPublishCfg(cfg, snapshot)
    {
        ; Save with best-effort rollback (see SettingsRepository
        ; .Save header). On any throw we restore the in-memory cfg
        ; from snapshot so services that hold a reference to
        ; this._cfg don't observe ghost values that never landed
        ; on disk — the MsgBox honestly reports "nothing was
        ; persisted; in-memory state restored".
        try
        {
            this._settingsRepo.Save(cfg)
        }
        catch as ex
        {
            this._RestoreCfgFromSnapshot(snapshot)
            try this._log.Warn("Settings save failed: " . ex.Message
                . " | What: " . (ex.HasOwnProp("What") ? ex.What : "?")
                . " | Line: " . (ex.HasOwnProp("Line") ? ex.Line : "?"),
                "SettingsDialog")
            try SpeedKalandraMsgBox(
                "Failed to save settings to disk.`n`n"
                . "Reason: " . ex.Message . "`n`n"
                . "Your changes were NOT persisted, and in-memory "
                . "state has been restored to its pre-save values. "
                . "See the Reason above for next steps — most save "
                . "failures resolve with a retry, but a rollback "
                . "failure (rare) names a preserved .pre-save file "
                . "and requires manual recovery. Details in "
                . "data\\speedkalandra.log.",
                "Save failed",
                "IconX")
            return false   ; no publishes, no success TrayTip, dialog stays open
        }

        ; Success path: publish diff events comparing snapshot vs cfg.

        ; logFile change → publish so the composition root can
        ; restart LogMonitor against the new path. Empty new path is
        ; also published (the user may want monitoring disabled).
        if (Trim(snapshot["logFile"]) != Trim(cfg.logFile))
        {
            try this._bus.Publish(Events.LogFilePathChanged, Map(
                "oldPath", snapshot["logFile"],
                "newPath", cfg.logFile))
        }
        ; hotkeys change → publish so HotkeyService can rebind
        ; without a full app reload. Send a defensive copy of the
        ; new map so the handler can't accidentally mutate cfg.hotkeys.
        if !SettingsDialog._StringMapsEqual(snapshot["hotkeys"], cfg.hotkeys)
        {
            try this._bus.Publish(Events.HotkeysChanged, Map(
                "oldHotkeys", snapshot["hotkeys"],
                "newHotkeys", SettingsDialog._CloneStringMap(cfg.hotkeys)))
        }
        ; vendor regex change → publish so CompactLayoutWidget can
        ; refresh its V1/V2/V3 button labels (filled vs empty)
        ; without a full app reload. Send a copy of the new array.
        if !SettingsDialog._StringArraysEqual(snapshot["vendorRegexes"], cfg.vendorRegexes)
        {
            try this._bus.Publish(Events.VendorRegexesChanged, Map(
                "oldRegexes", snapshot["vendorRegexes"],
                "newRegexes", SettingsDialog._CloneStringArray(cfg.vendorRegexes)))
        }
        ; Layout variant change → no event published. Widgets are
        ; instantiated once at boot, so a hot-reload would have to
        ; tear down GUI handles, re-position from INI, and re-wire
        ; bus subscriptions — too much complexity for a flag a user
        ; toggles a handful of times in the life of the app. A MsgBox
        ; tells them to restart instead.
        if (snapshot["layoutVariant"] != cfg.layoutVariant)
        {
            targetLabel := (cfg.layoutVariant = "plus") ? "Plus (experimental)" : "Classic"
            try SpeedKalandraMsgBox(
                "Layout variant changed to " . targetLabel . ".`n`n"
                . "Restart SpeedKalandra to apply.",
                "Layout change",
                "Iconi")
        }
        ; PB display mode change → publish so every widget that
        ; surfaces a PB-related value re-renders against the new
        ; source. Unlike layoutVariant, this is hot-reloadable:
        ; widgets keep their GUI handles and only reset their
        ; derived caches (timer colour, PB chip text) before the
        ; next Refresh writes the new mode's values.
        if (snapshot["pbDisplayMode"] != cfg.pbDisplayMode)
        {
            try this._bus.Publish(Events.PbDisplayModeChanged, Map(
                "oldMode", snapshot["pbDisplayMode"],
                "newMode", cfg.pbDisplayMode))
        }
        ; Outcome banner toggle — the widget subscribes so it can
        ; clear any banner that happens to be on screen when the
        ; user turns the feature OFF. Turning it ON has no
        ; immediate visible effect (next outcome surfaces it); we
        ; still publish on either direction so subscribers can
        ; rely on the event as a state-change signal.
        if (!!snapshot["showOutcomeBanner"] != !!cfg.showOutcomeBanner)
        {
            try this._bus.Publish(Events.ShowOutcomeBannerChanged, Map(
                "oldValue", !!snapshot["showOutcomeBanner"],
                "newValue", !!cfg.showOutcomeBanner))
        }

        try TrayTip("SpeedKalandra", "Settings saved.", "Mute")

        ; Save the route after settings. Route persistence is
        ; independent of the settings file (different repo, different
        ; INI), so a route failure here doesn't roll back the
        ; settings save above — the user gets a separate warning and
        ; the settings change still landed. routeService.Refresh
        ; (inside _SaveRouteIfWired) publishes RouteChanged so the
        ; live widget re-renders against both the new zone list AND
        ; the new cfg.routeRowsVisible without needing a dedicated
        ; rowsVisible event.
        this._SaveRouteIfWired()

        this.Close()
        return true
    }

    ; Defensive Map<string, string> snapshot/diff helpers for
    ; cfg.hotkeys. We need a copy before the loop mutates cfg.hotkeys
    ; and an equality check after so we know whether to publish
    ; Evt.HotkeysChanged. Empty input returns an empty Map / true so
    ; callers don't need a null check.
    static _CloneStringMap(m)
    {
        out := Map()
        if !(m is Map)
            return out
        for k, v in m
            out[k] := String(v)
        return out
    }

    static _StringMapsEqual(a, b)
    {
        if !(a is Map) || !(b is Map)
            return false
        if (a.Count != b.Count)
            return false
        for k, v in a
        {
            if !b.Has(k)
                return false
            if (String(v) != String(b[k]))
                return false
        }
        return true
    }

    ; Same idea as _CloneStringMap/_StringMapsEqual but for
    ; cfg.vendorRegexes (Array<string>, 3 fixed slots). Kept separate
    ; because Array and Map iterate differently in AHK v2.
    static _CloneStringArray(arr)
    {
        out := []
        if !(arr is Array)
            return out
        for _, v in arr
            out.Push(String(v))
        return out
    }

    static _StringArraysEqual(a, b)
    {
        if !(a is Array) || !(b is Array)
            return false
        if (a.Length != b.Length)
            return false
        for i, v in a
        {
            if (String(v) != String(b[i]))
                return false
        }
        return true
    }

    ; Simple bubble sort (small list ~10 hotkeys)
    _SortArray(arr)
    {
        n := arr.Length
        Loop n - 1
        {
            i := A_Index
            Loop n - i
            {
                j := A_Index
                if (StrCompare(arr[j], arr[j + 1]) > 0)
                {
                    tmp := arr[j]
                    arr[j] := arr[j + 1]
                    arr[j + 1] := tmp
                }
            }
        }
    }

    ; Hotkey capture flow:
    ;   1. User clicks "Capture" next to a binding
    ;   2. Button label flips to "Press..." and global input is
    ;      suppressed
    ;   3. User presses the combo (e.g. Ctrl+Alt+G)
    ;   4. InputHook.OnKeyDown captures the NON-modifier key; modifier
    ;      state is read via GetKeyState at that exact moment
    ;   5. Edit is updated with the combo in human-readable form
    ;
    ; Cancel paths:
    ;   - Esc alone (no modifier) cancels
    ;   - Esc + modifier (Ctrl+Esc, etc.) is a valid bind
    ;   - 10 s timeout cancels silently
    ;
    ; _MakeCaptureHandler exists because fat-arrow closures inside a
    ; loop don't capture the iteration variable's value correctly
    ; (every closure picks up the last assignment). Wrapping in a
    ; method gives each call a fresh scope so `action` binds correctly.
    _MakeCaptureHandler(action)
    {
        return (*) => this._OnCaptureHotkey(action)
    }

    ; Clear button: empties the edit; _OnSave then persists an empty
    ; string, which unbinds the hotkey.
    _MakeClearHandler(action)
    {
        return (*) => this._OnClearHotkey(action)
    }

    _OnClearHotkey(action)
    {
        editKey := "hk_" action
        if !this._ctrls.Has(editKey)
            return
        try this._ctrls[editKey].Value := ""
    }

    _OnCaptureHotkey(action)
    {
        editKey := "hk_" action
        btnKey  := "btn_capture_" action
        if !this._ctrls.Has(editKey) || !this._ctrls.Has(btnKey)
            return

        ; Locals `edit` / `btn` collide case-insensitively with the
        ; `Edit` and `Button` Gui-control classes; use Ctrl suffixes.
        editCtrl := this._ctrls[editKey]
        btnCtrl  := this._ctrls[btnKey]

        originalLabel := "Capture"
        try originalLabel := btnCtrl.Text
        try btnCtrl.Text := "Press..."

        ; State captured by reference by the OnKeyDown handler.
        ; Object literal for mutation by reference (a Map would also work).
        state := { key: "", mods: "", cancelled: false }

        try
        {
            ih := InputHook("T10")          ; 10s timeout, suppresses input by default
            ih.KeyOpt("{All}", "N")         ; notify on all key down
            ih.OnKeyDown := (hookObj, vk, sc) => this._HandleCaptureKey(hookObj, vk, sc, state)
            ih.Start()
            ih.Wait()
        }
        catch as ex
        {
            OutputDebug("SettingsDialog._OnCaptureHotkey failed: " ex.Message)
        }

        ; Restore button (defensive against dialog closed mid-capture)
        try btnCtrl.Text := originalLabel

        if (state.cancelled || state.key = "")
            return

        ; Builds AHK-syntax hotkey and converts to human for display
        ahkKey := state.mods . state.key
        try editCtrl.Value := HotkeyFormatter.ToHuman(ahkKey)
    }

    ; InputHook.OnKeyDown callback. Runs on the hook thread.
    ; Updates `state` (passed by reference) and calls ih.Stop when it
    ; captures a valid key.
    _HandleCaptureKey(ih, vk, sc, state)
    {
        ; Modifiers alone are NOT a valid key — we expect a "real" key
        ; while modifiers are held.
        ;   0x10 = Shift,   0xA0/A1 = LShift/RShift
        ;   0x11 = Ctrl,    0xA2/A3 = LCtrl/RCtrl
        ;   0x12 = Alt,     0xA4/A5 = LAlt/RAlt
        ;   0x5B/5C = LWin/RWin
        if (vk = 0x10 || vk = 0xA0 || vk = 0xA1
         || vk = 0x11 || vk = 0xA2 || vk = 0xA3
         || vk = 0x12 || vk = 0xA4 || vk = 0xA5
         || vk = 0x5B || vk = 0x5C)
            return

        ; PURE Esc (no modifier) cancels. Esc+modifier (Ctrl+Esc, etc)
        ; is a valid bind — falls through to the normal path below.
        if (vk = 0x1B)
        {
            anyMod := GetKeyState("Ctrl", "P") || GetKeyState("Alt", "P")
                   || GetKeyState("Shift", "P")
                   || GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
            if !anyMod
            {
                state.cancelled := true
                ih.Stop()
                return
            }
        }

        ; Captures the key name + modifier state at the exact moment.
        ; "vkXXscYY" is the most robust way to get the name
        ; (distinguishes NumpadEnter vs Enter, etc).
        state.key := GetKeyName(Format("vk{:X}sc{:X}", vk, sc))
        state.mods := ""
        if GetKeyState("Ctrl", "P")
            state.mods .= "^"
        if GetKeyState("Alt", "P")
            state.mods .= "!"
        if GetKeyState("Shift", "P")
            state.mods .= "+"
        if GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
            state.mods .= "#"

        ih.Stop()
    }

    ; ============================================================
    ; Route section — build, handlers, persistence helpers
    ; ============================================================
    ;
    ; The ROUTE section is rendered by _BuildRouteSection only when
    ; routeRepo + routeService + zonesCatalog are all wired (see
    ; _HasRouteWiring). When the section is hidden, none of the
    ; methods below execute either, so headless tests without the
    ; trio see the same lifecycle as a pre-feature build.
    ;
    ; Editing model:
    ;   - Open() loads the active route from routeRepo into the
    ;     _routeZones buffer (Array<String>).
    ;   - Move/Add/Remove handlers mutate the buffer and refresh the
    ;     ListBox.
    ;   - _SaveRouteIfWired persists the buffer back to disk via
    ;     routeRepo.Save (full overwrite, not incremental) and
    ;     publishes RouteChanged through routeService.Refresh so the
    ;     live RouteWidget re-renders.
    ;
    ; Cancel path: closing without Save discards every buffer edit
    ;   — the dialog never touches disk and the in-memory cfg
    ;   field for routeRowsVisible stays untouched.

    _BuildRouteSection(g, y)
    {
        profileLabel := IsObject(this._cfg) ? this._cfg.profileName : ""
        headerText := "ROUTE"
            . (profileLabel != "" ? " (build: " . profileLabel . ")" : "")
        this._SectionHeader(g, y, headerText)

        ; Listbox + side button column.
        items := this._BuildRouteListBoxItems()
        ; Width 420 leaves an 80px column on the right for the
        ; three reorder/remove buttons. Listbox height h100 shows
        ; ~5 rows at the default font; the slider below already
        ; lets the user control how many rows the LIVE widget
        ; surfaces, so the editor's compact view is acceptable.
        ; Originally h140 in the first draft of Commit 3 but that
        ; pushed the dialog past 1080p screens — see _BuildGui
        ; header note on the +Resize switch.
        this._ctrls["routeListBox"] := g.Add("ListBox",
            "x32 y" (y + 22) " w420 h100",
            items)
        if (items.Length > 0)
            try this._ctrls["routeListBox"].Choose(1)

        ; Right-side button column. Three buttons stacked with
        ; small gaps; ▲ at the top, ▼ just below, Remove at the
        ; bottom (aligned to the listbox's bottom edge so the
        ; deletion control is visually anchored). Heights h28
        ; (was h36) so all three fit in the shrunk h100 listbox.
        g.SetFont("s10 c" Theme.Color("text"), Theme.FONT_UI)
        btnUp := g.Add("Button", "x460 y" (y + 22) " w80 h28", "▲")
        btnUp.OnEvent("Click", (*) => this._OnRouteMoveUp())
        this._ctrls["routeBtnUp"] := btnUp

        btnDown := g.Add("Button", "x460 y" (y + 54) " w80 h28", "▼")
        btnDown.OnEvent("Click", (*) => this._OnRouteMoveDown())
        this._ctrls["routeBtnDown"] := btnDown

        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        btnDel := g.Add("Button", "x460 y" (y + 94) " w80 h28", "Remove")
        btnDel.OnEvent("Click", (*) => this._OnRouteRemove())
        this._ctrls["routeBtnRemove"] := btnDel

        ; Move past the listbox row.
        y += 22 + 100 + 8

        ; Add-zone row: label + non-town dropdown + Add button.
        this._Label(g, y, "Add zone")
        nonTowns := this._BuildNonTownZoneNames()
        g.SetFont(Theme.InputFont(), Theme.FONT_UI)
        dd := g.Add("DropDownList",
            "x180 y" y " w280 " Theme.InputBg(),
            nonTowns)
        if (nonTowns.Length > 0)
            try dd.Choose(1)
        this._ctrls["routeAddDropdown"] := dd

        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        btnAdd := g.Add("Button", "x466 y" (y - 1) " w74 h24", "+ Add")
        btnAdd.OnEvent("Click", (*) => this._OnRouteAdd())
        this._ctrls["routeBtnAdd"] := btnAdd

        y += 30

        ; Visible-rows slider (3-10).
        this._Label(g, y, "Visible rows")
        rows := this._ClampRows(this._cfg.routeRowsVisible)
        ; Slider has a built-in tooltip but it's a separate window
        ; that pops over the dialog — disorienting on a settings
        ; surface. Use a live-updating text label to the right of
        ; the slider track instead.
        slider := g.Add("Slider",
            "x180 y" y " w240 h22 Range3-10 Page1 TickInterval1",
            rows)
        slider.OnEvent("Change", (*) => this._OnRouteRowsChanged())
        this._ctrls["routeRowsVisible"] := slider

        g.SetFont("s9 bold c" Theme.Color("text"), Theme.FONT_UI)
        rowsLabel := g.Add("Text", "x425 y" (y + 2) " w20", String(rows))
        this._ctrls["routeRowsValueLabel"] := rowsLabel
        g.SetFont("s9 c" Theme.Color("muted"), Theme.FONT_UI)
        g.Add("Text", "x450 y" (y + 2) " w80", "(3 - 10)")

        y += 30

        ; Import / Export buttons.
        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        btnImport := g.Add("Button", "x180 y" y " w120 h28", "Import...")
        btnImport.OnEvent("Click", (*) => this._OnRouteImport())
        this._ctrls["routeBtnImport"] := btnImport

        btnExport := g.Add("Button", "x310 y" y " w120 h28", "Export...")
        btnExport.OnEvent("Click", (*) => this._OnRouteExport())
        this._ctrls["routeBtnExport"] := btnExport

        y += 40
        return y
    }

    ; Loads the active route from disk into _routeZones. Called from
    ; Open(). Silently leaves the buffer empty if route deps aren't
    ; wired — the section is hidden in that case anyway.
    _LoadRouteZonesFromRepo()
    {
        this._routeZones := []
        if !this._HasRouteWiring()
            return
        if !IsObject(this._cfg)
            return
        try
        {
            ; Param name `loaded` to avoid the `route`/`Route` case
            ; collision (CLAUDE.md §3).
            loaded := this._routeRepo.Load(this._cfg.profileName)
            if (loaded is Route)
                this._routeZones := loaded.GetZones()
        }
    }

    ; Rebuilds the listbox from _routeZones. selectIndex (1-based)
    ; is the row to focus after the rebuild; 0 means "no selection".
    _RefreshRouteListBox(selectIndex := 0)
    {
        if !this._ctrls.Has("routeListBox")
            return
        lb := this._ctrls["routeListBox"]
        items := this._BuildRouteListBoxItems()
        try
        {
            lb.Delete()
            if (items.Length > 0)
                lb.Add(items)
            if (selectIndex >= 1 && selectIndex <= items.Length)
                lb.Choose(selectIndex)
        }
    }

    ; Format the zone list for the ListBox. Numbering the rows
    ; (" 1. Zone", " 2. Zone") makes reorder feedback immediate
    ; — after a Move, the user sees the new position number, not
    ; just a reordered name.
    _BuildRouteListBoxItems()
    {
        items := []
        if !(this._routeZones is Array)
            return items
        for i, zone in this._routeZones
            items.Push(Format("{:2d}. {}", i, zone))
        return items
    }

    ; Reads the catalog, filters out town entries (Q5 decision:
    ; routes don't include towns), and returns sorted display names
    ; for the Add-zone dropdown.
    _BuildNonTownZoneNames()
    {
        out := []
        if !IsObject(this._zonesCatalog)
            return out
        for _, z in this._zonesCatalog.All()
        {
            if !z.isTown
                out.Push(z.name)
        }
        this._SortArray(out)
        return out
    }

    ; The four handlers accept an optional idxOverride so tests
    ; can drive them without a real ListBox — in headless mode
    ; the dialog has no _ctrls["routeListBox"], so reading
    ; selection from it would short-circuit every test. Production
    ; always calls without the override (default -1), which makes
    ; the handler read the live listbox selection as before.

    _OnRouteMoveUp(idxOverride := -1)
    {
        idx := this._ResolveRouteIdx(idxOverride)
        if (idx < 2 || idx > this._routeZones.Length)
            return
        ; AHK arrays are 1-based; idx is also 1-based here (from
        ; ListBox.Value), so swap with idx-1.
        tmp := this._routeZones[idx - 1]
        this._routeZones[idx - 1] := this._routeZones[idx]
        this._routeZones[idx] := tmp
        this._RefreshRouteListBox(idx - 1)
    }

    _OnRouteMoveDown(idxOverride := -1)
    {
        idx := this._ResolveRouteIdx(idxOverride)
        if (idx < 1 || idx >= this._routeZones.Length)
            return
        tmp := this._routeZones[idx + 1]
        this._routeZones[idx + 1] := this._routeZones[idx]
        this._routeZones[idx] := tmp
        this._RefreshRouteListBox(idx + 1)
    }

    _OnRouteRemove(idxOverride := -1)
    {
        idx := this._ResolveRouteIdx(idxOverride)
        if (idx < 1 || idx > this._routeZones.Length)
            return
        this._routeZones.RemoveAt(idx)
        ; Try to select the same position. If we removed the
        ; LAST item, select the new last (or 0 = no selection).
        newSel := idx > this._routeZones.Length
                ? this._routeZones.Length
                : idx
        this._RefreshRouteListBox(newSel)
    }

    _OnRouteAdd(zoneOverride := "")
    {
        zoneName := zoneOverride
        if (zoneName = "")
        {
            if !this._ctrls.Has("routeAddDropdown")
                return
            zoneName := Trim(this._ctrls["routeAddDropdown"].Text)
        }
        if (Trim(String(zoneName)) = "")
            return
        this._routeZones.Push(String(zoneName))
        this._RefreshRouteListBox(this._routeZones.Length)
    }

    ; Reads the route ListBox selection; returns 0 when there's no
    ; listbox (headless) or no selection. Used by all four route
    ; handlers above so the override semantics stay symmetric.
    _ResolveRouteIdx(override)
    {
        if (override >= 0)
            return Integer(override)
        if !this._ctrls.Has("routeListBox")
            return 0
        try
            return Integer(this._ctrls["routeListBox"].Value)
        catch
            return 0
    }

    _OnRouteRowsChanged()
    {
        if !this._ctrls.Has("routeRowsVisible")
            return
        if !this._ctrls.Has("routeRowsValueLabel")
            return
        try this._ctrls["routeRowsValueLabel"].Value :=
            String(this._ctrls["routeRowsVisible"].Value)
    }

    _OnRouteImport()
    {
        if !this._HasRouteWiring()
            return
        try
        {
            ; Local `file` collides with built-in `File` class —
            ; use `selectedFile`.
            selectedFile := FileSelect(1, ,
                "Import route from INI", "Route INI (*.ini)")
            if (selectedFile = "")
                return
            ok := this._routeRepo.ImportFromFile(
                selectedFile, this._cfg.profileName)
            if !ok
            {
                try SpeedKalandraMsgBox(
                    "Could not import route from`n`n  " . selectedFile . "`n`n"
                    . "Check that the file is a valid SpeedKalandra route "
                    . "INI (schema: [Route] zones=A|B|C, encoding UTF-16 LE BOM).",
                    "Import failed", "IconX")
                return
            }
            ; Reload the in-memory buffer from the freshly
            ; imported file so the listbox reflects what was
            ; written. Edits made before the import are silently
            ; discarded — import is a full overwrite by design.
            this._LoadRouteZonesFromRepo()
            this._RefreshRouteListBox(1)
            ; Refresh the live widget too so a successful import
            ; surfaces in the overlay without waiting for Save.
            try this._routeService.Refresh()
        }
    }

    _OnRouteExport()
    {
        if !this._HasRouteWiring()
            return
        if (this._routeZones.Length = 0)
        {
            try SpeedKalandraMsgBox(
                "Nothing to export — the route for build '"
                . this._cfg.profileName . "' is empty. Add zones "
                . "first, save, and try Export again.",
                "Nothing to export", "Iconi")
            return
        }
        try
        {
            ; Make sure the route on disk matches the in-memory
            ; buffer BEFORE export. The user may have added zones
            ; without clicking Save yet; export should reflect
            ; what they see, not the stale disk version.
            try this._routeRepo.Save(this._cfg.profileName,
                Route(this._routeZones))

            defaultName := this._SanitizeFileNameStem(this._cfg.profileName)
                . "_route.ini"
            ; FileSelect "S 16" = Save As + overwrite confirmation.
            selectedFile := FileSelect("S 16", defaultName,
                "Export route to INI", "Route INI (*.ini)")
            if (selectedFile = "")
                return
            ok := this._routeRepo.ExportToFile(
                this._cfg.profileName, selectedFile)
            if !ok
            {
                try SpeedKalandraMsgBox(
                    "Could not export route to`n`n  " . selectedFile . "`n`n"
                    . "Check write permission and free disk space.",
                    "Export failed", "IconX")
                return
            }
            try TrayTip("SpeedKalandra",
                "Route exported to: " . selectedFile, "Mute")
        }
    }

    ; Persists the in-memory _routeZones buffer back to the active
    ; profile's route INI and refreshes the live widget. Called by
    ; _PersistAndPublishCfg AFTER settingsRepo.Save succeeds. Route
    ; failure does NOT roll back the settings save — the user gets
    ; a separate warning and the settings change still landed.
    _SaveRouteIfWired()
    {
        if !this._HasRouteWiring()
            return
        profileName := this._cfg.profileName
        ; Param name `routeObj` to avoid the `Route`/`route` case
        ; collision (CLAUDE.md §3, see also RouteRepository.Save).
        routeObj := Route(this._routeZones)
        ok := false
        try
        {
            ok := this._routeRepo.Save(profileName, routeObj)
        }
        catch as ex
        {
            try this._log.Warn("Route save failed: " . ex.Message,
                "SettingsDialog")
            try SpeedKalandraMsgBox(
                "Failed to save the route for build '" . profileName . "'.`n`n"
                . "Reason: " . ex.Message . "`n`n"
                . "Settings WERE saved; only the route did not persist. "
                . "Reopen Settings and try again.",
                "Route save failed", "IconX")
            return
        }
        if !ok
        {
            try this._log.Warn(
                "Route save returned false (see prior warnings)",
                "SettingsDialog")
            return
        }
        ; Refresh service so the live widget re-renders against
        ; the new route AND the new cfg.routeRowsVisible. Defensive
        ; try — Refresh shouldn't throw, but a throw here must
        ; not bubble up and skip the dialog Close.
        try this._routeService.Refresh()
    }

    _ClampRows(n)
    {
        try
        {
            nn := Integer(n + 0)
            if (nn < 3)
                return 3
            if (nn > 10)
                return 10
            return nn
        }
        catch
            return 5    ; the AppSettings default — last-resort fallback
    }

    ; Sanitizes a profile name into a safe filename stem. Mirrors
    ; RouteRepository._SanitizeProfileName but kept private here
    ; because the dialog needs a slightly different fallback
    ; ("route" vs "default") and depending on infra internals
    ; would couple UI to persistence.
    _SanitizeFileNameStem(s)
    {
        name := Trim(String(s))
        if (name = "")
            return "route"
        for _, ch in StrSplit("<>:`"/\|?*", "")
            name := StrReplace(name, ch, "_")
        name := StrReplace(name, "`r", "_")
        name := StrReplace(name, "`n", "_")
        name := Trim(name)
        if (name = "")
            return "route"
        return name
    }
}
