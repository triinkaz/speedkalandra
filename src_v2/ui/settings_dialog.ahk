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
;   VendorRegexes     3 slots (max 50 chars each) for V1/V2/V3 shortcuts
;   Rules             AutoPauseOnFocus, DeathPenaltyEnabled + seconds
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
        ; Death penalty: UI shows seconds for friendliness;
        ; conversion to ms happens on save.
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
        g.Show("w" SettingsDialog.WINDOW_W " h" finalH)
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
        cfg := this._cfg
        cfg.profileName := this._ctrls["profileName"].Value
        ; gamePatch keeps whatever was already in cfg (default
        ; "Unknown" on a fresh install); the dialog doesn't expose it.

        ; Snapshot the old log path so we can detect a change and
        ; restart LogMonitor without a full app reload.
        oldLogFile := cfg.logFile
        cfg.logFile     := this._ctrls["logFile"].Value
        cfg.autoStartRegex    := this._ctrls["autoStartRegex"].Value
        cfg.autoFinalizeRegex := this._ctrls["autoFinalizeRegex"].Value

        ; Vendor regex slots — defensive 50-char clamp matches the
        ; Edit's Limit50.
        ;
        ; Snapshot vendorRegexes BEFORE rewriting cfg so we can emit
        ; Evt.VendorRegexesChanged on real changes and the
        ; CompactLayoutWidget refreshes its V1/V2/V3 button labels.
        oldVendorRegexes := SettingsDialog._CloneStringArray(cfg.vendorRegexes)
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
        vendorRegexesChanged := !SettingsDialog._StringArraysEqual(oldVendorRegexes, cfg.vendorRegexes)

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

        ; Hotkeys.
        ; The user types in human format ("Ctrl+Alt+F");
        ; HotkeyFormatter.ToAhk converts to internal syntax ("^!f")
        ; before persisting. Old-format input passes through as-is.
        ;
        ; Snapshot oldHotkeys BEFORE the loop so we can emit
        ; Evt.HotkeysChanged and trigger a hot rebind in HotkeyService.
        oldHotkeys := SettingsDialog._CloneStringMap(cfg.hotkeys)
        for _, action in this._hotkeyActions
        {
            ctrlKey := "hk_" action
            if this._ctrls.Has(ctrlKey)
            {
                rawVal := Trim(this._ctrls[ctrlKey].Value)
                cfg.hotkeys[action] := HotkeyFormatter.ToAhk(rawVal)
            }
        }
        hotkeysChanged := !SettingsDialog._StringMapsEqual(oldHotkeys, cfg.hotkeys)

        try this._settingsRepo.Save(cfg)
        ; logFile change → publish so the composition root can
        ; restart LogMonitor against the new path. Empty new path is
        ; also published (the user may want monitoring disabled).
        if (Trim(oldLogFile) != Trim(cfg.logFile))
        {
            try this._bus.Publish(Events.LogFilePathChanged, Map(
                "oldPath", oldLogFile,
                "newPath", cfg.logFile))
        }
        ; hotkeys change → publish so HotkeyService can rebind
        ; without a full app reload. Send a defensive copy of the new
        ; map so the handler can't accidentally mutate cfg.hotkeys.
        if hotkeysChanged
        {
            try this._bus.Publish(Events.HotkeysChanged, Map(
                "oldHotkeys", oldHotkeys,
                "newHotkeys", SettingsDialog._CloneStringMap(cfg.hotkeys)))
        }
        ; vendor regex change → publish so CompactLayoutWidget can
        ; refresh its V1/V2/V3 button labels (filled vs empty)
        ; without a full app reload. Send a copy of the new array.
        if vendorRegexesChanged
        {
            try this._bus.Publish(Events.VendorRegexesChanged, Map(
                "oldRegexes", oldVendorRegexes,
                "newRegexes", SettingsDialog._CloneStringArray(cfg.vendorRegexes)))
        }
        try TrayTip("SpeedKalandra", "Settings saved.", "Mute")
        this.Close()
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
}
