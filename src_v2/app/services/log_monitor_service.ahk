; ============================================================
; LogMonitorService — tail loop em Client.txt + parsing + eventos brutos
; ============================================================
;
; Responsabilidade:
;   - Manter posicao no arquivo Client.txt (tail loop)
;   - Detectar/parsear linhas conhecidas do log do Path of Exile 2
;   - Publicar EVENTOS BRUTOS no EventBus
;
; FILOSOFIA:
; Service "burro" e focado em I/O. Nao toma decisoes. Quem decide
; o que fazer (ex: tocar timer.Pause em Lost Focus, sync zone -> step)
; eh:
;   - O App composition root (Fase 5) liga eventos a comandos de outros
;     services. Ex: bus.Subscribe(WindowFocusChanged, (data) =>
;       data["state"] = "lost" ? timerService.Pause() : timerService.Resume())
;   - O SyncEngine (Fase 5) tem logica de sync de rota (FindBestMatchingStep)
;
; Linhas reconhecidas:
;   1. "X (Class) is now level N"             -> Evt.CharacterLevelUp
;   2. "Generating level N area X with seed"  -> Evt.AreaLevelChanged
;   3. "[SCENE] Set Source [name]"            -> Evt.SceneEntered
;   4. "You have entered ..."                 -> Evt.ZoneChanged
;   5. "X has been slain."                    -> Evt.DeathDetected
;   6. "[WINDOW] Lost focus" / "Gained focus" -> Evt.WindowFocusChanged
;
; OUT OF SCOPE (Fase 5 SyncEngine):
;   - Step.completionRegex/engageRegex/bossStartRegex matching
;     (esses sao logica de sync, nao log raw)
;   - Boss fight timing
;   - Auto-start na fala do Wounded Man (App composition root via
;     subscribe a NpcDialogue ou similar)
;
; Construcao:
;   monitor := LogMonitorService(clock, bus, log)
;   monitor.Configure(logFilePath)
;   monitor.Start(seedFromTail := true)
;   ; depois, periodicamente:
;   SetTimer(() => monitor.Tick(), 250)
;
; Para testes: pode chamar monitor.ProcessText(text) diretamente sem I/O.


