; RunHistoryDialog — lists every saved run on disk and gives the
; user actions over them (open plot, set as PB, delete, export,
; import). Subscribes to Cmd.OpenRunHistoryRequested.
;
; Layout:
;
;   +-------------------------------------------+
;   | Run History (N saved)                     |
;   |                                           |
;   | ListView 5 cols:                          |
;   |   Date | RunId | Duration | Deaths | Profile
;   |                                           |
;   | [Open plot] [Set as PB] [Delete] [Close]  |
;   | [Export selected] [Export all] [Import...]|
;   +-------------------------------------------+
;
; Set as PB updates only runPbMs + runPbRunId (and runPbByAct
; checkpoints when the chosen run has them). Per-zone PBs stay
; aggregated from all runs.
;
; Delete removes the run from disk and triggers
; PersonalBestService.RebuildFromHistory on the remaining set, so a
; PB sourced from the deleted run gets replaced or cleared.


class RunHistoryDialog
{
    static WINDOW_W := 620
    static WINDOW_H := 520    ; Tall enough to fit the second row of buttons.

    _bus         := ""
    _repo        := ""
    _plotDialog  := ""
    _personalBest := ""    ; PersonalBestService, for RebuildFromHistory / SetAsRunPb
    _headless    := false

    _gui    := ""
    _ctrls  := ""
    _isOpen := false

    ; Cache: runIds in ListView order to grab by selected row.
    _runIdsByRow := ""    ; Array<string>

    __New(bus, runHistory, plotDialog, personalBest, headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("RunHistoryDialog: 'bus' must be EventBus")
        if !(runHistory is RunHistoryRepository)
            throw TypeError("RunHistoryDialog: 'runHistory' must be RunHistoryRepository")
        if !(plotDialog is RunStatsPlotDialog)
            throw TypeError("RunHistoryDialog: 'plotDialog' must be RunStatsPlotDialog")
        ; personalBest can be "" for back-compat (tests can build without
        ; it); in production it must be PersonalBestService.
        if (personalBest != "" && !(personalBest is PersonalBestService))
            throw TypeError("RunHistoryDialog: 'personalBest' must be PersonalBestService or empty")

        this._bus          := bus
        this._repo         := runHistory
        this._plotDialog   := plotDialog
        this._personalBest := personalBest
        this._headless     := !!headless
        this._ctrls        := Map()
        this._runIdsByRow  := []

        bus.Subscribe(Commands.OpenRunHistoryRequested, (data) => this.Open())

        ; Auto-refresh on import: if the dialog is open, reload the
        ; list so freshly imported runs show up; if closed, no-op
        ; (the next Open reads from disk anyway).
        bus.Subscribe(Events.RunsImported, (data) => this._OnRunsImported(data))
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
            this._RefreshList()
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
        g := Gui("+AlwaysOnTop -MaximizeBox", "SpeedKalandra - Run History")
        g.BackColor := Theme.Color("bg")
        g.MarginX := 14
        g.MarginY := 12
        g.OnEvent("Close", (*) => this.Close())
        g.OnEvent("Escape", (*) => this.Close())
        this._gui := g

        ; Header
        g.SetFont("s12 bold c" Theme.Color("text"), Theme.FONT_UI)
        this._ctrls["header"] := g.Add("Text", "x14 y10 w580", "Run History")

        ; ListView
        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        lvW := 580
        lvH := 360
        this._ctrls["list"] := g.Add("ListView",
            "x14 y44 w" lvW " h" lvH " Background" Theme.Color("surface2"),
            ["Date", "Run ID", "Duration", "Deaths", "Profile"])
        this._ctrls["list"].ModifyCol(1, 150)
        this._ctrls["list"].ModifyCol(2, 130)
        this._ctrls["list"].ModifyCol(3, 80)
        this._ctrls["list"].ModifyCol(4, 60)
        this._ctrls["list"].ModifyCol(5, 140)

        ; Double-click opens plot
        this._ctrls["list"].OnEvent("DoubleClick", (*) => this._OnOpenSelected())

        ; Buttons
        btnY := 44 + lvH + 8
        btnOpen := g.Add("Button", "x14 y" btnY " w110 h28", "Open plot")
        btnOpen.OnEvent("Click", (*) => this._OnOpenSelected())

        btnSetPb := g.Add("Button", "x130 y" btnY " w110 h28", "Set as PB")
        btnSetPb.OnEvent("Click", (*) => this._OnSetAsPbSelected())

        btnDelete := g.Add("Button", "x246 y" btnY " w90 h28", "Delete")
        btnDelete.OnEvent("Click", (*) => this._OnDeleteSelected())

        btnClose := g.Add("Button", "x494 y" btnY " w100 h28", "Close")
        btnClose.OnEvent("Click", (*) => this.Close())

        ; Second row: export / import buttons.
        ; "Export selected" takes only the marked rows; "Export all"
        ; takes the whole history. Both publish Cmd.ExportRunsRequested
        ; and the app handler opens ExportOptionsDialog.
        btnRow2Y := btnY + 28 + 6
        btnExportSel := g.Add("Button", "x14 y" btnRow2Y " w130 h28", "Export selected")
        btnExportSel.OnEvent("Click", (*) => this._OnExportSelected())

        btnExportAll := g.Add("Button", "x150 y" btnRow2Y " w130 h28", "Export all")
        btnExportAll.OnEvent("Click", (*) => this._OnExportAll())

        ; "Import..." opens FileSelect and publishes Cmd.ImportRunsRequested.
        ; The handler in app.ahk runs Preview and opens the ImportPreviewDialog.
        btnImport := g.Add("Button", "x286 y" btnRow2Y " w110 h28", "Import...")
        btnImport.OnEvent("Click", (*) => this._OnImportClicked())

        this._RefreshList()
        g.Show("w" RunHistoryDialog.WINDOW_W " h" RunHistoryDialog.WINDOW_H)
    }

