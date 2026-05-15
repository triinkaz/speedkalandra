; ============================================================
; SettingsDialog - janela de configuracoes (Onda 6, minimal)
; ============================================================
;
; Dialog minimalista alinhado com AppSettings novo. Permite editar:
;   - General: ProfileName, GamePatch, LogFile path
;   - AutoStart: Regex (PoE2 eh localizado — user configura por idioma)
;   - AutoFinalize: Regex
;   - VendorRegexes: 3 slots (max 50 chars cada) pra atalhos V1/V2/V3
;   - Rules: AutoPauseOnFocus, DeathPenaltyEnabled + Penalty seconds
;   - Hotkeys (todas as actions registradas no cfg.hotkeys)
;
;   v17.15 (Bug #15): removidas linhas de UI pra PanelKeys.
;   v17.15.1: re-adicionada UI pra death penalty (descobriu-se que o
;   plot consumia esses campos).
;
; SUBSCRIPTIONS:
;   Cmd.OpenSettingsRequested -> Open()
;
; CONSTRUCAO:
;   dialog := SettingsDialog(bus, settingsRepo, cfg, headless := false)
;   ; bus.Publish(Commands.OpenSettingsRequested) abre
;
; NOTA SOBRE FONTES EM Gui.Add:
;   AHK v2 NAO aceita "s<size>" ou "c<hex>" como options inline na
;   string de Gui.Add("Edit", ...). Tamanho de fonte e cor sao
;   configurados via g.SetFont(...) ANTES do Add, e o controle
;   herda esses settings. Por isso o helper _AddEdit() seta a fonte
;   antes de adicionar.
;
;   Casos onde "c<hex>" inline SE aceita: Text, Link, Checkbox,
;   Radio, Button, GroupBox, Slider, Tab. Mas "s<size>" inline
;   nao funciona em nenhum controle. Para uniformidade, todos os
;   inputs do dialog usam SetFont.


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
    _hotkeyActions := ""    ; Array<actionName> ordenado

    __New(bus, settingsRepo, cfg, headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("SettingsDialog: 'bus' deve ser EventBus")
        if !(settingsRepo is SettingsRepository)
            throw TypeError("SettingsDialog: 'settingsRepo' deve ser SettingsRepository")
        if !(cfg is AppSettings)
            throw TypeError("SettingsDialog: 'cfg' deve ser AppSettings")

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
        g := Gui("+AlwaysOnTop +Resize -MaximizeBox", "SpeedKalandra - Settings")
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

        this._Label(g, y, "Patch")
        this._ctrls["gamePatch"] := this._AddEdit(g, 180, y, 360, this._cfg.gamePatch)
        y += 26

        this._Label(g, y, "PoE2 log (Client.txt)")
        this._ctrls["logFile"] := this._AddEdit(g, 180, y, 280, this._cfg.logFile)
        btnBrowse := g.Add("Button", "x466 y" (y - 2) " w74 h22", "Browse...")
        btnBrowse.OnEvent("Click", (*) => this._OnBrowseLog())
        y += 32

        ; v17.15 (Bug #15): linha de "Panel keys (csv)" removida.
        ; PanelKeyService foi desconectado em v17.2 e o campo
        ; panelOverlayKeys nao existe mais em AppSettings.

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

        ; ============ Vendor Regex Slots (Onda 8) ============
        ; Edits limitados a 50 chars via "Limit50". Botoes V1/V2/V3 do
        ; CompactLayoutWidget copiam cada slot pra clipboard com Ctrl+click.
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
        ; v17.15.1: death penalty (re-adicionado apos #15 over-removal).
        ; UI mostra segundos pra ser amigavel; convertido pra ms no save.
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

        ; Ordena actions alfabeticamente
        this._hotkeyActions := []
        for action, _ in this._cfg.hotkeys
            this._hotkeyActions.Push(action)
        this._SortArray(this._hotkeyActions)

        for _, action in this._hotkeyActions
        {
            this._Label(g, y, action)
            this._ctrls["hk_" action] := this._AddEdit(g, 180, y, 200, this._cfg.GetHotkey(action))
            y += 24
        }
        y += 12

        ; ============ Botoes ============
        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        btnSave := g.Add("Button", "x180 y" y " w120 h28", "Save")
        btnSave.OnEvent("Click", (*) => this._OnSave())
        btnCancel := g.Add("Button", "x310 y" y " w120 h28", "Cancel")
        btnCancel.OnEvent("Click", (*) => this.Close())

        finalH := y + 50
        g.Show("w" SettingsDialog.WINDOW_W " h" finalH)
    }

    ; ============================================================
    ; _AddEdit - helper que seta fonte ANTES e adiciona Edit com
    ;   options simples (sem opcoes de fonte inline, que AHK v2
    ;   rejeita).
    ;
    ;   extraOpts: opcoes adicionais validas pra Edit (ex: "Number",
    ;     "ReadOnly", "Multi", "Password"). NUNCA passar s<n> ou c<hex>.
    ; ============================================================
    _AddEdit(g, x, y, w, value, extraOpts := "")
    {
        g.SetFont(Theme.InputFont(), Theme.FONT_UI)
        opts := "x" x " y" y " w" w " " Theme.InputBg()
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
            file := FileSelect(1, this._cfg.logFile, "Select Client.txt", "Logs (*.txt)")
            if (file != "")
                this._ctrls["logFile"].Value := file
        }
    }

    _OnSave()
    {
        cfg := this._cfg
        cfg.profileName := this._ctrls["profileName"].Value
        cfg.gamePatch   := this._ctrls["gamePatch"].Value
        cfg.logFile     := this._ctrls["logFile"].Value
        cfg.autoStartRegex    := this._ctrls["autoStartRegex"].Value
        cfg.autoFinalizeRegex := this._ctrls["autoFinalizeRegex"].Value

        ; Vendor regex slots (Onda 8) — clamp defensivo a 50 chars
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

        ; v17.15.1: death penalty re-adicionado. UI usa segundos, persiste
        ; em ms. Defensivo: se input vazio/invalido cai pra 150s default.
        cfg.deathPenaltyEnabled := this._ctrls["deathPenaltyEnabled"].Value = 1
        try
        {
            secs := Integer(this._ctrls["deathPenaltySec"].Value + 0)
            cfg.deathPenaltyMs := secs >= 0 ? secs * 1000 : 0
        }
        catch
            cfg.deathPenaltyMs := 150000

        ; Hotkeys
        for _, action in this._hotkeyActions
        {
            ctrlKey := "hk_" action
            if this._ctrls.Has(ctrlKey)
                cfg.hotkeys[action] := Trim(this._ctrls[ctrlKey].Value)
        }

        try this._settingsRepo.Save(cfg)
        try TrayTip("SpeedKalandra", "Settings saved.", "Mute")
        this.Close()
    }

    ; Bubble sort simples (lista pequena ~10 hotkeys)
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
}
