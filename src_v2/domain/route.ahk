; ============================================================
; Route — ordered list of zones the speedrunner plans to visit
; ============================================================
;
; Pure domain model. No I/O, no event bus, no catalog dependency
; here — those live in RouteRepository (I/O) and RouteService
; (advance-on-ZoneEntered + town filtering). Keeping Route pure
; means it can be exercised in unit tests without setting up an
; INI file or seeding a fake catalog, and the same model survives
; future changes in persistence format or event wiring.
;
; STATE:
;   _zones      — Array<String>, display names in user-chosen order.
;                 Display names are stored verbatim (case sensitive
;                 as the user typed / picked from the catalog).
;                 Duplicates are NOT allowed: Add rejects a zone
;                 already present (case-insensitive match) and the
;                 array constructor drops duplicates silently with
;                 first-occurrence-wins. The earlier permissive
;                 semantic was changed because the route panel is
;                 a "path map with accumulated time per zone", not
;                 a splits-style sequence — going back to a zone
;                 already in the list is the EXPECTED behavior
;                 (handled by AdvanceTo's backward scan), so a
;                 second entry for the same zone has no use case
;                 and just confuses the per-zone time display.
;   _notes      — Map<lowerZoneName, noteText>. Per-zone runner
;                 tip rendered below the current zone on the
;                 overlay ("vendor first then portal back", etc).
;                 Stored as plain text; \n in stored text becomes
;                 a line break in the widget. Keys lowercased so
;                 SetNote("Mud Burrow") and SetNote("mud burrow")
;                 refer to the same note regardless of case drift.
;                 Empty/whitespace-only notes are normalized to
;                 absent (not an empty-string entry) so the widget
;                 doesn't reserve space for nothing.
;   _currentIdx — Integer in [-1, _zones.Length - 1]. -1 means
;                 "haven't entered any route zone yet this run".
;                 The Reset() method snaps back to -1 — used by
;                 RouteService on RunStarted / RunReset /
;                 RunCancelled. Zero-based otherwise. Notes are
;                 NOT cleared on Reset (they're route authoring
;                 data, not per-run state).
;
; SEMANTICS OF AdvanceTo:
;   The runner's path through a route isn't strictly forward — a
;   trip back to town between Act 1 zones means the next zone may
;   be one the runner already visited. So AdvanceTo follows a
;   "nearest match" rule:
;
;     1. Look forward from _currentIdx + 1 for a case-insensitive
;        match. If found, that becomes the new _currentIdx
;        (canonical advance).
;     2. If no forward match, look backward from _currentIdx down
;        to 0. If found, _currentIdx retreats (the player went
;        back to an earlier route zone — boss room, return to town
;        sweep, whatever).
;     3. If no match in either direction, the call is a silent
;        no-op (off-route zone).
;
;   The asymmetric forward-first scan stays even though Add now
;   rejects duplicates, because legacy route files on disk may
;   still contain duplicates that the constructor's silent dedupe
;   already collapsed — but as a defensive measure, the scan
;   logic doesn't assume uniqueness. Case-insensitive match is
;   forgiving against minor capitalization drift between editor
;   input and Client.txt resolution.
;
;   Town zones are NOT filtered here — RouteService strips
;   isTown=true events BEFORE invoking AdvanceTo, so this layer
;   never has to know what a town is. If a town name somehow ends
;   up in _zones (user error, legacy import), AdvanceTo treats it
;   like any other zone string.
;
; VISIBLE SLICE:
;   GetVisibleSlice(n) returns the n-row window starting at the
;   current zone. Used by RouteWidget to render. When _currentIdx
;   is -1 (haven't started), the slice starts at index 0 so the
;   widget shows "what's coming" before the first zone is entered.
;   Each row is a Map { name, idx, status } where status is one of:
;     "current"  — the row at _currentIdx
;     "upcoming" — rows after _currentIdx
;     "before"   — rows before _currentIdx (only when -1 -> 0
;                  snapping; otherwise the slice never includes
;                  before-current rows)

class Route
{
    _zones      := ""    ; Array<String>
    _notes      := ""    ; Map<lowerZoneName, noteText>
    _currentIdx := -1

    __New(zones := "", notes := "")
    {
        ; Accept an empty constructor (typical: build empty, then
        ; Add). Accept an Array of strings for one-shot
        ; initialization (typical: RouteRepository.Load returns a
        ; Route already populated). Dedupe silently (first wins)
        ; so a legacy file on disk that contained duplicates lands
        ; here as a normalized list — no caller has to remember
        ; to filter.
        this._zones := []
        this._notes := Map()
        this._notes.CaseSense := "Off"    ; case-insensitive lookup; keys still stored lowercased to be explicit
        this._currentIdx := -1
        if (zones != "")
        {
            if !(zones is Array)
                throw TypeError("Route: 'zones' must be Array<String> or empty")
            seen := Map()
            seen.CaseSense := "Off"
            for _, z in zones
            {
                zStr := String(z)
                if (Trim(zStr) = "")
                    continue
                if seen.Has(zStr)
                    continue
                seen[zStr] := true
                this._zones.Push(zStr)
            }
        }
        ; Notes parameter (optional). Map<zoneName, noteText> — the
        ; constructor normalizes keys to lowercase and drops empty
        ; notes so the in-memory state matches the on-disk contract.
        ; Notes for zones NOT present in _zones are kept defensively
        ; (a Remove between Save and Load wouldn't cascade to the
        ; notes section on disk if the user hand-edited the INI;
        ; clearing them silently would lose user data).
        if (notes != "")
        {
            if !(notes is Map)
                throw TypeError("Route: 'notes' must be Map<zoneName, noteText> or empty")
            ; Trim's default 2nd arg is " `t" (space + tab) and does
            ; NOT include `r/`n — a note that is just "`t`n" would
            ; otherwise survive the empty-check and end up stored as
            ; an effectively-blank entry. Pass all whitespace chars
            ; explicitly so multi-line newlines without content
            ; collapse to "absent".
            blankChars := " `t`r`n"
            for k, v in notes
            {
                kStr := String(k)
                vStr := String(v)
                if (Trim(kStr, blankChars) = "")
                    continue
                if (Trim(vStr, blankChars) = "")
                    continue
                this._notes[StrLower(kStr)] := vStr
            }
        }
    }

    ; ------------------------------------------------------------
    ; Queries
    ; ------------------------------------------------------------

    Count() => this._zones.Length
    IsEmpty() => this._zones.Length = 0
    HasRoute() => this._zones.Length > 0
    GetCurrentIdx() => this._currentIdx

    ; Returns the zone at a zero-based index, or "" if out of range.
    ; Defensive: callers can pass _currentIdx without an explicit
    ; range check.
    GetZoneAt(idx)
    {
        if (!IsNumber(idx) || idx < 0 || idx >= this._zones.Length)
            return ""
        return this._zones[idx + 1]    ; AHK arrays are 1-based; idx is 0-based
    }

    ; Returns a copy of the zone array (immutable from caller's POV).
    GetZones()
    {
        out := []
        for _, z in this._zones
            out.Push(z)
        return out
    }

    ; True when the zone (case-insensitive) is already present in
    ; the route. Single source of truth for Add's dedupe gate and
    ; for callers (Settings UI) that want feedback before pushing.
    HasZone(zoneName)
    {
        zStr := String(zoneName)
        if (Trim(zStr) = "")
            return false
        target := StrLower(zStr)
        for _, existing in this._zones
        {
            if (StrLower(existing) = target)
                return true
        }
        return false
    }

    ; ------------------------------------------------------------
    ; Notes
    ; ------------------------------------------------------------

    ; Returns the note text for zoneName, or "" if no note (and ""
    ; for zones not in the route either — callers can't distinguish
    ; "never set" from "empty", which is intentional; the widget
    ; renders both as "no note row").
    GetNote(zoneName)
    {
        zStr := String(zoneName)
        if (Trim(zStr) = "")
            return ""
        key := StrLower(zStr)
        return this._notes.Has(key) ? this._notes[key] : ""
    }

    ; Sets the note for zoneName. Empty/whitespace-only text deletes
    ; the note (so the widget stops reserving space for it). Returns
    ; true when the underlying _notes map was mutated, false on
    ; no-op (whitespace text against an already-empty entry).
    SetNote(zoneName, text)
    {
        zStr := String(zoneName)
        if (Trim(zStr) = "")
            return false
        key := StrLower(zStr)
        textStr := String(text)
        ; See __New: AHK v2's default Trim chars are " `t" (no
        ; `r/`n), so "`n" alone would NOT trim to empty. Pass all
        ; whitespace chars explicitly to keep SetNote("x", "`n")
        ; semantically equivalent to SetNote("x", "") — both
        ; mean "no note for this zone".
        if (Trim(textStr, " `t`r`n") = "")
        {
            if !this._notes.Has(key)
                return false
            this._notes.Delete(key)
            return true
        }
        if (this._notes.Has(key) && this._notes[key] = textStr)
            return false
        this._notes[key] := textStr
        return true
    }

    ; Defensive copy of the notes map. Used by RouteRepository.Save
    ; to serialize the [Notes] INI section, and by the Settings
    ; dialog to hydrate its editing buffer on Open().
    GetAllNotes()
    {
        out := Map()
        out.CaseSense := "Off"
        for k, v in this._notes
            out[k] := v
        return out
    }

    ; ------------------------------------------------------------
    ; Mutators (editing)
    ; ------------------------------------------------------------

    ; Appends a zone to the end of the route. Empty / whitespace-
    ; only names are silently ignored. Duplicates (case-insensitive)
    ; are REJECTED — the Settings UI is responsible for surfacing
    ; feedback to the user; this layer just returns false and
    ; leaves _zones untouched.
    Add(zoneName)
    {
        zStr := String(zoneName)
        if (Trim(zStr) = "")
            return false
        if this.HasZone(zStr)
            return false
        this._zones.Push(zStr)
        return true
    }

    ; Removes the zone at zero-based idx. Returns true on success,
    ; false on out-of-range. Also drops the matching note if one
    ; exists — keeping it around with no anchor zone would leak
    ; orphan notes into the [Notes] INI section on the next save.
    ; If the current zone is removed, the index snaps back to
    ; (idx - 1) so the next AdvanceTo can still find the route
    ; position relative to the shrinkage. If a zone BEFORE the
    ; current is removed, current shifts down by 1 to preserve
    ; identity. Removal AFTER current leaves the index untouched.
    Remove(idx)
    {
        if (!IsNumber(idx) || idx < 0 || idx >= this._zones.Length)
            return false
        removedZone := this._zones[idx + 1]
        this._zones.RemoveAt(idx + 1)
        ; Drop the note for the removed zone (defensive — only
        ; deletes if a note existed; no-op otherwise).
        key := StrLower(removedZone)
        if this._notes.Has(key)
            this._notes.Delete(key)
        if (this._currentIdx >= 0)
        {
            if (this._currentIdx > idx)
                this._currentIdx -= 1
            else if (this._currentIdx = idx)
                this._currentIdx -= 1    ; -1 if it was 0 (becomes "haven't started")
            ; else current < idx removed: untouched
        }
        return true
    }

    ; Swaps the zone at idx with the one above it (idx - 1).
    ; No-op when idx is 0 or out of range. Returns true on success.
    ; The _currentIdx is adjusted to follow the zones it points to
    ; through the swap — otherwise reordering would silently shift
    ; the player's "current" indicator to a different zone.
    MoveUp(idx)
    {
        if (!IsNumber(idx) || idx <= 0 || idx >= this._zones.Length)
            return false
        ; AHK 1-based array indices
        a := idx + 1
        b := idx        ; a-1 in 1-based = idx in 0-based notation
        tmp := this._zones[a]
        this._zones[a] := this._zones[b]
        this._zones[b] := tmp
        ; Adjust _currentIdx if it points to one of the swapped slots
        if (this._currentIdx = idx)
            this._currentIdx := idx - 1
        else if (this._currentIdx = idx - 1)
            this._currentIdx := idx
        return true
    }

    ; Swaps the zone at idx with the one below it (idx + 1).
    ; No-op when idx is last or out of range.
    MoveDown(idx)
    {
        if (!IsNumber(idx) || idx < 0 || idx >= this._zones.Length - 1)
            return false
        a := idx + 1
        b := idx + 2
        tmp := this._zones[a]
        this._zones[a] := this._zones[b]
        this._zones[b] := tmp
        if (this._currentIdx = idx)
            this._currentIdx := idx + 1
        else if (this._currentIdx = idx + 1)
            this._currentIdx := idx
        return true
    }

    ; ------------------------------------------------------------
    ; Mutators (progress)
    ; ------------------------------------------------------------

    ; Snaps _currentIdx back to -1 ("haven't started"). Called by
    ; RouteService on RunStarted / RunReset / RunCancelled so each
    ; new run starts the route from scratch.
    Reset()
    {
        this._currentIdx := -1
    }

    ; Attempts to advance/retreat the current position to match
    ; the given zone name. See class header for the matching
    ; algorithm. Returns true if a match was found (current index
    ; changed), false on off-route / empty input.
    AdvanceTo(zoneName)
    {
        if (this._zones.Length = 0)
            return false
        zStr := Trim(String(zoneName))
        if (zStr = "")
            return false

        ; Forward scan from _currentIdx + 1
        startFwd := this._currentIdx + 1
        i := startFwd
        while (i < this._zones.Length)
        {
            ; AHK `=` is case-insensitive string comparison
            if (this._zones[i + 1] = zStr)
            {
                this._currentIdx := i
                return true
            }
            i += 1
        }

        ; Backward scan from _currentIdx - 1 down to 0
        if (this._currentIdx >= 1)
        {
            i := this._currentIdx - 1
            while (i >= 0)
            {
                if (this._zones[i + 1] = zStr)
                {
                    this._currentIdx := i
                    return true
                }
                i -= 1
            }
        }

        ; Off-route: no match in either direction
        return false
    }

    ; ------------------------------------------------------------
    ; View helper
    ; ------------------------------------------------------------

    ; Returns up to n rows starting from the current zone. Each
    ; row is a Map { name, idx, status }. status:
    ;   "current"  — row at _currentIdx
    ;   "upcoming" — rows after _currentIdx
    ;   "before"   — rows preceding _currentIdx (only emitted when
    ;                _currentIdx is -1 and n > zones.Length, never
    ;                in the steady state)
    ;
    ; When _currentIdx = -1, the slice starts at index 0 so the
    ; widget shows the first zones of the route before the run
    ; begins. Otherwise the slice starts AT _currentIdx (current
    ; is the first visible row), and extends forward until either
    ; n rows are filled or the route ends.
    ;
    ; Returned array may have fewer than n rows when the route is
    ; shorter than n or when _currentIdx + n exceeds the route
    ; length. The widget should accept that and shrink itself
    ; accordingly.
    GetVisibleSlice(n)
    {
        out := []
        if (!IsNumber(n) || n <= 0)
            return out
        if (this._zones.Length = 0)
            return out

        startIdx := this._currentIdx >= 0 ? this._currentIdx : 0
        i := startIdx
        rowsLeft := Integer(n)
        while (rowsLeft > 0 && i < this._zones.Length)
        {
            status := (i = this._currentIdx) ? "current"
                    : (i  > this._currentIdx) ? "upcoming"
                    : "before"
            out.Push(Map(
                "name",   this._zones[i + 1],
                "idx",    i,
                "status", status
            ))
            i += 1
            rowsLeft -= 1
        }
        return out
    }
}
