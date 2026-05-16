; ============================================================
; RunHistoryDialog - lista de runs salvas (Onda 7, v17.6)
; ============================================================
;
; Janela auxiliar que mostra todas as runs persistidas em disco
; (via RunHistoryRepository) e permite abrir o plot de uma run
; especifica.
;
; LAYOUT:
;
;   +-------------------------------------------+
;   | Header: Historico de runs (N salvas)      |
;   |                                           |
;   | ListView 5 colunas:                       |
;   |   Data  |  RunId  |  Duracao  |  Mortes  | Perfil
;   |                                           |
;   | [Abrir plot] [Apagar]      [Fechar]       |
;   +-------------------------------------------+
;
; FLUXO:
;   - Open() lista runs do repositorio
;   - Click numa linha + "Abrir plot": publica
;     Commands.OpenRunStatsPlotRequested com runId da escolhida
;     (na verdade publica direto chamando o plot dialog com
;     o buildResult carregado, pra evitar acoplamento)
;   - "Delete" (v17.15.1): apaga run + reconstroi PBs a partir das
;     runs restantes (descarta contribuicoes da run apagada do PB
;     global, PB por ato e PBs por zona).
;   - "Set as PB" (v17.15.1): pina a run selecionada como Personal
;     Best oficial (runPbMs + runPbRunId). PBs por ato e por zona
;     ficam intactos (continuam agregados de todas as runs).
;
; SUBSCRIPTIONS:
;   Commands.OpenRunHistoryRequested -> Open()
;
; CONSTRUCAO:
;   dialog := RunHistoryDialog(bus, runHistory, plotDialog,
;                              personalBest, headless)


class RunHistoryDialog
{
    static WINDOW_W := 620
    static WINDOW_H := 520    ; v0.1.0: 480->520 pra caber segunda fileira de botoes (Export)

    _bus         := ""
    _repo        := ""
    _plotDialog  := ""
    _personalBest := ""    ; v17.15.1 — pra RebuildFromHistory apos delete
    _headless    := false

    _gui    := ""
    _ctrls  := ""
    _isOpen := false

    ; Cache: runIds na ordem do ListView pra pegar pela linha selecionada.
    _runIdsByRow := ""    ; Array<string>

    __New(bus, runHistory, plotDialog, personalBest, headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("RunHistoryDialog: 'bus' deve ser EventBus")
        if !(runHistory is RunHistoryRepository)
            throw TypeError("RunHistoryDialog: 'runHistory' deve ser RunHistoryRepository")
        if !(plotDialog is RunStatsPlotDialog)
            throw TypeError("RunHistoryDialog: 'plotDialog' deve ser RunStatsPlotDialog")
        ; v17.15.1: personalBest pode ser "" pra retrocompat (tests),
        ; mas em producao deve ser PersonalBestService.
        if (personalBest != "" && !(personalBest is PersonalBestService))
            throw TypeError("RunHistoryDialog: 'personalBest' deve ser PersonalBestService ou vazio")

        this._bus          := bus
        this._repo         := runHistory
        this._plotDialog   := plotDialog
        this._personalBest := personalBest
        this._headless     := !!headless
        this._ctrls        := Map()
        this._runIdsByRow  := []

        bus.Subscribe(Commands.OpenRunHistoryRequested, (data) => this.Open())

        ; v0.1.0: refresh automatico quando uma importacao concluir.
        ; Se dialog estiver aberto, recarrega a lista pra mostrar as
        ; runs recem-importadas. Se fechado, no-op (proxima Open lera
        ; do disco normalmente).
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

        ; Double-click abre plot
        this._ctrls["list"].OnEvent("DoubleClick", (*) => this._OnOpenSelected())

        ; Botoes
        btnY := 44 + lvH + 8
        btnOpen := g.Add("Button", "x14 y" btnY " w110 h28", "Open plot")
        btnOpen.OnEvent("Click", (*) => this._OnOpenSelected())

        btnSetPb := g.Add("Button", "x130 y" btnY " w110 h28", "Set as PB")
        btnSetPb.OnEvent("Click", (*) => this._OnSetAsPbSelected())

        btnDelete := g.Add("Button", "x246 y" btnY " w90 h28", "Delete")
        btnDelete.OnEvent("Click", (*) => this._OnDeleteSelected())

        btnClose := g.Add("Button", "x494 y" btnY " w100 h28", "Close")
        btnClose.OnEvent("Click", (*) => this.Close())

        ; ---- Segunda fileira: botoes de export (v0.1.0) ----
        ; "Export selected" pega so as runs marcadas no ListView.
        ; "Export all" exporta todas do historico. Ambos publicam
        ; Cmd.ExportRunsRequested; o handler em app.ahk abre o
        ; ExportOptionsDialog.
        btnRow2Y := btnY + 28 + 6
        btnExportSel := g.Add("Button", "x14 y" btnRow2Y " w130 h28", "Export selected")
        btnExportSel.OnEvent("Click", (*) => this._OnExportSelected())

        btnExportAll := g.Add("Button", "x150 y" btnRow2Y " w130 h28", "Export all")
        btnExportAll.OnEvent("Click", (*) => this._OnExportAll())

        ; "Import..." abre FileSelect e publica Cmd.ImportRunsRequested.
        ; O handler em app.ahk roda Preview e abre o ImportPreviewDialog.
        btnImport := g.Add("Button", "x286 y" btnRow2Y " w110 h28", "Import...")
        btnImport.OnEvent("Click", (*) => this._OnImportClicked())

        this._RefreshList()
        g.Show("w" RunHistoryDialog.WINDOW_W " h" RunHistoryDialog.WINDOW_H)
    }

