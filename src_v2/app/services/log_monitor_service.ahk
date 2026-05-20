; LogMonitorService — tail loop on PoE2's Client.txt that parses
; known lines and publishes raw events on the bus. Deliberately
; "dumb": it doesn't decide what to do with events. The composition
; root wires events to commands of other services.
;
; Recognized lines:
;   "X (Class) is now level N"             → Evt.CharacterLevelUp
;   "Generating level N area X with seed"  → Evt.AreaLevelChanged
;   "[SCENE] Set Source [name]"            → Evt.SceneEntered + Evt.ZoneChanged
;   "You have entered ..."                 → Evt.ZoneChanged (see note below)
;   "X has been slain."                    → Evt.DeathDetected (player only)
;   "[WINDOW] Lost / Gained focus"         → Evt.WindowFocusChanged
;
; "You have entered" status: not observed in current PoE2 Client.txt.
; The string almost certainly survived from an earlier game (or an
; earlier PoE2 build) where every zone transition emitted it. The
; parser branch and `_ExtractZoneEntered` regex are retained because
; the cost is minimal and the engine could reintroduce the line in a
; future patch — better defended than caught off-guard. In the
; current build, every ZoneChanged actually fires from the [SCENE]
; path.
;
; Every line also goes out as Evt.LogLineRead in raw form so other
; subscribers (e.g. AutoStartService matching against autoStartRegex)
; can parse on their own.
;
; ZoneChanged semantics:
;   The PoE2 client emits `[SCENE] Set Source [<raw>]` with <raw>
;   sometimes being a human-readable name ("Mud Burrow") and other
;   times the engine's internal id ("G1_3"). Either way must reach
;   downstream subscribers as the canonical human name when known,
;   so the zone tracker, plot builder, history INI and PB ini all
;   key their data by the same string. Resolution lives here — the
;   single publisher of ZoneChanged — instead of being replicated
;   in every consumer.
;
;   Algorithm (`_ResolveZoneToHumanName`):
;     1. lookup by name in ZonesCatalog (case-insensitive)
;     2. if not found, lookup by internal id
;     3. otherwise return the raw text (unknown zone — preserved
;        verbatim so legitimate new zones added to the game still
;        appear, just without catalog metadata)
;
;   The catalog is optional. When absent (unit tests without the
;   CSV), the raw text passes through unchanged — same behaviour as
;   before this change.
;
; Usage:
;   monitor := LogMonitorService(clock, bus, log, catalog)
;   monitor.Configure(logFilePath)
;   monitor.Start(seedFromTail := true)
;   SetTimer(() => monitor.Tick(), 250)
;
; Tests call monitor.ProcessText(text) directly, no I/O.


class LogMonitorService
{
    _clock        := ""
    _bus          := ""
    _log          := ""
    _catalog      := ""   ; ZonesCatalog or "" — see _ResolveZoneToHumanName
    _logFilePath  := ""
    _lastPos      := 0
    _partialLine  := ""
    _isRunning    := false
    _lastReadMs   := 0
    _characterName := ""   ; Filter for DeathDetected (player vs boss/monster).

    ; Tail size swept in Start(seedFromTail=true)
    static SEED_BYTES := 65536

    __New(clock, bus, logService, catalog := "")
    {
        if !(IsObject(clock) && clock.HasMethod("NowMs"))
            throw TypeError("LogMonitorService: 'clock' must have NowMs() method")
        if !(bus is EventBus)
            throw TypeError("LogMonitorService: 'bus' must be EventBus")
        if !(IsObject(logService) && logService.HasMethod("Info"))
            throw TypeError("LogMonitorService: 'logService' must have Info/Warn/Error methods")
        ; Catalog is optional (tests without the CSV pass ""); when
        ; provided it must be a real ZonesCatalog so a wiring bug
        ; trips at construction instead of silently bypassing
        ; resolution. Parameter is `catalog` (not `zonesCatalog`)
        ; to dodge the case-insensitive shadow of the class name —
        ; same convention as ZoneTrackingService, see
        ; ARCHITECTURE.md § 15.
        if (catalog != "" && !(catalog is ZonesCatalog))
            throw TypeError("LogMonitorService: 'catalog' must be ZonesCatalog or empty")
        this._clock   := clock
        this._bus     := bus
        this._log     := logService
        this._catalog := catalog
    }

    ; Sets the path to Client.txt. May be called before or after Start
    ; (Start re-reads the path).
    Configure(logFilePathStr)
    {
        this._logFilePath := logFilePathStr
    }

    ; Sets the player's character name, used to filter DeathDetected.
    ; PoE2 logs "<Name> has been slain." for both the player and
    ; bosses; without the filter every boss kill would be counted as
    ; a player death. The composition root sets this on boot from
    ; cfg.characterName and re-applies it on every CharacterLevelUp
    ; event. Empty string disables the filter entirely (no deaths
    ; published).
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

    ; ---- Processing (private) ----

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

