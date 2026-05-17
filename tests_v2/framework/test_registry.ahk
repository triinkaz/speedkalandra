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
    }

    static Reset()
    {
        TestRegistry.Classes := []
    }
}
