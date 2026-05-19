; ============================================================
; GameProcesses tests
; ============================================================
;
; Locks the single-source-of-truth contract for the PoE2
; executable list. Two services (FocusAutoPauseService,
; LoadingDetectionService) match against this list at runtime;
; a regression that drops an entry breaks one or both at the
; moment a new PoE2 build ships.
;
; These tests are intentionally minimal -- the value of the
; constant lives in being a single shared array, not in any
; transformation of it. Sanity assertions (well-formed entries,
; presence of canonical builds) catch the most likely
; regressions: someone editing the list and accidentally
; dropping an entry, or replacing it with an empty array.

class GameProcessesTests extends TestCase
{
    static Tests := [
        "list_is_non_empty",
        "every_entry_ends_in_dot_exe",
        "every_entry_is_a_non_empty_string",
        "no_duplicate_entries",
        "includes_canonical_standalone_build",
        "includes_canonical_steam_build"
    ]

    list_is_non_empty()
    {
        Assert.True(GameProcesses.POE2_EXECUTABLES.Length > 0,
            "POE2_EXECUTABLES must have at least one entry")
    }

    every_entry_ends_in_dot_exe()
    {
        ; ahk_exe matches the process image name, which on Windows
        ; always carries the .exe extension. An entry without it
        ; would silently never match anything. SubStr with a
        ; negative StartingPos counts from the end: -4 yields the
        ; last four chars (".exe").
        for _, name in GameProcesses.POE2_EXECUTABLES
        {
            Assert.True(SubStr(name, -4) = ".exe",
                "Entry '" name "' must end in .exe")
        }
    }

    every_entry_is_a_non_empty_string()
    {
        for _, name in GameProcesses.POE2_EXECUTABLES
        {
            Assert.Equal("String", Type(name),
                "Entry must be a String, got " Type(name))
            Assert.True(StrLen(name) > 0,
                "Entry must be a non-empty string")
        }
    }

    no_duplicate_entries()
    {
        ; Duplicates wouldn't break behavior (the for-loops short-
        ; circuit on first match), but they're a sign of a sloppy
        ; edit that may have intended to add a new entry and ended
        ; up duplicating an existing one.
        seen := Map()
        for _, name in GameProcesses.POE2_EXECUTABLES
        {
            Assert.False(seen.Has(name),
                "Duplicate entry: '" name "'")
            seen[name] := true
        }
    }

    includes_canonical_standalone_build()
    {
        ; The standalone (non-Steam) 64-bit PoE2 executable -- the
        ; build most users on the standalone launcher run today.
        ; If this disappears, focus auto-pause stops working for
        ; that population without any warning.
        Assert.True(this._contains("PathOfExile2_x64.exe"),
            "POE2_EXECUTABLES must include the canonical standalone build")
    }

    includes_canonical_steam_build()
    {
        ; The Steam-distributed 64-bit PoE1 executable, currently
        ; the launcher path for PoE2 EA on Steam. Same reasoning
        ; as the standalone canonical entry -- losing this is a
        ; silent break for the Steam population.
        Assert.True(this._contains("PathOfExile_x64Steam.exe"),
            "POE2_EXECUTABLES must include the canonical Steam build")
    }

    _contains(needle)
    {
        for _, name in GameProcesses.POE2_EXECUTABLES
        {
            if (name = needle)
                return true
        }
        return false
    }
}

TestRegistry.Register(GameProcessesTests)