class LogMonitorService
{
    _clock        := ""
    _bus          := ""
    _log          := ""
    _logFilePath  := ""
    _lastPos      := 0
    _partialLine  := ""
    _isRunning    := false
    _lastReadMs   := 0
    _characterName := ""   ; v17.15 (Bug #2): filtro pra DeathDetected

    ; Tamanho do tail varrido em Start(seedFromTail=true)
    static SEED_BYTES := 65536

    __New(clock, bus, logService)
    {
        if !(IsObject(clock) && clock.HasMethod("NowMs"))
            throw TypeError("LogMonitorService: 'clock' deve ter metodo NowMs()")
        if !(bus is EventBus)
            throw TypeError("LogMonitorService: 'bus' deve ser EventBus")
        if !(IsObject(logService) && logService.HasMethod("Info"))
            throw TypeError("LogMonitorService: 'logService' deve ter metodos Info/Warn/Error")
        this._clock := clock
        this._bus   := bus
        this._log   := logService
    }

    ; Define o caminho do Client.txt. Pode ser chamado antes ou depois
    ; de Start (Start re-le o path).
    Configure(logFilePathStr)
    {
        this._logFilePath := logFilePathStr
    }

    ; ============================================================
    ; SetCharacterName (v17.15 - Bug #2)
    ;
    ; Define o nome do player atual. Usado pra filtrar DeathDetected:
    ; PoE2 loga "<Name> has been slain." tanto pra player quanto pra
    ; bosses, então sem este filtro o deathCount inflava com kills.
    ;
    ; Chamado pelo composition root:
    ;   - No boot, apos instanciar logMonitor, com cfg.characterName.
    ;   - Em CharacterLevelUp, com o name vindo do evento.
    ;
    ; Empty string = filtro desativado (nenhuma death é publicada).
    ; ============================================================
    SetCharacterName(name)
    {
        this._characterName := String(name)
    }

    GetCharacterName() => this._characterName

    ; Start(seedFromTail := false)
    ;   Posiciona o cursor no fim do arquivo. Se seedFromTail eh true,
    ;   varre os ultimos SEED_BYTES bytes e publica os eventos mais
    ;   recentes (ultimo char level, ultima area level, ultima scene).
    ;   Util para sincronizar state quando o app inicia no meio de uma run.
    ;
    ;   Retorna true se conseguiu, false se arquivo nao existe ou nao abriu.
    Start(seedFromTail := false)
    {
        if (this._logFilePath = "")
        {
            this._log.Warn("Log file path nao configurado", "LogMonitor")
            return false
        }
        if !FileExist(this._logFilePath)
        {
            this._log.Warn("Log file nao encontrado: " this._logFilePath, "LogMonitor")
            return false
        }
        try
        {
            file := FileOpen(this._logFilePath, "r", "UTF-8")
        }
        catch Error as e
        {
            this._log.Error("Falha ao abrir log: " e.Message, "LogMonitor")
            return false
        }
        if !IsObject(file)
        {
            this._log.Error("FileOpen retornou nao-objeto", "LogMonitor")
            return false
        }
        size := file.Length

        if seedFromTail
        {
            seedSize := LogMonitorService.SEED_BYTES
            file.Pos := size > seedSize ? size - seedSize : 0
            seedText := file.Read()
            this._SeedFromText(seedText)
        }

        this._lastPos     := size
        file.Close()
        this._isRunning   := true
        this._lastReadMs  := this._clock.NowMs()
        this._partialLine := ""
        return true
    }

    Stop()
    {
        this._isRunning := false
    }

    IsRunning() => this._isRunning

    GetLastReadMs() => this._lastReadMs

    ; Tick — chamado periodicamente (ex: SetTimer). Le novo conteudo do
    ; arquivo a partir de _lastPos e processa linha por linha.
    ;
    ; No-op se nao esta running ou se nao ha conteudo novo.
    ; Detecta truncate (size < lastPos) e reseta posicao para 0.
    Tick()
    {
        if !this._isRunning
            return
        if (this._logFilePath = "")
            return
        if !FileExist(this._logFilePath)
            return

        try
        {
            file := FileOpen(this._logFilePath, "r", "UTF-8")
        }
        catch
        {
            return
        }
        if !IsObject(file)
            return

        size := file.Length
        ; File rotacionado/truncado
        if (size < this._lastPos)
            this._lastPos := 0
        if (size = this._lastPos)
        {
            file.Close()
            return
        }

        file.Pos := this._lastPos
        text := file.Read()
        this._lastPos := file.Pos
        file.Close()

        this._lastReadMs := this._clock.NowMs()
        if (text != "")
            this._ProcessChunk(text)
    }

    ; ProcessText(text) — interface publica para testes.
    ; Permite simular um chunk do log sem I/O real.
    ProcessText(text)
    {
        this._ProcessChunk(text)
    }

    ; ============================================================
    ; Processamento (privados)
    ; ============================================================

    ; Quebra um chunk em linhas, lidando com linhas parciais entre chunks.
    _ProcessChunk(textStr)
    {
        chunk := this._partialLine . textStr
        chunk := StrReplace(chunk, "`r`n", "`n")
        chunk := StrReplace(chunk, "`r", "`n")
        if (chunk = "")
            return
        endsWithNewline := SubStr(chunk, StrLen(chunk), 1) = "`n"
        lines := StrSplit(chunk, "`n")
        if !endsWithNewline
            this._partialLine := lines.Pop()
        else
            this._partialLine := ""
        for _, lineStr in lines
            this._ProcessLine(Trim(lineStr))
    }

    ; Tenta extrair informacao de uma linha. Cada extractor eh tentado
    ; em ordem; o primeiro que matchar publica o evento e retorna.
    ;
    ; Tambem publica Evt.LogLineRead com a linha bruta SEMPRE (mesmo
    ; se algum extractor matchou). Esse evento eh consumido por
    ; parsers especializados (BossFightTracker da Fase 5.3, etc).
    _ProcessLine(lineStr)
    {
        if (lineStr = "")
            return

        ; Broadcast da linha bruta antes de qualquer parsing especifico.
        ; Subscribers (ex: BossFightTracker) decidem se a linha interessa.
        this._bus.Publish(Events.LogLineRead, Map("line", lineStr))

        ; Character level up
        if this._ExtractCharacterLevelUp(lineStr, &charName, &charClass, &charLevel)
        {
            this._bus.Publish(Events.CharacterLevelUp, Map(
                "character", charName,
                "class",     charClass,
                "level",     charLevel
            ))
            return
        }

        ; Area level
        if this._ExtractAreaLevel(lineStr, &areaLevel, &areaCode)
        {
            this._bus.Publish(Events.AreaLevelChanged, Map(
                "areaLevel", areaLevel,
                "areaCode",  areaCode
            ))
            return
        }

        ; Scene
        scene := this._ExtractScene(lineStr)
        if (scene != "")
        {
            this._bus.Publish(Events.SceneEntered, Map(
                "sceneId", scene
            ))
            ; v17.15 (Bug #21): publica ZoneChanged tambem pra cada SCENE.
            ; PoE2 atual nao emite mais "You have entered" em todas as
            ; transicoes de zona — apenas "[SCENE] Set Source". Republicar
            ; como ZoneChanged garante que ZoneTrackingService e widgets de
            ; status recebam a mudanca.
            this._bus.Publish(Events.ZoneChanged, Map(
                "zoneName", scene,
                "sceneId",  scene
            ))
            ; v17.15 (Bug #21): log de Scene/Zone published movido de
            ; INFO pra DEBUG. Numa campanha completa o jogador entra em
            ; 100+ zonas — em INFO virava spam no log file.
            this._log.Debug("Scene/Zone published: " scene, "LogMonitor")
            return
        }

        ; Zone entered
        zone := this._ExtractZoneEntered(lineStr)
        if (zone != "")
        {
            this._bus.Publish(Events.ZoneChanged, Map(
                "zoneName", zone,
                "sceneId",  ""
            ))
            return
        }

        ; Death (PLAYER ONLY desde v17.15 - Bug #2)
        ;
        ; PoE2 loga "<Name> has been slain." pra player E pra bosses
        ; (vide boss_catalog.ini com defeat_regex). Sem filtro, cada
        ; boss kill inflava o deathCount da run. Filtra pelo nome do
        ; personagem atual (hidratado de cfg + atualizado em
        ; CharacterLevelUp).
        death := this._ExtractDeath(lineStr)
        if (death != "")
        {
            if (this._characterName != "" && death = this._characterName)
            {
                this._bus.Publish(Events.DeathDetected, Map(
                    "character", death
                ))
            }
            ; Se nao bate com o player, eh kill de boss/monstro —
            ; ignora silenciosamente (caso comum no log).
            return
        }

        ; Window focus
        focusState := this._ExtractFocus(lineStr)
        if (focusState != "")
        {
            this._bus.Publish(Events.WindowFocusChanged, Map(
                "state", focusState
            ))
            return
        }

        ; Linha desconhecida — silencio (nao log, evita poluicao)
    }

    ; Seed: varre texto inicial (tail do log no boot) e publica APENAS
    ; o ultimo evento de cada tipo encontrado. Razao: o objetivo do seed
    ; eh sincronizar state, nao reprocessar historia.
    _SeedFromText(textStr)
    {
        lastCharName  := ""
        lastCharClass := ""
        lastCharLevel := 0
        lastAreaLevel := 0
        lastAreaCode  := ""
        lastScene     := ""

        Loop Parse, textStr, "`n", "`r"
        {
            lineStr := A_LoopField
            if this._ExtractCharacterLevelUp(lineStr, &n, &c, &l)
            {
                lastCharName  := n
                lastCharClass := c
                lastCharLevel := l
            }
            if this._ExtractAreaLevel(lineStr, &al, &ac)
            {
                lastAreaLevel := al
                lastAreaCode  := ac
            }
            scene := this._ExtractScene(lineStr)
            if (scene != "")
                lastScene := scene
        }

        if (lastCharLevel > 0)
            this._bus.Publish(Events.CharacterLevelUp, Map(
                "character", lastCharName,
                "class",     lastCharClass,
                "level",     lastCharLevel
            ))
        if (lastAreaLevel > 0)
            this._bus.Publish(Events.AreaLevelChanged, Map(
                "areaLevel", lastAreaLevel,
                "areaCode",  lastAreaCode
            ))
        if (lastScene != "")
        {
            this._bus.Publish(Events.SceneEntered, Map(
                "sceneId", lastScene
            ))
            ; v17.15 (Bug #20): mesma republicacao de ZoneChanged tambem no
            ; seed inicial — essencial pra ZoneTrackingService comecar com
            ; zona correta apos boot no meio de uma run.
            this._bus.Publish(Events.ZoneChanged, Map(
                "zoneName", lastScene,
                "sceneId",  lastScene
            ))
        }
    }

    ; ============================================================
    ; Extractors — funcoes puras de regex
    ; ============================================================

    ; Padrao: ":<NAME> (<CLASS>) is now level <N>"
    ; Ex: ": Harvest (Warrior) is now level 42"
    _ExtractCharacterLevelUp(lineStr, &charName, &charClass, &charLevel)
    {
        charName  := ""
        charClass := ""
        charLevel := 0
        if RegExMatch(lineStr, "i):\s+(.+?)\s+\((.+?)\)\s+is now level\s+(\d+)", &m)
        {
            charName  := Trim(m[1])
            charClass := Trim(m[2])
            charLevel := Integer(m[3] + 0)
            return charLevel > 0
        }
        return false
    }

    ; Padrao: "Generating level <N> area <CODE> with seed <S>"
    _ExtractAreaLevel(lineStr, &areaLevel, &areaCode)
    {
        areaLevel := 0
        areaCode  := ""
        if RegExMatch(lineStr, "i)Generating\s+level\s+(\d+)\s+area\s+(.+?)\s+with\s+seed", &m)
        {
            areaLevel := Integer(m[1] + 0)
            areaCode  := Trim(m[2], A_Space Chr(34))
            return areaLevel > 0
        }
        return false
    }

    ; Padrao: "[SCENE] Set Source [<sceneName>]"
    ; Filtra:
    ;   - "(null)" / "(unknown)" : char select / loading
    ;   - "Act N"                : marker de transicao entre atos,
    ;                              eh cinematica/title card. Nao eh
    ;                              zona real (jogador nao esta jogando
    ;                              em "Act 1", esta em G1_town/etc.)
    ;                              Eh emitido junto com transicoes
    ;                              cross-act e poluiria sync engine se
    ;                              tratasse como ZoneChanged.
    _ExtractScene(lineStr)
    {
        if RegExMatch(lineStr, "\[SCENE\]\s+Set Source \[(.*?)\]", &m)
        {
            name := Trim(m[1])
            if (name = "" || name = "(null)" || name = "(unknown)")
                return ""
            ; Markers de transicao entre atos: "Act 1", "Act 2", ..., "Act 6".
            ; Tambem variantes case-insensitive como "act 1".
            if RegExMatch(name, "i)^Act\s+\d+$")
                return ""
            return name
        }
        return ""
    }

    ; Padrao: "You have entered <ZONE>."
    _ExtractZoneEntered(lineStr)
    {
        if RegExMatch(lineStr, "i)You have entered\s+(.+?)[\.]?$", &m)
            return Trim(m[1], " .")
        return ""
    }

    ; Padroes:
    ;   ":<NAME> has been slain."   (jogador, com prefixo de timestamp)
    ;   "<NAME> has been slain."    (incluindo monstros, sem prefixo)
    _ExtractDeath(lineStr)
    {
        if RegExMatch(lineStr, "i):\s+(.+?)\s+has been slain\.", &m)
            return Trim(m[1])
        if RegExMatch(lineStr, "i)^(.+?)\s+has been slain\.", &m2)
            return Trim(m2[1])
        return ""
    }

    ; Padrao: "[WINDOW] Lost focus" / "[WINDOW] Gained focus"
    _ExtractFocus(lineStr)
    {
        if RegExMatch(lineStr, "i)\[WINDOW\]\s+Lost focus")
            return "lost"
        if RegExMatch(lineStr, "i)\[WINDOW\]\s+Gained focus")
            return "gained"
        return ""
    }
}
