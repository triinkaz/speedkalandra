; ============================================================
; TestReporter - saida formatada do resultado dos testes
; ============================================================
;
; Trilha:
;   - Arquivo  tests_output.log  ao lado de run_tests.ahk
;     (linha-a-linha, greppable, persiste entre runs)
;   - MsgBox final com sumario (passed/failed/errored + duracao)
;   - ExitApp(N) onde N = failed + errored (0 = tudo verde)
;
; AHK v2 nao tem stdout confiavel sem AllocConsole. O log file
; cobre o caso CI / inspecao posterior, o MsgBox cobre dev local.

class TestReporter
{
    static _logPath  := ""
    static _started  := 0     ; A_TickCount no inicio

    static Init()
    {
        TestReporter._logPath := A_ScriptDir "\tests_output.log"
        TestReporter._started := A_TickCount

        if FileExist(TestReporter._logPath)
        {
            try FileDelete(TestReporter._logPath)
        }

        TestReporter._Write("=== SpeedKalandra Test Run @ "
            FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " ===")
        TestReporter._Write("")
    }

    static SuiteStart(className, testCount)
    {
        TestReporter._Write("--- " className " (" testCount " tests)")
    }

    static Pass(name)
    {
        TestReporter._Write("  [PASS] " name)
    }

    static Fail(name, err)
    {
        TestReporter._Write("  [FAIL] " name)
        TestReporter._Write("         " err.Message)
        if (err.HasOwnProp("File") && err.File != "")
            TestReporter._Write("         at " err.File ":" (err.HasOwnProp("Line") ? err.Line : "?"))
    }

    static Error(name, err)
    {
        TestReporter._Write("  [ERR ] " name)
        TestReporter._Write("         " Type(err) ": " err.Message)
        if (err.HasOwnProp("File") && err.File != "")
            TestReporter._Write("         at " err.File ":" (err.HasOwnProp("Line") ? err.Line : "?"))
        if (err.HasOwnProp("Stack") && err.Stack != "")
        {
            ; Imprime stack indentado (algumas linhas no maximo)
            for _, stackLine in StrSplit(err.Stack, "`n", "`r")
            {
                if (stackLine = "")
                    continue
                TestReporter._Write("         " stackLine)
            }
        }
    }

    static Summary(results)
    {
        durationMs := A_TickCount - TestReporter._started
        total := results.passed + results.failed + results.errored
        bad   := results.failed + results.errored

        TestReporter._Write("")
        TestReporter._Write("=== Summary ===")
        TestReporter._Write(Format("Total:    {1}", total))
        TestReporter._Write(Format("Passed:   {1}", results.passed))
        TestReporter._Write(Format("Failed:   {1}", results.failed))
        TestReporter._Write(Format("Errored:  {1}", results.errored))
        TestReporter._Write(Format("Duration: {1} ms", durationMs))

        if (results.failures.Length > 0)
        {
            TestReporter._Write("")
            TestReporter._Write("=== Failures recap ===")
            for _, f in results.failures
                TestReporter._Write("  - " f.name)
        }

        title := bad > 0
            ? "Tests FAILED (" bad "/" total ")"
            : "Tests OK (" total " passed)"

        body := Format(
            "Passed:   {1}`nFailed:   {2}`nErrored:  {3}`n`nDuration: {4} ms`n`nLog: {5}",
            results.passed, results.failed, results.errored,
            durationMs, TestReporter._logPath
        )

        ; MsgBox simples (sem AlwaysOnTop pra nao herdar problemas
        ; de overlay quando rodar testes com PoE aberto)
        MsgBox(body, title)

        ExitApp(bad > 0 ? 1 : 0)
    }

    static _Write(line)
    {
        try FileAppend(line "`n", TestReporter._logPath, "UTF-8")
    }
}
