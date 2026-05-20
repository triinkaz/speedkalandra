; RunStatsPlotDialog — run statistics window with three sections:
; KPIs, a current-run stacked bar, and a line chart of evolution
; across saved runs.
;
; Layout (900×760):
;
;   +----------------------------------------------+
;   | Header: Run XYZ — 01:01:59                   |
;   | Sub: profile / version / deaths              |
;   |                                              |
;   | KPIs: MAP TOWN LOADING DEATHS                |
;   |                                              |
;   | Granularity: [By map ▼]                      |
;   |                                              |
;   | CURRENT RUN DISTRIBUTION:                    |
;   | [stacked bar segmented by granularity]       |
;   |                                              |
;   | EVOLUTION ACROSS RUNS:                       |
;   |   [line chart, 1 line per series]            |
;   |                                              |
;   | LEGEND (click to hide/show):                 |
;   | ▌Item1 ▌Item2 ░Item3(hidden) ▌Item4 ...      |
;   |                                              |
;   | [Details...] [History...]       [Close]      |
;   +----------------------------------------------+
;
; Hide/show series:
;   Clicking a legend entry (swatch or text) toggles visibility of
;   the matching series. Hidden series are skipped by the line chart
;   AND the stacked bar, AND excluded from the yMax computation —
;   so hiding the Deaths series (often dominates the scale) zooms
;   the chart into the remaining ones automatically.
;
;   State lives in this._hiddenSeries as Map<"granularity:label",
;   true>. Persists across rebuilds (granularity change, run reload)
;   and resets on script restart. The key embeds the granularity
;   because labels differ between modes (Map: map names, Act:
;   "Act 1"/"Act 2"/..., Run: 4 fixed categories) and each mode
;   keeps its own hidden set.
;
; Line chart:
;   X axis  — each saved run as one position (oldest left, newest right)
;   Y axis  — time in ms, scaled 0 → yMax of VISIBLE series
;   series  — one line per granularity item; missing series are
;             rendered with `present: false` so the line breaks at
;             that point instead of falling to zero (which earlier
;             versions did, creating a misleading floor).
;   Render  — GDI via LineChartRenderer into a Picture control.
;
; Granularity options:
;   "Full run"   — 4 lines (map, town, loading, deaths)
;   "By act"     — 1 line per act, rotating palette
;   "By map"     — 1 line per map, stable color via hash
;   "By town"    — 1 line per town
;   "By loading" — 1 line per loading
; For the dynamic granularities we keep TOP_SERIES_MAX lines by total
; time.
;
; Min-act filter: dropdown next to granularity restricts the line
; chart to runs with maxActReached >= N. Helps compare runs of the
; same length (e.g. only ones that reached Act 3+). "All" (default)
; doesn't filter.
;
; Profile filter: third dropdown isolates the line chart to runs of
; a single profile. On first open it picks up the current run's
; profile by default (focus on same-profile comparison); afterwards
; persists the user's choice.
;
; Subscriptions:
;   Cmd.OpenRunStatsPlotRequested → Open()
;   Evt.RunCompleted              → Open()  (auto-trigger)


class RunStatsPlotDialog
{
    static WINDOW_W := 900
    static WINDOW_H := 760

    ; Vertical layout
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
    static Y_LEGEND      := 244 + 300 + 4 + 18 + 8   ; after X labels + gap
    static LEGEND_H      := 60

    static GRAN_LABELS := ["Full run", "By act", "By map", "By town", "By loading"]
    static GRAN_KEYS   := ["run", "ato", "mapa", "cidade", "loading"]

    ; Max-act-reached filter. Index 1 = "All" (no filter).
    static MIN_ACT_LABELS := ["All", "Act 1+", "Act 2+", "Act 3+", "Act 4+", "Act 5+", "Act 6+", "Act 7+", "Act 8+", "Act 9+", "Act 10+"]

    static ROTATING_PALETTE := [
        "38BDF8", "F97316", "A78BFA", "FACC15", "EF4444",
        "10B981", "EC4899", "8B5CF6", "06B6D4", "84CC16",
        "F472B6", "FB923C", "60A5FA", "FBBF24", "C084FC"
    ]