    ; Loads summaries from the repo and repopulates the ListView.
    _RefreshList()
    {
        if !IsObject(this._ctrls) || !this._ctrls.Has("list")
            return

        lv := this._ctrls["list"]
        try lv.Delete()
        this._runIdsByRow := []

        summaries := this._repo.LoadSummaries()
        for _, sm in summaries
        {
            if !IsObject(sm)
                continue

            firstTs := sm.Has("firstTs") && sm["firstTs"] != ""
                       ? sm["firstTs"]
                       : RunHistoryDialog._DeriveDateFromRunId(sm["runId"])
            ; Local `runId` collides case-insensitively with the
            ; `RunId` domain class; use `currentRunId`.
            currentRunId := sm.Has("runId")      ? sm["runId"]      : ""
            totalMs      := sm.Has("totalMs")    ? sm["totalMs"]    : 0
            deaths       := sm.Has("deathCount") ? sm["deathCount"] : 0
            profile      := sm.Has("profile")    ? sm["profile"]    : ""

            lv.Add(,
                firstTs,
                currentRunId,
                RunStatsPlotBuilder.FormatMs(totalMs),
                deaths,
                profile
            )
            this._runIdsByRow.Push(currentRunId)
        }

        ; Header counts the total
        if this._ctrls.Has("header")
        {
            n := summaries.Length
            try this._ctrls["header"].Value :=
                "Run History (" n " saved)"
        }

        ; Auto-selects the first row
        if (this._runIdsByRow.Length > 0)
        {
            try lv.Modify(1, "Select Focus")
        }
    }

    ; Loads the selected run's buildResult and opens the plot dialog.
    _OnOpenSelected()
    {
        ; Same `runId` collision; use `currentRunId`.
        currentRunId := this._GetSelectedRunId()
        if (currentRunId = "")
            return

        buildResult := this._repo.Load(currentRunId)
        if !IsObject(buildResult)
        {
            try SpeedKalandraMsgBox("Failed to load run " currentRunId, "SpeedKalandra", "IconX")
            return
        }

        ; Close the history afterwards to avoid visual overlap with
        ; the plot dialog.
        try this._plotDialog.OpenWithData(buildResult)
        this.Close()
    }

