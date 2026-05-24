; ============================================================
; RouteRepository — persists Route per profile under data/routes/
; ============================================================
;
; INI format (one file per profile, UTF-16 LE BOM):
;
;   [Route]
;   zones=The Riverbank|Clearfell|The Grelwood|The Red Vale
;
;   [Notes]
;   the riverbank=walk straight then open door
;   mud burrow=vendor first\nportal back to town
;
; Encoding follows the project-wide convention. AHK v2's
; IniRead key-lookup variant silently returns the default on
; UTF-8 BOM files; only UTF-16 LE BOM works. AtomicWriter +
; "UTF-16" encoding here matches PersonalBestRepository and
; SettingsRepository.
;
; Why pipe (|) as separator instead of comma:
;   PoE2 zone names don't contain pipes (verified against the
;   77 entries in data/zones.csv), but some names DO contain
;   commas in other games / future content. Pipe is a forward-
;   compatible choice that doesn't force escaping today.
;
; NOTES SECTION:
;   Keys are lowercased zone names (matches Route._notes internal
;   keying for case-insensitive lookup). Values are encoded with
;   two escape sequences — `\\` for a literal backslash and `\n`
;   for a line break — so a multi-line note serializes onto a
;   single INI value (INI format doesn't support multi-line
;   values natively). The decode is order-sensitive: `\\` must
;   be resolved before `\n` so the literal sequence "\\n" in the
;   user's note (the two characters backslash + n) doesn't get
;   mis-decoded as a newline. Implemented via char-by-char scan
;   rather than two StrReplace calls because StrReplace can't
;   express that disambiguation in a single pass.
;
;   The keys are lowercased before write to keep the file format
;   coherent with the in-memory Map keying — a user hand-editing
;   the INI with a different casing would still resolve correctly
;   on load (the Route constructor also lowercases on intake).
;
; PATH STRUCTURE:
;   <baseDir>\<sanitizedProfileName>.ini
;
;   Profile name sanitization strips Windows-reserved filename
;   characters (<>:"/\|?* + CRLF) and replaces them with "_".
;   Two profiles whose names collapse to the same sanitized
;   form would share a file — this is documented as a known
;   limitation (no real profile name would collide under
;   normal use).
;
; API:
;   Load(profileName)                    → Route
;   Save(profileName, route)             → bool
;   ImportFromProfile(srcProfile, dst)   → bool
;   ImportFromFile(path, dstProfile)     → bool
;   ExportToFile(profileName, path)      → bool
;   GetPathForProfile(profileName)       → string
;
; Load returns a fresh empty Route when:
;   - the profile file doesn't exist (first-time user)
;   - the [Route] section is missing
;   - the zones= key is empty
;   - the file is unreadable (logged via WarningSink)
;
;   Notes are best-effort: a missing or unreadable [Notes]
;   section just yields no notes; the route still loads.
;
; Save writes atomically via AtomicWriter (.tmp + FileMove). A
; crash mid-Save leaves an orphan .tmp and preserves the prior
; INI intact. Failures are forwarded to the injected
; WarningSink and Save returns false; the caller decides how
; to react.

class RouteRepository
{
    static SEPARATOR := "|"

    _baseDir := ""
    _warn    := ""

    __New(baseDir, sinkOrEmpty := "")
    {
        if (Trim(String(baseDir)) = "")
            throw ValueError("RouteRepository: 'baseDir' is required")
        this._baseDir := baseDir
        this._warn    := WarningSink.Resolve(sinkOrEmpty)
        ; Ensure the routes directory exists so the first Save
        ; doesn't fail on a missing path. DirCreate is no-op when
        ; the directory already exists.
        try DirCreate(this._baseDir)
    }

    GetBaseDir() => this._baseDir

    ; Returns the absolute path where the given profile's route
    ; lives. Public so SettingsDialog can show it to the user
    ; (e.g. "Route saved at <path>") and tests can assert on it.
    GetPathForProfile(profileName)
    {
        sanitized := RouteRepository._SanitizeProfileName(profileName)
        return this._baseDir "\" sanitized ".ini"
    }

    ; ------------------------------------------------------------
    ; Load
    ; ------------------------------------------------------------

    ; Returns a Route for the profile. Always returns a valid
    ; instance — empty when the file is absent or unreadable.
    ; Never throws.
    Load(profileName)
    {
        path := this.GetPathForProfile(profileName)
        if !FileExist(path)
            return Route()

        try
        {
            ini := IniFile(path)
            raw := ini.Read("Route", "zones", "")
            if (Trim(String(raw)) = "")
                return Route()
            zones := RouteRepository._SplitZones(raw)
            ; Notes are best-effort — a missing or unreadable
            ; [Notes] section yields an empty map; the route
            ; still loads. Read failures inside _LoadNotes are
            ; swallowed there (logged via the warning sink),
            ; never surfacing up.
            notes := this._LoadNotes(ini)
            return Route(zones, notes)
        }
        catch as ex
        {
            this._warn.Warn("Load failed for " . path, ex)
            return Route()
        }
    }

    ; ------------------------------------------------------------
    ; Save
    ; ------------------------------------------------------------

    ; Persists the route for the given profile. The full INI is
    ; serialized in memory then written via AtomicWriter. Returns
    ; true on success, false on failure (warning emitted via the
    ; injected sink). The route's _currentIdx is NOT persisted —
    ; the runtime position is a per-run concept tracked by
    ; RouteService and reset on every RunStarted.
    ;
    ; Note: the parameter is named `routeObj` (not `route`) because
    ; AHK v2 identifier lookup is case-insensitive, so a local
    ; `route` would shadow the global `Route` class on the next
    ; line and the `is Route` check would fail with
    ; `TypeError: Expected a Class but got a Route`. Same pattern
    ; documented in PersonalBestRepository (runId vs RunId).
    Save(profileName, routeObj)
    {
        if !(routeObj is Route)
            throw TypeError("RouteRepository.Save: 'routeObj' must be Route")

        path := this.GetPathForProfile(profileName)
        try
        {
            content := RouteRepository._Serialize(routeObj)
            AtomicWriter.WriteAll(path, content, "UTF-16")
            return true
        }
        catch as ex
        {
            this._warn.Warn("Save failed for " . path, ex)
            return false
        }
    }

    ; ------------------------------------------------------------
    ; Import / Export
    ; ------------------------------------------------------------

    ; Copies the route from srcProfile to dstProfile (full
    ; override — no merge). Returns true if a save happened,
    ; false when the source has no route (or unreadable).
    ImportFromProfile(srcProfile, dstProfile)
    {
        srcRoute := this.Load(srcProfile)
        if !srcRoute.HasRoute()
            return false
        return this.Save(dstProfile, srcRoute)
    }

    ; Imports a route from an external INI file (same schema as
    ; Save produces). The dst profile receives a full override.
    ; Returns true on success, false when the file is missing,
    ; malformed, or empty.
    ImportFromFile(path, dstProfile)
    {
        if (Trim(String(path)) = "")
            return false
        if !FileExist(path)
            return false

        try
        {
            ini := IniFile(path)
            raw := ini.Read("Route", "zones", "")
            if (Trim(String(raw)) = "")
                return false
            zones := RouteRepository._SplitZones(raw)
            if (zones.Length = 0)
                return false
            ; Round-trip notes too — an exported route file
            ; carrying [Notes] should land in the destination
            ; profile with those notes intact.
            notes := this._LoadNotes(ini)
            return this.Save(dstProfile, Route(zones, notes))
        }
        catch as ex
        {
            this._warn.Warn("ImportFromFile failed for " . path, ex)
            return false
        }
    }

    ; Writes the profile's current route to an arbitrary external
    ; path (same schema as the internal data/routes file). Used
    ; by the Settings UI's Export button so the user can share a
    ; route with another runner. Returns false when the profile
    ; has no route or the write fails.
    ExportToFile(profileName, path)
    {
        if (Trim(String(path)) = "")
            return false
        loaded := this.Load(profileName)
        if !loaded.HasRoute()
            return false
        try
        {
            content := RouteRepository._Serialize(loaded)
            AtomicWriter.WriteAll(path, content, "UTF-16")
            return true
        }
        catch as ex
        {
            this._warn.Warn("ExportToFile failed for " . path, ex)
            return false
        }
    }

    ; ------------------------------------------------------------
    ; Static helpers
    ; ------------------------------------------------------------

    ; Builds the full INI content from a Route. Strips the
    ; separator character from individual zone names defensively
    ; (no real PoE2 name contains it today, but the user could
    ; type one in the Settings UI before this layer validates).
    ; Param name is `routeObj` to avoid the case-insensitive
    ; collision with the `Route` class (see Save).
    static _Serialize(routeObj)
    {
        content := "[Route]`r`n"
        zonesPart := ""
        zones := routeObj.GetZones()
        for _, z in zones
        {
            zStr := String(z)
            zStr := StrReplace(zStr, "`r", "")
            zStr := StrReplace(zStr, "`n", "")
            zStr := StrReplace(zStr, RouteRepository.SEPARATOR, "")
            zStr := StrReplace(zStr, "=", "")
            zStr := StrReplace(zStr, "[", "")
            zStr := StrReplace(zStr, "]", "")
            if (Trim(zStr) = "")
                continue
            if (zonesPart != "")
                zonesPart .= RouteRepository.SEPARATOR
            zonesPart .= zStr
        }
        content .= "zones=" zonesPart "`r`n"

        ; [Notes] section (serialized only if there's at least
        ; one note — keeps the file format identical to the
        ; pre-notes era when the user has no per-zone tips).
        ; Keys are lowercased zone names (already are in the
        ; map returned by GetAllNotes); values are escaped via
        ; _EncodeNote to fit on a single INI line.
        notes := routeObj.GetAllNotes()
        if (notes.Count > 0)
        {
            content .= "`r`n[Notes]`r`n"
            for k, v in notes
            {
                kStr := String(k)
                ; Defensive: a hand-crafted note Map could carry
                ; characters that break the INI key (=, [, ],
                ; CRLF). Strip them on serialize so the file
                ; stays parseable on next Load. PoE2 zone names
                ; don't contain any of these, so production data
                ; never hits these StrReplaces.
                kStr := StrReplace(kStr, "`r", "")
                kStr := StrReplace(kStr, "`n", "")
                kStr := StrReplace(kStr, "=",  "")
                kStr := StrReplace(kStr, "[",  "")
                kStr := StrReplace(kStr, "]",  "")
                if (Trim(kStr) = "")
                    continue
                vStr := RouteRepository._EncodeNote(String(v))
                if (vStr = "")
                    continue
                content .= kStr "=" vStr "`r`n"
            }
        }

        return content
    }

    ; Splits a serialized zones string into an array. Empty
    ; entries (from leading/trailing/double separators) are
    ; filtered out; whitespace around each entry is trimmed.
    static _SplitZones(raw)
    {
        out := []
        rawStr := String(raw)
        if (Trim(rawStr) = "")
            return out
        for _, part in StrSplit(rawStr, RouteRepository.SEPARATOR)
        {
            trimmed := Trim(part)
            if (trimmed != "")
                out.Push(trimmed)
        }
        return out
    }

    ; Reads the [Notes] section of an open IniFile and returns
    ; a Map<zoneName, decodedText>. Always returns a Map (empty
    ; on absence or error) so the caller can pass it to Route's
    ; constructor unconditionally. Per-key failures are skipped
    ; silently; section-level failures emit a warning.
    _LoadNotes(ini)
    {
        out := Map()
        out.CaseSense := "Off"
        try
        {
            ; The IniFile abstraction returns a key=value map
            ; for the requested section. Missing sections come
            ; back as an empty map (no throw).
            section := ini.ReadSectionAsMap("Notes")
            ; Trim's default 2nd arg is " `t" and does NOT include
            ; `r/`n — a value that decodes to a bare newline (or
            ; just an escaped \n on disk that decoded to LF) would
            ; otherwise count as a non-empty note. Pass all
            ; whitespace chars explicitly so the load path mirrors
            ; the Route constructor's normalization.
            blankChars := " `t`r`n"
            for k, v in section
            {
                kStr := String(k)
                if (Trim(kStr, blankChars) = "")
                    continue
                vStr := RouteRepository._DecodeNote(String(v))
                if (Trim(vStr, blankChars) = "")
                    continue
                out[kStr] := vStr
            }
        }
        catch as ex
        {
            this._warn.Warn("LoadNotes failed (returning empty)", ex)
        }
        return out
    }

    ; Encodes a note for INI persistence:
    ;   \  → \\        (backslash escape; MUST run first)
    ;   LF → \n        (line break escape; second pass)
    ;   CR → ""        (Windows line endings drop the carriage;
    ;                   only the LF carries the line-break)
    ; Order matters: escape backslash FIRST so a literal backslash
    ; in the user's note (e.g. "C:\path") doesn't get mis-encoded
    ; as "C:\\path" then re-escaped to "C:\\\\path".
    static _EncodeNote(text)
    {
        s := String(text)
        if (s = "")
            return ""
        s := StrReplace(s, "\", "\\")
        s := StrReplace(s, "`r", "")
        s := StrReplace(s, "`n", "\n")
        return s
    }

    ; Decodes a note loaded from INI. Implemented as a char-by-
    ; char scan because StrReplace can't disambiguate "\\n" (the
    ; literal two-character sequence backslash+n that the user
    ; typed) from "\n" (the encoded newline) in a single pass.
    ; The scan resolves "\\" to a single backslash and "\n" to
    ; a line break; an unknown escape sequence (e.g. "\x") is
    ; preserved as-is so future format additions don't silently
    ; eat data.
    static _DecodeNote(text)
    {
        s := String(text)
        if (s = "")
            return ""
        out := ""
        i := 1
        len := StrLen(s)
        while (i <= len)
        {
            ch := SubStr(s, i, 1)
            if (ch = "\" && i < len)
            {
                next := SubStr(s, i + 1, 1)
                if (next = "\")
                {
                    out .= "\"
                    i += 2
                    continue
                }
                if (next = "n")
                {
                    out .= "`n"
                    i += 2
                    continue
                }
                ; Unknown escape — keep the backslash and let the
                ; next char be processed normally on the next
                ; iteration. Avoids silent data loss for future
                ; escape additions or for malformed input.
                out .= ch
                i += 1
                continue
            }
            out .= ch
            i += 1
        }
        return out
    }

    ; Sanitizes a profile name for use as an INI filename.
    ; Strips Windows-reserved filename characters and replaces
    ; them with underscores. Empty / whitespace-only names
    ; collapse to "default" so the path is always valid.
    static _SanitizeProfileName(profileName)
    {
        name := Trim(String(profileName))
        if (name = "")
            return "default"
        ; Replace each reserved char with "_"
        for _, ch in StrSplit("<>:`"/\|?*", "")
            name := StrReplace(name, ch, "_")
        name := StrReplace(name, "`r", "_")
        name := StrReplace(name, "`n", "_")
        name := Trim(name)
        if (name = "")
            return "default"
        return name
    }
}
