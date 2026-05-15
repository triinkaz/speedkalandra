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
    static WINDOW_H := 480

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
            runId   := sm.Has("runId")      ? sm["runId"]      : ""
            totalMs := sm.Has("totalMs")    ? sm["totalMs"]    : 0
            deaths  := sm.Has("deathCount") ? sm["deathCount"] : 0
            profile := sm.Has("profile")    ? sm["profile"]    : ""

            lv.Add(,
                firstTs,
                runId,
                RunStatsPlotBuilder.FormatMs(totalMs),
                deaths,
                profile
            )
            this._runIdsByRow.Push(runId)
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
        runId := this._GetSelectedRunId()
        if (runId = "")
            return

        buildResult := this._repo.Load(runId)
        if !IsObject(buildResult)
        {
            try MsgBox("Failed to load run " runId, "SpeedKalandra", "IconX")
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
        runId := this._GetSelectedRunId()
        if (runId = "")
            return

        result := ""
        try
            result := MsgBox("Delete run " runId "?`n`n"
                . "Personal Bests will be rebuilt from the remaining runs "
                . "(if this run was the source of any PB, it will be replaced "
                . "by the next best, or cleared if no other run qualifies)."
                . "`n`nThis action cannot be undone.",
                "SpeedKalandra", "YesNo IconQ")
        catch
            return
        if (result != "Yes")
            return

        deleted := false
        try deleted := this._repo.Delete(runId)

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
                : "Failed to delete run " runId "."
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
        runId := this._GetSelectedRunId()
        if (runId = "")
            return
        if (this._personalBest = "")
            return

        ; Carrega a run pra pegar totalMs (resumo seria suficiente,
        ; mas Load tem todo o contexto e o custo eh marginal).
        run := this._repo.Load(runId)
        if !IsObject(run)
        {
            try MsgBox("Failed to load run " runId, "SpeedKalandra", "IconX")
            return
        }
        runMs := run.Has("totalMs") ? run["totalMs"] : 0
        if (runMs <= 0)
        {
            try MsgBox("Run " runId " has no valid totalMs.",
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
        ckpts := run.Has("actCheckpoints") && IsObject(run["actCheckpoints"])
                 ? run["actCheckpoints"]
                 : Map()
        ckptCount := IsObject(ckpts) ? ckpts.Count : 0
        ckptNote := ckptCount > 0
            ? "Per-act PBs (shown in overlay) will be REPLACED by this run's checkpoints (" ckptCount " acts)."
            : "This run has no act checkpoints (saved before v17.15.1) so per-act PBs will NOT change."

        result := ""
        try
            result := MsgBox("Set this run as your Personal Best?`n`n"
                . "Run ID:   " runId "`n"
                . "Time:     " newPbStr "`n`n"
                . "Current PB: " currentPbStr "`n`n"
                . ckptNote "`n`n"
                . "Per-zone PBs remain aggregated from all runs.",
                "SpeedKalandra", "YesNo IconQ")
        catch
            return
        if (result != "Yes")
            return

        changed := false
        try changed := this._personalBest.SetAsRunPb(runMs, runId, ckpts)

        if !this._headless
        {
            msg := changed
                ? "Run " runId " set as PB (" newPbStr ")."
                : "Run " runId " was already the PB — no change."
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