    ; Deletes the selected run after confirmation, then calls
    ; PersonalBestService.RebuildFromHistory so any PB sourced from
    ; the deleted run is replaced or cleared.
    _OnDeleteSelected()
    {
        currentRunId := this._GetSelectedRunId()
        if (currentRunId = "")
            return

        result := ""
        try
            result := SpeedKalandraMsgBox("Delete run " currentRunId "?`n`n"
                . "Personal Bests will be rebuilt from the remaining runs "
                . "(if this run was the source of any PB, it will be replaced "
                . "by the next best, or cleared if no other run qualifies)."
                . "`n`nThis action cannot be undone.",
                "SpeedKalandra", "YesNo Icon?")
        catch
            return
        if (result != "Yes")
            return

        deleted := false
        try deleted := this._repo.Delete(currentRunId)

        ; Rebuilds PBs from the remaining runs.
        pbChanged := false
        if (deleted && this._personalBest != "")
        {
            try pbChanged := this._RebuildPbsFromHistory()
        }

        this._RefreshList()

        if !this._headless
        {
            msg := deleted
                ? (pbChanged
                    ? "Run deleted. PBs were rebuilt from history."
                    : "Run deleted (no PB changes).")
                : "Failed to delete run " currentRunId "."
            try TrayTip("SpeedKalandra", msg, "Mute")
        }
    }

    ; Pins the selected run as PB. Updates ONLY runPbMs + runPbRunId
    ; (and the per-act checkpoints when the run carries them). Per-zone
    ; PBs stay aggregated across all runs.
    _OnSetAsPbSelected()
    {
        ; Locals `runId` / `run` collide with the `RunId` class and
        ; the built-in `Run` function; use `currentRunId` / `runItem`.
        currentRunId := this._GetSelectedRunId()
        if (currentRunId = "")
            return
        if (this._personalBest = "")
            return

        ; Loads the run to get totalMs (the summary would suffice, but
        ; Load has the full context and the cost is marginal).
        runItem := this._repo.Load(currentRunId)
        if !IsObject(runItem)
        {
            try SpeedKalandraMsgBox("Failed to load run " currentRunId, "SpeedKalandra", "IconX")
            return
        }
        runMs := runItem.Has("totalMs") ? runItem["totalMs"] : 0
        if (runMs <= 0)
        {
            try SpeedKalandraMsgBox("Run " currentRunId " has no valid totalMs.",
                "SpeedKalandra", "IconX")
            return
        }

        ; Shows context: run time + current PB.
        ; A multi-line ternary with a string literal at the start of
        ; the second line fails the AHK v2 parser; use explicit
        ; if/else instead.
        currentPbStr := "none"
        if this._personalBest.HasRunPb()
        {
            currentPbStr := RunStatsPlotBuilder.FormatMs(this._personalBest.GetRunPbMs())
                          . " (" . this._personalBest.GetRunPbRunId() . ")"
        }
        newPbStr := RunStatsPlotBuilder.FormatMs(runMs)

        ; Counts how many checkpoints this run has (affects what changes
        ; in runPbByAct — the overlay reads this Map).
        ckpts := runItem.Has("actCheckpoints") && IsObject(runItem["actCheckpoints"])
                 ? runItem["actCheckpoints"]
                 : Map()
        ckptCount := IsObject(ckpts) ? ckpts.Count : 0
        ckptNote := ckptCount > 0
            ? "Per-act PBs (shown in overlay) will be REPLACED by this run's checkpoints (" ckptCount " acts)."
            : "This run has no act checkpoints (saved before that section was added) so per-act PBs will NOT change."

        result := ""
        try
            result := SpeedKalandraMsgBox("Set this run as your Personal Best?`n`n"
                . "Run ID:   " currentRunId "`n"
                . "Time:     " newPbStr "`n`n"
                . "Current PB: " currentPbStr "`n`n"
                . ckptNote "`n`n"
                . "Per-zone PBs remain aggregated from all runs.",
                "SpeedKalandra", "YesNo Icon?")
        catch
            return
        if (result != "Yes")
            return

        changed := false
        try changed := this._personalBest.SetAsRunPb(runMs, currentRunId, ckpts)

        if !this._headless
        {
            msg := changed
                ? "Run " currentRunId " set as PB (" newPbStr ")."
                : "Run " currentRunId " was already the PB — no change."
            try TrayTip("SpeedKalandra", msg, "Mute")
        }
    }

