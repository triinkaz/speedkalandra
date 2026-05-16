; ============================================================
; InMemoryLogger tests
; ============================================================
;
; InMemoryLogger captura logs em memoria pra assertion. Eh o logger
; de escolha quando o teste precisa verificar que algo foi logado
; (geralmente erros isolados pelo EventBus, warnings de validacao,
; etc).
;
; API testada:
;   - Debug/Info/Warn/Error -> entries.Push(Map(level, msg, context, ts))
;   - GetWarnCount / GetErrorCount -> filtram por level
;   - HasEntry(level)             -> existencia
;   - HasEntry(level, substring)  -> existencia + substring no msg
;   - Clear / ResetCounts         -> esvaziam entries

class InMemoryLoggerTests extends TestCase
{
    memLog := ""

    Setup()
    {
        this.memLog := InMemoryLogger()
    }

    static Tests := [
        "starts_with_empty_entries",
        "captures_each_log_call_in_entries_array",
        "entry_contains_level_msg_context_ts",
        "entry_with_no_context_has_empty_context_field",
        "has_entry_matches_by_level_only",
        "has_entry_matches_by_level_and_substring",
        "has_entry_returns_false_when_no_entries",
        "has_entry_returns_false_when_level_mismatches",
        "has_entry_returns_false_when_substring_not_found",
        "get_warn_count_filters_by_level",
        "get_error_count_filters_by_level",
        "clear_empties_entries_array",
        "reset_counts_clears_all_entries",
    ]

    starts_with_empty_entries()
    {
        Assert.Equal(0, this.memLog.entries.Length)
        Assert.Equal(0, this.memLog.GetWarnCount())
        Assert.Equal(0, this.memLog.GetErrorCount())
    }

    captures_each_log_call_in_entries_array()
    {
        this.memLog.Debug("d")
        this.memLog.Info("i")
        this.memLog.Warn("w")
        this.memLog.Error("e")
        Assert.Equal(4, this.memLog.entries.Length)
    }

    entry_contains_level_msg_context_ts()
    {
        this.memLog.Warn("hello world", "MyCtx")
        entry := this.memLog.entries[1]

        Assert.Equal("WARN",        entry["level"])
        Assert.Equal("hello world", entry["msg"])
        Assert.Equal("MyCtx",       entry["context"])
        ; ts vem de A_Now: YYYYMMDDHH24MISS = 14 chars
        Assert.Equal(14, StrLen(entry["ts"]))
    }

    entry_with_no_context_has_empty_context_field()
    {
        this.memLog.Info("just msg")
        entry := this.memLog.entries[1]
        Assert.Equal("", entry["context"])
    }

    has_entry_matches_by_level_only()
    {
        this.memLog.Info("anything")
        Assert.True(this.memLog.HasEntry("INFO"))
        Assert.False(this.memLog.HasEntry("WARN"))
    }

    has_entry_matches_by_level_and_substring()
    {
        this.memLog.Warn("the cake is a lie")
        Assert.True(this.memLog.HasEntry("WARN",  "cake"))
        Assert.True(this.memLog.HasEntry("WARN",  "lie"))
        Assert.False(this.memLog.HasEntry("INFO", "cake"))
    }

    has_entry_returns_false_when_no_entries()
    {
        Assert.False(this.memLog.HasEntry("INFO"))
        Assert.False(this.memLog.HasEntry("ERROR", "anything"))
    }

    has_entry_returns_false_when_level_mismatches()
    {
        this.memLog.Info("specific text")
        Assert.False(this.memLog.HasEntry("WARN", "specific text"))
    }

    has_entry_returns_false_when_substring_not_found()
    {
        this.memLog.Warn("foo bar baz")
        Assert.False(this.memLog.HasEntry("WARN", "qux"))
    }

    get_warn_count_filters_by_level()
    {
        this.memLog.Warn("w1")
        this.memLog.Info("i1")
        this.memLog.Warn("w2")
        this.memLog.Error("e1")
        Assert.Equal(2, this.memLog.GetWarnCount())
    }

    get_error_count_filters_by_level()
    {
        this.memLog.Warn("w1")
        this.memLog.Error("e1")
        this.memLog.Error("e2")
        Assert.Equal(2, this.memLog.GetErrorCount())
    }

    clear_empties_entries_array()
    {
        this.memLog.Info("a")
        this.memLog.Info("b")
        this.memLog.Clear()
        Assert.Equal(0, this.memLog.entries.Length)
        Assert.False(this.memLog.HasEntry("INFO"))
    }

    reset_counts_clears_all_entries()
    {
        ; Implementacao atual: ResetCounts() => this.Clear()
        ; Verificamos esse contrato.
        this.memLog.Warn("w")
        this.memLog.Error("e")
        Assert.Equal(1, this.memLog.GetWarnCount())

        this.memLog.ResetCounts()

        Assert.Equal(0, this.memLog.GetWarnCount())
        Assert.Equal(0, this.memLog.GetErrorCount())
        Assert.Equal(0, this.memLog.entries.Length,
            "ResetCounts limpa entries (alias para Clear)")
    }
}

TestRegistry.Register(InMemoryLoggerTests)
