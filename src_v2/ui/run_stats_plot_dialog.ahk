; ============================================================
; RunStatsPlotDialog - janela de stats da run (v17.11)
; ============================================================
;
; LAYOUT (900x760):
;
;   +----------------------------------------------+
;   | Header: Run XYZ - 01:01:59                   |
;   | Sub: Perfil X, Patch Y, Mortes Z             |
;   |                                              |
;   | KPIs: MAPA CIDADE LOADING MORTES             |
;   |                                              |
;   | Granularidade: [Por mapa ▼]                  |
;   |                                              |
;   | DISTRIBUICAO DA RUN ATUAL:                   |
;   | [stacked bar segmentado por granularidade]   |
;   |                                              |
;   | EVOLUCAO ENTRE RUNS:                         |
;   |         ┌──────────────────────────────┐    |
;   |   40m ──│ ⋅ ⋅ ⋅ ⋅ ⋅ ⋅ ⋅ ⋅ ⋅ ⋅ ⋅ ⋅ ⋅   │    |
;   |   30m ──│        ╭──╮       /\         │    |
;   |   20m ──│  ╱─╮  ╱    ╲──╮  /  \        │    |
;   |   10m ──│ ╱   ╲╱        ╲╱             │    |
;   |    0m ──└──────────────────────────────┘    |
;   |          Run1  Run2  Run3  Run4  Run5       |
;   |                                              |
;   | LEGENDA (clique pra ocultar/mostrar):        |
;   | ▌Item1 ▌Item2 ░Item3(oculto) ▌Item4 ...      |
;   |                                              |
;   | [Detalhes...] [Historico...]      [Fechar]   |
;   +----------------------------------------------+
;
; OCULTAR/MOSTRAR SERIES (v17.11):
;   Clicar num item da legenda (swatch ou texto) toggla visibilidade
;   da serie correspondente. Series ocultas:
;     - Nao sao desenhadas no line chart
;     - Nao sao desenhadas na stacked bar atual
;     - Aparecem na legenda com swatch cinza (surface3) e texto muted
;     - Sao excluidas do calculo de yMax — ocultar a serie de Mortes
;       (12min) que distorce a escala da liberacao automaticamente
;
;   Estado mantido em this._hiddenSeries como Map<"gran:label", true>.
;   Persiste entre rebuilds (granularity change, run reload) mas eh
;   resetado ao reiniciar o script.
;
;   Como labels mudam entre granularidades (Mapa: nomes de mapas,
;   Ato: "Ato 1"/"Ato 2"/..., Run: 5 cats fixas), a chave inclui o
;   granularity pra que cada modo tenha seu proprio set de hidden.
;
; GRAFICO DE LINHAS:
;   Eixo X horizontal:  cada run uma posicao (cronologica, mais
;                       antigas a esquerda, mais recentes a direita)
;   Eixo Y vertical:    tempo em ms (escala 0 -> maxMs entre series VISIVEIS)
;   Series:             1 linha por item da granularidade
;
;   Renderizado via GDI (LineChartRenderer) num Picture control.
;
; GRANULARIDADE:
;   - "Run inteira"  : 4 linhas (mapa, cidade, loading, mortes)
;   - "Por ato"      : 1 linha por ato — cores rotativas
;   - "Por mapa"     : 1 linha por mapa — cor estavel por hash
;   - "Por cidade"   : 1 linha por cidade
;   - "Por loading"  : 1 linha por loading
;
; Granularidade "Por boss" REMOVIDA em v17.13 (boss tracking saiu).
;
;   Pra granularidades dinamicas, **TOP-N** linhas pelo total de
;   tempo. Default TOP_SERIES_MAX = 8.
;
; FILTRO POR ATO MAX (v17.13):
;   Dropdown adicional ao lado da granularidade permite filtrar runs
;   no line chart por "min Ato alcancado". Util pra comparar runs do
;   mesmo tamanho (ex: so runs que foram ate Ato 3+).
;   - "Todas"      : nao filtra (default)
;   - "Ato 1+"     : runs com maxActReached >= 1
;   - "Ato 2+"     : runs com maxActReached >= 2
;   - ... ate Ato 10+
;
; GAPS NO LINE CHART (v17.13):
;   Quando uma run nao tem a serie (ex: "Ato 2" numa run que so foi
;   ate Ato 1), o ponto eh marcado como `present: false` em vez de
;   `yMs: 0`. O renderer quebra a linha nesses pontos, evitando o
;   "falso fundo" enganoso que aparecia antes.
;
; SUBSCRIPTIONS:
;   Cmd.OpenRunStatsPlotRequested -> Open()
;   Evt.RunCompleted              -> Open()  (auto-trigger)


class RunStatsPlotDialog
{
    static WINDOW_W := 900
    static WINDOW_H := 760

    ; Layout vertical
    static Y_HEADER     := 10
    static Y_SUBHEADER  := 34
    static Y_KPIS_LABEL := 64
    static Y_KPIS_VAL   := 78
    static Y_GRAN_LABEL := 116
    static Y_GRAN_DD    := 132
    static Y_BAR_LABEL  := 172
    static Y_BAR        := 188
    static Y_CHART_LABEL := 226
    static Y_CHART       := 244
    static CHART_H       := 300
    static Y_XLABELS     := 244 + 300 + 4    ; CHART_Y + CHART_H + gap
    static XLABEL_H      := 18
    static Y_LEGEND      := 244 + 300 + 4 + 18 + 8   ; apos X labels + gap
    static LEGEND_H      := 60

