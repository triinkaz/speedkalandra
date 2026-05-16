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

        ; v0.1.3: campo "Patch" removido do dialog. cfg.gamePatch ainda
        ; existe internamente (default "Unknown") pra retrocompat com runs
        ; antigas salvas no historico, mas o usuario nao precisa mais
        ; manter manualmente.

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

        ; v0.1.0: hint sobre a UX de captura. Edit field eh ReadOnly,
        ; usuario interage so via botoes (Capture + Clear).
        g.SetFont("s8 c" Theme.Color("muted"), Theme.FONT_UI)
        g.Add("Text", "x16 y" y " w520",
            "Click 'Capture' to record a key combo (Esc cancels). 'Clear' to unbind.")
        y += 18

        ; Ordena actions alfabeticamente
        this._hotkeyActions := []
        for action, _ in this._cfg.hotkeys
            this._hotkeyActions.Push(action)
        this._SortArray(this._hotkeyActions)

        for _, action in this._hotkeyActions
        {
            this._Label(g, y, action)
            ; v0.1.0: Edit eh ReadOnly. Display em formato human ("Ctrl+Alt+F")
            ; via HotkeyFormatter. Interacao so via botoes Capture/Clear.
            ; _OnSave converte de volta pra AHK syntax ("^!f") na hora de
            ; persistir.
            displayVal := HotkeyFormatter.ToHuman(this._cfg.GetHotkey(action))
            this._ctrls["hk_" action] := this._AddEdit(g, 180, y, 200, displayVal, "ReadOnly")

            ; Capture button: graba proximo combo via InputHook
            g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
            btnCap := g.Add("Button", "x384 y" (y-1) " w60 h22", "Capture")
            btnCap.OnEvent("Click", this._MakeCaptureHandler(action))
            this._ctrls["btn_capture_" action] := btnCap

            ; Clear button: desbinda a hotkey (limpa o edit)
            btnClr := g.Add("Button", "x448 y" (y-1) " w50 h22", "Clear")
            btnClr.OnEvent("Click", this._MakeClearHandler(action))
            this._ctrls["btn_clear_" action] := btnClr

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
    ;
    ;   v0.1.3: altura fixa h22 pra evitar Edit auto-expandir em multi
    ;   linhas quando o valor eh longo (caso do logFile com path full
    ;   do Steam). Antes, o Edit do logFile crescia pra 3 linhas e
    ;   sobrepunha visualmente o campo abaixo.
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
            ; v0.1.1: `file` colide com builtin `File`. Usar `selectedFile`.
            selectedFile := FileSelect(1, this._cfg.logFile, "Select Client.txt", "Logs (*.txt)")
            if (selectedFile != "")
                this._ctrls["logFile"].Value := selectedFile
        }
    }

    _OnSave()
    {
        cfg := this._cfg
        cfg.profileName := this._ctrls["profileName"].Value
        ; v0.1.3: gamePatch nao eh mais editavel no dialog. Mantem o valor
        ; que ja estava em cfg (default "Unknown" em fresh install).
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
        ; v0.1.0: usuario digita formato human-readable ("Ctrl+Alt+F");
        ; HotkeyFormatter.ToAhk converte pra syntax interno ("^!f") antes
        ; de persistir. Tolerante a passthrough do formato antigo.
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

    ; ============================================================
    ; Hotkey CAPTURE mode (v0.1.0)
    ; ============================================================
    ;
    ; Fluxo:
    ;   1. User clica "Capture" ao lado de uma hotkey
    ;   2. Botao muda label pra "Press..." e suprime input global
    ;   3. User pressiona o combo (ex: Ctrl+Alt+G)
    ;   4. InputHook OnKeyDown captura a key NAO-modifier; modifier
    ;      state eh lido via GetKeyState no momento exato
    ;   5. Edit eh atualizado com o combo em formato human-readable
    ;
    ; CANCELAR:
    ;   - Esc sozinho (sem modifier) cancela a captura
    ;   - Esc+modifier (Ctrl+Esc, etc) eh bind valido
    ;   - Timeout de 10s tambem cancela silenciosamente
    ;
    ; _MakeCaptureHandler eh necessario pq fat-arrows em loop nao
    ; capturam o valor da variavel de iteracao corretamente (closure
    ; pega a ultima atribuicao). Wrapping num metodo cria escopo novo
    ; por chamada, fixando o `action`.
    ; ============================================================
    _MakeCaptureHandler(action)
    {
        return (*) => this._OnCaptureHotkey(action)
    }

    ; v0.1.0: handler do botao Clear. Limpa o edit; _OnSave persiste
    ; como string vazia, desbindando a hotkey.
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

        ; v0.1.1: `edit` colide com builtin `Edit` (controle Gui).
        ; `btn` tambem pode colidir (Button). Usar sufixos Ctrl.
        editCtrl := this._ctrls[editKey]
        btnCtrl  := this._ctrls[btnKey]

        originalLabel := "Capture"
        try originalLabel := btnCtrl.Text
        try btnCtrl.Text := "Press..."

        ; State capturado por referencia pelo OnKeyDown handler.
        ; Object literal pra mutacao via referencia (Map serviria tambem).
        state := { key: "", mods: "", cancelled: false }

        try
        {
            ih := InputHook("T10")          ; 10s timeout, suprime input por default
            ih.KeyOpt("{All}", "N")         ; notify on all key down
            ih.OnKeyDown := (hookObj, vk, sc) => this._HandleCaptureKey(hookObj, vk, sc, state)
            ih.Start()
            ih.Wait()
        }
        catch as ex
        {
            OutputDebug("SettingsDialog._OnCaptureHotkey falhou: " ex.Message)
        }

        ; Restaura botao (defensivo contra dialog fechado mid-capture)
        try btnCtrl.Text := originalLabel

        if (state.cancelled || state.key = "")
            return

        ; Monta hotkey AHK syntax e converte pra human pro display
        ahkKey := state.mods . state.key
        try editCtrl.Value := HotkeyFormatter.ToHuman(ahkKey)
    }

    ; Callback do InputHook.OnKeyDown. Roda no thread do hook.
    ; Atualiza `state` (passado por referencia) e chama ih.Stop quando
    ; captura uma key valida.
    _HandleCaptureKey(ih, vk, sc, state)
    {
        ; Modifiers sozinhos NAO sao key valida — esperamos uma key
        ; "real" enquanto modifiers estao segurados.
        ;   0x10 = Shift,   0xA0/A1 = LShift/RShift
        ;   0x11 = Ctrl,    0xA2/A3 = LCtrl/RCtrl
        ;   0x12 = Alt,     0xA4/A5 = LAlt/RAlt
        ;   0x5B/5C = LWin/RWin
        if (vk = 0x10 || vk = 0xA0 || vk = 0xA1
         || vk = 0x11 || vk = 0xA2 || vk = 0xA3
         || vk = 0x12 || vk = 0xA4 || vk = 0xA5
         || vk = 0x5B || vk = 0x5C)
            return

        ; Esc PURO (sem modifier) cancela. Esc+modifier (Ctrl+Esc, etc)
        ; eh bind valido — cai pro caminho normal abaixo.
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

        ; Captura nome da key + modifier state no instante exato.
        ; "vkXXscYY" eh a forma mais robusta de obter o nome (diferencia
        ; NumpadEnter vs Enter, etc).
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
