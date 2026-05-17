; ============================================================
; TestRunner - orchestrates execution of the registered tests
; ============================================================
;
; For each class in TestRegistry.Classes:
;   For each method in cls.Tests:
;     1. Instantiate cls() fresh
;     2. Call instance.Setup() if it exists
;     3. Call instance.<method>()
;     4. Call instance.Teardown() if it exists (always, even after throw)
;     5. Classify the result:
;          throw AssertionFailed     -> failed
;          throw anything else       -> errored
;          no throw                  -> passed
;
; argv filter:
;   AutoHotkey64.exe run_tests.ahk EventBus
;   only runs tests whose "ClassName::method" contains "EventBus".
;   Useful for fast iteration during development.
;
; A "fail-fast" strategy is NOT adopted by default: the runner finishes
; the whole suite and reports at the end. A failed test does not stop
; the rest.

class TestRunner
{
    static Run()
    {
        results := {
            passed:   0,
            failed:   0,
            errored:  0,
            failures: []
        }

        filter := A_Args.Length > 0 ? A_Args[1] : ""

        for _, cls in TestRegistry.Classes
        {
            className := cls.Prototype.__Class
            tests     := cls.Tests
            reported  := false

            for _, methodName in tests
            {
                fullName := className "::" methodName

                if (filter != "" && !InStr(fullName, filter))
                    continue

                if (!reported)
                {
                    TestReporter.SuiteStart(className, tests.Length)
                    reported := true
                }

                outcome := TestRunner._RunOne(cls, methodName, fullName)

                switch outcome.kind
                {
                    case "pass":
                        results.passed += 1
                        TestReporter.Pass(methodName)
                    case "fail":
                        results.failed += 1
                        TestReporter.Fail(methodName, outcome.err)
                        results.failures.Push({ name: fullName, err: outcome.err })
                    case "error":
                        results.errored += 1
                        TestReporter.Error(methodName, outcome.err)
                        results.failures.Push({ name: fullName, err: outcome.err })
                }
            }
        }

        TestReporter.Summary(results)
    }

    static _RunOne(cls, methodName, fullName)
    {
        try
        {
            instance := cls()
        }
        catch as e
        {
            return { kind: "error", err: e }
        }

        ; Setup
        try
        {
            if (instance.HasMethod("Setup"))
                instance.Setup()
        }
        catch as e
        {
            TestRunner._SafeTeardown(instance)
            return { kind: "error", err: e }
        }

        ; The test itself
        testOutcome := ""
        try
        {
            if (!instance.HasMethod(methodName))
                throw MethodError("TestCase '" cls.Prototype.__Class
                    "' has no method '" methodName "' (but it's listed in static Tests)")

            instance.%methodName%()
            testOutcome := { kind: "pass" }
        }
        catch as e
        {
            if (e is AssertionFailed)
                testOutcome := { kind: "fail", err: e }
            else
                testOutcome := { kind: "error", err: e }
        }

        ; Teardown always (even after failure) - best effort, swallowed
        TestRunner._SafeTeardown(instance)

        return testOutcome
    }

    static _SafeTeardown(instance)
    {
        try
        {
            if (instance.HasMethod("Teardown"))
                instance.Teardown()
        }
        catch
        {
            ; silent - a failing teardown must not mask the test's error
        }
    }
}
