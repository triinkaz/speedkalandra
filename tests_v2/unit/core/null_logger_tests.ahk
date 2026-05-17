; ============================================================
; NullLogger tests
; ============================================================
;
; NullLogger is a no-op stub. The tests only ensure that:
;   - All log methods return 0 with no side effects
;   - Counters are always zero
;   - Flush/ResetCounts do not throw
;
; It exists for duck-typing with LogService and for use in tests
; that don't want to inspect the log (most of them).

class NullLoggerTests extends TestCase
{
    static Tests := [
        "log_methods_all_return_zero",
        "counters_always_return_zero",
        "flush_and_reset_counts_are_noop_and_do_not_throw",
        "methods_accept_optional_context_arg",
    ]

    log_methods_all_return_zero()
    {
        nullLog := NullLogger()
        Assert.Equal(0, nullLog.Debug("x"))
        Assert.Equal(0, nullLog.Info("x"))
        Assert.Equal(0, nullLog.Warn("x"))
        Assert.Equal(0, nullLog.Error("x"))
    }

    counters_always_return_zero()
    {
        nullLog := NullLogger()
        Assert.Equal(0, nullLog.GetWarnCount())
        Assert.Equal(0, nullLog.GetErrorCount())
        nullLog.Warn("ignored")
        nullLog.Error("ignored too")
        Assert.Equal(0, nullLog.GetWarnCount())
        Assert.Equal(0, nullLog.GetErrorCount())
    }

    flush_and_reset_counts_are_noop_and_do_not_throw()
    {
        nullLog := NullLogger()
        nullLog.Flush()
        nullLog.ResetCounts()
        Assert.Equal(0, nullLog.GetWarnCount())
    }

    methods_accept_optional_context_arg()
    {
        ; Signature sanity check - if any method doesn't accept the
        ; 2nd arg, this throws.
        nullLog := NullLogger()
        nullLog.Debug("msg", "Ctx")
        nullLog.Info("msg",  "Ctx")
        nullLog.Warn("msg",  "Ctx")
        nullLog.Error("msg", "Ctx")
        Assert.True(true)   ; reached here
    }
}

TestRegistry.Register(NullLoggerTests)
