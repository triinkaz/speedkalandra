; ============================================================
; TestRunner - orquestra execucao dos testes registrados
; ============================================================
;
; Para cada classe em TestRegistry.Classes:
;   Para cada metodo em cls.Tests:
;     1. Instancia cls() do zero
;     2. Chama instance.Setup() se existir
;     3. Chama instance.<metodo>()
;     4. Chama instance.Teardown() se existir (sempre, mesmo apos throw)
;     5. Classifica resultado:
;          throw AssertionFailed     -> failed
;          throw qualquer outro      -> errored
;          sem throw                 -> passed
;
; Filtro por argv:
;   AutoHotkey64.exe run_tests.ahk EventBus
;   roda apenas testes cuja "ClassName::method" contenha "EventBus".
;   Util pra iteracao rapida durante desenvolvimento.
;
; Estrategia "fail-fast" NAO eh adotada por padrao: o runner termina
; toda a suite e reporta no fim. Falha em um teste nao para o resto.

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

        ; Teste em si
        testOutcome := ""
        try
        {
            if (!instance.HasMethod(methodName))
                throw MethodError("TestCase '" cls.Prototype.__Class
                    "' nao tem metodo '" methodName "' (mas esta listado em static Tests)")

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

        ; Teardown sempre (mesmo apos falha) - best effort, swallowed
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
            ; silencioso - teardown que falha nao deve mascarar o erro do teste
        }
    }
}