    ; Line chart limits
    static MAX_RUNS_IN_CHART := 12     ; max runs on the X axis
    static TOP_SERIES_MAX    := 8      ; max series (by total ms)

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
    _minActFilter  := 0       ; 0 = all, N >= 1 = runs with maxActReached >= N
    _profileFilter        := ""    ; "" = All profiles; otherwise = profile name
    _profileFilterInited  := false ; false = first-open default still pending
    _currentData   := ""
    _hiddenSeries  := ""    ; Map<"granularity:label", true>

    _detailsGui  := ""

    __New(bus, plotBuilder, recorder, zoneTracker, timer, runHistory := "", headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("RunStatsPlotDialog: 'bus' must be EventBus")
        if !(plotBuilder is RunStatsPlotBuilder)
            throw TypeError("RunStatsPlotDialog: 'plotBuilder' must be RunStatsPlotBuilder")
        if !(recorder is RunStatsRecorder)
            throw TypeError("RunStatsPlotDialog: 'recorder' must be RunStatsRecorder")
        if !(zoneTracker is ZoneTrackingService)
            throw TypeError("RunStatsPlotDialog: 'zoneTracker' must be ZoneTrackingService")
        if !(timer is TimerService)
            throw TypeError("RunStatsPlotDialog: 'timer' must be TimerService")

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
        ; Include per-zone first-entry timestamps so the details
        ; popup can sort entries chronologically.
        zoneFirstEnteredAt := this._zoneTracker.GetFirstEnteredAtMap()
        runMs := this._timer.GetRunMs()
        return this._recorder.GetSnapshot(zoneTotals, runMs, zoneFirstEnteredAt)
    }

    ; ---- Hidden series state ----

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

    ; ---- GUI ----

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
        ; Local `runId` collides case-insensitively with the `RunId`
        ; domain class; use `currentRunId`. The same name shows up
        ; again in the X-axis label loop further down for consistency.
        currentRunId := data.Has("runId")    ? data["runId"]    : ""
        profile      := data.Has("profile")  ? data["profile"]  : ""
        patch        := data.Has("patch")    ? data["patch"]    : ""
        firstTs      := data.Has("firstTs")  ? data["firstTs"]  : ""
        totalMs      := data.Has("totalMs")  ? data["totalMs"]  : 0
        deathCnt     := data.Has("deathCount") ? data["deathCount"] : 0

        headerTxt := "Run " (currentRunId != "" ? currentRunId : "(in progress)") "  -  " RunStatsPlotBuilder.FormatMs(totalMs)
        ; gamePatch is preserved in data["patch"] for back-compat with
        ; saved runs but no longer displayed in the subheader.
        subTxt    := "Profile: " . profile . "   SpeedKalandra " . Version.STRING
        if (firstTs != "")
            subTxt .= "   Start: " firstTs
        if (deathCnt > 0)
            subTxt .= "   Deaths: " deathCnt

        g.SetFont("s12 bold c" Theme.Color("text"), Theme.FONT_UI)
        g.Add("Text", "x14 y" RunStatsPlotDialog.Y_HEADER " w" innerW, headerTxt)

        g.SetFont("s9 c" Theme.Color("muted"), Theme.FONT_UI)
        g.Add("Text", "x14 y" RunStatsPlotDialog.Y_SUBHEADER " w" innerW, subTxt)

        ; --- KPIs ---
        ; SegmentDefinitions has 4 entries (map / town / loading /
        ; death); colW splits the usable width between those four
        ; columns.
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

        ; --- Granularity dropdown ---
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

        ; --- Min Act filter dropdown ---
        ; Restricts the line chart to runs that reached at least act
        ; N — avoids comparing an Act-1-only run against a full
        ; campaign.
        g.SetFont("s8 bold c" Theme.Color("subtle"), Theme.FONT_UI)
        g.Add("Text", "x224 y" RunStatsPlotDialog.Y_GRAN_LABEL " w200", "MAX ACT FILTER")

        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        ddMinAct := g.Add("DropDownList",
            "x224 y" RunStatsPlotDialog.Y_GRAN_DD " w120 h180 Background" Theme.Color("surface3")
            . " Choose" (this._minActFilter + 1),
            RunStatsPlotDialog.MIN_ACT_LABELS)
        ddMinAct.OnEvent("Change", (ctrl, *) => this._OnMinActFilterChanged(ctrl))
        this._ctrls["dropdown_min_act"] := ddMinAct

