; ============================================================
; SettingsDialog - settings window (Wave 6, minimal)
; ============================================================
;
; Minimalist dialog aligned with the new AppSettings. Lets you edit:
;   - General: ProfileName, GamePatch, LogFile path
;   - AutoStart: Regex (PoE2 is localized — user configures per language)
;   - AutoFinalize: Regex
;   - VendorRegexes: 3 slots (max 50 chars each) for V1/V2/V3 shortcuts
;   - Rules: AutoPauseOnFocus, DeathPenaltyEnabled + Penalty seconds
;   - Hotkeys (all actions registered in cfg.hotkeys)
;
;   v17.15 (Bug #15): removed UI lines for PanelKeys.
;   v17.15.1: re-added UI for death penalty (it was discovered that
;   the plot consumed these fields).
;
; SUBSCRIPTIONS:
;   Cmd.OpenSettingsRequested -> Open()
;
; CONSTRUCTION:
;   dialog := SettingsDialog(bus, settingsRepo, cfg, headless := false)
;   ; bus.Publish(Commands.OpenSettingsRequested) opens it
;
; NOTE ON FONTS IN Gui.Add:
;   AHK v2 does NOT accept "s<size>" or "c<hex>" as inline options in
;   the Gui.Add("Edit", ...) string. Font size and color are
;   configured via g.SetFont(...) BEFORE the Add, and the control
;   inherits those settings. That's why the _AddEdit() helper sets
;   the font before adding.
;
;   Cases where inline "c<hex>" IS accepted: Text, Link, Checkbox,
;   Radio, Button, GroupBox, Slider, Tab. But inline "s<size>" does
;   not work on any control. For uniformity, all dialog inputs use
;   SetFont.


class SettingsDialog
{
    static WINDOW_W := 560
    static WINDOW_H := 620

    _bus           := ""
    _settingsRepo  := ""
    _cfg           := ""
    _headless      := false
    _gui           := ""
    _ctrls         := ""    ; Map<key, GuiControl>
    _isOpen        := false
    _hotkeyActions := ""    ; Array<actionName> ordered

    __New(bus, settingsRepo, cfg, headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("SettingsDialog: 'bus' must be EventBus")
        if !(settingsRepo is SettingsRepository)
            throw TypeError("SettingsDialog: 'settingsRepo' must be SettingsRepository")
        if !(cfg is AppSettings)
            throw TypeError("SettingsDialog: 'cfg' must be AppSettings")

        this._bus          := bus
        this._settingsRepo := settingsRepo
        this._cfg          := cfg
        this._headless     := !!headless
        this._ctrls        := Map()
        this._hotkeyActions := []

        bus.Subscribe(Commands.OpenSettingsRequested, (data) => this.Open())
    }

    IsOpen() => this._isOpen

    Open()
    {
        if this._headless
        {
            this._isOpen := true
            return true
        }
        if this._isOpen && this._gui
        {
            try this._gui.Show()
            return true
        }
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
        g := Gui("+AlwaysOnTop +Resize -MaximizeBox", "SpeedKalandra " . Version.STRING . " - Settings")
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

        this._Label(g, y, "Profile name")
        this._ctrls["profileName"] := this._AddEdit(g, 180, y, 360, this._cfg.profileName)
        y += 26

        ; v0.1.3: "Patch" field removed from the dialog. cfg.gamePatch
        ; still exists internally (default "Unknown") for back-compat
        ; with old runs saved in history, but the user no longer needs
        ; to maintain it manually.

        this._Label(g, y, "PoE2 log (Client.txt)")
        this._ctrls["logFile"] := this._AddEdit(g, 180, y, 280, this._cfg.logFile)
        btnBrowse := g.Add("Button", "x466 y" (y - 2) " w74 h22", "Browse...")
        btnBrowse.OnEvent("Click", (*) => this._OnBrowseLog())
        y += 32

        ; v17.15 (Bug #15): "Panel keys (csv)" line removed.
        ; PanelKeyService was disconnected in v17.2 and the
        ; panelOverlayKeys field no longer exists in AppSettings.

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

        ; ============ Vendor Regex Slots (Wave 8) ============
        ; Edits limited to 50 chars via "Limit50". V1/V2/V3 buttons in
        ; CompactLayoutWidget copy each slot to clipboard via Ctrl+click.
        this._SectionHeader(g, y, "VENDOR SHORTCUTS (clipboard via V1/V2/V3 in overlay, max 50 chars)")
        y += 22
        Loop 3
        {
            i := A_Index
            this._Label(g, y, "Slot V" i)
            val := (IsObject(this._cfg.vendorRegexes) && this._cfg.vendorRegexes.Has(i))
                   ? this._cfg.vendorRegexes[i]
                   : ""
            this._ctrls["vendorRegex" i] := this._AddEdit(g, 180, y, 360, val, "Limit50")
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
        ; v17.15.1: death penalty (re-added after the #15 over-removal).
        ; UI shows seconds to be friendly; converted to ms on save.
        this._ctrls["deathPenaltyEnabled"] := g.Add("Checkbox",
            "x180 y" y (this._cfg.deathPenaltyEnabled ? " Checked" : ""),
            "Apply death penalty in run plot")
        y += 26
        this._Label(g, y, "Penalty (seconds)")
        penaltySec := Round(this._cfg.deathPenaltyMs / 1000)
        this._ctrls["deathPenaltySec"] := this._AddEdit(g, 180, y, 120, penaltySec, "Number")
        y += 36

        ; ============ Hotkeys ============
        this._SectionHeader(g, y, "HOTKEYS")
        y += 22

        ; v0.1.0: hint about the capture UX. The Edit field is ReadOnly;
        ; the user only interacts via buttons (Capture + Clear).
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
            ; v0.1.0: Edit is ReadOnly. Display in human format
            ; ("Ctrl+Alt+F") via HotkeyFormatter. Interaction only via
            ; Capture/Clear buttons. _OnSave converts back to AHK syntax
            ; ("^!f") at persist time.
            displayVal := HotkeyFormatter.ToHuman(this._cfg.GetHotkey(action))
            this._ctrls["hk_" action] := this._AddEdit(g, 180, y, 200, displayVal, "ReadOnly")

            ; Capture button: grabs the next combo via InputHook
            g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
            btnCap := g.Add("Button", "x384 y" (y-1) " w60 h22", "Capture")
            btnCap.OnEvent("Click", this._MakeCaptureHandler(action))
            this._ctrls["btn_capture_" action] := btnCap

            ; Clear button: unbinds the hotkey (clears the edit)
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
        g.Show("w" SettingsDialog.WINDOW_W " h" finalH)
    }

    ; ============================================================
    ; _AddEdit - helper that sets the font BEFORE and adds an Edit
    ;   with simple options (no inline font options, which AHK v2
    ;   rejects).
    ;
    ;   extraOpts: additional options valid for Edit (e.g. "Number",
    ;     "ReadOnly", "Multi", "Password"). NEVER pass s<n> or c<hex>.
    ;
    ;   v0.1.3: fixed height h22 to prevent the Edit from auto-expanding
    ;   to multiple lines when the value is long (the logFile case with
    ;   the full Steam path). Previously, the logFile Edit grew to 3
    ;   lines and visually overlapped the field below.
    ; ============================================================
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
            ; v0.1.1: `file` collides with the builtin `File`. Use `selectedFile`.
            selectedFile := FileSelect(1, this._cfg.logFile, "Select Client.txt", "Logs (*.txt)")
            if (selectedFile != "")
                this._ctrls["logFile"].Value := selectedFile
        }
    }

    _OnSave()
    {
        cfg := this._cfg
        cfg.profileName := this._ctrls["profileName"].Value
        ; v0.1.3: gamePatch is no longer editable in the dialog. Keeps
        ; the value that was already in cfg (default "Unknown" on fresh
        ; install).
        cfg.logFile     := this._ctrls["logFile"].Value
        cfg.autoStartRegex    := this._ctrls["autoStartRegex"].Value
        cfg.autoFinalizeRegex := this._ctrls["autoFinalizeRegex"].Value

        ; Vendor regex slots (Wave 8) — defensive clamp to 50 chars
        vrOut := ["", "", ""]
        Loop 3
        {
            i := A_Index
            if this._ctrls.Has("vendorRegex" i)
            {
                v := this._ctrls["vendorRegex" i].Value
                if (StrLen(v) > 50)
                    v := SubStr(v, 1, 50)
                vrOut[i] := v
            }
        }
        cfg.vendorRegexes := vrOut

        cfg.autoPauseOnFocus := this._ctrls["autoPauseOnFocus"].Value = 1

        ; v17.15.1: death penalty re-added. UI uses seconds, persists
        ; in ms. Defensive: if input is empty/invalid, falls back to
        ; the 150s default.
        cfg.deathPenaltyEnabled := this._ctrls["deathPenaltyEnabled"].Value = 1
        try
        {
            secs := Integer(this._ctrls["deathPenaltySec"].Value + 0)
            cfg.deathPenaltyMs := secs >= 0 ? secs * 1000 : 0
        }
        catch
            cfg.deathPenaltyMs := 150000

        ; Hotkeys
        ; v0.1.0: user types human-readable format ("Ctrl+Alt+F");
        ; HotkeyFormatter.ToAhk converts to internal syntax ("^!f")
        ; before persisting. Tolerant of old-format passthrough.
        for _, action in this._hotkeyActions
        {
            ctrlKey := "hk_" action
            if this._ctrls.Has(ctrlKey)
            {
                rawVal := Trim(this._ctrls[ctrlKey].Value)
                cfg.hotkeys[action] := HotkeyFormatter.ToAhk(rawVal)
            }
        }

        try this._settingsRepo.Save(cfg)
        try TrayTip("SpeedKalandra", "Settings saved.", "Mute")
        this.Close()
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

    ; ============================================================
    ; Hotkey CAPTURE mode (v0.1.0)
    ; ============================================================
    ;
    ; Flow:
    ;   1. User clicks "Capture" next to a hotkey
    ;   2. Button label changes to "Press..." and global input is suppressed
    ;   3. User presses the combo (e.g. Ctrl+Alt+G)
    ;   4. InputHook OnKeyDown captures the NON-modifier key; modifier
    ;      state is read via GetKeyState at the exact moment
    ;   5. Edit is updated with the combo in human-readable format
    ;
    ; CANCEL:
    ;   - Esc alone (no modifier) cancels the capture
    ;   - Esc+modifier (Ctrl+Esc, etc) is a valid bind
    ;   - 10s timeout also cancels silently
    ;
    ; _MakeCaptureHandler is necessary because fat-arrows in a loop
    ; do not capture the iteration variable's value correctly (the
    ; closure picks up the last assignment). Wrapping in a method
    ; creates a fresh scope per call, fixing `action`.
    ; ============================================================
    _MakeCaptureHandler(action)
    {
        return (*) => this._OnCaptureHotkey(action)
    }

    ; v0.1.0: Clear button handler. Clears the edit; _OnSave persists
    ; as empty string, unbinding the hotkey.
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

        ; v0.1.1: `edit` collides with the builtin `Edit` (Gui control).
        ; `btn` may also collide (Button). Use Ctrl suffixes.
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
}
