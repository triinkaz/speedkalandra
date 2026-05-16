; ============================================================
; NullLogger tests
; ============================================================
;
; NullLogger e' um stub no-op. Os testes garantem apenas que:
;   - Todos os metodos de log retornam 0 sem efeitos colaterais
;   - Counters sempre zero
;   - Flush/ResetCounts nao estouram
;
; Existe pra duck-typing com LogService e para uso em testes que
; nao querem inspecionar log (a maioria deles).

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
        ; Sanity check de assinatura - se algum metodo nao aceitar
        ; o 2o arg, isso estoura.
        nullLog := NullLogger()
        nullLog.Debug("msg", "Ctx")
        nullLog.Info("msg",  "Ctx")
        nullLog.Warn("msg",  "Ctx")
        nullLog.Error("msg", "Ctx")
        Assert.True(true)   ; chegou ate aqui
    }
}

TestRegistry.Register(NullLoggerTests)
