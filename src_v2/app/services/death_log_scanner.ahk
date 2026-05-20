; ============================================================
; DeathLogScanner - one-shot aggregation over a raw Client.txt
; ============================================================
;
; The DeathStatsDialog uses this for its "All-time (from log)"
; view. Reads the full Client.txt sequentially and emits the same
; perZone shape DeathStatsService produces from data/deaths.csv,
; so the dialog can swap the data source without changing the UI.
;
; NOT for live tailing — that lives in LogMonitorService with its
; own state machine (file position, partial-line buffering, seed
; on boot). This is a pure one-shot read with no side effects: no
; events, no disk writes, no event-bus dependency. The result
; lives only in the Map returned from Scan().
;
; Zone detection — three signal sources, in order of precedence:
;
;   1. `Generating level <N> area "<code>" with seed`
;        Emitted for every zone transition. Carries the internal
;        id with an optional `C_` prefix marking cruel difficulty
;        (e.g. `G3_3` = Jungle Ruins normal, `C_G3_3` = cruel).
;        The ONLY way to detect cruel — see (2).
;
;   2. `[SCENE] Set Source [<name>]`
;        Emitted for normal-difficulty zone transitions, hideouts,
;        and endgame maps. NOT emitted for cruel — verified
;        empirically against a real Client.txt where cruel
;        area-gens had zero corresponding SCENE lines. The live
;        tail (LogMonitorService) has the same blind spot; the
;        scanner uses the area-gen signal to recover for the
;        all-time view.
;
;   3. `<NAME> has been slain.`
;        Death event. Counted against the most recent resolved
;        zone, or `skippedNonCampaign` if none resolved.
;
; Campaign-only policy:
;   Counts deaths in campaign zones only. Anything not in
;   `data/zones.csv` (hideouts, atlas maps, endgame trials, towns)
;   is dropped and the count surfaces in `skippedNonCampaign` so
;   the user can see what the filter dropped. Cruel is resolved
;   dynamically — see `_ResolveAreaCode`.
;
; Parser duplication:
;   The three static parsers mirror regexes in `LogMonitorService`
;   (`_ExtractScene`, `_ExtractDeath`, `_ExtractAreaLevel`). Not
;   extracted because the live tail carries unrelated complexity
;   (state machine, partial-line handling) that would weigh down
;   a shared module. Any change to the live regexes must be
;   reflected here; the tests pin both against the same fixtures.
;
; Character filter:
;   The PoE2 log emits "X has been slain." for the player and for
;   any minions/allies/party members that die. Bosses do NOT emit
;   this line in current PoE2 builds (verified empirically against
;   real Client.txt), so a missing filter does not pollute the
;   result with boss deaths. `Scan(path, characterFilter := "")`
;   drops every death whose subject name does not match
;   `characterFilter` when it is non-empty; an empty filter counts
;   every death the log records. The `DeathStatsDialog` wires an
;   empty filter for the "All-time (from log)" view — that view
;   is meant to surface every character the player ever ran on
;   the install, not just the active one. The parameter is kept
;   on the API surface so future callers (per-character
;   diagnostics, hypothetical alt-character drill-down) can opt
;   in to filtering without a separate `Scan` method.


class DeathLogScanner
{
    static CRUEL_SUFFIX := " (Cruel)"
    static CRUEL_PREFIX := "C_"

    _catalog := ""

    ; Parameter is `catalog` (not `zonesCatalog`) to dodge the
    ; case-insensitive shadow of the class name on the right-hand
    ; side of `is ZonesCatalog` — same convention as
    ; LogMonitorService / DeathStatsService / ZoneTrackingService.
    ; See ARCHITECTURE.md §15.
    __New(catalog := "")
    {
        if (catalog != "" && !(catalog is ZonesCatalog))
            throw TypeError("DeathLogScanner: 'catalog' must be ZonesCatalog or empty")
        this._catalog := catalog
    }

