; ============================================================
; ExportOptionsDialog - export options dialog
; ============================================================
;
; Opened when the user clicks "Export selected" or "Export all" in
; RunHistoryDialog. Shows a preview of the operation + options
; (anonymize, includePbs) + path picker.
;
; FLOW:
;   1. RunHistoryDialog publishes Cmd.ExportRunsRequested with runIds[]
;   2. app.ahk handler opens this dialog: Open(runIds)
;   3. User configures options + path
;   4. Click "Export" -> calls RunExportService.Export
;   5. Shows a MsgBox with the result (count + path of generated file)
;   6. Closes
;
; LAYOUT:
;   +---------------------------------------------+
;   | Export runs                                 |
;   |                                             |
;   | You're exporting: 3 runs                    |
;   |                                             |
;   | Options:                                    |
;   |   [x] Anonymize (replace profile name)      |
;   |   [x] Include personal bests                |
;   |                                             |
;   | Output file:                                |
;   |   [_______________________] [Browse...]     |
;   |                                             |
;   |                  [Cancel]  [Export]         |
;   +---------------------------------------------+
;
; SUBSCRIPTIONS:
;   None. Opened explicitly via Open(runIds) by the
;   Cmd.ExportRunsRequested handler in app.ahk.
;
; CONSTRUCTION:
;   dialog := ExportOptionsDialog(bus, exportService, headless)


class ExportOptionsDialog
{
    static WINDOW_W := 520
    static WINDOW_H := 280

    _bus           := ""
    _exportService := ""
    _headless      := false

    _gui      := ""
    _ctrls    := ""
    _runIds   := ""
    _isOpen   := false

    __New(bus, exportService, headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("ExportOptionsDialog: 'bus' must be EventBus")
        if !(exportService is RunExportService)
            throw TypeError("ExportOptionsDialog: 'exportService' must be RunExportService")

        this._bus           := bus
        this._exportService := exportService
        this._headless      := !!headless
        this._ctrls         := Map()
        this._runIds        := []
    }

    ; ============================================================
    ; Open(runIds) - opens the dialog with the list of runs to export
    ;
    ; runIds: Array<string>. If empty or non-array, no-op with log.
    ; ============================================================
    Open(runIds)
    {
        if this._headless
            return
        if !IsObject(runIds) || !(runIds is Array) || runIds.Length = 0
        {
            try TrayTip("SpeedKalandra", "Nothing to export.", "Mute")
            return
        }
        if this._isOpen
            this.Close()

        this._runIds := runIds.Clone()
        this._isOpen := true
        this._BuildGui()
        this._gui.Show("w" ExportOptionsDialog.WINDOW_W " h" ExportOptionsDialog.WINDOW_H)
    }

    Close()
    {
        if this._gui
        {
            try this._gui.Destroy()
            this._gui := ""
        }
        this._ctrls := Map()
        this._isOpen := false
    }

    ; ============================================================
    ; Internals
    ; ============================================================

    _BuildGui()
    {
        g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox +ToolWindow",
                 "Export runs")
        g.MarginX := 16
        g.MarginY := 14
        g.BackColor := Theme.Color("bg")
        g.SetFont("s10 c" Theme.Color("text"), Theme.FONT_UI)

        ; Header
        g.SetFont("s11 bold c" Theme.Color("text"), Theme.FONT_UI)
        g.Add("Text", "x16 y14 w488", "Export runs to JSON")
        g.SetFont("s10 c" Theme.Color("text"), Theme.FONT_UI)

        ; Count
        n := this._runIds.Length
        countText := n = 1
            ? "You're exporting: 1 run"
            : "You're exporting: " n " runs"
        g.Add("Text", "x16 y44 w488", countText)

        ; --- Options ---
        g.SetFont("s9 c" Theme.Color("muted") " bold", Theme.FONT_UI)
        g.Add("Text", "x16 y78 w488", "OPTIONS")

        g.SetFont("s10 c" Theme.Color("text"), Theme.FONT_UI)
        this._ctrls["anonymize"] := g.Add("Checkbox",
            "x16 y98 w488 Checked", "Anonymize (replace profile name with 'Anonymous')")
        this._ctrls["includePbs"] := g.Add("Checkbox",
            "x16 y122 w488 Checked", "Include personal bests")

        ; --- Output path ---
        g.SetFont("s9 c" Theme.Color("muted") " bold", Theme.FONT_UI)
        g.Add("Text", "x16 y156 w488", "OUTPUT FILE")

        g.SetFont("s10 c" Theme.Color("text"), Theme.FONT_UI)
        defaultPath := RunExportService.GetDefaultExportPath()
        this._ctrls["path"] := g.Add("Edit",
            "x16 y176 w400 h22", defaultPath)
        btnBrowse := g.Add("Button", "x422 y175 w82 h24", "Browse...")
        btnBrowse.OnEvent("Click", (*) => this._OnBrowse())

        ; --- Buttons ---
        btnY := 220
        btnCancel := g.Add("Button", "x310 y" btnY " w90 h30", "Cancel")
        btnCancel.OnEvent("Click", (*) => this.Close())

        btnExport := g.Add("Button", "x410 y" btnY " w94 h30 Default", "Export")
        btnExport.OnEvent("Click", (*) => this._OnExport())

        g.OnEvent("Close",  (*) => this.Close())
        g.OnEvent("Escape", (*) => this.Close())

        this._gui := g
    }

    _OnBrowse()
    {
        ; Ensure the default folder exists before FileSelect
        RunExportService.EnsureExportDir()

        currentPath := this._ctrls["path"].Value
        ; FileSelect Save mode ("S2" = require non-existing dir parent valid + overwrite prompt)
        ; Default 1 = overwrite warning if file exists
        try
        {
            selected := FileSelect("S 8", currentPath,
                "Save export as", "JSON files (*.json)")
            if (selected != "")
                this._ctrls["path"].Value := selected
        }
        catch as ex
        {
            OutputDebug("ExportOptionsDialog._OnBrowse failed: " ex.Message)
        }
    }

    _OnExport()
    {
        path := Trim(this._ctrls["path"].Value)
        if (path = "")
        {
            try SpeedKalandraMsgBox("Please specify an output file path.",
                "Export runs", "IconX")
            return
        }

        ; Ensure .json extension
        if !RegExMatch(path, "i)\.json$")
            path .= ".json"

        ; Confirms overwrite if the file exists
        if FileExist(path)
        {
            result := ""
            try
                result := SpeedKalandraMsgBox("File already exists:`n`n" path
                    . "`n`nOverwrite?", "Export runs", "YesNo Icon?")
            catch
                return
            if (result != "Yes")
                return
        }

        anonymize  := this._ctrls["anonymize"].Value = 1
        includePbs := this._ctrls["includePbs"].Value = 1

        result := this._exportService.Export(this._runIds, path, Map(
            "anonymized", anonymize,
            "includePbs", includePbs
        ))

        if result["success"]
        {
            count := result["runsExported"]
            msg := count " run" (count = 1 ? "" : "s")
                . " exported to:`n`n" result["path"]
            if (result["errors"].Length > 0)
            {
                msg .= "`n`nWarnings (non-fatal):"
                for _, e in result["errors"]
                    msg .= "`n  - " e
            }
            try SpeedKalandraMsgBox(msg, "Export complete", "Iconi")
            this.Close()
        }
        else
        {
            msg := "Export failed.`n`nErrors:"
            for _, e in result["errors"]
                msg .= "`n  - " e
            try SpeedKalandraMsgBox(msg, "Export failed", "IconX")
            ; Doesn't close the dialog — user can retry with different options
        }
    }
}
