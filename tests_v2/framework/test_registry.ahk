; ============================================================
; TestRegistry - registry of test classes
; ============================================================
;
; Each test file, at the end, calls:
;   TestRegistry.Register(MySuite)
;
; This populates an array that the TestRunner consumes at run time.
;
; Why an explicit registry and not auto-discovery by name?
; - AHK v2 has no enumeration of subclasses derived from a base.
; - Auto-discovery by name (scanning symbols by "Test" prefix) would
;   be worse ergonomically and would miss classes with off-pattern names.
; - Explicit is visible in the diff and impossible to "accidentally" forget.

class TestRegistry
{
    static Classes := []

    static Register(cls)
    {
        if (!IsObject(cls))
            throw TypeError("TestRegistry.Register: argument is not a class")
        if (!cls.HasOwnProp("Tests"))
            throw ValueError("TestCase '" cls.Prototype.__Class "' missing static Tests array")
        if (!(cls.Tests is Array))
            throw TypeError("TestCase '" cls.Prototype.__Class "': static Tests must be Array")
        TestRegistry.Classes.Push(cls)

        ; CI diagnostic: a previous run died between the boot header
        ; and TestReporter.Init() with no error logged. Recording each
        ; successful registration in the boot log lets us see exactly
        ; which test file is the last one parsed/loaded — if the next
        ; one fails (parse or static-init crash), the missing entry
        ; names the file. Cost is ~50 short writes per run.
        try FileAppend("REG: " cls.Prototype.__Class "`n",
            A_ScriptDir "\tests_boot.log", "UTF-8")
    }

    static Reset()
    {
        TestRegistry.Classes := []
    }
}
