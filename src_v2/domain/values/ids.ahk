; ============================================================
; Ids — validators for typed identifiers
; ============================================================
;
; Instead of creating a wrapping class for each id type (overhead in
; AHK v2 without bringing real benefit since we have no type-checking),
; we expose classes with static IsValid/MustBeValid methods.
;
; Usage:
;   StepId.IsValid(id)        ; bool
;   StepId.MustBeValid(id)    ; throws if invalid, returns id itself
;
; Accepted patterns:
;
; StepId: <act>_<NN>_<slug>
;   - act: lowercase letters and digits, starting with a letter
;     Examples: a1, a2, ..., a9, interlude, endgame, custom_xyz
;   - NN: 2 numeric digits (01..99)
;   - slug: lowercase, digits, underscores
;   Valid examples: a1_01_riverbank_miller, interlude_01_placeholder_start
;
; RunId: YYYYMMDD_HHMMSS
;   - 8 digits for the day + underscore + 6 digits for the time
;   Example: 20260425_072055
;   Optionally accepts a "_<token>" suffix for legacy cases where the
;   profile was appended: 20260425_072055_Default
;
; ProfileId: non-empty string with no leading/trailing whitespace.
;   Example: "Glacial Cascade/Wind Blast" (spaces and slashes OK)


class StepId
{
    ; Pattern compatible with all legacy ids:
    ;   a1_01_*, a2_15_*, interlude_01_*, endgame_01_*, custom_99_*
    static _PATTERN := "^[a-z][a-z0-9]*_\d{2}_[a-z0-9_]+$"

    static IsValid(id)
    {
        ; (id = "") implies StrLen=0; a single check is enough.
        if (id = "")
            return false
        return RegExMatch(id, StepId._PATTERN) > 0
    }

    static MustBeValid(id, context := "")
    {
        if !StepId.IsValid(id)
            throw ValueError("Invalid StepId: '" id "'" (context != "" ? " (" context ")" : ""))
        return id
    }
}


class RunId
{
    ; YYYYMMDD_HHMMSS
    ; The optional `(_[a-zA-Z0-9_-]+)?` group exists only for back-compat:
    ; old runs had the profile name appended to runId
    ; (e.g. '20260425_072055_Default'). Generate() below NEVER creates a suffix.
    static _PATTERN := "^\d{8}_\d{6}(_[a-zA-Z0-9_-]+)?$"

    static IsValid(id)
    {
        if (id = "")
            return false
        return RegExMatch(id, RunId._PATTERN) > 0
    }

    static MustBeValid(id, context := "")
    {
        if !RunId.IsValid(id)
            throw ValueError("Invalid RunId: '" id "'" (context != "" ? " (" context ")" : ""))
        return id
    }

    ; Generates a new runId from the clock. Format: YYYYMMDD_HHMMSS
    ; clock.Now() returns YYYYMMDDHHmmss (14 chars). We insert '_'
    ; between date and time.
    static Generate(clock)
    {
        if !IsObject(clock) || !clock.HasMethod("Now")
            throw TypeError("RunId.Generate: 'clock' must have a Now() method")
        nowStr := clock.Now()
        if (StrLen(nowStr) < 14)
            throw ValueError("RunId.Generate: clock.Now() returned an invalid string: '" nowStr "'")
        return SubStr(nowStr, 1, 8) "_" SubStr(nowStr, 9, 6)
    }
}


class ProfileId
{
    static IsValid(id)
    {
        if (id = "")
            return false
        if (Trim(id) != id)
            return false
        return true
    }

    static MustBeValid(id, context := "")
    {
        if !ProfileId.IsValid(id)
            throw ValueError("Invalid ProfileId: '" id "'" (context != "" ? " (" context ")" : ""))
        return id
    }
}
