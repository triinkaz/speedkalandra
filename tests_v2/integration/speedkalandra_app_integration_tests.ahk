; ============================================================
; SpeedKalandraAppIntegrationTests
; ============================================================
;
; Wave 8: integration test do composition root (SpeedKalandraApp).
;
; Estrategia:
;   - headless=true: pula disclaimer, prompts, TrayTip
;   - clock injetado (FakeClock) pra controlar tempo de runs
;   - NAO chama app.Start(): isso renderiza widgets (Gui real).
;     Em vez disso, exercita o bus diretamente publicando Commands
;     (NewRunRequested, FinalizeRunRequested) que sao consumidos
;     pelo RunService via subscribers registrados no construtor.
;   - Setup cria diretorio temp com zones.csv minimal, ini vazio,
;     runHistory dir, personal_bests.ini vazio.
;
; Cobertura:
;   - Construtor inicializa todos os services principais
;   - NewRunRequested -> runService.NewRun -> RunState persistido
;   - FinalizeRunRequested em run curta (<3min) -> NAO salva no historico
;   - FinalizeRunRequested em run longa (>=3min) -> salva
;   - PB atualizado em run completed
;   - Crash recovery: segunda instancia hidrata state da primeira


class SpeedKalandraAppIntegrationTests extends TestCase
{
    tmpDir        := ""
    iniPath       := ""
    zonesCsvPath  := ""
    logPath       := ""
    runHistoryDir := ""
    pbPath        := ""
    stubClock     := ""
    app           := ""

    Setup()
    {
        this.tmpDir        := Fixtures.TempDir()
        this.iniPath       := this.tmpDir "\settings.ini"
        this.zonesCsvPath  := this.tmpDir "\zones.csv"
        this.logPath       := this.tmpDir "\app.log"
        this.runHistoryDir := this.tmpDir "\runs"
        this.pbPath        := this.tmpDir "\pb.ini"

        ; Cria zones.csv minimal valido (formato real do projeto)
        FileAppend(
            "name;internal_id;act;is_town`n"
            . "Clearfell Encampment;G1_town;1;1`n"
            . "The Riverbank;G1_1;1;0`n"
            . "Mud Burrow;G1_3;1;0`n"
            . "The Karui Shores;G3_town;3;1`n",
            this.zonesCsvPath, "UTF-8")
        Fixtures.RegisterTempPath(this.zonesCsvPath)
        Fixtures.RegisterTempPath(this.iniPath)
        Fixtures.RegisterTempPath(this.logPath)
        Fixtures.RegisterTempPath(this.pbPath)

        ; Cria dir runs (RunHistoryRepository nao cria automaticamente)
        try DirCreate(this.runHistoryDir)
        Fixtures.RegisterTempPath(this.runHistoryDir)

        ; FakeClock com base 1000000ms (arbitrario, longe de 0)
        this.stubClock := Fixtures.MakeFakeClock(1000000)

        this.app := SpeedKalandraApp(Map(
            "iniPath",          this.iniPath,
            "zonesCsvPath",     this.zonesCsvPath,
            "logPath",          this.logPath,
            "runHistoryDir",    this.runHistoryDir,
            "personalBestPath", this.pbPath,
            "headless",         true,
            "clock",            this.stubClock
        ))
    }