    static GRAN_LABELS := ["Full run", "By act", "By map", "By town", "By loading"]
    static GRAN_KEYS   := ["run", "ato", "mapa", "cidade", "loading"]

    ; Filtro por ato max alcancado (v17.13). Index 1 = "All" (sem filtro).
    static MIN_ACT_LABELS := ["All", "Act 1+", "Act 2+", "Act 3+", "Act 4+", "Act 5+", "Act 6+", "Act 7+", "Act 8+", "Act 9+", "Act 10+"]

    static ROTATING_PALETTE := [
        "38BDF8", "F97316", "A78BFA", "FACC15", "EF4444",
        "10B981", "EC4899", "8B5CF6", "06B6D4", "84CC16",
        "F472B6", "FB923C", "60A5FA", "FBBF24", "C084FC"
    ]

    ; Limites do line chart
    static MAX_RUNS_IN_CHART := 12     ; runs maximas no eixo X
    static TOP_SERIES_MAX    := 8      ; series maximas (por total ms)

    _bus         := ""
    _builder     := ""
    _recorder    := ""
    _zoneTracker := ""
    _timer       := ""
    _runHistory  := ""
    _headless    := false

    _gui     := ""
    _ctrls   := ""
    _isOpen  := false

    _granularity   := "run"
    _minActFilter  := 0       ; v17.13: 0 = todas, N>=1 = runs com maxActReached >= N
    _profileFilter        := ""    ; v17.14: "" = All profiles; senao = nome do profile
    _profileFilterInited  := false ; v17.14: false = ainda nao inicializado (vai pegar profile da run atual)
    _currentData   := ""
    _hiddenSeries  := ""    ; Map<"granularity:label", true>

    _detailsGui  := ""

    __New(bus, plotBuilder, recorder, zoneTracker, timer, runHistory := "", headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("RunStatsPlotDialog: 'bus' deve ser EventBus")
        if !(plotBuilder is RunStatsPlotBuilder)
            throw TypeError("RunStatsPlotDialog: 'plotBuilder' deve ser RunStatsPlotBuilder")
        if !(recorder is RunStatsRecorder)
            throw TypeError("RunStatsPlotDialog: 'recorder' deve ser RunStatsRecorder")
        if !(zoneTracker is ZoneTrackingService)
            throw TypeError("RunStatsPlotDialog: 'zoneTracker' deve ser ZoneTrackingService")
        if !(timer is TimerService)
            throw TypeError("RunStatsPlotDialog: 'timer' deve ser TimerService")

        this._bus         := bus
        this._builder     := plotBuilder
        this._recorder    := recorder
        this._zoneTracker := zoneTracker
        this._timer       := timer
        this._runHistory  := runHistory
        this._headless    := !!headless
        this._ctrls       := Map()
        this._hiddenSeries := Map()

        bus.Subscribe(Commands.OpenRunStatsPlotRequested, (data) => this.Open())
        bus.Subscribe(Events.RunCompleted,                (data) => this.Open())
    }

    IsOpen() => this._isOpen

    Open(snapshot := "")
    {
        if (snapshot = "")
            snapshot := this._BuildSnapshot()

        try
            data := this._builder.Build(snapshot)
        catch as err
        {
            if !this._headless
                try MsgBox("Failed to build plot: " err.Message,
                    "SpeedKalandra", "IconX")
            return false
        }

        return this._ShowWithData(data)
    }

    OpenWithData(buildResult)
    {
        if !IsObject(buildResult)
            return false
        return this._ShowWithData(buildResult)
    }

    _ShowWithData(data)
    {
        this._currentData := data

        if this._headless
        {
            this._isOpen := true
            return true
        }

        if this._gui
        {
            try this._gui.Destroy()
            this._gui := ""
            this._ctrls := Map()
        }
        this._BuildGui(data)
        this._isOpen := true
        return true
    }

    Close()
    {
        if this._detailsGui
        {
            try this._detailsGui.Destroy()
            this._detailsGui := ""
        }
        if this._gui
        {
            try this._gui.Destroy()
            this._gui := ""
            this._ctrls := Map()
        }
        this._isOpen := false
    }

    _BuildSnapshot()
    {
        zoneTotals := this._zoneTracker.GetTotals()
        runMs := this._timer.GetRunMs()
        return this._recorder.GetSnapshot(zoneTotals, runMs)
    }

    ; ============================================================
    ; Hidden series state (v17.11)
    ; ============================================================
    _HiddenKey(label) => this._granularity ":" label
    _IsSeriesHidden(label) => this._hiddenSeries.Has(this._HiddenKey(label))

    _ToggleSeriesVisibility(label)
    {
        key := this._HiddenKey(label)
        if this._hiddenSeries.Has(key)
            this._hiddenSeries.Delete(key)
        else
            this._hiddenSeries[key] := true
        if IsObject(this._currentData)
            this._ShowWithData(this._currentData)
    }

    _MakeLegendClickHandler(label)
    {
        return (*) => this._ToggleSeriesVisibility(label)
    }

