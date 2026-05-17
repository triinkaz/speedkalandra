; ============================================================
; TestReporter - formatted output for test results
; ============================================================
;
; Trail:
;   - File  tests_output.log  next to run_tests.ahk
;     (line-by-line, greppable, persists between runs)
;   - Final MsgBox with summary (passed/failed/errored + duration)
;   - ExitApp(N) where N = failed + errored (0 = all green)
;
; AHK v2 has no reliable stdout without AllocConsole. The log file
; covers the CI / post-inspection case, the MsgBox covers local dev.

class TestReporter
{
    static _logPath  := ""
    static _started  := 0     ; A_TickCount at start

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
            ; Prints stack indented (a few lines at most)
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

        ; Simple MsgBox (no AlwaysOnTop to avoid inheriting overlay
        ; issues when running tests with PoE open)
        MsgBox(body, title)

        ExitApp(bad > 0 ? 1 : 0)
    }

    static _Write(line)
    {
        try FileAppend(line "`n", TestReporter._logPath, "UTF-8")
    }
}