        ; --- Profile filter dropdown ---
        ; Isolates the line chart to runs of a single profile. First
        ; open defaults to the current run's profile (focus on
        ; same-profile comparison); afterwards persists the user's
        ; choice. The profile list is built dynamically from saved
        ; runs + the current run.
        profiles := this._GetAvailableProfiles(data)
        profileLabels := ["All profiles"]
        for _, p in profiles
            profileLabels.Push(p)

        ; Initialize filter on first open (goes to current run's profile)
        if !this._profileFilterInited
        {
            initProfile := data.Has("profile") ? String(data["profile"]) : ""
            this._profileFilter := initProfile
            this._profileFilterInited := true
        }

        ; Determine the dropdown's initial selection
        profileChoice := 1   ; default: "All profiles" (index 1)
        if (this._profileFilter != "")
        {
            idx := 1
            for _, p in profiles
            {
                if (p = this._profileFilter)
                {
                    profileChoice := idx + 1   ; +1 because "All profiles" is item 1
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

        ; --- Current stacked bar ---
        g.SetFont("s8 bold c" Theme.Color("subtle"), Theme.FONT_UI)
        g.Add("Text", "x14 y" RunStatsPlotDialog.Y_BAR_LABEL " w" innerW, "CURRENT RUN DISTRIBUTION")

        barW := innerW
        g.Add("Text",
            "x14 y" RunStatsPlotDialog.Y_BAR " w" barW " h28 Background" Theme.Color("surface3"),
            "")

        ; Current-run segments, FILTERED by visible series
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

        ; Collect disk runs in ascending chronological order
        chartRuns := this._CollectRunsForChart(data)
        nRuns := chartRuns.Length

        ; allSeries = all series (including hidden ones) — used for the legend
        ; visibleSeries = filtered subset — used for the chart
        allSeries := []
        visibleSeries := []

        if (nRuns < 1)
        {
            ; No saved runs — placeholder
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
            ; Builds the series (top N by total ms)
            allSeries := this._BuildLineChartSeries(chartRuns)

            ; Filters visible series
            for _, s in allSeries
            {
                if !this._IsSeriesHidden(s["label"])
                    visibleSeries.Push(s)
            }

            ; yMax from VISIBLE ones ONLY (to zoom in when hiding large series)
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

            ; Renders the line chart with VISIBLE series only
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

            ; X axis labels (one per run, below the chart). Reuses
            ; the currentRunId already declared at the top of
            ; _BuildGui.
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

        ; --- Legend (ALL series, with differentiated visual for hidden ones) ---
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

        ; --- Buttons ---
        btnY := RunStatsPlotDialog.WINDOW_H - 50
        btnDetails := g.Add("Button", "x14 y" btnY " w110 h28", "Details...")
        btnDetails.OnEvent("Click", (*) => this._OpenDetailsPopup())

        if IsObject(this._runHistory)
        {
            btnHist := g.Add("Button", "x130 y" btnY " w110 h28", "History...")
            btnHist.OnEvent("Click", (*) => this._bus.Publish(Commands.OpenRunHistoryRequested, Map()))
        }

        ; "Death Stats" lives here (the run-statistics dialog) rather
        ; than in RunHistoryDialog because the aggregate spans every
        ; recorded death across all play sessions, not just the runs
        ; currently in history — see DeathLogRepository header for
        ; the run-lifecycle decoupling, and KNOWN_ISSUES.md ("Death log
        ; is decoupled from run history") for the user-facing note.
        btnDeathStats := g.Add("Button", "x246 y" btnY " w110 h28", "Death Stats")
        btnDeathStats.OnEvent("Click", (*) => this._bus.Publish(Commands.OpenDeathStatsRequested, Map()))

        btnClose := g.Add("Button", "x" (RunStatsPlotDialog.WINDOW_W - 120) " y" btnY " w100 h28", "Close")
        btnClose.OnEvent("Click", (*) => this.Close())

        g.Show("w" RunStatsPlotDialog.WINDOW_W " h" RunStatsPlotDialog.WINDOW_H)
    }

    ; Returns the runs to plot in chronological order, applying both
    ; the min-act and profile filters. The currently in-progress run
    ; always appears regardless of filters.
    _CollectRunsForChart(currentData)
    {
        all := []
        currentRunId := currentData.Has("runId") ? currentData["runId"] : ""
        minAct := this._minActFilter
        profileFilter := this._profileFilter

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

                    ; Apply the min-act filter. Runs saved before this
                    ; field existed have maxActReached = 0, so they
                    ; only appear when the filter is "All".
                    if (minAct > 0)
                    {
                        smMaxAct := sm.Has("maxActReached") ? sm["maxActReached"] : 0
                        if (smMaxAct < minAct)
                            continue
                    }

                    ; Apply the profile filter. Empty filter = "All
                    ; profiles" (no filter). Legacy runs without a
                    ; saved profile are excluded when a filter is
                    ; active — no exact match possible.
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

    ; Builds the line-chart series. Points get `present: false` when
    ; the series is absent from that run (e.g. "Act 2" in a run that
    ; only reached Act 1) — the renderer breaks the line there
    ; instead of dropping to zero, which earlier versions did and
    ; created a misleading floor.
    ;
    ; Exception: under "run" granularity the 4 fixed categories
    ; (map / town / loading / death) are always considered present.
    ; ms = 0 there is real data ("run without deaths"), not absence.
    _BuildLineChartSeries(runs)
    {
        if !IsObject(runs) || runs.Length = 0
            return []

        useGap := this._granularity != "run"

        ; Local `run` collides case-insensitively with the built-in
        ; `Run` function; use `runItem` throughout this method.
        universe := Map()
        for _, runItem in runs
        {
            segs := this._GetSegmentsForRun(runItem, this._granularity)
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
            for idx, runItem in runs
            {
                segs := this._GetSegmentsForRun(runItem, this._granularity)
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
                    ; Dynamic granularity and this run doesn't carry
                    ; the label → GAP (the renderer breaks the line).
                    points.Push(Map("xIdx", idx - 1, "yMs", 0, "present", false))
                }
                else
                {
                    ; "run" granularity OR label exists in the run -> valid data.
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

    ; Handler of the min-act dropdown.
    ; idx = 1 → All (filter = 0); idx = N → Act (N - 1)+
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

    ; Handler of the profile dropdown.
    ; idx = 1 → "All profiles" (filter = "")
    ; idx > 1 → labels[idx] (profile name)
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

    ; Returns the unique profile names across saved runs + the
    ; current run, sorted alphabetically. Empty profiles (legacy
    ; runs) are ignored — they fall under "All profiles" implicitly.
    _GetAvailableProfiles(currentData)
    {
        seen := Map()
        list := []

        ; Current run's profile (in case it's the first run of that
        ; profile, it wouldn't be on disk yet)
        if IsObject(currentData) && currentData.Has("profile")
        {
            p := String(currentData["profile"])
            if (p != "" && !seen.Has(p))
            {
                seen[p] := true
                list.Push(p)
            }
        }

        ; Profiles from runs saved on disk
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

        ; Alphabetical sort (insertion sort — N typically < 10)
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
            ; Accept both "Ato N" (legacy Portuguese saves) and
            ; "Act N" (current) so older runs still plot correctly.
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

    ; Builds the legend, one item per series (visible + hidden).
    ; Hidden series get a gray swatch (surface3) and muted text;
    ; visible ones get the real color. Each item (swatch + text)
    ; carries 0x100 (SS_NOTIFY) + a Click handler that toggles
    ; visibility.
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

            ; Swatch — gray if hidden, real color if visible
            swatchColor := hidden ? Theme.Color("surface3") : color
            swatch := g.Add("Text",
                "x" x " y" (y + 3) " w10 h10 0x100 Background" swatchColor, "")
            try swatch.OnEvent("Click", this._MakeLegendClickHandler(label))

            ; Text — muted/subtle if hidden, text if visible
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

    ; Details popup. Splits the details list into two tabs so the
    ; user isn't overwhelmed:
    ;   Activities — map / town / death entries
    ;   Loading    — loading events on their own (a typical run has
    ;                50+ loadings vs ~30 zones, very different cadence)
    ; Entries within each tab are already in chronological order
    ; (the builder sorted them). Entries without a timestamp
    ; (legacy / aggregated) end up at the bottom of their tab.
    _OpenDetailsPopup()
    {
        if !IsObject(this._currentData)
            return

        if this._detailsGui
        {
            try this._detailsGui.Destroy()
            this._detailsGui := ""
        }

        details      := this._currentData.Has("details") ? this._currentData["details"] : []
        ; Local `runId` collides with the `RunId` domain class; use
        ; `currentRunId`.
        currentRunId := this._currentData.Has("runId")   ? this._currentData["runId"]   : ""

        g := Gui("+AlwaysOnTop -MaximizeBox",
            "SpeedKalandra - Details" (currentRunId != "" ? " (" currentRunId ")" : ""))
        g.BackColor := Theme.Color("bg")
        g.MarginX := 14
        g.MarginY := 12
        g.OnEvent("Close", (*) => this._CloseDetailsPopup())
        g.OnEvent("Escape", (*) => this._CloseDetailsPopup())
        this._detailsGui := g

        ; Split details into activities + loading. The builder already
        ; sorted them chronologically, so a single pass preserves order.
        activityDetails := []
        loadingDetails  := []
        if IsObject(details)
        {
            for _, row in details
            {
                if !IsObject(row)
                    continue
                cat := row.Has("category") ? row["category"] : ""
                if (cat = "loading")
                    loadingDetails.Push(row)
                else
                    activityDetails.Push(row)
            }
        }

        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        tab := g.Add("Tab3", "x14 y14 w780 h360",
            ["Activities (" activityDetails.Length ")",
             "Loading (" loadingDetails.Length ")"])

        ; --- Tab 1: Activities (map + town + death) ---
        tab.UseTab(1)
        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        lvActivities := g.Add("ListView",
            "x24 y44 w760 h318 Background" Theme.Color("surface2"),
            ["Type", "Label", "Time", "Note", "When"])
        lvActivities.ModifyCol(1, 90)
        lvActivities.ModifyCol(2, 280)
        lvActivities.ModifyCol(3, 80)
        lvActivities.ModifyCol(4, 180)
        lvActivities.ModifyCol(5, 130)
        for _, row in activityDetails
        {
            lvActivities.Add(,
                row.Has("categoryLabel") ? row["categoryLabel"] : "",
                row.Has("label")         ? row["label"]         : "",
                RunStatsPlotBuilder.FormatMs(row.Has("ms") ? row["ms"] : 0),
                row.Has("note")          ? row["note"]          : "",
                row.Has("timestamp")     ? row["timestamp"]     : ""
            )
        }

        ; --- Tab 2: Loading (isolated) ---
        tab.UseTab(2)
        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        lvLoading := g.Add("ListView",
            "x24 y44 w760 h318 Background" Theme.Color("surface2"),
            ["Label", "Time", "When"])
        ; Loading rows use the `label` field as "<from> -> <to>" already.
        ; The `note` is typically empty for loading entries, so omitting
        ; that column gives more room to the label/timestamp.
        lvLoading.ModifyCol(1, 480)
        lvLoading.ModifyCol(2, 100)
        lvLoading.ModifyCol(3, 160)
        for _, row in loadingDetails
        {
            lvLoading.Add(,
                row.Has("label")     ? row["label"]     : "",
                RunStatsPlotBuilder.FormatMs(row.Has("ms") ? row["ms"] : 0),
                row.Has("timestamp") ? row["timestamp"] : ""
            )
        }

        ; Reset the tab context before adding the buttons — otherwise
        ; they'd be parented to the currently active tab.
        tab.UseTab()

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
