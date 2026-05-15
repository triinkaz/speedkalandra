; ============================================================
; SpeedKalandraApp - composition root (Onda 7, v17.10)
; ============================================================
;
; VERSAO POS-DEMOLICAO: focada em speedrun puro.
;
; PERSISTENCIA DE RUN (crash recovery + perf):
;   4 pecas sao persistidas no INI:
;     1. [RunState].(RunId,StartedAt,Status) — metadata (transicoes only)
;     2. [RunState].RunBaseMs                — timer (tick periodico 5s)
;     3. [RunState].LoadingTotalMs           — loading acumulado
;     4. [RunZoneTotals]                     — Map<zona, ms>
;
;   OTIMIZACAO CRITICA (v14.1): _PersistRunData usa cache de hash pra
;   pular IniWrites desnecessarios. Antes fazia 25 IniWrites a cada 5s
;   bloqueando o thread por 1-2s — causava lag de 6s no pause-detection.
;
; HISTORICO DE RUNS (v17.6 + v17.10):
;   Toda run salva em data/runs/{runId}.ini pelo RunHistoryRepository.
;   Save acontece em dois eventos:
;     - Evt.RunCompleted (Ctrl+Alt+F) — sempre salva
;     - Evt.RunCancelled (Ctrl+Alt+N -> CancelRun, ou Ctrl+Alt+R) —
;       salva so se runMs >= MIN_CANCELLED_SAVE_MS (3min). Evita lixo
;       de aborts rapidos / testes.
;
;   ORDEM DE SUBSCRIBE (v17.10):
;     O EventBus chama subscribers em ordem FIFO. RunStatsRecorder e
;     ZoneTrackingService ambos zeram seu state interno em RunCancelled.
;     Se inscrevessemos nosso save handler em Start() (depois deles),
;     o snapshot ja viria vazio.
;
;     Solucao: inscrevemos os handlers no __New, LOGO APOS criar
;     this.runHistory e ANTES de instanciar zoneTracker e statsRecorder.
;     Assim nosso handler eh chamado FIRST quando RunCancelled dispara,
;     com state intacto.
;
;     A arrow function captura `this` por escopo (nao por valor); quando
;     o handler eh invocado, this.statsRecorder etc. ja existem.
;
; AUTO-MICRO POR PANEL KEYS (REMOVIDO em v17.2):
;   PanelKeyService DESCONECTADO. MICRO so ativa via Ctrl+F9.
;
; GAME PAUSE DETECTION (REMOVIDO em v17.5):
;   GamePauseDetectionService DESCONECTADO (falsos positivos).


class SpeedKalandraApp
{
    ; Runs canceladas com menos disso NAO sao salvas no historico
    ; (evita lixo de teste/abort rapido). Em milissegundos.
    static MIN_CANCELLED_SAVE_MS := 180000   ; 3min

    _cfg          := ""
    _settingsRepo := ""
    log    := ""
    bus    := ""
    clock  := ""

    zonesCatalog := ""

    timer            := ""
    runState         := ""
    runService       := ""
    xpService        := ""
    logMonitor       := ""
    zoneTracker      := ""
    loadingDetection := ""
    loadingTotals    := ""
    personalBest     := ""
    actCheckpoints   := ""   ; v17.13
    statsRecorder    := ""
    plotBuilder      := ""
    autoFinalize     := ""
    autoStart        := ""

    runHistory      := ""    ; RunHistoryRepository — v17.6

    overlayMode     := ""
    overlayApplier  := ""
    focusAutoPause  := ""
    hudScanner      := ""
    hotkeyService   := ""
    overlayInter    := ""
    tickEmitter     := ""

    compactWidget := ""
    microWidget   := ""
    steveWidget   := ""    ; v17.14
    widgets       := ""

    settingsDialog     := ""
    plotDialog         := ""
    runHistoryDialog   := ""

    _started   := false
    _persistFn := ""
    _logMonitorTimer  := ""
    _runPersistTimer  := ""
    _headless         := false    ; v17.13 — controla se mostra MsgBox de confirmacao

    _lastSavedLoadingTotal := -1
    _lastSavedZoneTotalsHash := ""