    Teardown()
    {
        if IsObject(this.app)
        {
            try this.app.Stop()
        }
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Construtor / componentes ---
        "constructor_creates_all_main_components",
        "constructor_subscribes_run_history_handlers",
        "constructor_loads_zones_catalog",
        "constructor_does_not_throw_with_empty_ini",
        "constructor_no_run_active_initially",

        ; --- Run lifecycle via bus ---
        "new_run_via_command_starts_run",
        "new_run_persists_to_ini",
        "new_run_starts_timer",
        "cancel_run_via_command_stops_run",

        ; --- Finalize: threshold de 3min ---
        "short_run_finalize_does_not_save_to_history",
        "long_run_finalize_saves_to_history",
        "long_run_finalize_updates_personal_best",
        "very_short_run_does_not_update_pb",

        ; --- Crash recovery ---
        "second_app_instance_hydrates_active_run_from_disk",
        "second_instance_resumes_timer_with_correct_base_ms",

        ; --- Stop ---
        "stop_does_not_throw_when_never_started",
        "stop_is_idempotent",

        ; --- Wave 9: regression tests bugs catalogaÝos sem cobertura direta ---
        ; Bug #9 (AUDITORIA): Riverbank reseta level a cada entry. Fix:
        ; nome exato "The Riverbank" + flag _riverbankSeenInRun que
        ; reseta em RunStarted/RunReset/RunCancelled.
        "bug9_first_riverbank_entry_resets_level_to_1",
        "bug9_second_riverbank_entry_does_not_reset_level",
        "bug9_non_exact_match_does_not_trigger_reset",
        "bug9_new_run_clears_riverbank_flag",
        "bug9_run_reset_clears_riverbank_flag",

        ; --- v0.1.3: Death penalty no timer real-time ---
        ; Handler _OnDeathApplyTimerPenalty subscrito a Evt.DeathDetected.
        ; Verifica cfg.deathPenaltyEnabled + timer.IsActive() antes de
        ; chamar timer.AddPenaltyMs. Cobre os 4 caminhos do guard.
        "death_penalty_applies_to_timer_when_enabled_and_run_active",
        "death_penalty_does_not_apply_when_disabled",
        "death_penalty_does_not_apply_when_no_run_active",
        "death_penalty_accumulates_with_multiple_deaths",
        "death_penalty_uses_configured_ms_value",
        "death_penalty_does_not_apply_when_configured_ms_is_zero"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _ListRunFiles()
    {
        files := []
        Loop Files, this.runHistoryDir "\*.ini"
            files.Push(A_LoopFileName)
        return files
    }

    ; Simula tempo em uma zona pra que ZoneTrackingService.GetTotalsForSnapshot
    ; retorne totals nao-vazio. RunHistoryRepository.Save rejeita buildResult
    ; com totalMs<1000ms (filtro de "lixo de teste"), e o builder calcula
    ; totalMs como soma das categorias do totals — sem zona ativa nem
    ; loading, totals fica vazio e Save retorna false silenciosamente.
    _EnterZoneAndAdvance(zoneName, advanceMs)
    {
        this.app.bus.Publish(Events.ZoneChanged, Map(
            "zoneName", zoneName,
            "ts",       FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
        ))
        this.stubClock.AdvanceMs(advanceMs)
    }

    ; ============================================================
    ; Construtor / componentes
    ; ============================================================

    constructor_creates_all_main_components()
    {
        Assert.True(this.app.bus is EventBus, "bus existe")
        Assert.True(this.app.clock = this.stubClock, "clock injetado preservado")
        Assert.True(this.app.timer is TimerService)
        Assert.True(this.app.runService is RunService)
        Assert.True(this.app.runState is RunStateRepository)
        Assert.True(this.app.zoneTracker is ZoneTrackingService)
        Assert.True(this.app.zonesCatalog is ZonesCatalog)
        Assert.True(this.app.personalBest is PersonalBestService)
        Assert.True(this.app.runHistory is RunHistoryRepository)
        Assert.True(this.app.statsRecorder is RunStatsRecorder)
        Assert.True(this.app.overlayMode is OverlayModeService)
        Assert.True(this.app.hotkeyService is HotkeyService)
    }

    constructor_subscribes_run_history_handlers()
    {
        ; RunCompleted e RunCancelled tem handlers de _SaveRunSnapshot,
        ; alem dos handlers que widgets/services inscrevem.
        ; Verifica que pelo menos 1 subscriber existe.
        Assert.True(this.app.bus.Subscribers(Events.RunCompleted) >= 1)
        Assert.True(this.app.bus.Subscribers(Events.RunCancelled) >= 1)
    }

    constructor_loads_zones_catalog()
    {
        ; Setup criou zones.csv com 5 linhas (4 zonas + header). Catalog
        ; deve ter 4 entradas.
        Assert.Equal(4, this.app.zonesCatalog.Count())
    }

    constructor_does_not_throw_with_empty_ini()
    {
        ; Setup nao cria settings.ini explicitamente — o app deve aceitar
        ; arquivo inexistente e usar defaults.
        Assert.True(IsObject(this.app))
    }

    constructor_no_run_active_initially()
    {
        Assert.False(this.app.runService.IsActive())
    }

    ; ============================================================
    ; Run lifecycle via bus
    ; ============================================================

    new_run_via_command_starts_run()
    {
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        Assert.True(this.app.runService.IsActive())
        Assert.Equal("running", this.app.runService.GetStatus())
    }

    new_run_persists_to_ini()
    {
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        producedId := this.app.runService.GetRunId()
        Assert.True(StrLen(producedId) > 0, "RunId gerado")

        ; Verifica persistencia: instancia nova de RunStateRepository
        ; sobre o mesmo INI le o state salvo
        ini := IniFile(this.iniPath)
        repo := RunStateRepository(ini)
        loaded := repo.Load()
        Assert.Equal(producedId, loaded.runId)
        Assert.Equal("running", loaded.status)
    }

    new_run_starts_timer()
    {
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        Assert.True(this.app.timer.IsRunning())
    }

    cancel_run_via_command_stops_run()
    {
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.app.bus.Publish(Commands.CancelRunRequested, Map())
        Assert.False(this.app.runService.IsActive())
        Assert.Equal("cancelled", this.app.runService.GetStatus())
    }

    ; ============================================================
    ; Finalize: threshold de 3min
    ; ============================================================

    short_run_finalize_does_not_save_to_history()
    {
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        ; Avanca clock 30s (muito menos que 3min threshold)
        this.stubClock.AdvanceMs(30000)
        this.app.bus.Publish(Commands.FinalizeRunRequested, Map())

        files := this._ListRunFiles()
        Assert.Equal(0, files.Length,
            "Run < 3min nao deve ser salva no historico")
    }

    long_run_finalize_saves_to_history()
    {
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        ; Helper: simula zona ativa por 5min pra que totals tenha tempo
        ; (sem isso, buildResult.totalMs=0 e Save rejeita).
        this._EnterZoneAndAdvance("The Riverbank", 300000)
        producedId := this.app.runService.GetRunId()
        this.app.bus.Publish(Commands.FinalizeRunRequested, Map())

        files := this._ListRunFiles()
        Assert.Equal(1, files.Length, "Run >= 3min salva no historico")
        ; Filename eh "{runId}.ini"
        Assert.Equal(producedId ".ini", files[1])
    }

    long_run_finalize_updates_personal_best()
    {
        ; Sem PB inicial
        Assert.False(this.app.personalBest.HasRunPb())

        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(300000)   ; 5min
        producedId := this.app.runService.GetRunId()
        this.app.bus.Publish(Commands.FinalizeRunRequested, Map())

        Assert.True(this.app.personalBest.HasRunPb(),
            "PB atualizado apos finalize de run >= 3min")
        Assert.Equal(producedId, this.app.personalBest.GetRunPbRunId())
        Assert.Equal(300000, this.app.personalBest.GetRunPbMs())
    }

    very_short_run_does_not_update_pb()
    {
        Assert.False(this.app.personalBest.HasRunPb())
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(30000)   ; 30s < 3min threshold
        this.app.bus.Publish(Commands.FinalizeRunRequested, Map())
        Assert.False(this.app.personalBest.HasRunPb(),
            "Run < 3min nao atualiza PB")
    }

    ; ============================================================
    ; Crash recovery
    ; ============================================================

    second_app_instance_hydrates_active_run_from_disk()
    {
        ; Primeira instancia: cria run e persiste
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        firstRunId := this.app.runService.GetRunId()
        this.stubClock.AdvanceMs(60000)   ; 1min na run
        ; Forca persistencia do timer (normalmente seria via SetTimer)
        this.app.runService.PersistTick()

        ; "Crash": destroi primeira instancia
        try this.app.Stop()
        this.app := ""

        ; Segunda instancia: deve hidratar a run ativa do INI
        secondClock := Fixtures.MakeFakeClock(2000000)
        app2 := SpeedKalandraApp(Map(
            "iniPath",          this.iniPath,
            "zonesCsvPath",     this.zonesCsvPath,
            "logPath",          this.logPath,
            "runHistoryDir",    this.runHistoryDir,
            "personalBestPath", this.pbPath,
            "headless",         true,
            "clock",            secondClock
        ))

        Assert.True(app2.runService.IsActive(),
            "Run ativa hidratada do INI")
        Assert.Equal(firstRunId, app2.runService.GetRunId(),
            "Mesmo runId preservado")

        try app2.Stop()
    }

    second_instance_resumes_timer_with_correct_base_ms()
    {
        ; Primeira: 1min na run
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(60000)
        this.app.runService.PersistTick()

        try this.app.Stop()
        this.app := ""

        ; Segunda: timer deve continuar com base = 60000ms
        secondClock := Fixtures.MakeFakeClock(2000000)
        app2 := SpeedKalandraApp(Map(
            "iniPath",          this.iniPath,
            "zonesCsvPath",     this.zonesCsvPath,
            "logPath",          this.logPath,
            "runHistoryDir",    this.runHistoryDir,
            "personalBestPath", this.pbPath,
            "headless",         true,
            "clock",            secondClock
        ))

        ; Timer hidratado em running com 60s ja contados.
        ; Avancar 30s deve resultar em 90s total.
        secondClock.AdvanceMs(30000)
        Assert.Equal(90000, app2.timer.GetRunMs())

        try app2.Stop()
    }

    ; ============================================================
    ; Stop
    ; ============================================================

    stop_does_not_throw_when_never_started()
    {
        ; Setup nao chamou Start; Stop deve ser no-op silencioso
        this.app.Stop()
        Assert.True(true)
    }

    stop_is_idempotent()
    {
        this.app.Stop()
        this.app.Stop()
        Assert.True(true)
    }

    ; ============================================================
    ; Wave 9 — Regression: Bug #9 (Riverbank single-reset)
    ; ============================================================
    ;
    ; AUDITORIA #9: "Riverbank reseta level a cada entry".
    ;
    ; Comportamento PRE-fix:
    ;   InStr(zone, "Riverbank") + reset incondicional.
    ;   Problema 1: substring match (qualquer zona com "Riverbank" no
    ;               nome casava).
    ;   Problema 2: re-entrada (death respawn, portal, party invite)
    ;               resetava level cacheado pra 1, causando XP display
    ;               errado ate o proximo CharacterLevelUp.
    ;
    ; Fix (v17.15):
    ;   Match exato "The Riverbank" + flag _riverbankSeenInRun. Flag
    ;   resetada em RunStarted (nova run libera novo reset) e em
    ;   RunReset/RunCancelled.
    ;
    ; Os testes chamam `_OnZoneEnteredForLevel` direto na instancia
    ; (handler eh subscribed em app.Start() que nao chamamos aqui).
    ; Isso cobre a logica de unica vez sem precisar do widget Show.

    bug9_first_riverbank_entry_resets_level_to_1()
    {
        ; Run ativa + level setado a 50
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.app.xpService.SetCharacter("Olaf", "Warrior", 50)
        Assert.Equal(50, this.app.xpService.GetCharacterLevel())

        ; Primeira entrada em "The Riverbank" deve resetar level pra 1
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank"))
        Assert.Equal(1, this.app.xpService.GetCharacterLevel(),
            "Bug #9: primeira entrada em The Riverbank reseta level pra 1")
    }

    bug9_second_riverbank_entry_does_not_reset_level()
    {
        ; Setup: run ativa, primeira entrada em Riverbank ja aconteceu
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.app.xpService.SetCharacter("Olaf", "Warrior", 50)
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank"))
        Assert.Equal(1, this.app.xpService.GetCharacterLevel())

        ; Simula progressao: jogador subiu pra level 5 desde a primeira
        ; entrada (e.g. via CharacterLevelUp event que setou o level)
        this.app.xpService.SetCharacter("Olaf", "Warrior", 5)
        Assert.Equal(5, this.app.xpService.GetCharacterLevel())

        ; Segunda entrada em Riverbank (death respawn / portal / invite):
        ; NAO deve resetar (Bug #9 fix)
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank"))
        Assert.Equal(5, this.app.xpService.GetCharacterLevel(),
            "Bug #9: re-entrada em Riverbank NAO reseta level (flag bloqueia)")
    }

    bug9_non_exact_match_does_not_trigger_reset()
    {
        ; Pre-fix, "InStr(zone, \"Riverbank\")" casaria qualquer substring.
        ; Fix usa match exato, entao zonas similares mas nao exatas nao
        ; resetam (defensivo contra mudancas hipoteticas de nome em PoE2).
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.app.xpService.SetCharacter("Olaf", "Warrior", 50)

        ; Zonas com "Riverbank" no nome mas nao exato
        this.app._OnZoneEnteredForLevel(Map("zoneName", "Riverbank"))           ; sem "The"
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank East"))  ; sufixo
        this.app._OnZoneEnteredForLevel(Map("zoneName", "Old Riverbank"))       ; prefixo

        Assert.Equal(50, this.app.xpService.GetCharacterLevel(),
            "Bug #9: match exato 'The Riverbank' — substrings nao casam")
    }

    bug9_new_run_clears_riverbank_flag()
    {
        ; Setup: run 1 com Riverbank ja visitado
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.app.xpService.SetCharacter("Olaf", "Warrior", 50)
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank"))
        ; Level resetado pra 1, _riverbankSeenInRun = true

        ; Set level pra 10 (simulando progressao na run)
        this.app.xpService.SetCharacter("Olaf", "Warrior", 10)

        ; Nova run: dispara RunStarted -> _OnRunStartedForXp limpa flag
        ; (handler eh subscribed em __New via _WireEventHandlers, ativo
        ; mesmo sem Start)
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        ; Set level de novo (NewRun zera area mas nao character level)
        this.app.xpService.SetCharacter("Olaf", "Warrior", 10)

        ; Primeira entrada em Riverbank na nova run: DEVE resetar
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank"))
        Assert.Equal(1, this.app.xpService.GetCharacterLevel(),
            "Bug #9: NewRun limpa flag, permitindo novo reset na nova run")
    }

    bug9_run_reset_clears_riverbank_flag()
    {
        ; Mesmo cenario do _new_run mas via Reset em vez de NewRun.
        ; _OnRunEndedClearZones esta subscribed em RunReset e RunCancelled.
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.app.xpService.SetCharacter("Olaf", "Warrior", 50)
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank"))

        this.app.xpService.SetCharacter("Olaf", "Warrior", 10)
        this.app.bus.Publish(Commands.ResetRunRequested, Map())

        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.app.xpService.SetCharacter("Olaf", "Warrior", 10)
        this.app._OnZoneEnteredForLevel(Map("zoneName", "The Riverbank"))
        Assert.Equal(1, this.app.xpService.GetCharacterLevel(),
            "Bug #9: Reset tambem limpa flag (via _OnRunEndedClearZones)")
    }

    ; ============================================================
    ; v0.1.3 — Death penalty no timer real-time
    ; ============================================================
    ;
    ; Antes de v0.1.3, death penalty (cfg.deathPenaltyMs) so aparecia
    ; no plot post-finalize (categoria "Deaths" em RunStatsPlotBuilder).
    ; O timer da run em tempo real ficava sem refletir a penalty,
    ; criando inconsistencia visual: usuario via 1:05:00 no overlay
    ; mas 1:07:30 no plot apos finalize.
    ;
    ; Fix: handler _OnDeathApplyTimerPenalty subscrito a Evt.DeathDetected.
    ; Quando dispara e cfg.deathPenaltyEnabled + timer.IsActive(),
    ; chama timer.AddPenaltyMs(cfg.deathPenaltyMs). Usuario ve o
    ; ponteiro saltar pra frente no overlay assim que morre.
    ;
    ; AppSettings defaults relevantes:
    ;   cfg.deathPenaltyEnabled = true
    ;   cfg.deathPenaltyMs      = 150000  (2min30s)
    ;
    ; Estes testes publicam Evt.DeathDetected direto no bus pra simular
    ; o evento que normalmente vem do LogMonitorService (ao parsear
    ; linha de morte no Client.txt).

    death_penalty_applies_to_timer_when_enabled_and_run_active()
    {
        ; Start run, advance 1min, dispara DeathDetected
        ; → timer deve pular pra 1min + 150s (default penalty) = 3min30s
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(60000)   ; 1min
        Assert.Equal(60000, this.app.timer.GetRunMs())

        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        ; 60000 (clock) + 150000 (default penalty) = 210000
        Assert.Equal(210000, this.app.timer.GetRunMs(),
            "Death penalty (150s) somada ao timer em tempo real")
    }

    death_penalty_does_not_apply_when_disabled()
    {
        ; cfg.deathPenaltyEnabled := false desabilita o handler.
        ; Publish DeathDetected e o timer nao deve mexer.
        this.app._cfg.deathPenaltyEnabled := false

        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(60000)
        before := this.app.timer.GetRunMs()

        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        Assert.Equal(before, this.app.timer.GetRunMs(),
            "Com flag off, DeathDetected nao move o timer")
    }

    death_penalty_does_not_apply_when_no_run_active()
    {
        ; Sem NewRun, timer.IsActive() = false. Handler retorna early.
        Assert.False(this.app.timer.IsActive())
        before := this.app.timer.GetRunMs()   ; 0

        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        Assert.Equal(before, this.app.timer.GetRunMs(),
            "Sem run ativa, DeathDetected eh ignorado")
        Assert.False(this.app.timer.IsActive(),
            "Timer continua IDLE apos morte fora de run")
    }

    death_penalty_accumulates_with_multiple_deaths()
    {
        ; 3 mortes na mesma run → timer ganha 3 * penalty
        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(60000)   ; 1min

        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))
        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))
        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        ; 60s + 3 * 150s = 60 + 450 = 510s
        Assert.Equal(510000, this.app.timer.GetRunMs(),
            "3 mortes acumulam 3 * 150s no timer")
    }

    death_penalty_uses_configured_ms_value()
    {
        ; cfg.deathPenaltyMs customizado (90s) deve ser respeitado.
        this.app._cfg.deathPenaltyMs := 90000

        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(60000)
        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        Assert.Equal(150000, this.app.timer.GetRunMs(),
            "60s + cfg.deathPenaltyMs (90s) = 150s")
    }

    death_penalty_does_not_apply_when_configured_ms_is_zero()
    {
        ; Edge case defensivo: se cfg.deathPenaltyMs = 0 (usuario
        ; configurou "sem penalty" explicitamente), handler retorna
        ; early sem mexer no timer. Cobre o ultimo guard do handler.
        this.app._cfg.deathPenaltyMs := 0

        this.app.bus.Publish(Commands.NewRunRequested, Map())
        this.stubClock.AdvanceMs(60000)
        before := this.app.timer.GetRunMs()

        this.app.bus.Publish(Events.DeathDetected, Map("character", "Olaf"))

        Assert.Equal(before, this.app.timer.GetRunMs(),
            "deathPenaltyMs=0 nao mexe no timer")
    }
}

TestRegistry.Register(SpeedKalandraAppIntegrationTests)
