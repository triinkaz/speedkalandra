; ============================================================
; LogMonitorService — tail loop on Client.txt + parsing + raw events
; ============================================================
;
; Responsibility:
;   - Maintain position in the Client.txt file (tail loop)
;   - Detect/parse known lines from the Path of Exile 2 log
;   - Publish RAW EVENTS to the EventBus
;
; PHILOSOPHY:
; "Dumb" service focused on I/O. Does not make decisions. Whoever
; decides what to do (e.g. trigger timer.Pause on Lost Focus, sync
; zone -> step) is:
;   - The App composition root (Phase 5) wires events to commands
;     of other services. E.g.: bus.Subscribe(WindowFocusChanged, (data) =>
;       data["state"] = "lost" ? timerService.Pause() : timerService.Resume())
;   - The SyncEngine (Phase 5) has route sync logic (FindBestMatchingStep)
;
; Recognized lines:
;   1. "X (Class) is now level N"             -> Evt.CharacterLevelUp
;   2. "Generating level N area X with seed"  -> Evt.AreaLevelChanged
;   3. "[SCENE] Set Source [name]"            -> Evt.SceneEntered
;   4. "You have entered ..."                 -> Evt.ZoneChanged
;   5. "X has been slain."                    -> Evt.DeathDetected
;   6. "[WINDOW] Lost focus" / "Gained focus" -> Evt.WindowFocusChanged
;
; OUT OF SCOPE (Phase 5 SyncEngine):
;   - Step.completionRegex/engageRegex/bossStartRegex matching
;     (those are sync logic, not raw log)
;   - Boss fight timing
;   - Auto-start on the Wounded Man line (App composition root via
;     subscribe to NpcDialogue or similar)
;
; Construction:
;   monitor := LogMonitorService(clock, bus, log)
;   monitor.Configure(logFilePath)
;   monitor.Start(seedFromTail := true)
;   ; then, periodically:
;   SetTimer(() => monitor.Tick(), 250)
;
; For tests: can call monitor.ProcessText(text) directly without I/O.


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
    _characterName := ""   ; v17.15 (Bug #2): filter for DeathDetected

    ; Tail size swept in Start(seedFromTail=true)
    static SEED_BYTES := 65536

    __New(clock, bus, logService)
    {
        if !(IsObject(clock) && clock.HasMethod("NowMs"))
            throw TypeError("LogMonitorService: 'clock' must have NowMs() method")
        if !(bus is EventBus)
            throw TypeError("LogMonitorService: 'bus' must be EventBus")
        if !(IsObject(logService) && logService.HasMethod("Info"))
            throw TypeError("LogMonitorService: 'logService' must have Info/Warn/Error methods")
        this._clock := clock
        this._bus   := bus
        this._log   := logService
    }

    ; Sets the path to Client.txt. May be called before or after Start
    ; (Start re-reads the path).
    Configure(logFilePathStr)
    {
        this._logFilePath := logFilePathStr
    }

    ; ============================================================
    ; SetCharacterName (v17.15 - Bug #2)
    ;
    ; Sets the current player's name. Used to filter DeathDetected:
    ; PoE2 logs "<Name> has been slain." both for the player and for
    ; bosses, so without this filter deathCount would inflate with kills.
    ;
    ; Called by the composition root:
    ;   - On boot, after instantiating logMonitor, with cfg.characterName.
    ;   - On CharacterLevelUp, with the name from the event.
    ;
    ; Empty string = filter disabled (no death is published).
    ; ============================================================
    SetCharacterName(name)
    {
        this._characterName := String(name)
    }

    GetCharacterName() => this._characterName

    ; Start(seedFromTail := false)
    ;   Positions the cursor at the end of the file. If seedFromTail
    ;   is true, scans the last SEED_BYTES bytes and publishes the
    ;   most recent events (last char level, last area level, last
    ;   scene). Useful for syncing state when the app starts in the
    ;   middle of a run.
    ;
    ;   Returns true on success, false if the file does not exist
    ;   or fails to open.
    Start(seedFromTail := false)
    {
        if (this._logFilePath = "")
        {
            this._log.Warn("Log file path not configured", "LogMonitor")
            return false
        }
        if !FileExist(this._logFilePath)
        {
            this._log.Warn("Log file not found: " this._logFilePath, "LogMonitor")
            return false
        }
        try
        {
            logFile := FileOpen(this._logFilePath, "r", "UTF-8")
        }
        catch Error as e
        {
            this._log.Error("Failed to open log: " e.Message, "LogMonitor")
            return false
        }
        if !IsObject(logFile)
        {
            this._log.Error("FileOpen returned non-object", "LogMonitor")
            return false
        }
        size := logFile.Length

        if seedFromTail
        {
            seedSize := LogMonitorService.SEED_BYTES
            logFile.Pos := size > seedSize ? size - seedSize : 0
            seedText := logFile.Read()
            this._SeedFromText(seedText)
        }

        this._lastPos     := size
        logFile.Close()
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

    ; Tick — called periodically (e.g. SetTimer). Reads new content
    ; from the file starting at _lastPos and processes line by line.
    ;
    ; No-op if not running or if no new content. Detects truncate
    ; (size < lastPos) and resets position to 0.
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
            logFile := FileOpen(this._logFilePath, "r", "UTF-8")
        }
        catch
        {
            return
        }
        if !IsObject(logFile)
            return

        size := logFile.Length
        ; File rotated/truncated
        if (size < this._lastPos)
            this._lastPos := 0
        if (size = this._lastPos)
        {
            logFile.Close()
            return
        }

        logFile.Pos := this._lastPos
        text := logFile.Read()
        this._lastPos := logFile.Pos
        logFile.Close()

        this._lastReadMs := this._clock.NowMs()
        if (text != "")
            this._ProcessChunk(text)
    }

    ; ProcessText(text) — public interface for tests.
    ; Allows simulating a log chunk without real I/O.
    ProcessText(text)
    {
        this._ProcessChunk(text)
    }

    ; ============================================================
    ; Processing (private)
    ; ============================================================

    ; Splits a chunk into lines, handling partial lines between chunks.
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

    ; Tries to extract information from a line. Each extractor is
    ; tried in order; the first one to match publishes the event and
    ; returns.
    ;
    ; Also publishes Evt.LogLineRead with the raw line ALWAYS (even
    ; if some extractor matched). This event is consumed by
    ; specialized parsers (BossFightTracker of Phase 5.3, etc.).
    _ProcessLine(lineStr)
    {
        if (lineStr = "")
            return

        ; Broadcast the raw line before any specific parsing.
        ; Subscribers (e.g. BossFightTracker) decide if the line matters.
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
            ; v17.15 (Bug #21): publishes ZoneChanged also for each SCENE.
            ; Current PoE2 no longer emits "You have entered" on all zone
            ; transitions — only "[SCENE] Set Source". Republishing as
            ; ZoneChanged ensures that ZoneTrackingService and status
            ; widgets receive the change.
            this._bus.Publish(Events.ZoneChanged, Map(
                "zoneName", scene,
                "sceneId",  scene
            ))
            ; v17.15 (Bug #21): Scene/Zone published log moved from
            ; INFO to DEBUG. In a full campaign the player enters
            ; 100+ zones — at INFO it became spam in the log file.
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

        ; Death (PLAYER ONLY since v17.15 - Bug #2)
        ;
        ; PoE2 logs "<Name> has been slain." for the player AND for
        ; bosses (see boss_catalog.ini with defeat_regex). Without a
        ; filter, each boss kill inflated the run's deathCount.
        ; Filters by the current character name (hydrated from cfg +
        ; updated on CharacterLevelUp).
        death := this._ExtractDeath(lineStr)
        if (death != "")
        {
            if (this._characterName != "" && death = this._characterName)
            {
                this._bus.Publish(Events.DeathDetected, Map(
                    "character", death
                ))
            }
            ; If it doesn't match the player, it's a boss/monster kill —
            ; silently ignore (common case in the log).
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

        ; Unknown line — silence (no log, avoids pollution)
    }

    ; Seed: scans initial text (log tail on boot) and publishes ONLY
    ; the last event of each type found. Reason: the goal of the seed
    ; is to sync state, not to reprocess history.
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
            ; v17.15 (Bug #20): same ZoneChanged republication also on
            ; the initial seed — essential for ZoneTrackingService to
            ; start with the correct zone after a boot in the middle
            ; of a run.
            this._bus.Publish(Events.ZoneChanged, Map(
                "zoneName", lastScene,
                "sceneId",  lastScene
            ))
        }
    }

    ; ============================================================
    ; Extractors — pure regex functions
    ; ============================================================

    ; Pattern: ":<NAME> (<CLASS>) is now level <N>"
    ; E.g.: ": Harvest (Warrior) is now level 42"
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

    ; Pattern: "Generating level <N> area <CODE> with seed <S>"
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

    ; Pattern: "[SCENE] Set Source [<sceneName>]"
    ; Filters out:
    ;   - "(null)" / "(unknown)" : char select / loading
    ;   - "Act N"                : transition marker between acts,
    ;                              this is cinematic/title card. Not
    ;                              a real zone (the player isn't
    ;                              playing in "Act 1", they're in
    ;                              G1_town/etc.). It's emitted alongside
    ;                              cross-act transitions and would
    ;                              pollute the sync engine if treated
    ;                              as ZoneChanged.
    _ExtractScene(lineStr)
    {
        if RegExMatch(lineStr, "\[SCENE\]\s+Set Source \[(.*?)\]", &m)
        {
            name := Trim(m[1])
            if (name = "" || name = "(null)" || name = "(unknown)")
                return ""
            ; Transition markers between acts: "Act 1", "Act 2", ..., "Act 6".
            ; Also case-insensitive variants like "act 1".
            if RegExMatch(name, "i)^Act\s+\d+$")
                return ""
            return name
        }
        return ""
    }

    ; Pattern: "You have entered <ZONE>."
    _ExtractZoneEntered(lineStr)
    {
        if RegExMatch(lineStr, "i)You have entered\s+(.+?)[\.]?$", &m)
            return Trim(m[1], " .")
        return ""
    }

    ; Patterns:
    ;   ":<NAME> has been slain."   (player, with timestamp prefix)
    ;   "<NAME> has been slain."    (including monsters, no prefix)
    _ExtractDeath(lineStr)
    {
        if RegExMatch(lineStr, "i):\s+(.+?)\s+has been slain\.", &m)
            return Trim(m[1])
        if RegExMatch(lineStr, "i)^(.+?)\s+has been slain\.", &m2)
            return Trim(m2[1])
        return ""
    }

    ; Pattern: "[WINDOW] Lost focus" / "[WINDOW] Gained focus"
    _ExtractFocus(lineStr)
    {
        if RegExMatch(lineStr, "i)\[WINDOW\]\s+Lost focus")
            return "lost"
        if RegExMatch(lineStr, "i)\[WINDOW\]\s+Gained focus")
            return "gained"
        return ""
    }
}