    ; Reads all saved runs (full Load with details + checkpoints) and
    ; calls PersonalBestService.RebuildFromHistory.
    ;
    ; Cost: O(N) full INI reads. Typically N < 100, total < 500ms.
    _RebuildPbsFromHistory()
    {
        if (this._personalBest = "")
            return false
        runs := []
        try
        {
            for _, rid in this._repo.ListRunIds()
            {
                br := this._repo.Load(rid)
                if IsObject(br)
                    runs.Push(br)
            }
        }
        return this._personalBest.RebuildFromHistory(runs)
    }

    _GetSelectedRunId()
    {
        if !this._ctrls.Has("list")
            return ""
        lv := this._ctrls["list"]
        row := 0
        try
            row := lv.GetNext(0, "F")    ; first selected
        catch
            row := 0
        if (row < 1 || row > this._runIdsByRow.Length)
            return ""
        return this._runIdsByRow[row]
    }

    ; ---- Multi-select helpers ----

    ; All marked rows (not just the focused one). Unlike
    ; _GetSelectedRunId which uses GetNext(0, "F"), this iterates
    ; the Selected state, which can span multiple rows. Used by
    ; "Export selected".
    ;
    ; AHK v2: GetNext accepts "" (default = Selected), "C" (Checked)
    ; or "F" (Focused). "S" doesn't exist — it was an AHK v1 holdover.
    _GetSelectedRunIds()
    {
        out := []
        if !this._ctrls.Has("list")
            return out
        lv := this._ctrls["list"]
        row := 0
        loop
        {
            row := lv.GetNext(row)   ; default = next Selected
            if (row <= 0)
                break
            if (row <= this._runIdsByRow.Length)
                out.Push(this._runIdsByRow[row])
        }
        return out
    }

    ; Collects runIds from marked rows and publishes
    ; Cmd.ExportRunsRequested. Empty selection → friendly hint.
    _OnExportSelected()
    {
        runIds := this._GetSelectedRunIds()
        if (runIds.Length = 0)
        {
            try SpeedKalandraMsgBox("Select one or more runs first (Ctrl+Click or Shift+Click for multi-selection).",
                "SpeedKalandra - Export", "IconI")
            return
        }
        this._bus.Publish(Commands.ExportRunsRequested, Map("runIds", runIds))
    }

    ; Collects every runId from disk and publishes
    ; Cmd.ExportRunsRequested.
    _OnExportAll()
    {
        runIds := []
        try
        {
            for _, rid in this._repo.ListRunIds()
                runIds.Push(rid)
        }
        if (runIds.Length = 0)
        {
            try SpeedKalandraMsgBox("No runs in history to export.",
                "SpeedKalandra - Export", "IconI")
            return
        }
        this._bus.Publish(Commands.ExportRunsRequested, Map("runIds", runIds))
    }

    ; Opens FileSelect in exports/ and publishes
    ; Cmd.ImportRunsRequested. The app handler runs Preview and pops
    ; up ImportPreviewDialog.
    _OnImportClicked()
    {
        path := ""
        try
        {
            ; FileSelect mode "3" = file must exist, single selection.
            ; Starts in exports/ (creates the folder first if missing).
            try RunExportService.EnsureExportDir()
            path := FileSelect("3", RunExportService.DEFAULT_EXPORT_DIR "\",
                "Select export file to import", "JSON files (*.json)")
        }
        catch as ex
        {
            OutputDebug("RunHistoryDialog._OnImportClicked FileSelect failed: " ex.Message)
            return
        }
        if (path = "")
            return
        this._bus.Publish(Commands.ImportRunsRequested, Map("path", path))
    }

    ; Subscriber for Evt.RunsImported — refresh the list when the
    ; dialog is already open; otherwise no-op.
    _OnRunsImported(data)
    {
        if this._isOpen && this._gui
            try this._RefreshList()
    }

    ; runId has the format "20260513_051547" — converts to "2026-05-13 05:15:47"
    ; if firstTs is not available.
    static _DeriveDateFromRunId(runId)
    {
        if (Trim(String(runId)) = "")
            return ""
        ; YYYYMMDD_HHMMSS -> YYYY-MM-DD HH:MM:SS
        if RegExMatch(runId, "^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})$", &m)
        {
            return m[1] "-" m[2] "-" m[3] " " m[4] ":" m[5] ":" m[6]
        }
        return runId
    }
}