    ; Scan(logPath, characterFilter := "") -> Map
    ;
    ; Reads the entire log at logPath line-by-line, tracking the
    ; current campaign zone via `Generating level` and `[SCENE] Set
    ; Source` lines (see header for precedence). Counts deaths
    ; matching `characterFilter` and attributes them to the
    ; current zone. Returns:
    ;
    ;   Map(
    ;     "success"             : Boolean,
    ;     "errorMessage"        : String,
    ;     "totalDeaths"         : Integer,
    ;     "perZone"             : Array<Map{zoneName, count}>, count desc
    ;     "linesScanned"        : Integer,
    ;     "skippedNonCampaign"  : Integer  ; deaths not attributable
    ;                                       ; to a campaign zone
    ;                                       ; (no zone yet, hideout,
    ;                                       ; endgame, town, unknown)
    ;   )
    ;
    ; success=false paths: empty path, missing file, file read
    ; throws. errorMessage carries the reason; caller surfaces it
    ; in the UI. On success errorMessage is "".
    Scan(logPath, characterFilter := "")
    {
        result := Map(
            "success",            false,
            "errorMessage",       "",
            "totalDeaths",        0,
            "perZone",            [],
            "linesScanned",       0,
            "skippedNonCampaign", 0
        )

        pathStr := String(logPath)
        if (Trim(pathStr) = "")
        {
            result["errorMessage"] := "Log path is empty"
            return result
        }
        if !FileExist(pathStr)
        {
            result["errorMessage"] := "Log file not found: " . pathStr
            return result
        }

        charFilter         := String(characterFilter)
        fileHandle         := ""
        countByZone        := Map()
        currentZone        := ""    ; "" = no campaign zone active (drop deaths)
        totalDeaths        := 0
        linesScanned       := 0
        skippedNonCampaign := 0

        try
        {
            ; FileOpen + ReadLine streams line-by-line without loading
            ; the whole file into memory — important for active players
            ; with hundreds of MB of Client.txt accumulated over a
            ; league. UTF-8 is forced because PoE2 writes the log
            ; that way and the default (system locale) can lose
            ; non-ASCII zone names on non-English Windows installs.
            ;
            ; Note: AHK v2's `Loop Read` only accepts 2 parameters
            ; (input + optional output file) and no encoding hint, so
            ; FileOpen is the only path that honours the encoding
            ; contract above. ReadLine returns the line without the
            ; trailing newline but may keep a stray `\r` on CRLF
            ; files — Trim handles that.
            fileHandle := FileOpen(pathStr, "r", "UTF-8")
            if !IsObject(fileHandle)
            {
                result["errorMessage"] := "FileOpen returned non-object for: " . pathStr
                return result
            }

            while !fileHandle.AtEOF
            {
                linesScanned += 1
                lineStr := Trim(fileHandle.ReadLine(), " `t`r`n")
                if (lineStr = "")
                    continue

                ; (1) Area gen — highest priority (only cruel-aware
                ; signal). See header.
                areaCode := DeathLogScanner._ParseAreaGen(lineStr)
                if (areaCode != "")
                {
                    currentZone := this._ResolveAreaCode(areaCode)
                    continue
                }

                ; (2) Scene — fallback. Resolves to "" for hideouts /
                ; endgame / town / unknown, which DOES reset
                ; currentZone so a death after leaving a campaign
                ; zone isn't mis-attributed to it.
                scene := DeathLogScanner._ParseScene(lineStr)
                if (scene != "")
                {
                    currentZone := this._ResolveSceneName(scene)
                    continue
                }

                deathChar := DeathLogScanner._ParseDeath(lineStr)
                if (deathChar = "")
                    continue

                ; Character filter — when set, drop deaths whose
                ; subject doesn't match. Empty filter counts all
                ; (as documented in the header).
                if (charFilter != "" && deathChar != charFilter)
                    continue

                ; Death in a non-campaign zone (or before any zone
                ; was seen). Counted in skippedNonCampaign so the
                ; UI can show "X deaths outside campaign zones" —
                ; transparent rather than silently lossy.
                if (currentZone = "")
                {
                    skippedNonCampaign += 1
                    continue
                }

                countByZone[currentZone] := (countByZone.Has(currentZone)
                    ? countByZone[currentZone] : 0) + 1
                totalDeaths += 1
            }

            try fileHandle.Close()
        }
        catch as ex
        {
            ; AHK v2 has no `finally` clause; close defensively on
            ; the failure path. The handle may already be invalid
            ; if FileOpen itself threw — the inner `try` swallows
            ; that case silently.
            try
            {
                if IsObject(fileHandle)
                    fileHandle.Close()
            }
            result["errorMessage"] := "Failed to read log: " . ex.Message
            return result
        }

        ; Build perZone Array<Map> + sort desc, stable for ties.
        ; Map iteration in AHK preserves insertion order, so the
        ; pre-sort order mirrors first-appearance order in the log
        ; — equal counts will land in the order the zones were
        ; first visited, which is the friendly default.
        perZone := []
        for zoneName, count in countByZone
            perZone.Push(Map("zoneName", zoneName, "count", count))
        DeathLogScanner._SortByCountDesc(perZone)

        result["success"]            := true
        result["totalDeaths"]        := totalDeaths
        result["perZone"]            := perZone
        result["linesScanned"]       := linesScanned
        result["skippedNonCampaign"] := skippedNonCampaign
        return result
    }

    ; ============================================================
    ; Zone resolution
    ; ============================================================

    ; Resolves an internal area code from `Generating level` into
    ; a canonical campaign-zone display name, or "" if the code
    ; doesn't map to a non-town campaign zone:
    ;
    ;   "G3_3"   -> "Jungle Ruins"
    ;   "C_G3_3" -> "Jungle Ruins (Cruel)"
    ;   "G1_town" -> ""              (town, dropped)
    ;   "C_G1_town" -> ""            (cruel town, dropped)
    ;   "HideoutCanal" -> ""         (not in catalog, dropped)
    ;
    ; Without a catalog the method returns "" — area codes are
    ; opaque without it, and the no-catalog mode is only used by
    ; tests that exercise the scene path instead. Production
    ; always wires a real catalog.
    _ResolveAreaCode(code)
    {
        if (code = "")
            return ""
        if (this._catalog = "")
            return ""

        isCruel := false
        baseCode := code
        if (SubStr(code, 1, StrLen(DeathLogScanner.CRUEL_PREFIX)) = DeathLogScanner.CRUEL_PREFIX)
        {
            isCruel := true
            baseCode := SubStr(code, StrLen(DeathLogScanner.CRUEL_PREFIX) + 1)
        }

        entry := this._catalog.FindById(baseCode)
        if !IsObject(entry)
            return ""
        if entry.isTown
            return ""

        return isCruel
            ? entry.name . DeathLogScanner.CRUEL_SUFFIX
            : entry.name
    }

