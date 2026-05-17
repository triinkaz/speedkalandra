; ============================================================
; WindowState tests
; ============================================================
;
; Covers the minimalist WindowState value object (microLocked,
; steveLocked). Small surface area, but validates bool coercions
; and ToMap roundtrip.

class WindowStateTests extends TestCase
{
    static Tests := [
        "defaults_both_locks_are_false",
        "from_map_reads_micro_locked_true",
        "from_map_reads_steve_locked_true",
        "from_map_reads_both_locks",
        "from_map_coerces_string_one_to_true",
        "from_map_coerces_string_zero_to_false",
        "from_map_uses_default_when_key_missing",
        "from_map_throws_type_error_on_non_object",
        "to_map_roundtrip",
    ]

    defaults_both_locks_are_false()
    {
        ws := WindowState.Defaults()
        Assert.False(ws.microLocked)
        Assert.False(ws.steveLocked)
    }

    from_map_reads_micro_locked_true()
    {
        ws := WindowState.FromMap(Map("microLocked", true))
        Assert.True(ws.microLocked)
        Assert.False(ws.steveLocked)
    }

    from_map_reads_steve_locked_true()
    {
        ws := WindowState.FromMap(Map("steveLocked", true))
        Assert.True(ws.steveLocked)
        Assert.False(ws.microLocked)
    }

    from_map_reads_both_locks()
    {
        ws := WindowState.FromMap(Map("microLocked", true, "steveLocked", true))
        Assert.True(ws.microLocked)
        Assert.True(ws.steveLocked)
    }

    from_map_coerces_string_one_to_true()
    {
        ws := WindowState.FromMap(Map("microLocked", "1"))
        Assert.True(ws.microLocked)
    }

    from_map_coerces_string_zero_to_false()
    {
        ws := WindowState.FromMap(Map("microLocked", "0"))
        Assert.False(ws.microLocked)
    }

    from_map_uses_default_when_key_missing()
    {
        ws := WindowState.FromMap(Map())
        Assert.False(ws.microLocked)
        Assert.False(ws.steveLocked)
    }

    from_map_throws_type_error_on_non_object()
    {
        Assert.Throws(TypeError, () => WindowState.FromMap("not a map"))
        Assert.Throws(TypeError, () => WindowState.FromMap(42))
    }

    to_map_roundtrip()
    {
        ws := WindowState()
        ws.microLocked := true
        ws.steveLocked := false
        m := ws.ToMap()

        Assert.Equal(true,  m["microLocked"])
        Assert.Equal(false, m["steveLocked"])

        ; Roundtrip: ToMap -> FromMap should preserve
        ws2 := WindowState.FromMap(m)
        Assert.Equal(ws.microLocked, ws2.microLocked)
        Assert.Equal(ws.steveLocked, ws2.steveLocked)
    }
}

TestRegistry.Register(WindowStateTests)