    ; v17.15 (Bug #9): flag pra reset de level so na PRIMEIRA entrada
    ; do Riverbank na run. Antes, qualquer re-entrada (death respawn,
    ; portal, party invite) resetava characterLevel pra 1 silenciosamente.
    _riverbankSeenInRun := false

    ; v17.14 — "Undo last save" (F1): runId do save mais recente que ainda
    ; pode ser desfeito. Limpo apos 60s pelo _undoTimerFn ou ao executar undo.
    _lastSavedRunId := ""
    _undoTimerFn    := ""

    __New(config := "")
    {
        cfgMap := IsObject(config) ? config : Map()

        scriptDir := A_ScriptDir
        iniPath := cfgMap.Has("iniPath") ? cfgMap["iniPath"]
                                          : (scriptDir "\speedkalandra.ini")
        zonesCsvPath := cfgMap.Has("zonesCsvPath") ? cfgMap["zonesCsvPath"]
                                                    : (scriptDir "\data\zones.csv")
        logPath := cfgMap.Has("logPath") ? cfgMap["logPath"]
                                          : (scriptDir "\data\speedkalandra.log")
        runHistoryDir := cfgMap.Has("runHistoryDir") ? cfgMap["runHistoryDir"]
                                                      : (scriptDir "\data\runs")
        pbPath := cfgMap.Has("personalBestPath") ? cfgMap["personalBestPath"]
                                                  : (scriptDir "\data\personal_bests.ini")

        headless := cfgMap.Has("headless") ? !!cfgMap["headless"] : false
        this._headless := headless

        this.log   := LogService(logPath, "INFO", headless ? 1 : 32)
        this.bus   := EventBus(this.log)
        this.clock := RealClock()

        ini := IniFile(iniPath)
        this._settingsRepo := SettingsRepository(ini)
        this._cfg := this._settingsRepo.Load()

        this.zonesCatalog := ZonesCatalog(zonesCsvPath)
        this.log.Info("Catalogo de zonas carregado: " this.zonesCatalog.Count() " zonas", "App")

        ; Historico de runs (v17.6)
        this.runHistory := RunHistoryRepository(runHistoryDir)

        ; Personal bests (v17.13) — carrega do INI no construtor do
        ; service (via repo.Load). Atualizado em _SaveRunSnapshot quando
        ; reason="completed".
        this.personalBest := PersonalBestService(PersonalBestRepository(pbPath))
        if this.personalBest.HasRunPb()
        {
            try this.log.Info("PB de run carregado: "
                this.personalBest.GetRunPbMs() " ms ("
                this.personalBest.GetRunPbRunId() ")", "App")
        }

        ; (ActCheckpointTracker eh instanciado MAIS ABAIXO, depois do
        ; this.timer ser criado — ele depende do TimerService.GetRunMs.)

        ; ============================================================
        ; v17.10: HISTORY SAVE handlers — inscritos AGORA, antes dos
        ; services que zeram state em RunCancelled (statsRecorder e
        ; zoneTracker mais abaixo). Ordem FIFO do EventBus garante que
        ; nossos handlers sao chamados primeiro, com snapshot intacto.
        ; ============================================================
        this.bus.Subscribe(Events.RunCompleted,
            (data) => this._SaveRunSnapshot("completed"))
        this.bus.Subscribe(Events.RunCancelled,
            (data) => this._SaveRunSnapshot("cancelled"))

        this.runState   := RunStateRepository(ini)
        this.timer      := TimerService(this.clock, this.bus)
        this.runService := RunService(this.clock, this.bus, this.timer, this.runState)

        ; Act checkpoint tracker (v17.13) — rastreia tempo total da run
        ; em cada transicao de ato. Alimenta PB-por-ato no finalize.
        ; Depende do this.timer (pra GetRunMs), entao instanciado AQUI
        ; logo apos o timer.
        this.actCheckpoints := ActCheckpointTracker(this.bus, this.timer)

        hydratedState := this.runState.Load()
        try this.runService.Hydrate(hydratedState)

        this.focusAutoPause := FocusAutoPauseService(this.bus, this.timer, this._cfg)

        ; GamePauseDetection DESCONECTADO em v17.5

        this.hotkeyService := HotkeyService(this.bus, headless)
        this.hotkeyService.Hydrate(this._cfg.hotkeys)

        ; PanelKeys DESCONECTADO em v17.2

        this.overlayMode := OverlayModeService(this.bus, this._cfg)
        this.overlayMode.Hydrate()
        this.overlayInter := OverlayInteractionService(this.bus, headless)

        this.xpService := XpService()
        this.xpService.Hydrate(
            this._cfg.characterName,
            this._cfg.characterClass,
            this._cfg.characterLevel,
            this._cfg.currentAreaLevel,
            this._cfg.currentAreaCode
        )

        this.logMonitor := LogMonitorService(this.clock, this.bus, this.log)
        this.logMonitor.Configure(this._cfg.logFile)
        ; v17.15 (Bug #2): hidrata o nome do personagem pro filtro de
        ; DeathDetected. Sem isso, deaths em real-time entre boot e
        ; primeiro CharacterLevelUp nao seriam contados.
        this.logMonitor.SetCharacterName(this._cfg.characterName)

        ; zoneTracker subscribe RunCancelled aqui — DEPOIS do nosso save handler
        this.zoneTracker := ZoneTrackingService(this.bus, this.clock, this.zonesCatalog)

        try
        {
            zoneTotals := this.runState.LoadZoneTotals()
            this.zoneTracker.Hydrate(zoneTotals)
            if (hydratedState is RunState && hydratedState.IsRunning())
            {
                this.zoneTracker.SetRunActive(true)
                this.log.Info("Zone tracker hidratado: " . zoneTotals.Count . " zonas com tempo acumulado (run em andamento)", "App")
            }
            this._lastSavedZoneTotalsHash := this._ComputeTotalsHash(zoneTotals)
        }
        catch as ex
        {
            this.log.Warn("Falha ao hidratar zone totals: " . ex.Message
                . " | What: " . (ex.HasOwnProp("What") ? ex.What : "?")
                . " | Line: " . (ex.HasOwnProp("Line") ? ex.Line : "?")
                . " | File: " . (ex.HasOwnProp("File") ? ex.File : "?"), "App")
        }

        this.hudScanner := HudPixelScanner((x, y) => PixelGetColor(x, y, "RGB"))
        zoneProvider := () => this.zoneTracker.GetActiveZone()
        stepProvider := () => Map("actIndex", this._DeduceCurrentAct(), "stepId", "")
        this.loadingDetection := LoadingDetectionService(
            this.bus, this.clock, this.hudScanner, this._cfg, this.timer,
            zoneProvider, stepProvider, "", headless
        )
        this.loadingTotals := LoadingTotalsService(this.bus)

        try
        {
            if (hydratedState is RunState && hydratedState.IsActive())
            {
                loadingMs := this.runState.LoadLoadingTotal()
                this.loadingTotals.Hydrate(loadingMs)
                if (loadingMs > 0)
                    this.log.Info("Loading totals hidratados: " . loadingMs . " ms acumulados", "App")
                this._lastSavedLoadingTotal := loadingMs
            }
        }
        catch as ex
        {
            this.log.Warn("Falha ao hidratar loading totals: " . ex.Message
                . " | What: " . (ex.HasOwnProp("What") ? ex.What : "?")
                . " | Line: " . (ex.HasOwnProp("Line") ? ex.Line : "?")
                . " | File: " . (ex.HasOwnProp("File") ? ex.File : "?"), "App")
        }

        ; statsRecorder subscribe RunCancelled aqui — DEPOIS do nosso save handler
        this.statsRecorder := RunStatsRecorder(this.bus, this.clock)
        this.plotBuilder   := RunStatsPlotBuilder(this.zonesCatalog, this._cfg)

        this.autoFinalize := AutoFinalizeService(this.bus, this._cfg)
        ; v17.15 (Bug #4): passa runService pra que AutoStart saiba se ja
        ; existe run ativa hidratada e nao a apague com a proxima linha
        ; do log que casar autoStartRegex.
        this.autoStart := AutoStartService(this.bus, this._cfg, this.runService)

        compactPos := this._GetWidgetPos("compactLayout", 10, 1.5)
        microPos   := this._GetWidgetPos("microLayout",   75, 92)
        stevePos   := this._GetWidgetPos("steveLayout",   10, 1.5)   ; v17.14

        this._persistFn := () => this._PersistSettings()

        this.compactWidget := CompactLayoutWidget(
            this.bus, compactPos, this._persistFn,
            this.timer, this.zoneTracker, this.xpService,
            this.zonesCatalog, this.loadingTotals, this._cfg,
            this.personalBest
        )

        this.microWidget := MicroLayoutWidget(
            this.bus, microPos, this._persistFn,
            this.timer, this.xpService
        )

        this.steveWidget := SteveLayoutWidget(
            this.bus, stevePos, this._persistFn,
            this.timer, this.zoneTracker, this.xpService,
            this.zonesCatalog, this.loadingTotals, this.personalBest
        )

        this.widgets := Map()
        this.widgets["compactLayout"] := this.compactWidget
        this.widgets["microLayout"]   := this.microWidget
        this.widgets["steveLayout"]   := this.steveWidget

        this.overlayApplier := OverlayModeApplier(this.bus, this.widgets)
        this.tickEmitter := AppTickEmitter(this.bus, 300)

        this.settingsDialog := SettingsDialog(this.bus, this._settingsRepo, this._cfg, headless)
        this.plotDialog := RunStatsPlotDialog(
            this.bus, this.plotBuilder, this.statsRecorder,
            this.zoneTracker, this.timer, this.runHistory, headless
        )
        this.runHistoryDialog := RunHistoryDialog(this.bus, this.runHistory, this.plotDialog, this.personalBest, headless)

        this._WireEventHandlers()
    }

    Start()
    {
        if this._started
            return
        this._started := true

        ; v17.15.2: mostra disclaimer no boot se ainda nao foi reconhecido.
        ; Modal — bloqueia o restante do Start() ate user dismisse.
        this._ShowDisclaimerIfNeeded()

        ; v17.14 — F4: se ha run ativa hidratada, pergunta ao usuario
        ; o que fazer antes de subir os widgets/hotkeys. Resolve a
        ; ambiguidade de "run pendurada" no boot.
        this._PromptHydratedRun()

        this.bus.Subscribe(Events.CharacterLevelUp,
            (data) => this._OnCharacterLevelUp(data))
        this.bus.Subscribe(Events.AreaLevelChanged,
            (data) => this._OnAreaLevelChanged(data))

        this.bus.Subscribe(Events.ZoneEntered,
            (data) => this._OnZoneEnteredForLevel(data))

        this.bus.Subscribe(Events.RunReset,
            (data) => this._OnRunEndedClearZones(data))
        this.bus.Subscribe(Events.RunCancelled,
            (data) => this._OnRunEndedClearZones(data))

        ; NOTA: os subscribes pra RunCompleted/RunCancelled que CHAMAM
        ; _SaveRunSnapshot ja foram feitos no __New (antes dos services
        ; que zeram state). Nao re-inscrever aqui.

        if (this._cfg.logFile != "" && FileExist(this._cfg.logFile))
        {
            this.logMonitor.Start(true)
            this._logMonitorTimer := () => this.logMonitor.Tick()
            try SetTimer(this._logMonitorTimer, 250)
            this.log.Info("Log monitor iniciado: " this._cfg.logFile, "App")
        }
        else if (this._cfg.logFile = "")
        {
            ; v17.15.2: fresh install — logFile vazio eh esperado. INFO
            ; em vez de WARN pra nao disparar TrayTip de "boot com avisos"
            ; no primeiro boot do user.
            this.log.Info("Log file nao configurado. Configure o caminho do Client.txt em Settings (tray menu) pra ativar detecção de zona.", "App")
        }
        else
        {
            ; logFile configurado mas inexistente — user errou o path.
            ; Continua WARN pra notificar.
            this.log.Warn("Log file configurado mas arquivo não existe: " this._cfg.logFile, "App")
        }

        this.focusAutoPause.Start()
        this.hotkeyService.Start()
        this.overlayInter.Start()

        if this._cfg.loadingVisualEnabled
            this.loadingDetection.Start()

        this.compactWidget.Show()
        this.microWidget.Show()
        this.steveWidget.Show()

        this.overlayApplier.ApplyMode(this.overlayMode.GetMode())

        this.tickEmitter.Start()

        this._runPersistTimer := () => this._PersistRunData()
        try SetTimer(this._runPersistTimer, 5000)

        this.bus.Publish(Events.AppStarted, Map())
        this.log.Info("SpeedKalandra iniciado", "App")

        ; ============================================================
        ; Surface de warnings/errors do boot (v17.15).
        ;
        ; LogService conta WARN/ERROR independente do minLevel. Se o
        ; boot logou algo, emite TrayTip pra que o user saiba — sem
        ; isso, warnings ficavam silenciosos no arquivo de log (caso do
        ; bug "Map has no method Count" que rodou por 3 dias sem ninguém
        ; perceber).
        ;
        ; Reseta counters apos surface: warnings durante runtime não
        ; acumulam no proximo boot prompt.
        ; ============================================================
        warnCount := this.log.GetWarnCount()
        errorCount := this.log.GetErrorCount()
        if (!this._headless && (warnCount > 0 || errorCount > 0))
        {
            label := errorCount > 0
                ? "Boot com erros (" warnCount " warn, " errorCount " error)"
                : "Boot com avisos (" warnCount " warn)"
            try TrayTip("SpeedKalandra",
                label . "`nVeja data\speedkalandra.log para detalhes.",
                "Iconi")
        }
        try this.log.ResetCounts()
    }

    Stop()
    {
        if !this._started
            return
        this._started := false

        this.bus.Publish(Events.AppStopping, Map())

        if (this._logMonitorTimer != "")
            try SetTimer(this._logMonitorTimer, 0)
        if (this._runPersistTimer != "")
            try SetTimer(this._runPersistTimer, 0)

        try this.tickEmitter.Stop()
        try this.loadingDetection.Stop()
        try this.overlayInter.Stop()
        try this.hotkeyService.Stop()
        try this.focusAutoPause.Stop()
        try this.logMonitor.Stop()

        try this.compactWidget.Hide()
        try this.microWidget.Hide()
        try this.steveWidget.Hide()

        try this._PersistSettings()
        try this._PersistRunDataFull()
        try this.log.Flush()
    }

    ToggleOverlay()
    {
        mode := this.overlayMode.GetMode()
        if (mode = OverlayModes.MICRO)
        {
            if this.microWidget.IsVisible()
                this.microWidget.Hide()
            else
                this.microWidget.Show()
        }
        else if (mode = OverlayModes.STEVE)
        {
            if this.steveWidget.IsVisible()
                this.steveWidget.Hide()
            else
                this.steveWidget.Show()
        }
        else
        {
            if this.compactWidget.IsVisible()
                this.compactWidget.Hide()
            else
                this.compactWidget.Show()
        }
    }

    HandleTimerToggle()
    {
        if this.runService.IsActive()
            this.timer.Toggle()
        else
            this.runService.NewRun()
    }

    _WireEventHandlers()
    {
        this.bus.Subscribe(Commands.ToggleOverlayRequested,
            (data) => this.ToggleOverlay())

        this.bus.Subscribe(Commands.TimerToggleRequested,
            (data) => this.HandleTimerToggle())

        this.bus.Subscribe(Events.RunStarted,
            (data) => this._OnRunStartedForXp(data))

        ; v17.13 — reset de PBs via tray menu
        this.bus.Subscribe(Commands.ResetPersonalBestsRequested,
            (data) => this._OnResetPersonalBestsRequested())
    }

    _OnCharacterLevelUp(data)
    {
        if !IsObject(data)
            return
        name  := data.Has("character") ? data["character"] : ""
        class := data.Has("class")     ? data["class"]     : ""
        level := data.Has("level")     ? data["level"]     : 0
        this.xpService.SetCharacter(name, class, level)
        if (name != "")
        {
            this._cfg.characterName := name
            ; v17.15 (Bug #2): propaga pro filtro de DeathDetected
            try this.logMonitor.SetCharacterName(name)
        }
        if (class != "")
            this._cfg.characterClass := class
        if (level > 0)
            this._cfg.characterLevel := level
    }

    _OnAreaLevelChanged(data)
    {
        if !IsObject(data)
            return
        lvl  := data.Has("areaLevel") ? data["areaLevel"] : 0
        code := data.Has("areaCode")  ? data["areaCode"]  : ""
        this.xpService.SetCurrentArea(lvl, code)
        if (lvl > 0)
            this._cfg.currentAreaLevel := lvl
        if (code != "")
            this._cfg.currentAreaCode := code
    }

    _OnZoneEnteredForLevel(data)
    {
        ; v17.15 (Bug #9): so reseta level pra 1 na PRIMEIRA entrada
        ; do Riverbank em uma run nova.
        ;
        ; Antes: InStr(zone, "Riverbank") + reset incondicional.
        ; Problema 1: substring match (qualquer zona com "Riverbank"
        ;             no nome casava — pouco provavel em PoE2 mas
        ;             fragil contra mudancas de nome).
        ; Problema 2: re-entrada (death respawn, portal, party invite)
        ;             resetava level cacheado, causando XP display errado
        ;             ate o proximo CharacterLevelUp.
        ;
        ; Agora: nome exato "The Riverbank" + flag _riverbankSeenInRun.
        ; Flag eh resetado em RunStarted (NEW run) e RunEnded (Reset/Cancel).
        if !IsObject(data) || !data.Has("zoneName")
            return
        zone := data["zoneName"]
        if (zone != "The Riverbank")
            return
        if this._riverbankSeenInRun
            return
        this._riverbankSeenInRun := true
        this.xpService.SetCharacter("", "", 1)
        this._cfg.characterLevel := 1
    }

    ; v17.14 — Handler de RunStarted que NAO reseta XP area quando a
    ; run vem de Hydrate (reload do app). Hydrate restaura state
    ; persistido; resetar XP area perderia info acumulada da run.
    _OnRunStartedForXp(data)
    {
        isHydrate := IsObject(data) && data.Has("hydrated") && data["hydrated"]
        if isHydrate
            return
        try this.xpService.ResetCurrentArea()
        ; v17.15 (Bug #9): nova run, libera o reset de level no Riverbank
        this._riverbankSeenInRun := false
    }

    _OnRunEndedClearZones(data)
    {
        try this.runState.ClearZoneTotals()
        this._lastSavedLoadingTotal := -1
        this._lastSavedZoneTotalsHash := ""
        ; v17.15 (Bug #9): fim de run, libera flag pra proxima
        this._riverbankSeenInRun := false
    }

    ; ============================================================
    ; _ShowDisclaimerIfNeeded (v17.15.2)
    ;
    ; Modal no boot. Mostra dialog com disclaimer + checkbox "Don't
    ; show again". Se user marcar checkbox e clicar "I understand",
    ; persiste cfg.disclaimerAcknowledged = true e nao mostra mais.
    ;
    ; Headless mode: pula. Ja-acknowledged: pula.
    ;
    ; O texto eh em ingles pra alcancar a maior audiencia possivel
    ; (PoE2 eh global; player brasileiro normalmente ja domina ingles
    ; de gaming). Mantemos o texto em um lugar so pra facil edicao.
    ; ============================================================
    _ShowDisclaimerIfNeeded()
    {
        if this._headless
            return
        if this._cfg.disclaimerAcknowledged
            return

        ; Texto do disclaimer (multi-line continuation section).
        ; Whitespace inicial de cada linha eh stripado pelo AHK ate
        ; alinhar com o `)` de fechamento.
        bodyText := "
        (
SpeedKalandra is a personal project by a player, not a developer.

I built this because some functionality was missing from the overlays available during my runs, and I wanted something for my own use that other players might also find useful.

Yes, I know other speedrun trackers exist, some maintained by teams. I don't care if there are 10 other people working on this - I'm not trying to compete with them. I'm doing this because it's fun, and because I want a tracker that works the way I want it to.

The code was written with substantial help from AI. I directed what I wanted, reviewed the output, tested in actual runs, and iterated when things broke - but I won't pretend I wrote the architecture from scratch or deeply understand every line. I understand enough to use it, debug obvious problems, and make small adjustments.

What this means for you:

- USE AT YOUR OWN RISK. I tested on my own machine for my own playstyle. Your setup may differ in ways I haven't anticipated.

- BUGS ARE LIKELY. I fix what I personally hit. Edge cases I never encounter may sit broken for a long time.

- DON'T EXPECT FAST SUPPORT. I'm not maintaining this as a product. If you open an issue, I'll read it, but response times will be whenever-I-feel-like-it.

- FORK, MODIFY, RIP PARTS OUT. If you're a real developer and want to clean up something that's clearly wrong, go ahead.

- ANTI-CHEAT / TOS: The tool only reads the PoE2 Client.txt log file and captures pixel colors from the screen for loading detection. It does not inject into the game process, modify game files, or send inputs to the game. To my knowledge this is within typical overlay/tracker territory, but I make no guarantees - use it understanding that ultimately you're responsible for what runs on your machine while playing.

If it helps your runs, great. If it doesn't fit your needs, that's fine too - the goal was to scratch my own itch, not to build the universal speedrun tracker.
        )"

        choice := { dontShow: false, done: false }

        g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox +ToolWindow",
                 "SpeedKalandra - Disclaimer")
        g.MarginX := 16
        g.MarginY := 14

        g.SetFont("s11 bold", "Segoe UI")
        g.Add("Text", "x16 y14 w560", "Before using SpeedKalandra...")

        ; Multi-line Edit read-only com VScroll. Wrap automatico.
        g.SetFont("s9", "Segoe UI")
        edt := g.Add("Edit",
            "x16 y42 w560 h360 +Multi +ReadOnly +VScroll Background0xFFFFFF",
            bodyText)

        ; Checkbox
        g.SetFont("s9", "Segoe UI")
        chkDontShow := g.Add("Checkbox", "x16 y414 w300",
            "Don't show this disclaimer again")

        ; Botao
        btnOk := g.Add("Button", "x456 y410 w120 h30 Default", "I understand")

        ; Handlers — closure compartilha o objeto choice por referencia
        dismissFn := (*) => (
            choice.dontShow := chkDontShow.Value = 1,
            choice.done := true,
            g.Destroy()
        )
        btnOk.OnEvent("Click", dismissFn)
        g.OnEvent("Close",  dismissFn)
        g.OnEvent("Escape", dismissFn)

        ; Centraliza na tela
        g.Show("w592 h460")

        ; Bloqueia ate o user dismisse (mesmo padrao do _PromptHydratedRun)
        hwnd := g.Hwnd
        while (!choice.done && WinExist("ahk_id " hwnd))
            Sleep 50

        ; Se user marcou checkbox, persiste o ack pra nao mostrar mais
        if (choice.dontShow)
        {
            this._cfg.disclaimerAcknowledged := true
            try this._PersistSettings()
            if IsObject(this.log)
                try this.log.Info("Disclaimer acknowledged pelo usuario", "App")
        }
    }

    ; ============================================================
    ; _PromptHydratedRun (v17.14 — F4)
    ;
    ; Chamado no inicio do Start(). Se ha run ativa hidratada (vinda
    ; do INI persistido), mostra GUI custom com 3 botoes:
    ;   - Resume: no-op, app continua com a run hidratada normalmente
    ;   - Finalize & save: chama FinalizeRun -> _SaveRunSnapshot salva
    ;     via threshold (>=3min) e atualiza PBs
    ;   - Discard: chama ResetRun -> limpa state sem salvar
    ;
    ; Headless mode: pula (default = Resume, comportamento de testes).
    ;
    ; GUI bloqueia ate o user escolher (modal). Sem timeout — a decisao
    ; precisa ser explicita pra evitar estado inconsistente.
    ; ============================================================
    _PromptHydratedRun()
    {
        if this._headless
            return
        if !IsObject(this.runService) || !this.runService.IsActive()
            return

        ; v17.15 (Bug #5): pausa timer durante a decisao do usuario.
        ;
        ; Antes: loop Sleep 50 bloqueava thread principal sem desabilitar
        ; o cronometro. Timer hidratado em "running" continuava contando
        ; durante o tempo de decisao (potencialmente minutos) — dispatch:
        ; pra speedrun onde 1s importa, eh inadmissivel.
        ;
        ; Agora: pausa explicita antes do prompt. Se user escolher Resume,
        ; o timer eh retomado. Discard/Finalize zeram o timer de qualquer
        ; forma (via ResetRun/FinalizeRun).
        wasRunningBeforePrompt := IsObject(this.timer) && this.timer.IsRunning()
        if wasRunningBeforePrompt
            try this.timer.Pause()

        state := this.runService.GetState()
        runMs := IsObject(this.timer) ? this.timer.GetRunMs() : 0
        durStr := SpeedKalandraApp._FormatMsForMsg(runMs)
        startedAt := state.startedAt != "" ? state.startedAt : "unknown"

        ; Choice via closure compartilhada
        choice := { value: "" }

        g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox +ToolWindow",
            "SpeedKalandra — Active run found")
        g.SetFont("s10")
        g.Add("Text", "x20 y20 w360",
            "An active run was found from a previous session:")
        g.SetFont("s10 bold")
        g.Add("Text", "x20 y50 w360",
            "Started:  " startedAt "`n"
            . "Duration: " durStr)
        g.SetFont("s10")
        g.Add("Text", "x20 y100 w360", "What do you want to do?")

        ; Botoes
        btnResume := g.Add("Button", "x20 y140 w110 h32 Default", "Resume")
        btnResume.OnEvent("Click", (*) => (choice.value := "resume", g.Destroy()))

        btnFinalize := g.Add("Button", "x140 y140 w120 h32", "Finalize && save")
        btnFinalize.OnEvent("Click", (*) => (choice.value := "finalize", g.Destroy()))

        btnDiscard := g.Add("Button", "x270 y140 w110 h32", "Discard")
        btnDiscard.OnEvent("Click", (*) => (choice.value := "discard", g.Destroy()))

        ; Fechar X = Resume (default seguro — nao perde dados)
        g.OnEvent("Close", (*) => (choice.value := "resume", g.Destroy()))
        g.OnEvent("Escape", (*) => (choice.value := "resume", g.Destroy()))

        g.Show("w400 h190")

        ; Aguarda escolha (bloqueia thread). g.Destroy() acima dispara
        ; o exit do loop.
        hwnd := g.Hwnd
        while (choice.value = "" && WinExist("ahk_id " hwnd))
            Sleep 50

        ; Aplica escolha
        if (choice.value = "discard")
        {
            try this.runService.ResetRun()
            try this.log.Info("Run hidratada descartada pelo usuario (" . durStr . ", iniciada em " . startedAt . ")", "App")
            try TrayTip("SpeedKalandra", "Previous run discarded.", "Mute")
        }
        else if (choice.value = "finalize")
        {
            ; FinalizeRun publica RunCompleted -> _SaveRunSnapshot("completed")
            ; aplica threshold e salva ou descarta
            try this.runService.FinalizeRun()
            try this.log.Info("Run hidratada finalizada pelo usuario (" . durStr . ", iniciada em " . startedAt . ")", "App")
        }
        else
        {
            ; "resume" (botao ou close-X): retoma o timer se estava
            ; running antes do prompt. Se estava paused, mantem paused.
            if wasRunningBeforePrompt
                try this.timer.Resume()
        }
    }

    ; ============================================================
    ; _SaveRunSnapshot (v17.14 — sem MsgBox de confirmacao, F1)
    ;
    ; Chamado em DOIS eventos (subscritos no __New ANTES dos services
    ; que zeram state):
    ;   - Evt.RunCompleted  (Ctrl+Alt+F)  -> reason = "completed"
    ;   - Evt.RunCancelled  (CancelRun direto) -> reason = "cancelled"
    ;
    ; Threshold MIN_CANCELLED_SAVE_MS (3min) aplica pra AMBOS reasons:
    ;   - Run < 3min: descarta silenciosamente (lixo de teste)
    ;   - Run >= 3min: salva direto, sem MsgBox
    ;
    ; Apos save com sucesso de uma run completed, marca o save como
    ; "undoable" por 60s via tray menu "Undo last save". User pode
    ; clicar pra remover do historico (PBs nao sao revertidos — se
    ; precisar limpar PB indevido, usar "Reset PBs" do tray menu).
    ;
    ; Falhas silenciosas: nao queremos quebrar o fluxo de finalizacao
    ; por erro de I/O no historico.
    ; ============================================================
    _SaveRunSnapshot(reason)
    {
        try
        {
            if !IsObject(this.runHistory)
                return

            zoneTotals := IsObject(this.zoneTracker)
                          ? this.zoneTracker.GetTotalsForSnapshot()
                          : Map()
            runMs := IsObject(this.timer) ? this.timer.GetRunMs() : 0

            ; Threshold uniforme pra completed E cancelled (F1)
            if (runMs < SpeedKalandraApp.MIN_CANCELLED_SAVE_MS)
            {
                if IsObject(this.log)
                {
                    try this.log.Info("Run muito curta descartada (< "
                        SpeedKalandraApp.MIN_CANCELLED_SAVE_MS "ms): "
                        runMs " ms (reason=" reason ")", "App")
                }
                ; TrayTip soh pra completed — cancelled eh esperado
                ; ser silencioso (usuario cancelou intencionalmente)
                if (reason = "completed" && !this._headless)
                {
                    try TrayTip("SpeedKalandra",
                        "Run too short (" SpeedKalandraApp._FormatMsForMsg(runMs)
                        "), not saved.", "Mute")
                }
                return
            }

            if !IsObject(this.statsRecorder) || !IsObject(this.plotBuilder)
                return

            snapshot := this.statsRecorder.GetSnapshot(zoneTotals, runMs)
            buildResult := this.plotBuilder.Build(snapshot)

            ; v17.15.1: captura actCheckpoints AGORA e injeta no buildResult
            ; antes do Save. Permite que PersonalBestService.RebuildFromHistory
            ; reconstrua PBs por ato apos delete de runs. Runs salvas antes
            ; dessa mudanca nao tem checkpoints persistidos — rebuild os
            ; ignora silenciosamente (read retorna Map vazio).
            ;
            ; Captura aqui (nao mais abaixo) garante que o save ja persista
            ; os mesmos checkpoints que UpdateFromRun vai consumir.
            actCheckpoints := Map()
            if IsObject(this.actCheckpoints)
            {
                try this.actCheckpoints.CaptureCurrentAsCheckpoint(runMs)
                try actCheckpoints := this.actCheckpoints.GetCheckpoints()
            }
            buildResult["actCheckpoints"] := actCheckpoints

            saved := this.runHistory.Save(buildResult)
            rid := buildResult.Has("runId") ? buildResult["runId"] : ""
            if (saved && IsObject(this.log))
            {
                this.log.Info("Run salva no historico (" reason "): " rid
                    " (" runMs " ms)", "App")
            }

            ; --- Personal bests (v17.13) ---
            ; Atualiza PBs SOMENTE em runs completed. Cancelled nao conta
            ; pra PB (mesmo se passar o threshold).
            pbChanged := false
            if (reason = "completed" && IsObject(this.personalBest))
            {
                ; v17.15.1: usa actCheckpoints ja capturado acima (era
                ; capturado 2x antes — desnecessario).
                try pbChanged := this.personalBest.UpdateFromRun(runMs, rid, zoneTotals, actCheckpoints)
                if (pbChanged && IsObject(this.log))
                {
                    nActs := 0
                    for _, _ms in actCheckpoints
                    {
                        if (_ms > 0)
                            nActs += 1
                    }
                    try this.log.Info("PB atualizado em run " rid
                        " (runMs=" runMs ", checkpoints=" nActs ")", "App")
                }
            }

            ; --- TrayTip + tray menu "Undo last save" ---
            ; Soh pra completed. Cancelled (raro agora que NewRun nao chama
            ; CancelRun) eh silencioso.
            if (saved && reason = "completed" && !this._headless)
            {
                durStr := SpeedKalandraApp._FormatMsForMsg(runMs)
                msg := pbChanged
                    ? "Saved (" durStr "). PB updated! Tray menu has Undo (60s)."
                    : "Saved (" durStr "). Tray menu has Undo (60s)."
                try TrayTip("SpeedKalandra", msg, "Mute")
                this._MarkUndoableSave(rid)
            }
        }
        catch as ex
        {
            try this.log.Warn("Falha ao salvar run no historico: " ex.Message, "App")
        }
    }

    ; ============================================================
    ; Undo last save (v17.14 — F1)
    ;
    ; Fluxo:
    ;   1. _SaveRunSnapshot salva run -> _MarkUndoableSave(runId)
    ;   2. _MarkUndoableSave armazena runId + adiciona tray menu item
    ;      + arma SetTimer 60s
    ;   3a. User clica "Undo last save" -> UndoLastSave() apaga arquivo +
    ;       limpa tudo
    ;   3b. 60s passam -> _ExpireUndoableSave() remove menu item e limpa runId
    ;
    ; PBs NAO sao revertidos no undo (decisao deliberada — vide F1).
    ; Pra limpar PB indevido, usar "Reset PBs" do tray menu.
    ; ============================================================
    _MarkUndoableSave(runId)
    {
        if (runId = "")
            return
        this._lastSavedRunId := runId

        ; Cancela timer antigo se existia (save anterior ainda undoable)
        if (this._undoTimerFn != "")
        {
            try SetTimer(this._undoTimerFn, 0)
            this._undoTimerFn := ""
        }

        ; Adiciona tray menu item (helper global em speedkalandra.ahk)
        try SpeedKalandraTrayAddUndoItem()

        ; Arma timer pra expirar apos 60s (negativo = roda 1 vez)
        this._undoTimerFn := () => this._ExpireUndoableSave()
        try SetTimer(this._undoTimerFn, -60000)
    }

    UndoLastSave()
    {
        runId := this._lastSavedRunId
        if (runId = "")
        {
            ; Item de menu obsoleto — limpa por garantia
            try SpeedKalandraTrayRemoveUndoItem()
            return
        }

        ; Apaga arquivo do historico
        deleted := false
        try
        {
            if IsObject(this.runHistory)
                deleted := this.runHistory.Delete(runId)
        }
        catch
            deleted := false

        ; Limpa state interno
        this._lastSavedRunId := ""
        if (this._undoTimerFn != "")
        {
            try SetTimer(this._undoTimerFn, 0)
            this._undoTimerFn := ""
        }
        try SpeedKalandraTrayRemoveUndoItem()

        if IsObject(this.log)
        {
            try this.log.Info("Undo last save: " runId
                (deleted ? " (removido)" : " (arquivo nao encontrado)"), "App")
        }
        if !this._headless
        {
            msg := deleted
                ? "Last save removed from history. (PBs were not reverted.)"
                : "Last save not found (already removed?)."
            try TrayTip("SpeedKalandra", msg, "Mute")
        }
    }

    _ExpireUndoableSave()
    {
        this._lastSavedRunId := ""
        this._undoTimerFn := ""
        try SpeedKalandraTrayRemoveUndoItem()
    }

    ; ============================================================
    ; _OnResetPersonalBestsRequested (v17.13)
    ;
    ; Subscrito a Commands.ResetPersonalBestsRequested (tray menu).
    ; Mostra MsgBox de confirmacao (acao destrutiva) e chama Reset() no
    ; PersonalBestService. Em headless mode, reseta direto sem prompt.
    ; ============================================================
    _OnResetPersonalBestsRequested()
    {
        if !IsObject(this.personalBest)
            return

        if this._headless
        {
            this.personalBest.Reset()
            return
        }

        ; Mostra contexto do que vai ser perdido
        runPbStr := this.personalBest.HasRunPb()
                    ? SpeedKalandraApp._FormatMsForMsg(this.personalBest.GetRunPbMs())
                    : "—"
        zoneCount := 0
        try
        {
            for zk, zv in this.personalBest.GetAllZonePbs()
                zoneCount += 1
        }
        actPbCount := 0
        try
            actPbCount := this.personalBest.CountActPbs()

        result := ""
        try
        {
            result := MsgBox(
                "Reset all Personal Bests?`n`n"
                . "Full run PB: " runPbStr "`n"
                . "PBs per act: " actPbCount "`n"
                . "Zone PBs: " zoneCount "`n`n"
                . "This action erases all best times and cannot be undone.",
                "SpeedKalandra - Reset PBs",
                "YesNo IconQ Default2")
        }
        catch
            return

        if (result != "Yes")
            return

        this.personalBest.Reset()
        try this.log.Info("PBs resetados pelo usuario (run PB: " runPbStr
            ", " actPbCount " atos, " zoneCount " zonas)", "App")
        try TrayTip("SpeedKalandra", "Personal Bests reset.", "Mute")
    }

    ; Helper static pra formatar ms em MM:SS ou H:MM:SS (pra mensagens).
    static _FormatMsForMsg(ms)
    {
        if (ms < 0)
            ms := 0
        totalSec := Floor(ms / 1000)
        h := Floor(totalSec / 3600)
        m := Floor(Mod(totalSec, 3600) / 60)
        s := Mod(totalSec, 60)
        if (h > 0)
            return Format("{:d}:{:02d}:{:02d}", h, m, s)
        return Format("{:02d}:{:02d}", m, s)
    }

    _PersistRunData()
    {
        try this.runService.PersistTick()

        ; v17.15 (Bug #8): catch explicito — ARCHITECTURE.md proibe
        ; try silencioso. _PersistRunData roda a cada 5s; se algo
        ; falhar (disco cheio, INI corrompido), precisamos saber.
        try
        {
            if IsObject(this.loadingTotals)
               && IsObject(this.runService)
               && this.runService.IsActive()
            {
                ltms := this.loadingTotals.GetTotalMs()
                if (ltms != this._lastSavedLoadingTotal)
                {
                    this.runState.SaveLoadingTotal(ltms)
                    this._lastSavedLoadingTotal := ltms
                }
            }
        }
        catch as ex
        {
            try this.log.Warn("Falha ao persistir loading total: " . ex.Message, "App")
        }

        try
        {
            if IsObject(this.zoneTracker) && this.zoneTracker.IsRunActive()
            {
                snapshot := this.zoneTracker.GetTotals()
                hash := this._ComputeTotalsHash(snapshot)
                if (hash != this._lastSavedZoneTotalsHash)
                {
                    this.runState.SaveZoneTotals(snapshot)
                    this._lastSavedZoneTotalsHash := hash
                }
            }
        }
        catch as ex
        {
            try this.log.Warn("Falha ao persistir zone totals: " . ex.Message, "App")
        }
    }

    _PersistRunDataFull()
    {
        try this.runService.PersistTick()

        ; v17.15 (Bug #8): catch explicito (mesma motivacao do _PersistRunData).
        ; _PersistRunDataFull eh chamado em Stop()/OnExit — ultima chance
        ; de salvar antes de fechar. Falhar silenciosamente significa perda
        ; de dados sem feedback.
        try
        {
            if IsObject(this.loadingTotals)
               && IsObject(this.runService)
               && this.runService.IsActive()
            {
                ltms := this.loadingTotals.GetTotalMs()
                this.runState.SaveLoadingTotal(ltms)
                this._lastSavedLoadingTotal := ltms
            }
        }
        catch as ex
        {
            try this.log.Warn("Falha ao persistir loading total (Full): " . ex.Message, "App")
        }

        try
        {
            if IsObject(this.zoneTracker) && this.zoneTracker.IsRunActive()
            {
                snapshot := this.zoneTracker.GetTotalsForSnapshot()
                this.runState.SaveZoneTotals(snapshot)
                this._lastSavedZoneTotalsHash := this._ComputeTotalsHash(snapshot)
            }
        }
        catch as ex
        {
            try this.log.Warn("Falha ao persistir zone totals (Full): " . ex.Message, "App")
        }
    }

    _ComputeTotalsHash(totalsMap)
    {
        if !IsObject(totalsMap)
            return ""
        parts := ""
        for k, v in totalsMap
            parts .= k "=" v "|"
        return parts
    }

    _GetWidgetPos(widgetId, defaultLeftPct, defaultTopPct)
    {
        if !IsObject(this._cfg.overlay)
            this._cfg.overlay := OverlayLayout.Defaults()

        existing := this._cfg.overlay.GetPosition(widgetId)
        if (existing != "")
            return existing

        pos := OverlayPosition.FromMap(Map(
            "left",     defaultLeftPct,
            "top",      defaultTopPct,
            "scale",    1.0,
            "visible",  true,
            "centered", false
        ))
        this._cfg.overlay.SetPosition(widgetId, pos)
        return pos
    }

    _PersistSettings()
    {
        try this._settingsRepo.Save(this._cfg)
    }

    _DeduceCurrentAct()
    {
        if !IsObject(this.zoneTracker)
            return 0
        zone := this.zoneTracker.GetActiveZone()
        if (zone = "" || !IsObject(this.zonesCatalog))
            return 0
        return this.zonesCatalog.GetActOfName(zone)
    }
}