    ; Resolves a scene name from `[SCENE] Set Source` into a
    ; canonical campaign-zone display name, or "" for towns and
    ; unknown zones (hideouts, endgame maps, future zones not yet
    ; in the catalog). The scene line carries the human name
    ; verbatim, with two fallbacks because PoE2 occasionally emits
    ; the internal id instead:
    ;
    ;   "Mud Burrow"   -> "Mud Burrow"
    ;   "G1_3"         -> "Mud Burrow"          (resolved via id)
    ;   "Canal Hideout" -> ""                    (not campaign)
    ;   "Brand New Zone" -> ""                   (not in catalog)
    ;
    ; Without a catalog the raw name is returned (no resolution,
    ; no filtering) — same legacy behaviour as the live tail's
    ; `_ResolveZoneToHumanName`. This mode is only used by tests
    ; that don't carry a CSV.
    _ResolveSceneName(raw)
    {
        if (raw = "")
            return ""
        if (this._catalog = "")
            return raw

        entry := this._catalog.FindByName(raw)
        if !IsObject(entry)
            entry := this._catalog.FindById(raw)
        if !IsObject(entry)
            return ""
        if entry.isTown
            return ""

        return entry.name
    }

    ; ============================================================
    ; Static parsers (duplicated from LogMonitorService — see header)
    ; ============================================================

    ; Pattern: `Generating level <N> area "<code>" with seed <S>`
    ;
    ; Returns the code (without quotes) on a match, "" otherwise.
    ; Cruel is signalled by a `C_` prefix on the code — preserved
    ; verbatim here; `_ResolveAreaCode` is the one that interprets
    ; it. Mirrors `LogMonitorService._ExtractAreaLevel` but extracts
    ; the code instead of the level (the level is already published
    ; on the bus as `Evt.AreaLevelChanged` for the live tail; the
    ; scanner doesn't need it).
    static _ParseAreaGen(lineStr)
    {
        if RegExMatch(lineStr, 'i)Generating\s+level\s+\d+\s+area\s+"([^"]+)"\s+with\s+seed', &m)
            return Trim(m[1])
        return ""
    }

    ; Pattern: "[SCENE] Set Source [<name>]"
    ; Filters out:
    ;   - "(null)" / "(unknown)" : char select / loading screens
    ;   - "Act N"                : cinematic title card between acts,
    ;                              not a real zone
    ;   - "Interlude"            : cinematic title card, same
    ;                              family as `Act N` markers — not
    ;                              a playable zone
    ; See LogMonitorService._ExtractScene for the live-tail twin.
    static _ParseScene(lineStr)
    {
        if RegExMatch(lineStr, "\[SCENE\]\s+Set Source \[(.*?)\]", &m)
        {
            name := Trim(m[1])
            if (name = "" || name = "(null)" || name = "(unknown)")
                return ""
            if RegExMatch(name, "i)^Act\s+\d+$")
                return ""
            if (StrLower(name) = "interlude")
                return ""
            return name
        }
        return ""
    }

    ; Patterns:
    ;   ":<NAME> has been slain."  (with timestamp prefix)
    ;   "<NAME> has been slain."   (no prefix — covers monsters too,
    ;                               filtered out downstream by
    ;                               characterFilter)
    ; See LogMonitorService._ExtractDeath for the live-tail twin.
    static _ParseDeath(lineStr)
    {
        if RegExMatch(lineStr, "i):\s+(.+?)\s+has been slain\.", &m)
            return Trim(m[1])
        if RegExMatch(lineStr, "i)^(.+?)\s+has been slain\.", &m2)
            return Trim(m2[1])
        return ""
    }

    ; In-place insertion sort: descending by "count". Stable for
    ; ties — equal counts preserve the order the zones first
    ; appeared in the log. Identical shape to
    ; DeathStatsService._SortByCountDesc; duplicated here rather
    ; than imported so the scanner has no dependency on the
    ; service that consumes its results.
    static _SortByCountDesc(arr)
    {
        if !IsObject(arr) || arr.Length < 2
            return
        n := arr.Length
        i := 2
        while (i <= n)
        {
            j := i
            while (j > 1 && arr[j]["count"] > arr[j - 1]["count"])
            {
                tmp := arr[j]
                arr[j] := arr[j - 1]
                arr[j - 1] := tmp
                j -= 1
            }
            i += 1
        }
    }
}
