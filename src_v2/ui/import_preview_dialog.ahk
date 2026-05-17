; ============================================================
; ImportPreviewDialog - import preview/confirmation dialog (v0.1.0)
; ============================================================
;
; Opened by the Cmd.ImportRunsRequested handler in app.ahk after
; RunImportService.Preview succeeds. Shows:
;   - File path (basename)
;   - Meta (exported at, by, anonymized, has PBs)
;   - Summary (total, new, identical, rename)
;   - Warnings (if any)
;   - 3 radios for PB strategy (keep default, rebuild, replace)
;   - Cancel / Import
;
; FLOW:
;   1. RunHistoryDialog -> "Import..." button -> FileSelect ->
;      bus.Publish(Cmd.ImportRunsRequested, {path})
;   2. app.ahk._OnImportRunsRequested calls RunImportService.Preview
;   3. If preview ok -> this.OpenWithPreview(preview)
;   4. User configures strategy + clicks Import
;   5. _OnImport calls RunImportService.Execute
;   6. MsgBox with result + this.Close()
;   7. RunHistoryDialog listens to Evt.RunsImported to refresh the list
;
; PB STRATEGY UX:
;   - "keep" (default): no-op, safest
;   - "rebuild": rebuilds PBs from current history (includes imports)
;   - "replace": replaces local PBs with the ones from the file.
;     DISABLED if the file has no PBs. Extra confirmation before
;     executing.
;
; CONSTRUCTION:
;   dialog := ImportPreviewDialog(bus, importService, headless)


class ImportPreviewDialog
{
    static WINDOW_W := 560
    static WINDOW_H := 460

    _bus           := ""
    _importService := ""
    _headless      := false

    _gui     := ""
    _ctrls   := ""
    _preview := ""
    _isOpen  := false

    __New(bus, importService, headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("ImportPreviewDialog: 'bus' must be EventBus")
        if !(importService is RunImportService)
            throw TypeError("ImportPreviewDialog: 'importService' must be RunImportService")

        this._bus           := bus
        this._importService := importService
        this._headless      := !!headless
        this._ctrls         := Map()
    }

    ; ============================================================
    ; OpenWithPreview(preview) - opens the dialog with preview data
    ;
    ; Expects a Map from RunImportService.Preview with success=true.
    ; ============================================================
    OpenWithPreview(preview)
    {
        if this._headless
            return
        if !IsObject(preview) || !preview.Has("success") || !preview["success"]
            return
        if this._isOpen
            this.Close()

        this._preview := preview
        this._isOpen := true
        this._BuildGui()
        this._gui.Show("w" ImportPreviewDialog.WINDOW_W " h" ImportPreviewDialog.WINDOW_H)
    }

    Close()
    {
        if this._gui
        {
            try this._gui.Destroy()
            this._gui := ""
        }
        this._ctrls := Map()
        this._preview := ""
        this._isOpen := false
    }

    ; ============================================================
    ; Internals
    ; ============================================================

    _BuildGui()
    {
        prev := this._preview
        sum  := prev["summary"]
        meta := prev["meta"]

        g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox +ToolWindow",
                 "Import preview")
        g.MarginX := 16
        g.MarginY := 14
        g.BackColor := Theme.Color("bg")
        g.SetFont("s10 c" Theme.Color("text"), Theme.FONT_UI)

        ; --- Header ---
        g.SetFont("s11 bold c" Theme.Color("text"), Theme.FONT_UI)
        g.Add("Text", "x16 y14 w528", "Import runs from JSON")
        g.SetFont("s10 c" Theme.Color("text"), Theme.FONT_UI)

        ; --- File info ---
        fileName := ""
        try SplitPath(prev["path"], &fileName)
        if (fileName = "")
            fileName := prev["path"]
        g.Add("Text", "x16 y44 w528", "File: " fileName)

        ; --- Meta ---
        g.SetFont("s9 c" Theme.Color("muted"), Theme.FONT_UI)
        exportedAt := meta.Has("exportedAt") ? String(meta["exportedAt"]) : "?"
        exportedBy := meta.Has("exportedBy") ? String(meta["exportedBy"]) : "?"
        g.Add("Text", "x16 y64 w528", "Exported " exportedAt " by " exportedBy)

        anonStr := (meta.Has("anonymized") && meta["anonymized"])
            ? "Anonymized: yes (profile names blanked)"
            : "Anonymized: no"
        g.Add("Text", "x16 y80 w528", anonStr)

        pbStr := IsObject(prev["importedPbs"])
            ? "Personal bests included in file: yes"
            : "Personal bests included in file: no"
        g.Add("Text", "x16 y96 w528", pbStr)

        ; --- Summary section ---
        g.SetFont("s9 c" Theme.Color("muted") " bold", Theme.FONT_UI)
        g.Add("Text", "x16 y124 w528", "SUMMARY")