    ; Tries each extractor in order; the first that matches publishes
    ; the event and returns. Every line also goes out as
    ; Evt.LogLineRead in raw form for downstream parsers (e.g.
    ; AutoStartService).
    _ProcessLine(lineStr)
    {
        if (lineStr = "")
            return

        ; Broadcast the raw line before any specific parsing.
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
            ; Republish as ZoneChanged too. Current PoE2 no longer
            ; emits "You have entered" on every zone transition
            ; (only "[SCENE] Set Source" is reliable), so without
            ; this branch ZoneTrackingService and the status widgets
            ; would miss the change.
            ;
            ; The raw `scene` may be a human name OR an internal id
            ; ("G1_2"). _ResolveZoneToHumanName turns either into the
            ; canonical human name when the catalog knows it. The
            ; `sceneId` field always carries the raw text — useful
            ; for diagnostics and any subscriber that wants the
            ; engine id.
            humanName := this._ResolveZoneToHumanName(scene)
            this._bus.Publish(Events.ZoneChanged, Map(
                "zoneName", humanName,
                "sceneId",  scene
            ))
            ; DEBUG, not INFO: a full campaign hits 100+ zones and
            ; an INFO line per scene drowned the log file.
            this._log.Debug("Scene/Zone published: " scene
                . (humanName != scene ? " → " humanName : ""), "LogMonitor")
            return
        }

        ; Zone entered
        zone := this._ExtractZoneEntered(lineStr)
        if (zone != "")
        {
            ; Resolve to canonical form too: "You have entered" lines
            ; usually already match the catalog exactly, but the
            ; resolution recovers the canonical case/punctuation if
            ; the log emits a slightly different variant. Unknown
            ; zones pass through unchanged.
            this._bus.Publish(Events.ZoneChanged, Map(
                "zoneName", this._ResolveZoneToHumanName(zone),
                "sceneId",  ""
            ))
            return
        }

        ; Death — player only. PoE2 logs "<Name> has been slain."
        ; for the player AND for bosses (see boss_catalog.ini with
        ; defeat_regex). Filter by the configured character name to
        ; keep the run's deathCount honest.
        death := this._ExtractDeath(lineStr)
        if (death != "")
        {
            if (this._characterName != "" && death = this._characterName)
            {
                this._bus.Publish(Events.DeathDetected, Map(
                    "character", death
                ))
            }
            ; Non-player kill — just drop it.
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
            ; Republish as ZoneChanged on the seed too — same
            ; rationale as _ProcessLine. Without this,
            ; ZoneTrackingService would boot mid-run without knowing
            ; the current zone. Resolution to canonical name mirrors
            ; the live path so the hydrated widgets show the human
            ; name on first frame.
            this._bus.Publish(Events.ZoneChanged, Map(
                "zoneName", this._ResolveZoneToHumanName(lastScene),
                "sceneId",  lastScene
            ))
        }
    }

    ; ---- Extractors (pure regex) ----

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
    ; Not observed in current PoE2 Client.txt — every real-world
    ; ZoneChanged comes from the [SCENE] branch. The regex stays
    ; because the cost is one RegExMatch per unmatched line and the
    ; engine could start emitting the format again. If/when a future
    ; cleanup confirms the line is permanently gone, remove the
    ; branch in _ProcessLine, the `_SeedFromText` analogue isn't
    ; needed (seed only inspects [SCENE]), and the `extracts_zone_entered_*`
    ; / `zone_entered_*` tests in log_monitor_service_tests.
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

    ; ---- Zone name resolution ----

    ; Turns a raw zone string from the log (either a human name like
    ; "Mud Burrow" or an internal id like "G1_3") into the canonical
    ; human name when the catalog knows it. Without resolution the
    ; two would travel downstream as distinct strings and end up as
    ; two separate keys in `_totals`, the run history INI and the PB
    ; ini — the same physical zone counted as two.
    ;
    ; Order of attempts:
    ;   1. FindByName (case-insensitive in ZonesCatalog) catches the
    ;      common case — PoE2 most often emits the human name,
    ;      sometimes with slight case/whitespace drift. Returns the
    ;      catalog's stored display name, which restores canonical
    ;      casing/punctuation.
    ;   2. FindById catches lines that emit the engine id ("G1_3",
    ;      "G1_town", etc.). Returns the human name from the matched
    ;      entry.
    ;   3. Pass through the raw text. Unknown zones (a fresh game
    ;      patch adds an area, a randomized instance with an opaque
    ;      name) still surface to the user, just without the act/
    ;      isTown metadata downstream services derive from the
    ;      catalog.
    ;
    ; No catalog → every input passes through unchanged, preserving
    ; the legacy no-resolution behaviour for tests/headless setups that don't
    ; wire one in.
    _ResolveZoneToHumanName(rawZone)
    {
        if (rawZone = "")
            return rawZone
        if (this._catalog = "")
            return rawZone

        entry := this._catalog.FindByName(rawZone)
        if IsObject(entry)
            return entry.name

        entry := this._catalog.FindById(rawZone)
        if IsObject(entry)
            return entry.name

        return rawZone
    }
}
