; ============================================================
; DeathLogRepository — append-only log of player deaths
; ============================================================
;
; Persists every detected death to data/deaths.csv at the moment
; LogMonitorService publishes DeathDetected. Independent of run
; lifecycle: an entry is recorded even if the run is later
; reset, cancelled, or never finalized. This is the source of
; truth for aggregate "where the player dies" stats — the
; per-run deathCount in RunHistoryRepository is run-scoped and
; only survives if the run is saved.
;
; Deleting a run from history does NOT remove its death entries
; here — the two stores are intentionally decoupled. Documented
; in KNOWN_ISSUES.md.
;
; Format (data/deaths.csv, UTF-8, ';' separator, double-quoted):
;
;   ts;zoneName;patch;profile
;   "2026-05-20 14:32:11";"Cemetery of the Eternals";"0.4";"Default"
;   "2026-05-20 14:35:47";"Mud Burrow";"0.4";"Default"
;
; Validation contract:
;   - zoneName cannot contain CR or LF (would split the row across
;     two CSV lines on next load; CsvFile parses line-by-line).
;     Rejected up front with a warn — surfacing the upstream bug
;     instead of silently corrupting the log.
;   - Empty zoneName is silently dropped: LogMonitorService may
;     emit DeathDetected before the first ZoneChanged seeds the
;     active zone (e.g. log seed on boot before the player moves).
;     That's a legitimate gap, not a bug.
;
; Crash safety:
;   FileAppend is line-oriented (no in-memory accumulation), so
;   the worst case after a crash mid-write is a trailing partial
;   line. CsvFile.ReadAllRows skips rows with the wrong column
;   count, so a torn last line does not contaminate the load.
;   Atomic-write semantics (.tmp + FileMove) would force a full
;   rewrite on every append — overkill for an append-only log.

class DeathLogRepository
{
    static HEADER := ["ts", "zoneName", "patch", "profile"]
    static EXPECTED_COLUMNS := 4

    _path := ""
    _csv  := ""
    _warn := ""

    __New(path, sinkOrEmpty := "")
    {
        if (Trim(String(path)) = "")
            throw ValueError("DeathLogRepository: 'path' is required")
        this._path := path
        ; Parameter is `sinkOrEmpty` (not `warningSink`) to avoid the
        ; case-insensitive shadow of the WarningSink class — same
        ; convention as RunHistoryRepository.
        this._warn := WarningSink.Resolve(sinkOrEmpty)
        ; CsvFile.__New only validates the path string and ensures
        ; the parent directory exists. The actual file is created
        ; lazily by EnsureHeader on the first successful Append.
        this._csv  := CsvFile(path, DeathLogRepository.EXPECTED_COLUMNS)
    }

    GetPath() => this._path

    ; Records one death. ts defaults to now (FormatTime). Returns
    ; true on success, false on validation failure or I/O error.
    ;
    ; The empty-zone case is silent because it represents a real
    ; upstream gap (death fired before any ZoneChanged seeded the
    ; active zone) — warning every time would flood the log on
    ; certain boot orderings. The CR/LF case IS warned because
    ; that means upstream produced structurally broken text and
    ; we want it visible.
    Append(zoneName, patch, profile, ts := "")
    {
        zoneStr := String(zoneName)
        if (Trim(zoneStr) = "")
            return false
        if (InStr(zoneStr, "`r") > 0 || InStr(zoneStr, "`n") > 0)
        {
            this._warn.Warn("DeathLogRepository.Append rejected: zoneName contains CR/LF ('" zoneStr "')")
            return false
        }

        if (ts = "")
            ts := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")

        try
        {
            this._csv.EnsureHeader(DeathLogRepository.HEADER)
            this._csv.AppendRow([String(ts), zoneStr, String(patch), String(profile)])
            return true
        }
        catch as ex
        {
            this._warn.Warn("DeathLogRepository.Append failed for zone '" zoneStr "'", ex)
            return false
        }
    }

    ; Returns every recorded death as Array<Map>. Missing file →
    ; empty array (a fresh install has no deaths yet). Rows with
    ; wrong column count are skipped by CsvFile.ReadAllRows — a
    ; torn last line from a crash does not stop the load.
    LoadAll()
    {
        out := []
        try
        {
            for _, fields in this._csv.ReadAllRows()
            {
                if !IsObject(fields) || fields.Length < DeathLogRepository.EXPECTED_COLUMNS
                    continue
                out.Push(Map(
                    "ts",       fields[1],
                    "zoneName", fields[2],
                    "patch",    fields[3],
                    "profile",  fields[4]
                ))
            }
        }
        catch as ex
        {
            this._warn.Warn("DeathLogRepository.LoadAll failed", ex)
            return []
        }
        return out
    }
}
