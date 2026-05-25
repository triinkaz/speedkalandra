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
;                     non-town dropdown with click-to-add + Visible rows slider +
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
    static WINDOW_W := 880
    ; Tab control reorganization (B7) made the dialog auto-fit each
    ; tab's content; the worst case is ROUTE at ~380 px. With Tab3
    ; h=430 and a footer row at y=490, the total window comes in
    ; at ~540 px — well under any reasonable screen, no longer
    ; needing the cap to fit. The cap + +Resize stay as defense in
    ; depth (see _BuildGui).
    static WINDOW_H := 540

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
    _routeNotes    := ""    ; Map<lowerZoneName, noteText> — in-memory notes
                            ; buffer. Hydrated from disk on Open(),
                            ; mutated by the right-panel Edit's content
                            ; via _StashCurrentNoteFromEdit, persisted
                            ; back via Route(zones, notes) on Save.
                            ; Map.CaseSense="Off" so SetNote/GetNote with
                            ; any zone-name casing hit the same entry,
                            ; matching Route._notes internal contract.
    _currentNoteZone := ""  ; Display name (original case) of the zone
                            ; currently bound to the right-panel Edit.
                            ; "" when no zone is selected. Used by the
                            ; ListBox onChange handler to know which
                            ; buffer entry to write to when the user
                            ; navigates to a different zone (the new
                            ; selection's note then populates the Edit).
    ; Stable BoundFunc registered via OnMessage(WM_HSCROLL) so the
    ; route sliders update their value labels DURING the drag, not
    ; just at mouse release. AHK v2 Slider's OnEvent("Change") fires
    ; reliably on keyboard navigation and click-to-track jumps but
    ; can defer to mouse-up for thumb drags depending on the trackbar
    ; style; WM_HSCROLL (0x114) is the underlying Win32 notification
    ; that fires on every thumb-track step including mid-drag. The
    ; handler dispatches by lParam (the source control's hwnd) so a
    ; SINGLE OnMessage registration covers every slider in the
    ; dialog (currently rowsVisible + noteFontSize; future sliders
    ; just add a `_ctrls.Has("<key>") && lParam = ...Hwnd` clause
    ; in _OnSliderScrollMessage). The field stays "" until _BuildGui
    ; binds it, and Close() tears it down so a re-open re-binds a
    ; fresh handler.
    _sliderScrollFn := ""

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
        ; Notes buffer with case-insensitive lookup. Hydrated
        ; explicitly on Open() via _LoadRouteZonesFromRepo, so a
        ; programmatic caller that bypasses Open (rare; mostly
        ; tests) starts with an empty map rather than an undefined
        ; field.
        this._routeNotes := Map()
        this._routeNotes.CaseSense := "Off"
        this._currentNoteZone := ""
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
        ; Tear down the WM_HSCROLL handler before the Gui dies so
        ; the OnMessage callback can't fire against a destroyed
        ; slider hwnd on the next system message cycle.
        if (this._sliderScrollFn != "")
        {
            try OnMessage(0x0114, this._sliderScrollFn, 0)
            this._sliderScrollFn := ""
        }
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
        ; +Resize kept as defense in depth alongside the Tab
        ; reorganization. Tab3 makes each tab autonomous — the
        ; worst case (ROUTE) sits at ~380 px of content within a
        ; h=430 tab body, so the total window (~540 px) fits any
        ; reasonable screen without the cap. The cap + +Resize only
        ; kick in if a future section pushes a SINGLE tab past the
        ; screen height; that would itself be a smell worth
        ; addressing structurally rather than papering over.
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

        ; ============ Tab control ============
        ; Tab3 (NOT Tab/Tab2) is the modern AHK v2 variant — the
        ; older Tab class had z-order and focus issues when
        ; controls overlapped the tab header. The 5 tabs map to
        ; the 9 original sections grouped by user intent:
        ;
        ;   General    : profile + log file path
        ;   Automation : auto-start, auto-finalize, vendor shortcuts
        ;   Behavior   : rules (autoPause, deathPenalty), layouts,
        ;                display (PB mode, outcome banner)
        ;   Route      : zone list editor + per-zone notes panel
        ;                (only rendered when route deps are wired)
        ;   Hotkeys    : capture/clear for every registered hotkey
        ;
        ; Decision (BACKLOG B7): tabs picked over (A) a native
        ; vertical scrollbar via WM_VSCROLL + SetScrollInfo and
        ; (C) a separate "Route..." dialog. Scrollbar resolves the
        ; symptom but adds ~80-150 lines of manual scroll plumbing
        ; and edge cases (FileSelect mid-scroll, Edit focus while
        ; scrolled). Separate dialog only defers the problem —
        ; when another section grows (e.g. HOTKEYS expanding for
        ; B1 cruel/interlude commands), the parent dialog is tall
        ; again. Tabs resolve it structurally: each tab is
        ; independent, and a future section grows ITS tab, not
        ; the global height.
        ;
        ; The Route tab is added to the label array conditionally
        ; — mirrors the original render-skip when _HasRouteWiring()
        ; is false. Position-by-name (tabs.UseTab("Route")) keeps
        ; this conditional clean: no integer index drift when the
        ; tab is absent.
        tabLabels := ["General", "Automation", "Behavior"]
        if this._HasRouteWiring()
            tabLabels.Push("Route")
        tabLabels.Push("Hotkeys")

        tabs := g.Add("Tab3",
            "x16 y46 w848 h430",
            tabLabels)
        this._ctrls["tabs"] := tabs

        ; ------------ Tab: General ------------
        tabs.UseTab("General")
        y := 80

        ; UI label is "Build": the persisted field in AppSettings is
        ; still `profileName` (and the ctrl key stays "profileName" so
        ; _OnSave keeps writing to cfg.profileName). The rename is a
        ; vocabulary shift towards the PoE-player audience — a "build"
        ; is the recognizable label for what they pick. AppSettings
        ; / SettingsRepository / DeathLogRepository are unaffected.
        this._Label(g, y, "Build")
        this._ctrls["profileName"] := this._AddEdit(g, 180, y, 360, this._cfg.profileName)
        y += 30

        ; cfg.gamePatch isn't editable in the dialog — it's preserved
        ; internally (default "Unknown") for back-compat with old
        ; saved runs but the user no longer maintains it.

        this._Label(g, y, "PoE2 log (Client.txt)")
        this._ctrls["logFile"] := this._AddEdit(g, 180, y, 280, this._cfg.logFile)
        btnBrowse := g.Add("Button", "x466 y" (y - 2) " w74 h22", "Browse...")
        btnBrowse.OnEvent("Click", (*) => this._OnBrowseLog())

        ; ------------ Tab: Automation ------------
        tabs.UseTab("Automation")
        y := 80
        this._SectionHeader(g, y, "AUTO-START (starts run when regex matches in log)")
        y += 22
        this._Label(g, y, "Regex (empty = off)")
        this._ctrls["autoStartRegex"] := this._AddEdit(g, 180, y, 360, this._cfg.autoStartRegex)
        y += 36

        this._SectionHeader(g, y, "AUTO-FINALIZE (finalizes run when regex matches in log)")
        y += 22
        this._Label(g, y, "Regex (empty = off)")
        this._ctrls["autoFinalizeRegex"] := this._AddEdit(g, 180, y, 360, this._cfg.autoFinalizeRegex)
        y += 36

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

        ; ------------ Tab: Behavior ------------
        tabs.UseTab("Behavior")
        y := 80
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

        ; ------------ Tab: Route (conditional) ------------
        if this._HasRouteWiring()
        {
            tabs.UseTab("Route")
            ; _BuildRouteSection returns the new y but we discard
            ; it — inside a tab body the y cursor doesn't flow into
            ; anything afterwards (Hotkeys lives in its own tab).
            this._BuildRouteSection(g, 80)
        }

        ; ------------ Tab: Hotkeys ------------
        tabs.UseTab("Hotkeys")
        y := 80

        ; Hint about the capture UX — the Edit field is ReadOnly;
        ; the user only interacts via Capture + Clear buttons.
        g.SetFont("s8 c" Theme.Color("muted"), Theme.FONT_UI)
        g.Add("Text", "x32 y" y " w800",
            "Click 'Capture' to record a key combo (Esc cancels). 'Clear' to unbind.")
        y += 22

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

        ; ============ Footer (outside any tab) ============
        ; UseTab() with no argument resets so subsequent Add calls
        ; land on the dialog body, not on whichever tab was last
        ; active. Save/Cancel are common across every tab —
        ; clicking Save persists ALL fields from ALL tabs, not just
        ; the currently-visible one (snapshot/restore semantics in
        ; _OnSave + _PersistAndPublishCfg are unchanged by the
        ; tab refactor).
        tabs.UseTab()

        y := 490
        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        btnSave := g.Add("Button", "x180 y" y " w120 h28", "Save")
        btnSave.OnEvent("Click", (*) => this._OnSave())
        btnCancel := g.Add("Button", "x310 y" y " w120 h28", "Cancel")
        btnCancel.OnEvent("Click", (*) => this.Close())

        finalH := y + 50
        ; Cap kept as defense in depth — see WINDOW_H comment. With
        ; Tab3 the worst-case tab body fits, so finalH (~540) sits
        ; comfortably under maxH on any realistic screen; the cap
        ; only kicks in for a degenerate display (e.g. very low
        ; vertical resolution).
        maxH := A_ScreenHeight - 80
        if (finalH > maxH)
            finalH := maxH
        ; Center forces the window to start centered on the active
        ; monitor instead of Windows' default top-left placement.
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

        ; Route note font size: read from slider, clamp [6,16].
        ; Same fallback-to-existing pattern as routeRowsVisible.
        if this._ctrls.Has("routeNoteFontSize")
            cfg.routeNoteFontSize := this._ClampFontSize(
                this._ctrls["routeNoteFontSize"].Value)

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
            "routeNoteFontSize",    cfg.routeNoteFontSize,
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
        cfg.routeNoteFontSize   := snapshot["routeNoteFontSize"]
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

        ; Capture the header's Y so the right-side notes panel can
        ; align with the listbox vertically. The panel sits in the
        ; x560…x870 column that opened up when WINDOW_W grew from
        ; 560 to 880 — the left column (x16…x540) keeps all the
        ; original ROUTE controls (listbox / buttons / dropdown /
        ; slider / Default-Import-Export) untouched.
        routeStartY := y

        ; Listbox + side button column.
        items := this._BuildRouteListBoxItems()
        ; Width 420 leaves an 80 px column on the right for the
        ; three reorder/remove buttons. Listbox height h140 shows
        ; ~7 rows at the default font — enough lookahead to
        ; reorder a multi-act route without scrolling for every
        ; move. The Tab control reorganization (B7) freed enough
        ; vertical real estate to revert from the h100 stopgap
        ; that B4 Commit 3 used to keep the all-in-one dialog
        ; under 1080p; now the Route tab body has its own h=430
        ; budget and h140 fits comfortably.
        lb := g.Add("ListBox",
            "x32 y" (y + 22) " w420 h140",
            items)
        ; Wire the selection-change handler so navigating between
        ; zones in the listbox stashes the current Edit content to
        ; the buffer (for the previously-selected zone) and then
        ; populates the Edit with the newly-selected zone's note.
        ; The handler is a closure rather than a bound method so
        ; it captures `this` correctly across the AHK event-loop
        ; boundary (ObjBindMethod would also work but the closure
        ; reads consistently with the rest of this dialog).
        lb.OnEvent("Change", (*) => this._OnRouteListBoxChanged())
        this._ctrls["routeListBox"] := lb
        if (items.Length > 0)
            try lb.Choose(1)

        ; Right-side button column. Three buttons stacked with
        ; small gaps; ▲ at the top, ▼ just below, Remove at the
        ; bottom (aligned to the listbox's bottom edge so the
        ; deletion control is visually anchored). With listbox
        ; h=140, the listbox spans y+22 to y+162; Remove sits at
        ; y+134 to bottom-align (h28 fits within y+134..y+162).
        g.SetFont("s10 c" Theme.Color("text"), Theme.FONT_UI)
        btnUp := g.Add("Button", "x460 y" (y + 22) " w80 h28", "▲")
        btnUp.OnEvent("Click", (*) => this._OnRouteMoveUp())
        this._ctrls["routeBtnUp"] := btnUp

        btnDown := g.Add("Button", "x460 y" (y + 54) " w80 h28", "▼")
        btnDown.OnEvent("Click", (*) => this._OnRouteMoveDown())
        this._ctrls["routeBtnDown"] := btnDown

        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        btnDel := g.Add("Button", "x460 y" (y + 134) " w80 h28", "Remove")
        btnDel.OnEvent("Click", (*) => this._OnRouteRemove())
        this._ctrls["routeBtnRemove"] := btnDel

        ; Move past the listbox row.
        y += 22 + 140 + 8

        ; Add-zone row: label + non-town dropdown with
        ; click-to-add (B11). Picking a zone from the dropdown
        ; adds it to the route IMMEDIATELY — no separate Add
        ; button. TUGs feedback: "95% of the time you want to
        ; add what you clicked anyway". Dedupe in _OnRouteAdd
        ; surfaces a specific MsgBox on the rare misclick that
        ; lands on a zone already in the route, and Remove is
        ; one click, so the cost of a 5% misclick is low.
        ;
        ; The dropdown spans the full inner width (was 280 px
        ; with a 74 px Add button to its right; now 360 px
        ; matches the listbox's available width). The Change
        ; OnEvent is wired AFTER the initial dd.Choose(1) so the
        ; pre-selection of row 1 at build time can't accidentally
        ; fire the add handler against a freshly-built dialog —
        ; AHK v2 doesn't fire Change for programmatic Choose() in
        ; practice, but ordering this way is belt-and-suspenders.
        this._Label(g, y, "Add zone")
        nonTowns := this._BuildNonTownZoneNames()
        g.SetFont(Theme.InputFont(), Theme.FONT_UI)
        dd := g.Add("DropDownList",
            "x180 y" y " w360 " Theme.InputBg(),
            nonTowns)
        if (nonTowns.Length > 0)
            try dd.Choose(1)
        dd.OnEvent("Change", (*) => this._OnRouteAddFromDropdown())
        this._ctrls["routeAddDropdown"] := dd

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

        ; Register a SINGLE WM_HSCROLL handler that dispatches by
        ; lParam (slider hwnd) so the label tracks the thumb
        ; DURING the drag, not just at mouse release. AHK v2's
        ; Slider.OnEvent("Change") fires reliably on keyboard and
        ; click-to-track, but the mouse-drag case can defer the
        ; notification to TB_ENDTRACK (mouse up) depending on the
        ; underlying trackbar style — TUGs reported this as "the
        ; number doesn't change until you let go of the slider".
        ; WM_HSCROLL (0x0114) carries the thumb position on every
        ; TB_THUMBTRACK step, which is the missing signal. The
        ; handler is bound ONCE here (not per slider) because the
        ; OnMessage table is global per-process; binding a second
        ; handler for noteFontSize would mean two separate handlers
        ; competing for the same message. Instead the single
        ; _OnSliderScrollMessage filters by lParam internally and
        ; routes to the appropriate per-slider handler. The bound
        ; function reference is stored on the instance so Close()
        ; can detach it cleanly — a stale OnMessage callback
        ; against a destroyed slider would crash on the next
        ; message cycle.
        if (this._sliderScrollFn = "")
        {
            this._sliderScrollFn := ObjBindMethod(this, "_OnSliderScrollMessage")
            try OnMessage(0x0114, this._sliderScrollFn)
        }

        g.SetFont("s9 bold c" Theme.Color("text"), Theme.FONT_UI)
        rowsLabel := g.Add("Text", "x425 y" (y + 2) " w20", String(rows))
        this._ctrls["routeRowsValueLabel"] := rowsLabel
        g.SetFont("s9 c" Theme.Color("muted"), Theme.FONT_UI)
        g.Add("Text", "x450 y" (y + 2) " w80", "(3 - 10)")

        y += 30

        ; Note-font-size slider (6-16 pt). Sits right below the
        ; rows-visible slider so the two route-overlay knobs are
        ; grouped. The base font size (cfg.routeNoteFontSize) is
        ; multiplied by the anchor's render scale inside
        ; RouteWidget._Render — same scaling behavior as the zone
        ; rows — so this knob shifts the BASE without affecting
        ; the rest of the widget's vertical rhythm. Motivated by
        ; TUGs's feedback ("I can barely see what my notes say"):
        ; the default 8 pt is on the small side for high-DPI
        ; setups and the configurability resolves it without
        ; making everyone read 12 pt notes.
        this._Label(g, y, "Note font size")
        fontSize := this._ClampFontSize(this._cfg.routeNoteFontSize)
        fontSlider := g.Add("Slider",
            "x180 y" y " w240 h22 Range6-16 Page1 TickInterval2",
            fontSize)
        fontSlider.OnEvent("Change",
            (*) => this._OnRouteNoteFontSizeChanged())
        this._ctrls["routeNoteFontSize"] := fontSlider

        g.SetFont("s9 bold c" Theme.Color("text"), Theme.FONT_UI)
        fontLabel := g.Add("Text", "x425 y" (y + 2) " w20",
            String(fontSize))
        this._ctrls["routeNoteFontSizeValueLabel"] := fontLabel
        g.SetFont("s9 c" Theme.Color("muted"), Theme.FONT_UI)
        g.Add("Text", "x450 y" (y + 2) " w80", "(6 - 16 pt)")

        y += 30

        ; Default / Import / Export buttons row.
        ; "Default" replaces the current route with every non-town
        ; zone from the catalog in internal_id order — the user
        ; trims down to their preferred route. Asks confirmation
        ; when the buffer is non-empty so a careless click doesn't
        ; throw away in-progress edits. 3 buttons at w110 each
        ; with 10 px gaps fit in the dialog's 528 px usable width
        ; (16 px margin × 2 off WINDOW_W=560).
        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        btnDefault := g.Add("Button", "x180 y" y " w110 h28", "Default")
        btnDefault.OnEvent("Click", (*) => this._OnRouteLoadDefault())
        this._ctrls["routeBtnDefault"] := btnDefault

        btnImport := g.Add("Button", "x300 y" y " w110 h28", "Import...")
        btnImport.OnEvent("Click", (*) => this._OnRouteImport())
        this._ctrls["routeBtnImport"] := btnImport

        btnExport := g.Add("Button", "x420 y" y " w110 h28", "Export...")
        btnExport.OnEvent("Click", (*) => this._OnRouteExport())
        this._ctrls["routeBtnExport"] := btnExport

        y += 40

        ; --- Right-side notes panel ---
        ; Sits in the x560…x870 column opened by WINDOW_W=880, top-
        ; aligned with the listbox so the two surfaces read as a
        ; single "select a zone on the left, edit its note on the
        ; right" workflow. The header label restates the currently
        ; selected zone's name so the user can't accidentally type
        ; into the wrong row's note after a long editing session.
        ;
        ; The Edit is Multi/VScroll/Wrap/WantReturn:
        ;   - Multi:      multi-line semantics (newlines render as breaks)
        ;   - VScroll:    scrollbar when content exceeds h180
        ;   - Wrap:       long lines wrap at the right edge
        ;   - WantReturn: Enter inside the field inserts a newline
        ;                 rather than submitting the dialog
        ;   - Limit500:   matches the soft cap mentioned in the
        ;                 ROUTE section docstring; longer tips get
        ;                 truncated client-side rather than producing
        ;                 a giant note row in the live overlay.
        panelY := routeStartY + 22
        g.SetFont("s9 bold c" Theme.Color("text"), Theme.FONT_UI)
        noteHeader := g.Add("Text", "x560 y" panelY " w300",
            "Select a zone to edit notes")
        this._ctrls["routeNoteHeader"] := noteHeader

        g.SetFont(Theme.InputFont(), Theme.FONT_UI)
        noteEdit := g.Add("Edit",
            "x560 y" (panelY + 22) " w300 h180 " Theme.InputBg()
                . " +Multi +VScroll +Wrap WantReturn Limit500",
            "")
        this._ctrls["routeNoteEdit"] := noteEdit

        ; Helper hint immediately below the Edit so the user
        ; doesn't have to discover the multi-line semantics by
        ; trial-and-error. Muted color so it reads as secondary.
        g.SetFont("s8 c" Theme.Color("muted"), Theme.FONT_UI)
        g.Add("Text", "x560 y" (panelY + 206) " w300",
            "Notes appear below the current zone on the route overlay. Enter = new line.")

        ; Populate the right panel from whatever's currently
        ; selected in the listbox (default: row 1 from the
        ; Choose(1) above). Without this, the panel would stay on
        ; "Select a zone…" until the user clicked a row, even
        ; though row 1 IS selected.
        this._RefreshNotePanelForSelection()

        return y
    }

    ; Loads the active route from disk into _routeZones. Called from
    ; Open(). Silently leaves the buffer empty if route deps aren't
    ; wired — the section is hidden in that case anyway.
    _LoadRouteZonesFromRepo()
    {
        this._routeZones := []
        this._routeNotes := Map()
        this._routeNotes.CaseSense := "Off"
        this._currentNoteZone := ""
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
            {
                this._routeZones := loaded.GetZones()
                ; GetAllNotes returns a defensive copy that's already
                ; lowercase-keyed and case-insensitive — use it
                ; directly as the editing buffer. Mutations through
                ; the right panel Edit go via _StashCurrentNoteFromEdit
                ; which also writes lowercase keys, keeping the buffer
                ; coherent with Route._notes' internal contract.
                this._routeNotes := loaded.GetAllNotes()
            }
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
        removedZone := this._routeZones[idx]
        this._routeZones.RemoveAt(idx)
        ; Drop the note from the buffer too so the buffer stays
        ; coherent with what Save persists via Route(zones, notes)
        ; — Route.Remove drops the matching note on its own, but
        ; the buffer here is what the construction passes IN, so
        ; we have to mirror that contract proactively.
        removedKey := StrLower(String(removedZone))
        if this._routeNotes.Has(removedKey)
            this._routeNotes.Delete(removedKey)
        ; If the removed zone is the one the right panel is
        ; currently bound to, clear _currentNoteZone BEFORE the
        ; subsequent listbox refresh fires the onChange handler.
        ; Without this, _StashCurrentNoteFromEdit would re-insert
        ; whatever text is in the Edit field under the (now stale)
        ; removedKey, resurrecting the deletion we just performed.
        if (StrLower(this._currentNoteZone) = removedKey)
        {
            this._currentNoteZone := ""
            this._SetNoteHeaderText("")
            this._SetNoteEditText("")
        }
        ; Try to select the same position. If we removed the
        ; LAST item, select the new last (or 0 = no selection).
        newSel := idx > this._routeZones.Length
                ? this._routeZones.Length
                : idx
        this._RefreshRouteListBox(newSel)
        ; The listbox refresh above doesn't always trigger the
        ; onChange handler reliably (depends on whether the
        ; selected index changed). Re-sync the right panel
        ; explicitly to be defensive against that.
        this._RefreshNotePanelForSelection()
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
        ; Dedupe up front (case-insensitive). Route.Add ALSO rejects
        ; duplicates, but doing the check here lets us surface a
        ; specific MsgBox so the user understands why the listbox
        ; didn't grow — a silent no-op would feel like a bug.
        if SettingsDialog._ContainsZoneCaseInsensitive(this._routeZones, zoneName)
        {
            ; Log at INFO so the dedupe path leaves an observable
            ; trace in InMemoryLogger for headless tests (the
            ; MsgBox below is the user-facing signal but isn't
            ; observable in headless mode — SpeedKalandraMsgBox
            ; stubs to "Cancel" without recording calls).
            try this._log.Info("Add ignored duplicate zone: '" . zoneName . "'",
                "SettingsDialog")
            try SpeedKalandraMsgBox(
                "'" . zoneName . "' is already in the route. Routes "
                . "don't allow duplicate zones — the overlay tracks "
                . "one row per zone, and time spent on each visit "
                . "accumulates onto the single existing row "
                . "automatically (so a 'second visit' isn't a "
                . "separate slot in the route).",
                "Duplicate zone",
                "Iconi")
            return
        }
        this._routeZones.Push(String(zoneName))
        this._RefreshRouteListBox(this._routeZones.Length)
        ; New row is now selected — sync the right panel to it
        ; (header restates the new zone name; Edit is empty since
        ; freshly-added zones have no note).
        this._RefreshNotePanelForSelection()
    }

    ; Click-to-add wrapper (B11). Reads the current selection
    ; from the "Add zone" dropdown and delegates to _OnRouteAdd.
    ; Wired on the dropdown's Change event so picking a zone
    ; adds it immediately, with no separate Add button. Tests
    ; still drive _OnRouteAdd directly via its zoneOverride arg
    ; — this wrapper exists only to source the zone name from
    ; the live GUI control when present. No-op when the dropdown
    ; wasn't built (headless / non-route configurations).
    _OnRouteAddFromDropdown()
    {
        if !this._ctrls.Has("routeAddDropdown")
            return
        zoneName := ""
        try zoneName := Trim(String(this._ctrls["routeAddDropdown"].Text))
        if (zoneName = "")
            return
        this._OnRouteAdd(zoneName)
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

    ; ============================================================
    ; Notes panel — ListBox onChange + Edit content sync
    ; ============================================================
    ;
    ; The right-side panel is bound to the ListBox selection: when
    ; the user clicks a different zone, the Edit's current content
    ; is stashed into _routeNotes under the PREVIOUS zone's key,
    ; then the Edit is populated with the NEW zone's note (or
    ; empty when the zone has no note yet). _SaveRouteIfWired
    ; also calls _StashCurrentNoteFromEdit so the last unflushed
    ; edit before clicking Save isn't silently dropped.
    ;
    ; Headless mode: tests can drive this flow by calling
    ; _OnRouteListBoxChanged directly after writing to a stub
    ; routeNoteEdit; the real GUI Edit is never built.

    _OnRouteListBoxChanged()
    {
        if !this._HasRouteWiring()
            return
        ; Stash first — we're about to overwrite the Edit with the
        ; new selection's content, so the previous content must
        ; reach the buffer before that happens.
        this._StashCurrentNoteFromEdit()
        this._RefreshNotePanelForSelection()
    }

    ; Reads the current listbox selection and reflects it in the
    ; right panel (header label + Edit content + _currentNoteZone
    ; binding). Does NOT stash the Edit's current content — the
    ; caller is expected to call _StashCurrentNoteFromEdit first
    ; when that's appropriate. Used by:
    ;   - _OnRouteListBoxChanged (after stash)
    ;   - _OnRouteRemove          (after the removed row is gone)
    ;   - _OnRouteAdd             (selection moves to the new row)
    ;   - _OnRouteImport          (selection resets to row 1)
    ;   - _BuildRouteSection      (initial population)
    _RefreshNotePanelForSelection()
    {
        idx := this._ResolveRouteIdx(-1)
        if (idx < 1 || idx > this._routeZones.Length)
        {
            this._currentNoteZone := ""
            this._SetNoteHeaderText("")
            this._SetNoteEditText("")
            return
        }
        zone := this._routeZones[idx]
        this._currentNoteZone := String(zone)
        this._SetNoteHeaderText(this._currentNoteZone)
        key := StrLower(this._currentNoteZone)
        existing := this._routeNotes.Has(key) ? this._routeNotes[key] : ""
        this._SetNoteEditText(existing)
    }

    ; Flushes the Edit's current Value into _routeNotes under the
    ; lowercase key for _currentNoteZone. Empty / whitespace-only
    ; content deletes the buffer entry (matches Route.SetNote's
    ; "empty means absent" semantic so the on-disk file doesn't
    ; carry a no-op key=value pair after Save). Whitespace chars
    ; checked are the full set space/tab/CR/LF since AHK v2's
    ; default Trim chars omit CR/LF (same gotcha that bit us in
    ; the Route constructor).
    ;
    ; No-op when _currentNoteZone is empty (no zone selected) or
    ; the Edit control wasn't built (headless without routeNoteEdit).
    _StashCurrentNoteFromEdit()
    {
        if (this._currentNoteZone = "")
            return
        if !this._ctrls.Has("routeNoteEdit")
            return
        text := ""
        try text := String(this._ctrls["routeNoteEdit"].Value)
        key := StrLower(this._currentNoteZone)
        if (Trim(text, " `t`r`n") = "")
        {
            if this._routeNotes.Has(key)
                this._routeNotes.Delete(key)
            return
        }
        this._routeNotes[key] := text
    }

    ; Writes the header label above the right-panel Edit. Empty
    ; zoneName means "no zone selected" — fallback text reminds
    ; the user to click a row to start editing.
    _SetNoteHeaderText(zoneName)
    {
        if !this._ctrls.Has("routeNoteHeader")
            return
        txt := (zoneName = "")
            ? "Select a zone to edit notes"
            : "Notes for: " . zoneName
        try this._ctrls["routeNoteHeader"].Value := txt
    }

    ; Writes the right-panel Edit's content. Defensive try around
    ; the Value assignment so a teardown race (Edit destroyed mid
    ; flow) doesn't crash the dialog.
    _SetNoteEditText(text)
    {
        if !this._ctrls.Has("routeNoteEdit")
            return
        try this._ctrls["routeNoteEdit"].Value := String(text)
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

    ; Mirror of _OnRouteRowsChanged for the note-font-size slider.
    ; Single-responsibility on purpose — keeping the two handlers
    ; separate makes future tweaks (e.g. a font-size preview that
    ; live-updates the overlay during drag) localizable to one
    ; method without touching the rows-visible behavior.
    _OnRouteNoteFontSizeChanged()
    {
        if !this._ctrls.Has("routeNoteFontSize")
            return
        if !this._ctrls.Has("routeNoteFontSizeValueLabel")
            return
        try this._ctrls["routeNoteFontSizeValueLabel"].Value :=
            String(this._ctrls["routeNoteFontSize"].Value)
    }

    ; WM_HSCROLL (0x0114) handler. Fires during the slider's thumb
    ; drag on every step, complementing the OnEvent("Change") that
    ; covers keyboard and click-to-track. Dispatches by lParam (the
    ; source control's hwnd in Win32 WM_HSCROLL semantics) so a
    ; single OnMessage registration covers every slider in the
    ; dialog — new sliders only need a `_ctrls.Has("<key>") &&
    ; lParam = ...Hwnd` clause below and their own _OnXChanged
    ; method. Each label update is delegated to the same
    ; _OnXChanged that the Change event uses so the read path stays
    ; in one place per slider.
    _OnSliderScrollMessage(wParam, lParam, msg, hwnd)
    {
        if this._ctrls.Has("routeRowsVisible")
            && lParam = this._ctrls["routeRowsVisible"].Hwnd
        {
            this._OnRouteRowsChanged()
            return
        }
        if this._ctrls.Has("routeNoteFontSize")
            && lParam = this._ctrls["routeNoteFontSize"].Hwnd
        {
            this._OnRouteNoteFontSizeChanged()
            return
        }
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
            ; LoadRouteZones cleared _currentNoteZone already; sync
            ; the right panel to whatever's now selected (row 1 if
            ; the imported route is non-empty, otherwise the empty
            ; "Select a zone…" state).
            this._RefreshNotePanelForSelection()
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
        ; Flush whatever the user has typed in the right-panel
        ; Edit into the buffer before serializing — without this,
        ; an edit made just before Save (no listbox-change to
        ; trigger the onChange stash) would be silently dropped.
        this._StashCurrentNoteFromEdit()
        ; Param name `routeObj` to avoid the `Route`/`route` case
        ; collision (CLAUDE.md §3, see also RouteRepository.Save).
        routeObj := Route(this._routeZones, this._routeNotes)
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

    ; Replaces the in-memory _routeZones buffer with every non-town
    ; campaign zone in catalog order (sorted by internal_id parsed
    ; numerically — "G1_2" < "G1_13" < "G2_1"). Asks confirmation
    ; when the buffer is non-empty so a careless click doesn't lose
    ; in-progress edits.
    ;
    ; skipConfirm is the test seam: headless tests bypass the
    ; SpeedKalandraMsgBox (which is stubbed to return "Cancel" in
    ; the headless harness, which would otherwise abort every test).
    ; Production callers (the button OnEvent) pass no arg and get
    ; the default confirmation flow.
    _OnRouteLoadDefault(skipConfirm := false)
    {
        if !this._HasRouteWiring()
            return
        defaultZones := this._BuildDefaultRouteZones()
        if (defaultZones.Length = 0)
        {
            try SpeedKalandraMsgBox(
                "No zones in catalog to load. Check that "
                . "data\\zones.csv exists and contains non-town entries.",
                "Empty catalog", "Iconi")
            return
        }
        if (!skipConfirm && this._routeZones.Length > 0)
        {
            answer := SpeedKalandraMsgBox(
                "Replace the current route with all " . defaultZones.Length
                . " non-town campaign zones in catalog order?`n`n"
                . "Your in-progress edits will be lost (click No to keep them).",
                "Replace route?", "YesNo Icon?")
            if (answer != "Yes")
                return
        }
        this._routeZones := defaultZones
        this._RefreshRouteListBox(1)
    }

    ; Builds the default route: every non-town zone in the catalog,
    ; sorted by internal_id parsed numerically. The internal_id
    ; format is "G<act>_<n>" or "G<act>_<n>_<sub>" (and rarely
    ; "G<act>_<n>a" with a letter suffix); a naive StrCompare puts
    ; "G1_13_1" before "G1_2" because '1' < '2' lexicographically.
    ; _InternalIdSortKey normalizes each numeric segment to a 4-digit
    ; zero-padded string so lexicographic sort matches numeric order.
    _BuildDefaultRouteZones()
    {
        out := []
        if !IsObject(this._zonesCatalog)
            return out
        ; Build {name, sortKey} pairs so the sort doesn't have to
        ; reparse the internal_id on every comparison.
        pairs := []
        for _, z in this._zonesCatalog.All()
        {
            if z.isTown
                continue
            pairs.Push({
                name:    z.name,
                sortKey: SettingsDialog._InternalIdSortKey(z.internalId)
            })
        }
        this._SortPairsByKey(pairs)
        for _, p in pairs
            out.Push(p.name)
        return out
    }

    ; Bubble-sort an array of {name, sortKey} pairs in place by
    ; sortKey (StrCompare). Small arrays (~60 elements) so the O(n²)
    ; cost is negligible and the in-place mutation is clearer than
    ; building a parallel array.
    _SortPairsByKey(pairs)
    {
        n := pairs.Length
        Loop n - 1
        {
            i := A_Index
            Loop n - i
            {
                j := A_Index
                if (StrCompare(pairs[j].sortKey, pairs[j + 1].sortKey) > 0)
                {
                    tmp := pairs[j]
                    pairs[j] := pairs[j + 1]
                    pairs[j + 1] := tmp
                }
            }
        }
    }

    ; Normalizes a zone internal_id (e.g. "G1_13_2") into a sortable
    ; key (e.g. "0001_0013_0002") so lexicographic StrCompare matches
    ; the natural campaign order. Letter suffixes ("G4_8a") are
    ; preserved AFTER the zero-padded number so "G4_8" < "G4_8a" < "G4_9".
    static _InternalIdSortKey(internalId)
    {
        s := String(internalId)
        if (SubStr(s, 1, 1) = "G" || SubStr(s, 1, 1) = "g")
            s := SubStr(s, 2)
        parts := StrSplit(s, "_")
        out := ""
        for i, p in parts
        {
            if (i > 1)
                out .= "_"
            ; Split each segment into leading-digits + rest (e.g.
            ; "8a" → numStr="8", rest="a"; "13" → numStr="13", rest="").
            ; IsDigit(ch) is used instead of `ch >= "0" && ch <= "9"`
            ; because AHK v2's relational operators are NUMERIC: when
            ; the loop reaches a letter (e.g. "a" in "G4_8a"), the
            ; coercion `"a" >= "0"` throws TypeError("Expected a Number
            ; but got a String"). IsDigit operates on the string
            ; directly and returns false for any non-digit char.
            numStr  := ""
            rest    := ""
            len     := StrLen(p)
            k       := 1
            while (k <= len)
            {
                ch := SubStr(p, k, 1)
                if IsDigit(ch)
                {
                    numStr .= ch
                    k++
                }
                else
                {
                    rest := SubStr(p, k)
                    break
                }
            }
            if (numStr = "")
                out .= "0000" . rest    ; pure-alpha segment (unlikely but defensive)
            else
                out .= Format("{:04d}", Integer(numStr)) . rest
        }
        return out
    }

    ; Case-insensitive presence check on an Array<String>. Used by
    ; _OnRouteAdd's dedupe guard — Route.Add ALSO rejects duplicates,
    ; but we surface a specific MsgBox here, which requires knowing
    ; about the duplicate before pushing onto the buffer. Inlined
    ; rather than calling Route.HasZone because the buffer is a
    ; plain Array, not a Route instance, until Save serializes it.
    static _ContainsZoneCaseInsensitive(arr, name)
    {
        if !(arr is Array)
            return false
        target := StrLower(String(name))
        if (target = "")
            return false
        for _, z in arr
        {
            if (StrLower(String(z)) = target)
                return true
        }
        return false
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

    ; Mirror of _ClampRows for the note-font-size slider. The valid
    ; range [6, 16] matches the slider's `Range6-16` option and the
    ; clamp policy in AppSettings.FromMap / SettingsRepository so
    ; every path that lands a value on cfg.routeNoteFontSize agrees
    ; on the same domain. Fallback default 8 is the AppSettings
    ; baseline and also the pre-config NOTE_FONT_SIZE_BASE constant
    ; in RouteWidget — keeping all three in sync means a user with
    ; a hand-corrupted INI lands back on the original visual.
    _ClampFontSize(n)
    {
        try
        {
            nn := Integer(n + 0)
            if (nn < 6)
                return 6
            if (nn > 16)
                return 16
            return nn
        }
        catch
            return 8    ; the AppSettings default — last-resort fallback
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