        g.SetFont("s10 c" Theme.Color("text"), Theme.FONT_UI)
        g.Add("Text", "x32 y144 w528", "Total runs in file: " sum["total"])
        g.Add("Text", "x32 y162 w528", "New (will import): " sum["new"])
        g.Add("Text", "x32 y180 w528", "Identical (will skip): " sum["identical"])
        g.Add("Text", "x32 y198 w528", "Conflicts (will rename _imported): " sum["rename"])

        ; --- Warnings (if any) ---
        ; v0.1.0 Phase 5: cap at 5 visible to avoid dialog overflow when
        ; the file has many warnings. Final summary shows how many were
        ; left out.
        wY := 224
        if prev["warnings"].Length > 0
        {
            g.SetFont("s9 c" Theme.Color("muted") " bold", Theme.FONT_UI)
            g.Add("Text", "x16 y" wY " w528", "WARNINGS")
            wY += 18
            g.SetFont("s9 c" Theme.Color("muted"), Theme.FONT_UI)

            maxShow := 5
            shown := 0
            for _, w in prev["warnings"]
            {
                if (shown >= maxShow)
                {
                    extra := prev["warnings"].Length - maxShow
                    g.Add("Text", "x32 y" wY " w512",
                        "... and " extra " more warning" (extra = 1 ? "" : "s"))
                    wY += 16
                    break
                }
                g.Add("Text", "x32 y" wY " w512", "• " w)
                wY += 16
                shown += 1
            }
            wY += 6
        }

        ; --- PB strategy section ---
        g.SetFont("s9 c" Theme.Color("muted") " bold", Theme.FONT_UI)
        g.Add("Text", "x16 y" wY " w528", "PERSONAL BESTS STRATEGY")
        wY += 22

        g.SetFont("s10 c" Theme.Color("text"), Theme.FONT_UI)

        this._ctrls["radio_keep"] := g.Add("Radio",
            "x32 y" wY " w480 Group Checked",
            "Keep my current PBs (recommended)")
        wY += 22

        this._ctrls["radio_rebuild"] := g.Add("Radio",
            "x32 y" wY " w480",
            "Rebuild PBs from full history (after import)")
        wY += 22

        hasPbs := IsObject(prev["importedPbs"])
        replaceLabel := hasPbs
            ? "Replace with imported PBs (DESTRUCTIVE — overwrites local)"
            : "Replace with imported PBs (unavailable — file has no PBs)"
        replaceOpts := "x32 y" wY " w480"
        if !hasPbs
            replaceOpts .= " Disabled"
        this._ctrls["radio_replace"] := g.Add("Radio", replaceOpts, replaceLabel)
        wY += 32

        ; --- Buttons ---
        btnY := ImportPreviewDialog.WINDOW_H - 48

        btnCancel := g.Add("Button", "x340 y" btnY " w90 h30", "Cancel")
        btnCancel.OnEvent("Click", (*) => this.Close())

        ; Import is disabled if there's nothing to do
        canImport := (sum["new"] + sum["rename"]) > 0
        importOpts := "x440 y" btnY " w104 h30 Default"
        if !canImport
            importOpts .= " Disabled"
        btnImport := g.Add("Button", importOpts, "Import")
        btnImport.OnEvent("Click", (*) => this._OnImport())

        g.OnEvent("Close",  (*) => this.Close())
        g.OnEvent("Escape", (*) => this.Close())

        this._gui := g
    }

    _OnImport()
    {
        strategy := this._DeterminePbStrategy()

        ; Extra warning for "replace" (destructive)
        if (strategy = "replace")
        {
            answer := ""
            try
                answer := SpeedKalandraMsgBox(
                    "Are you sure you want to REPLACE your local Personal Bests with the ones from the imported file?`n`n"
                    . "This will overwrite your current PBs and cannot be undone.",
                    "Replace PBs - confirm",
                    "YesNo Icon!")
            catch
                return
            if (answer != "Yes")
                return
        }

        result := this._importService.Execute(this._preview, strategy)

        msg := "IMPORT RESULT:`n`n"
            . "Imported: " result["imported"] "`n"
            . "  (of which renamed: " result["renamed"] ")`n"
            . "Skipped (identical): " result["skipped"] "`n"
            . "PBs: " result["pbAction"]

        if result["errors"].Length > 0
        {
            msg .= "`n`nErrors:"
            for _, e in result["errors"]
                msg .= "`n  - " e
        }

        try SpeedKalandraMsgBox(msg, "Import complete",
            result["success"] ? "Iconi" : "IconX")

        this.Close()
    }

    ; Reads the 3 radios and returns the chosen strategy.
    _DeterminePbStrategy()
    {
        try
        {
            if this._ctrls.Has("radio_rebuild") && this._ctrls["radio_rebuild"].Value
                return "rebuild"
            if this._ctrls.Has("radio_replace") && this._ctrls["radio_replace"].Value
                return "replace"
        }
        return "keep"
    }
}