    ; ============================================================
    ; GUI
    ; ============================================================
    _BuildGui(data)
    {
        g := Gui("+AlwaysOnTop -MaximizeBox", "SpeedKalandra - Run Statistics")
        g.BackColor := Theme.Color("bg")
        g.MarginX := 14
        g.MarginY := 12
        g.OnEvent("Close", (*) => this.Close())
        g.OnEvent("Escape", (*) => this.Close())
        this._gui := g

        innerW := RunStatsPlotDialog.WINDOW_W - 28

        ; --- Header + Subheader ---
        runId    := data.Has("runId")    ? data["runId"]    : ""
        profile  := data.Has("profile")  ? data["profile"]  : ""
        patch    := data.Has("patch")    ? data["patch"]    : ""
        firstTs  := data.Has("firstTs")  ? data["firstTs"]  : ""
        totalMs  := data.Has("totalMs")  ? data["totalMs"]  : 0
        deathCnt := data.Has("deathCount") ? data["deathCount"] : 0

        headerTxt := "Run " (runId != "" ? runId : "(in progress)") "  -  " RunStatsPlotBuilder.FormatMs(totalMs)
        subTxt    := "Profile: " profile "   Patch: " patch
        if (firstTs != "")
            subTxt .= "   Start: " firstTs
        if (deathCnt > 0)
            subTxt .= "   Deaths: " deathCnt

        g.SetFont("s12 bold c" Theme.Color("text"), Theme.FONT_UI)
        g.Add("Text", "x14 y" RunStatsPlotDialog.Y_HEADER " w" innerW, headerTxt)

        g.SetFont("s9 c" Theme.Color("muted"), Theme.FONT_UI)
        g.Add("Text", "x14 y" RunStatsPlotDialog.Y_SUBHEADER " w" innerW, subTxt)

        ; --- KPIs ---
        ; SegmentDefinitions tem 4 entradas (mapa/cidade/loading/morte) apos
        ; remocao da categoria boss em v17.13. colW divide o espaco util
        ; entre essas 4 colunas (em vez das 5 originais).
        totals := data.Has("totals") ? data["totals"] : Map()
        colW := Floor((innerW - 16) / 4)
        i := 0
        for _, seg in RunStatsPlotBuilder.SegmentDefinitions()
        {
            key   := seg["key"]
            color := seg["color"]
            label := seg["label"]
            x := 14 + (i * (colW + 4))

            g.SetFont("s8 bold c" color, Theme.FONT_UI)
            g.Add("Text", "x" x " y" RunStatsPlotDialog.Y_KPIS_LABEL " w" colW, StrUpper(label))

            ms := totals.Has(key) ? totals[key] : 0
            g.SetFont("s11 bold c" color, Theme.FONT_UI)
            g.Add("Text", "x" x " y" RunStatsPlotDialog.Y_KPIS_VAL " w" colW, RunStatsPlotBuilder.FormatMs(ms))

            i += 1
        }

        ; --- Dropdown de granularidade ---
        g.SetFont("s8 bold c" Theme.Color("subtle"), Theme.FONT_UI)
        g.Add("Text", "x14 y" RunStatsPlotDialog.Y_GRAN_LABEL " w200", "GRANULARITY")

        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        choice := 1
        idx := 1
        for _, key in RunStatsPlotDialog.GRAN_KEYS
        {
            if (key = this._granularity)
            {
                choice := idx
                break
            }
            idx++
        }
        dd := g.Add("DropDownList",
            "x14 y" RunStatsPlotDialog.Y_GRAN_DD " w200 h180 Background" Theme.Color("surface3")
            . " Choose" choice,
            RunStatsPlotDialog.GRAN_LABELS)
        dd.OnEvent("Change", (ctrl, *) => this._OnGranularityChanged(ctrl))
        this._ctrls["dropdown_gran"] := dd

        ; --- Dropdown de filtro Min Ato (v17.13) ---
        ; Permite restringir o line chart a runs que chegaram pelo menos
        ; ate o ato N — evita comparar run de Ato 1 only com campanha cheia.
        g.SetFont("s8 bold c" Theme.Color("subtle"), Theme.FONT_UI)
        g.Add("Text", "x224 y" RunStatsPlotDialog.Y_GRAN_LABEL " w200", "MAX ACT FILTER")

        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        ddMinAct := g.Add("DropDownList",
            "x224 y" RunStatsPlotDialog.Y_GRAN_DD " w120 h180 Background" Theme.Color("surface3")
            . " Choose" (this._minActFilter + 1),
            RunStatsPlotDialog.MIN_ACT_LABELS)
        ddMinAct.OnEvent("Change", (ctrl, *) => this._OnMinActFilterChanged(ctrl))
        this._ctrls["dropdown_min_act"] := ddMinAct

        ; --- Dropdown de filtro PROFILE (v17.14) ---
        ; Permite isolar runs de um perfil especifico no line chart.
        ; Default na primeira abertura: profile da run atual (foca em
        ; comparacoes do mesmo perfil). Depois persiste a escolha do user.
        ;
        ; Lista de profiles construida dinamicamente a partir das runs
        ; salvas no disco + profile da run atual.
        profiles := this._GetAvailableProfiles(data)
        profileLabels := ["All profiles"]
        for _, p in profiles
            profileLabels.Push(p)

        ; Inicializa filtro na primeira abertura (vai pra profile da run atual)
        if !this._profileFilterInited
        {
            initProfile := data.Has("profile") ? String(data["profile"]) : ""
            this._profileFilter := initProfile
            this._profileFilterInited := true
        }

        ; Determina selecao inicial do dropdown
        profileChoice := 1   ; default: "All profiles" (index 1)
        if (this._profileFilter != "")
        {
            idx := 1
            for _, p in profiles
            {
                if (p = this._profileFilter)
                {
                    profileChoice := idx + 1   ; +1 porque "All profiles" eh o item 1
                    break
                }
                idx++
            }
        }

        g.SetFont("s8 bold c" Theme.Color("subtle"), Theme.FONT_UI)
        g.Add("Text", "x358 y" RunStatsPlotDialog.Y_GRAN_LABEL " w200", "PROFILE")

        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        ddProfile := g.Add("DropDownList",
            "x358 y" RunStatsPlotDialog.Y_GRAN_DD " w180 h180 Background" Theme.Color("surface3")
            . " Choose" profileChoice,
            profileLabels)
        ddProfile.OnEvent("Change", (ctrl, *) => this._OnProfileFilterChanged(ctrl, profileLabels))
        this._ctrls["dropdown_profile"] := ddProfile

        ; --- Stacked bar atual ---
        g.SetFont("s8 bold c" Theme.Color("subtle"), Theme.FONT_UI)
        g.Add("Text", "x14 y" RunStatsPlotDialog.Y_BAR_LABEL " w" innerW, "CURRENT RUN DISTRIBUTION")

        barW := innerW
        g.Add("Text",
            "x14 y" RunStatsPlotDialog.Y_BAR " w" barW " h28 Background" Theme.Color("surface3"),
            "")

        ; Segmentos da run atual, FILTRADOS pelas series visiveis
        currentSegsAll := this._GetSegmentsForRun(data, this._granularity)
        currentSegsVisible := []
        for _, s in currentSegsAll
        {
            if !this._IsSeriesHidden(s["label"])
                currentSegsVisible.Push(s)
        }

        totalCurMs := 0
        for _, s in currentSegsVisible
            totalCurMs += s["ms"]

        if (totalCurMs > 0)
        {
            curX := 14
            for _, segData in currentSegsVisible
            {
                segW := Round((segData["ms"] / totalCurMs) * barW)
                if (segW < 1)
                    continue
                color := segData["color"]
                g.Add("Text",
                    "x" curX " y" RunStatsPlotDialog.Y_BAR " w" segW " h28 Background" color,
                    "")
                curX += segW
            }
        }

        ; --- LINE CHART ---
        g.SetFont("s8 bold c" Theme.Color("subtle"), Theme.FONT_UI)
        g.Add("Text", "x14 y" RunStatsPlotDialog.Y_CHART_LABEL " w" innerW, "EVOLUTION ACROSS RUNS")

        ; Coleta runs do disco em ordem cronologica ascendente
        chartRuns := this._CollectRunsForChart(data)
        nRuns := chartRuns.Length

        ; allSeries = todas as series (incluindo ocultas) — usado pra legenda
        ; visibleSeries = subset filtrado — usado pro chart
        allSeries := []
        visibleSeries := []

        if (nRuns < 1)
        {
            ; Sem runs salvas — placeholder
            g.Add("Text",
                "x14 y" RunStatsPlotDialog.Y_CHART " w" innerW
                . " h" RunStatsPlotDialog.CHART_H " Background" Theme.Color("surface"),
                "")
            g.SetFont("s10 c" Theme.Color("muted"), Theme.FONT_UI)
            g.Add("Text",
                "x14 y" (RunStatsPlotDialog.Y_CHART + RunStatsPlotDialog.CHART_H // 2 - 10)
                . " w" innerW " h20 Center Background" Theme.Color("surface"),
                "Finalize at least one run to see evolution")
        }
        else
        {
            ; Constroi as series (top N por total ms)
            allSeries := this._BuildLineChartSeries(chartRuns)

            ; Filtra series visiveis
            for _, s in allSeries
            {
                if !this._IsSeriesHidden(s["label"])
                    visibleSeries.Push(s)
            }

            ; yMax APENAS das visiveis (pra dar zoom quando ocultar series grandes)
            yMax := 1
            for _, s in visibleSeries
            {
                for _, p in s["points"]
                {
                    if (p["yMs"] > yMax)
                        yMax := p["yMs"]
                }
            }
            yMaxRounded := this._RoundUpYMax(yMax)

            ; Y axis labels (5 ticks: 0%, 25%, 50%, 75%, 100%)
            yAxisLabelW := 44
            chartX := 14 + yAxisLabelW
            chartW := innerW - yAxisLabelW

            nYTicks := 5
            j := 0
            while (j < nYTicks)
            {
                yPct := j / (nYTicks - 1)
                yMsLabel := Round(yMaxRounded * yPct)
                yLabelTxt := this._FormatTimeShort(yMsLabel)
                yPos := Round(RunStatsPlotDialog.Y_CHART + RunStatsPlotDialog.CHART_H - 1
                              - (yPct * (RunStatsPlotDialog.CHART_H - 1)))

                g.SetFont("s7 c" Theme.Color("muted"), Theme.FONT_UI)
                g.Add("Text",
                    "x14 y" (yPos - 7) " w" (yAxisLabelW - 4) " h14 Right Background" Theme.Color("bg"),
                    yLabelTxt)
                j++
            }

            ; Renderiza line chart com APENAS series visiveis
            LineChartRenderer.Render(g, chartX, RunStatsPlotDialog.Y_CHART,
                chartW, RunStatsPlotDialog.CHART_H,
                Map(
                    "series",       visibleSeries,
                    "xCount",       nRuns,
                    "yMaxMs",       yMaxRounded,
                    "bgColor",      SubStr(Theme.Color("surface"), 1, 6),
                    "stripeColors", ["131517", "1A1D21"],
                    "gridColor",    "303338"
                ))

            ; X axis labels (1 por run, dispostos sob o chart)
            currentRunId := data.Has("runId") ? data["runId"] : ""
            xLabelW := 80
            if (nRuns > 1)
            {
                usableW := chartW - 16
                gap := usableW / (nRuns - 1)
                k := 0
                while (k < nRuns)
                {
                    rk := chartRuns[k + 1]
                    rkRunId := rk.Has("runId") ? rk["runId"] : ""
                    isCur := (rkRunId != "" && rkRunId = currentRunId)
                    isClick := IsObject(this._runHistory)
                               && rkRunId != ""
                               && !isCur

                    label := this._ShortDateForLabel(rk)
                    xCenter := chartX + 8 + Round(k * gap)
                    xPos := xCenter - xLabelW // 2

                    labelColor := isCur ? Theme.Color("accentSoft")
                                        : (isClick ? Theme.Color("steel") : Theme.Color("muted"))

                    g.SetFont("s7 c" labelColor, Theme.FONT_UI)
                    labelOpts := "x" xPos " y" RunStatsPlotDialog.Y_XLABELS
                               . " w" xLabelW " h" RunStatsPlotDialog.XLABEL_H
                               . " Center Background" Theme.Color("bg")
                    if isClick
                        labelOpts .= " 0x100"
                    lblCtrl := g.Add("Text", labelOpts, label)
                    if isClick
                    {
                        handler := this._MakeRowClickHandler(rkRunId)
                        try lblCtrl.OnEvent("Click", handler)
                    }
                    k++
                }
            }
            else
            {
                rk := chartRuns[1]
                label := this._ShortDateForLabel(rk)
                xCenter := chartX + chartW // 2
                xPos := xCenter - xLabelW // 2
                g.SetFont("s7 c" Theme.Color("muted"), Theme.FONT_UI)
                g.Add("Text",
                    "x" xPos " y" RunStatsPlotDialog.Y_XLABELS
                    . " w" xLabelW " h" RunStatsPlotDialog.XLABEL_H
                    . " Center Background" Theme.Color("bg"),
                    label)
            }
        }

        ; --- Legenda (TODAS series, com visual diferenciado pra ocultas) ---
        if (allSeries.Length > 0)
        {
            g.SetFont("s8 bold c" Theme.Color("subtle"), Theme.FONT_UI)
            g.Add("Text", "x14 y" RunStatsPlotDialog.Y_LEGEND " w" innerW,
                "LEGEND (click to hide/show)")

            seriesLegend := []
            for _, s in allSeries
            {
                seriesLegend.Push(Map(
                    "label", s["label"],
                    "color", s["color"],
                    "ms",    s["totalMs"]
                ))
            }
            this._BuildLegend(g, seriesLegend, innerW)
        }

        ; --- Botoes ---
        btnY := RunStatsPlotDialog.WINDOW_H - 50
        btnDetails := g.Add("Button", "x14 y" btnY " w110 h28", "Details...")
        btnDetails.OnEvent("Click", (*) => this._OpenDetailsPopup())

        if IsObject(this._runHistory)
        {
            btnHist := g.Add("Button", "x130 y" btnY " w110 h28", "History...")
            btnHist.OnEvent("Click", (*) => this._bus.Publish(Commands.OpenRunHistoryRequested, Map()))
        }

        btnClose := g.Add("Button", "x" (RunStatsPlotDialog.WINDOW_W - 120) " y" btnY " w100 h28", "Close")
        btnClose.OnEvent("Click", (*) => this.Close())

        g.Show("w" RunStatsPlotDialog.WINDOW_W " h" RunStatsPlotDialog.WINDOW_H)
    }

    ; ============================================================
    ; _CollectRunsForChart - lista runs em ordem cronologica
    ;
    ; v17.13: aplica filtro _minActFilter — runs com maxActReached <
    ; minAct sao excluidas (exceto a run atual em curso, que sempre
    ; aparece).
    ; ============================================================
    _CollectRunsForChart(currentData)
    {
        all := []
        currentRunId := currentData.Has("runId") ? currentData["runId"] : ""
        minAct := this._minActFilter
        profileFilter := this._profileFilter   ; v17.14

        if IsObject(this._runHistory)
        {
            try
            {
                summaries := this._runHistory.LoadSummaries(RunStatsPlotDialog.MAX_RUNS_IN_CHART)
                for _, sm in summaries
                {
                    if !IsObject(sm)
                        continue
                    smId := sm.Has("runId") ? sm["runId"] : ""
                    if (smId != "" && smId = currentRunId)
                        continue

                    ; Aplica filtro min act (v17.13).
                    ; Runs salvas em versoes antigas podem nao ter
                    ; maxActReached — considera 0 (aparece so se filtro=Todas).
                    if (minAct > 0)
                    {
                        smMaxAct := sm.Has("maxActReached") ? sm["maxActReached"] : 0
                        if (smMaxAct < minAct)
                            continue
                    }

                    ; Aplica filtro de profile (v17.14).
                    ; Filtro vazio = "All profiles" (nao filtra nada).
                    ; Runs sem profile salvo (legado) sao excluidas quando
                    ; ha filtro ativo — nao da pra match exato.
                    if (profileFilter != "")
                    {
                        smProfile := sm.Has("profile") ? String(sm["profile"]) : ""
                        if (smProfile != profileFilter)
                            continue
                    }

                    if (this._granularity != "run")
                    {
                        full := ""
                        try
                            full := this._runHistory.Load(smId)
                        catch
                            full := ""
                        if IsObject(full)
                            all.Push(full)
                        else
                            all.Push(sm)
                    }
                    else
                    {
                        all.Push(sm)
                    }
                }
            }
        }

        if IsObject(currentData)
        {
            curTotal := currentData.Has("totalMs") ? currentData["totalMs"] : 0
            if (curTotal > 0)
                all.Push(currentData)
        }

        n := all.Length
        if (n > 1)
        {
            ii := 2
            while (ii <= n)
            {
                jj := ii
                while (jj > 1)
                {
                    aId := all[jj].Has("runId") ? all[jj]["runId"] : ""
                    bId := all[jj-1].Has("runId") ? all[jj-1]["runId"] : ""
                    if (StrCompare(aId, bId) >= 0)
                        break
                    tmp := all[jj]
                    all[jj] := all[jj-1]
                    all[jj-1] := tmp
                    jj--
                }
                ii++
            }
        }

        if (n > RunStatsPlotDialog.MAX_RUNS_IN_CHART)
        {
            trimmed := []
            start := n - RunStatsPlotDialog.MAX_RUNS_IN_CHART + 1
            i := start
            while (i <= n)
            {
                trimmed.Push(all[i])
                i++
            }
            return trimmed
        }
        return all
    }

    ; ============================================================
    ; _BuildLineChartSeries - constroi series pro line chart
    ;
    ; v17.13: marca pontos com `present: false` quando a serie nao
    ; aparece naquela run — except pra granularidade "run" onde as 4
    ; categorias fixas (mapa/cidade/loading/morte) sao sempre present
    ; (ms=0 eh dado valido: "run sem mortes" em vez de "run sem dados").
    ; ============================================================
    _BuildLineChartSeries(runs)
    {
        if !IsObject(runs) || runs.Length = 0
            return []

        useGap := this._granularity != "run"

        universe := Map()
        for _, run in runs
        {
            segs := this._GetSegmentsForRun(run, this._granularity)
            for _, s in segs
            {
                lbl := s["label"]
                if !universe.Has(lbl)
                    universe[lbl] := s["color"]
            }
        }

        rawSeries := []
        for lbl, color in universe
        {
            points := []
            totalMs := 0
            for idx, run in runs
            {
                segs := this._GetSegmentsForRun(run, this._granularity)
                found := false
                ms := 0
                for _, s in segs
                {
                    if (s["label"] = lbl)
                    {
                        ms := s["ms"]
                        found := true
                        break
                    }
                }

                if useGap && !found
                {
                    ; Granularidade "por ato/mapa/etc" e label nao existe
                    ; nessa run -> GAP (linha quebra). v17.13.
                    points.Push(Map("xIdx", idx - 1, "yMs", 0, "present", false))
                }
                else
                {
                    ; Granularidade "run" OU label existe na run -> dado valido.
                    points.Push(Map("xIdx", idx - 1, "yMs", ms, "present", true))
                    totalMs += ms
                }
            }
            rawSeries.Push(Map(
                "label",   lbl,
                "color",   color,
                "points",  points,
                "totalMs", totalMs
            ))
        }

        n := rawSeries.Length
        ii := 2
        while (ii <= n)
        {
            jj := ii
            while (jj > 1 && rawSeries[jj]["totalMs"] > rawSeries[jj-1]["totalMs"])
            {
                tmp := rawSeries[jj]
                rawSeries[jj] := rawSeries[jj-1]
                rawSeries[jj-1] := tmp
                jj--
            }
            ii++
        }

        result := []
        i := 1
        while (i <= rawSeries.Length && i <= RunStatsPlotDialog.TOP_SERIES_MAX)
        {
            result.Push(rawSeries[i])
            i++
        }
        return result
    }

    _RoundUpYMax(yMax)
    {
        if (yMax <= 0)
            return 60000
        candidates := [30000, 60000, 120000, 300000, 600000, 900000, 1800000, 3600000, 7200000, 14400000]
        for _, c in candidates
        {
            if (c >= yMax)
                return c
        }
        return yMax
    }

    _FormatTimeShort(ms)
    {
        if (ms <= 0)
            return "0"
        totalSec := Floor(ms / 1000)
        if (totalSec < 60)
            return totalSec "s"
        totalMin := Floor(totalSec / 60)
        if (totalMin < 60)
            return totalMin "m"
        h := Floor(totalMin / 60)
        m := Mod(totalMin, 60)
        if (m = 0)
            return h "h"
        return h "h" Format("{:02d}", m)
    }

    _ShortDateForLabel(run)
    {
        if !IsObject(run)
            return ""
        ts := run.Has("firstTs") ? run["firstTs"] : ""
        if (ts != "")
        {
            if RegExMatch(ts, "^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})", &m)
                return m[2] "-" m[3] " " m[4] ":" m[5]
            return SubStr(ts, 1, 16)
        }
        rid := run.Has("runId") ? run["runId"] : ""
        if (rid != "")
        {
            if RegExMatch(rid, "^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})", &m)
                return m[2] "-" m[3] " " m[4] ":" m[5]
            return SubStr(rid, 1, 12)
        }
        return ""
    }

    _OnGranularityChanged(ctrl)
    {
        try
            idx := ctrl.Value
        catch
            return
        if (idx < 1 || idx > RunStatsPlotDialog.GRAN_KEYS.Length)
            return
        this._granularity := RunStatsPlotDialog.GRAN_KEYS[idx]

        if IsObject(this._currentData)
            this._ShowWithData(this._currentData)
    }

    ; v17.13 — handler do dropdown de filtro min act.
    ; idx=1 -> Todas (filter=0), idx=N -> Ato (N-1)+
    _OnMinActFilterChanged(ctrl)
    {
        try
            idx := ctrl.Value
        catch
            return
        if (idx < 1 || idx > RunStatsPlotDialog.MIN_ACT_LABELS.Length)
            return
        this._minActFilter := idx - 1

        if IsObject(this._currentData)
            this._ShowWithData(this._currentData)
    }

    ; v17.14 — handler do dropdown de filtro de profile.
    ; idx=1 -> "All profiles" -> filtro vazio ("")
    ; idx>1 -> labels[idx] (nome do profile)
    _OnProfileFilterChanged(ctrl, labels)
    {
        try
            idx := ctrl.Value
        catch
            return
        if (idx < 1 || idx > labels.Length)
            return
        this._profileFilter := (idx = 1) ? "" : labels[idx]

        if IsObject(this._currentData)
            this._ShowWithData(this._currentData)
    }

    ; v17.14 — lista profiles unicos das runs salvas + run atual.
    ; Retorna array de strings ordenado alfabeticamente. Profiles vazios
    ; (runs antigas) sao ignorados — entram no "All profiles" implicitamente.
    _GetAvailableProfiles(currentData)
    {
        seen := Map()
        list := []

        ; Profile da run atual (caso seja a primeira run desse perfil,
        ; ele nao estaria no disco ainda)
        if IsObject(currentData) && currentData.Has("profile")
        {
            p := String(currentData["profile"])
            if (p != "" && !seen.Has(p))
            {
                seen[p] := true
                list.Push(p)
            }
        }

        ; Profiles das runs salvas no disco
        if IsObject(this._runHistory)
        {
            try
            {
                summaries := this._runHistory.LoadSummaries()
                for _, sm in summaries
                {
                    if !IsObject(sm)
                        continue
                    p := sm.Has("profile") ? String(sm["profile"]) : ""
                    if (p != "" && !seen.Has(p))
                    {
                        seen[p] := true
                        list.Push(p)
                    }
                }
            }
        }

        ; Sort alfabetico (insertion sort — N tipicamente < 10)
        n := list.Length
        ii := 2
        while (ii <= n)
        {
            jj := ii
            while (jj > 1 && StrCompare(list[jj], list[jj-1]) < 0)
            {
                tmp := list[jj]
                list[jj] := list[jj-1]
                list[jj-1] := tmp
                jj--
            }
            ii++
        }
        return list
    }

    _GetSegmentsForRun(run, granularity)
    {
        if !IsObject(run)
            return []

        switch granularity
        {
            case "run":
                return this._SegsRun(run)
            case "ato":
                return this._SegsByAct(run)
            case "mapa":
                return this._SegsByCategory(run, "mapa")
            case "cidade":
                return this._SegsByCategory(run, "cidade")
            case "loading":
                return this._SegsByCategory(run, "loading")
        }
        return []
    }

    _SegsRun(run)
    {
        segs := []
        totals := run.Has("totals") ? run["totals"] : Map()
        for _, def in RunStatsPlotBuilder.SegmentDefinitions()
        {
            key := def["key"]
            ms := totals.Has(key) ? totals[key] : 0
            if (ms <= 0)
                continue
            segs.Push(Map(
                "label", def["label"],
                "ms",    ms,
                "color", def["color"]
            ))
        }
        return segs
    }

    _SegsByAct(run)
    {
        actMap := Map()
        details := run.Has("details") ? run["details"] : []
        if !IsObject(details)
            return []
        for _, d in details
        {
            if !IsObject(d)
                continue
            note := d.Has("note") ? d["note"] : ""
            actNum := 0
            ; Aceita "Ato N" (legado) ou "Act N" (v17.13b) pra compat com
            ; runs salvas em versoes anteriores.
            if RegExMatch(note, "(?:Ato|Act)\s+(\d+)", &m)
                actNum := Integer(m[1] + 0)
            if (actNum <= 0)
                continue
            ms := d.Has("ms") ? d["ms"] : 0
            if (ms <= 0)
                continue
            key := String(actNum)
            if !actMap.Has(key)
                actMap[key] := 0
            actMap[key] += ms
        }

        keys := []
        for k, _ in actMap
            keys.Push(k)
        n := keys.Length
        ii := 2
        while (ii <= n)
        {
            jj := ii
            while (jj > 1 && Integer(keys[jj] + 0) < Integer(keys[jj-1] + 0))
            {
                tmp := keys[jj]
                keys[jj] := keys[jj-1]
                keys[jj-1] := tmp
                jj--
            }
            ii++
        }

        segs := []
        for i, k in keys
        {
            color := RunStatsPlotDialog._PaletteAt(i - 1)
            segs.Push(Map(
                "label", "Act " k,
                "ms",    actMap[k],
                "color", color
            ))
        }
        return segs
    }

    _SegsByCategory(run, category)
    {
        agg := Map()
        details := run.Has("details") ? run["details"] : []
        if !IsObject(details)
            return []
        for _, d in details
        {
            if !IsObject(d)
                continue
            cat := d.Has("category") ? d["category"] : ""
            if (cat != category)
                continue
            ms := d.Has("ms") ? d["ms"] : 0
            if (ms <= 0)
                continue
            label := d.Has("label") ? d["label"] : ""
            if (label = "")
                continue
            if !agg.Has(label)
                agg[label] := 0
            agg[label] += ms
        }

        segs := []
        for label, ms in agg
        {
            color := RunStatsPlotDialog._ColorForLabel(label)
            segs.Push(Map(
                "label", label,
                "ms",    ms,
                "color", color
            ))
        }
        n := segs.Length
        ii := 2
        while (ii <= n)
        {
            jj := ii
            while (jj > 1 && segs[jj]["ms"] > segs[jj-1]["ms"])
            {
                tmp := segs[jj]
                segs[jj] := segs[jj-1]
                segs[jj-1] := tmp
                jj--
            }
            ii++
        }
        return segs
    }

    ; ============================================================
    ; _BuildLegend - itens da granularidade com cor + label + tempo
    ;
    ; Mostra TODAS as series (visiveis + ocultas). Series ocultas tem
    ; swatch cinza (surface3) e texto muted; visiveis tem cor real.
    ;
    ; Cada item (swatch + texto) tem 0x100 (SS_NOTIFY) + Click handler
    ; pra togglar visibilidade.
    ; ============================================================
    _BuildLegend(g, segs, innerW)
    {
        if !IsObject(segs) || segs.Length = 0
            return

        legendY := RunStatsPlotDialog.Y_LEGEND + 14
        itemH := 16
        maxLineW := innerW
        maxItems := 18

        x := 14
        y := legendY
        i := 0
        for _, s in segs
        {
            if (i >= maxItems)
                break

            label := s["label"]
            ms    := s["ms"]
            color := s["color"]
            hidden := this._IsSeriesHidden(label)

            txt := label " " RunStatsPlotBuilder.FormatMs(ms)
            itemW := StrLen(txt) * 6 + 14 + 12
            if (itemW > 240)
                itemW := 240

            if (x + itemW > 14 + maxLineW)
            {
                x := 14
                y += itemH
                if (y > legendY + RunStatsPlotDialog.LEGEND_H - itemH)
                    break
            }

            ; Swatch — cinza se hidden, cor real se visivel
            swatchColor := hidden ? Theme.Color("surface3") : color
            swatch := g.Add("Text",
                "x" x " y" (y + 3) " w10 h10 0x100 Background" swatchColor, "")
            try swatch.OnEvent("Click", this._MakeLegendClickHandler(label))

            ; Texto — muted/subtle se hidden, text se visivel
            textColor := hidden ? Theme.Color("subtle") : Theme.Color("text")
            g.SetFont("s8 c" textColor, Theme.FONT_UI)
            lblCtrl := g.Add("Text",
                "x" (x + 14) " y" y " w" (itemW - 14) " h" itemH " 0x100 Background" Theme.Color("bg"),
                txt)
            try lblCtrl.OnEvent("Click", this._MakeLegendClickHandler(label))

            x += itemW + 4
            i++
        }
    }

    _MakeRowClickHandler(runId)
    {
        return (*) => this._OnHistoryRowClicked(runId)
    }

    _OnHistoryRowClicked(runId)
    {
        if (runId = "" || !IsObject(this._runHistory))
            return
        bres := this._runHistory.Load(runId)
        if !IsObject(bres)
            return
        this._ShowWithData(bres)
    }

    ; ============================================================
    ; Popup de detalhes
    ; ============================================================
    _OpenDetailsPopup()
    {
        if !IsObject(this._currentData)
            return

        if this._detailsGui
        {
            try this._detailsGui.Destroy()
            this._detailsGui := ""
        }

        details := this._currentData.Has("details") ? this._currentData["details"] : []
        runId   := this._currentData.Has("runId")   ? this._currentData["runId"]   : ""

        g := Gui("+AlwaysOnTop -MaximizeBox",
            "SpeedKalandra - Details" (runId != "" ? " (" runId ")" : ""))
        g.BackColor := Theme.Color("bg")
        g.MarginX := 14
        g.MarginY := 12
        g.OnEvent("Close", (*) => this._CloseDetailsPopup())
        g.OnEvent("Escape", (*) => this._CloseDetailsPopup())
        this._detailsGui := g

        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        lv := g.Add("ListView",
            "x14 y14 w780 h360 Background" Theme.Color("surface2"),
            ["Type", "Label", "Time", "Note", "When"])
        lv.ModifyCol(1, 90)
        lv.ModifyCol(2, 280)
        lv.ModifyCol(3, 80)
        lv.ModifyCol(4, 200)
        lv.ModifyCol(5, 130)

        if IsObject(details)
        {
            for _, row in details
            {
                if !IsObject(row)
                    continue
                lv.Add(,
                    row.Has("categoryLabel") ? row["categoryLabel"] : "",
                    row.Has("label")         ? row["label"]         : "",
                    RunStatsPlotBuilder.FormatMs(row.Has("ms") ? row["ms"] : 0),
                    row.Has("note")          ? row["note"]          : "",
                    row.Has("timestamp")     ? row["timestamp"]     : ""
                )
            }
        }

        btnClose := g.Add("Button", "x694 y386 w100 h28", "Close")
        btnClose.OnEvent("Click", (*) => this._CloseDetailsPopup())

        g.Show("w820 h430")
    }

    _CloseDetailsPopup()
    {
        if this._detailsGui
        {
            try this._detailsGui.Destroy()
            this._detailsGui := ""
        }
    }

    static _PaletteAt(idx0)
    {
        p := RunStatsPlotDialog.ROTATING_PALETTE
        return p[Mod(idx0, p.Length) + 1]
    }

    static _ColorForLabel(label)
    {
        if (label = "")
            return RunStatsPlotDialog._PaletteAt(0)
        h := 0
        n := StrLen(label)
        i := 1
        while (i <= n)
        {
            h := h * 31 + Ord(SubStr(label, i, 1))
            h := Mod(h, 99991)
            i++
        }
        return RunStatsPlotDialog._PaletteAt(Abs(h))
    }
}