    ; ============================================================
    ; _RefreshList - carrega summaries do repo e popula o ListView
    ; ============================================================
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
            ; v0.1.1: `runId` local colide com classe `RunId`. Usar `currentRunId`.
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

        ; Header conta total
        if this._ctrls.Has("header")
        {
            n := summaries.Length
            try this._ctrls["header"].Value :=
                "Run History (" n " saved)"
        }

        ; Auto-seleciona primeira linha
        if (this._runIdsByRow.Length > 0)
        {
            try lv.Modify(1, "Select Focus")
        }
    }

    ; ============================================================
    ; _OnOpenSelected - carrega buildResult da run e abre o plot
    ; ============================================================
    _OnOpenSelected()
    {
        ; v0.1.1: `runId` local colide com classe `RunId`. Usar `currentRunId`.
        currentRunId := this._GetSelectedRunId()
        if (currentRunId = "")
            return

        buildResult := this._repo.Load(currentRunId)
        if !IsObject(buildResult)
        {
            try SpeedKalandraMsgBox("Failed to load run " currentRunId, "SpeedKalandra", "IconX")
            return
        }

        ; Abre o plot dialog com este buildResult. Fecha o historico
        ; depois pra evitar sobreposicao visual.
        try this._plotDialog.OpenWithData(buildResult)
        this.Close()
    }

    ; ============================================================
    ; _OnDeleteSelected - apaga a run selecionada (com confirmacao)
    ;
    ; v17.15.1: apos apagar do disco, chama PersonalBestService.
    ; RebuildFromHistory pra descartar contribuicao da run deletada
    ; nos PBs (global, por ato, por zona). Sem isso, deletar uma
    ; run "acidental" que era o PB nao corrigia o PB.
    ; ============================================================
    _OnDeleteSelected()
    {
        ; v0.1.1: `runId` local colide com classe `RunId`. Usar `currentRunId`.
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

        ; Reconstroi PBs a partir das runs restantes.
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

    ; ============================================================
    ; _OnSetAsPbSelected - pina a run selecionada como PB (v17.15.1)
    ;
    ; Atualiza APENAS runPbMs + runPbRunId no PB service. PB por
    ; ato e por zona ficam intactos (continuam agregados de todas
    ; as runs).
    ; ============================================================
    _OnSetAsPbSelected()
    {
        ; v0.1.1: `runId` e `run` locais colidem com classe `RunId` e
        ; builtin `Run`. Usar `currentRunId` e `runItem`.
        currentRunId := this._GetSelectedRunId()
        if (currentRunId = "")
            return
        if (this._personalBest = "")
            return

        ; Carrega a run pra pegar totalMs (resumo seria suficiente,
        ; mas Load tem todo o contexto e o custo eh marginal).
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

        ; Mostra contexto: tempo da run + PB atual
        ; v17.15.1: ternario multi-linha com string-literal no comeco da
        ; segunda linha falha no parser do AHK v2 (mesma familia do Bug
        ; #25). Usa if/else explicito.
        currentPbStr := "none"
        if this._personalBest.HasRunPb()
        {
            currentPbStr := RunStatsPlotBuilder.FormatMs(this._personalBest.GetRunPbMs())
                          . " (" . this._personalBest.GetRunPbRunId() . ")"
        }
        newPbStr := RunStatsPlotBuilder.FormatMs(runMs)

        ; Conta quantos checkpoints essa run tem (afeta o que vai mudar
        ; em runPbByAct — o overlay le esse Map).
        ckpts := runItem.Has("actCheckpoints") && IsObject(runItem["actCheckpoints"])
                 ? runItem["actCheckpoints"]
                 : Map()
        ckptCount := IsObject(ckpts) ? ckpts.Count : 0
        ckptNote := ckptCount > 0
            ? "Per-act PBs (shown in overlay) will be REPLACED by this run's checkpoints (" ckptCount " acts)."
            : "This run has no act checkpoints (saved before v17.15.1) so per-act PBs will NOT change."

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

    ; Le todas as runs salvas (full Load com details + checkpoints)
    ; e chama PersonalBestService.RebuildFromHistory.
    ;
    ; Custo: O(N) full reads de INI. Tipicamente N < 100, total < 500ms.
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
            row := lv.GetNext(0, "F")    ; primeira selecionada
        catch
            row := 0
        if (row < 1 || row > this._runIdsByRow.Length)
            return ""
        return this._runIdsByRow[row]
    }

    ; ============================================================
    ; _GetSelectedRunIds (v0.1.0) - todas as linhas marcadas
    ;
    ; Diferente de _GetSelectedRunId (que usa "F" pra pegar so a linha
    ; focada), este itera o estado Selected que pode estar em multiplas
    ; linhas. Usado pelo "Export selected".
    ;
    ; NOTA AHK v2: GetNext aceita "" (default=Selected), "C" (Checked)
    ; ou "F" (Focused). NAO existe "S" — era do AHK v1.
    ; ============================================================
    _GetSelectedRunIds()
    {
        out := []
        if !this._ctrls.Has("list")
            return out
        lv := this._ctrls["list"]
        row := 0
        loop
        {
            row := lv.GetNext(row)   ; default = proxima Selected
            if (row <= 0)
                break
            if (row <= this._runIdsByRow.Length)
                out.Push(this._runIdsByRow[row])
        }
        return out
    }

    ; ============================================================
    ; _OnExportSelected (v0.1.0)
    ;
    ; Coleta runIds das linhas marcadas e publica Cmd.ExportRunsRequested.
    ; Se nenhuma linha esta marcada, mostra hint amigavel.
    ; ============================================================
    _OnExportSelected()
    {
        runIds := this._GetSelectedRunIds()
        if (runIds.Length = 0)
        {
            try SpeedKalandraMsgBox("Select one or more runs first (Ctrl+Click ou Shift+Click pra multipla selecao).",
                "SpeedKalandra - Export", "IconI")
            return
        }
        this._bus.Publish(Commands.ExportRunsRequested, Map("runIds", runIds))
    }

    ; ============================================================
    ; _OnExportAll (v0.1.0)
    ;
    ; Coleta TODOS os runIds do historico e publica Cmd.ExportRunsRequested.
    ; ============================================================
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

    ; ============================================================
    ; _OnImportClicked (v0.1.0)
    ;
    ; Abre FileSelect com pasta default em exports/ e publica
    ; Cmd.ImportRunsRequested. O handler em app.ahk faz o resto.
    ; ============================================================
    _OnImportClicked()
    {
        path := ""
        try
        {
            ; FileSelect mode "3" = file must exist, single selection.
            ; Inicia em exports/ (cria a pasta antes se nao existe).
            try RunExportService.EnsureExportDir()
            path := FileSelect("3", RunExportService.DEFAULT_EXPORT_DIR "\",
                "Select export file to import", "JSON files (*.json)")
        }
        catch as ex
        {
            OutputDebug("RunHistoryDialog._OnImportClicked FileSelect falhou: " ex.Message)
            return
        }
        if (path = "")
            return
        this._bus.Publish(Commands.ImportRunsRequested, Map("path", path))
    }

    ; ============================================================
    ; _OnRunsImported (v0.1.0)
    ;
    ; Subscriber do Evt.RunsImported. Refresh da lista se dialog
    ; estiver aberto. Caso contrario, no-op.
    ; ============================================================
    _OnRunsImported(data)
    {
        if this._isOpen && this._gui
            try this._RefreshList()
    }

    ; runId tem formato "20260513_051547" — converte pra "2026-05-13 05:15:47"
    ; se firstTs nao tiver disponivel.
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
