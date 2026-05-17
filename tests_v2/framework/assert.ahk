; ============================================================
; Assert - assertions for the SpeedKalandra tests
; ============================================================
;
; Every failed assertion throws AssertionFailed (extends Error).
; The TestRunner distinguishes AssertionFailed (fail) from other throws (errored).
;
; Public API:
;   Assert.True(actual, message := "")
;   Assert.False(actual, message := "")
;   Assert.Equal(expected, actual, message := "")        deep comparison
;   Assert.NotEqual(expected, actual, message := "")
;   Assert.Near(expected, actual, tolerance, message := "")
;   Assert.Contains(needle, haystack, message := "")     string or array
;   Assert.IsType(expectedClass, actual, message := "")  uses `is`
;   Assert.Throws(expectedClass, fn, message := "")
;   Assert.Fail(message)
;
; Equal does deep compare for Array and Map. For other objects,
; falls back to reference comparison (==).
;
; Message convention: Assert.Equal(expected, observed, "context")
; — the first argument is always the expected one, the second is observed.

class AssertionFailed extends Error
{
    __New(message)
    {
        super.__New(message)
        this.What := "AssertionFailed"
    }
}

class Assert
{
    static True(actual, message := "")
    {
        if (actual)
            return
        Assert._Throw("Expected true, got " Assert._Repr(actual), message)
    }

    static False(actual, message := "")
    {
        if (!actual)
            return
        Assert._Throw("Expected false, got " Assert._Repr(actual), message)
    }

    static Equal(expected, actual, message := "")
    {
        if (Assert._DeepEqual(expected, actual))
            return
        Assert._Throw(
            "Expected " Assert._Repr(expected) ", got " Assert._Repr(actual),
            message
        )
    }

    static NotEqual(expected, actual, message := "")
    {
        if (!Assert._DeepEqual(expected, actual))
            return
        Assert._Throw(
            "Expected != " Assert._Repr(expected) ", but it's equal",
            message
        )
    }

    static Near(expected, actual, tolerance, message := "")
    {
        if (!IsNumber(expected) || !IsNumber(actual) || !IsNumber(tolerance))
            Assert._Throw("Near requires numbers, got expected=" Type(expected) " actual=" Type(actual), message)
        diff := Abs(expected - actual)
        if (diff <= tolerance)
            return
        Assert._Throw(
            "Expected " expected " +- " tolerance ", got " actual " (delta " diff ")",
            message
        )
    }

    static Contains(needle, haystack, message := "")
    {
        ; haystack can be a string (InStr) or an array (linear search)
        if (haystack is Array)
        {
            for _, item in haystack
            {
                if (Assert._DeepEqual(needle, item))
                    return
            }
            Assert._Throw(
                "Array does not contain " Assert._Repr(needle) ": " Assert._Repr(haystack),
                message
            )
        }
        else if (Type(haystack) = "String")
        {
            if (InStr(haystack, needle))
                return
            Assert._Throw(
                "String does not contain " Assert._Repr(needle) ": " Assert._Repr(haystack),
                message
            )
        }
        else
        {
            Assert._Throw("Contains does not support haystack of type " Type(haystack), message)
        }
    }

    static IsType(expectedClass, actual, message := "")
    {
        if (actual is expectedClass)
            return
        actualType := IsObject(actual) ? Type(actual) : Type(actual)
        Assert._Throw(
            "Expected instance of " expectedClass.Prototype.__Class ", got " actualType,
            message
        )
    }

    static Throws(expectedClass, fn, message := "")
    {
        ; BoundFunc and Closure are subclasses of Func in AHK v2, so
        ; `fn is Func` covers the three common cases. Other callables
        ; (Class constructors, objects with __Call) should be wrapped
        ; in an arrow function before being passed here.
        if (!IsObject(fn) || !(fn is Func))
            Assert._Throw("Throws requires callable (Func/Closure/BoundFunc), got " Type(fn), message)
        try
        {
            fn()
        }
        catch as e
        {
            if (e is expectedClass)
                return
            Assert._Throw(
                "Expected throw of " expectedClass.Prototype.__Class
                . ", got " Type(e) ": " e.Message,
                message
            )
        }
        Assert._Throw(
            "Expected throw of " expectedClass.Prototype.__Class ", no throw occurred",
            message
        )
    }

    static Fail(message)
    {
        Assert._Throw("Fail()", message)
    }

    ; ============================================================
    ; Internals
    ; ============================================================

    static _Throw(detail, userMessage)
    {
        full := detail
        if (userMessage != "")
            full .= " | " userMessage
        throw AssertionFailed(full)
    }

    static _DeepEqual(a, b)
    {
        ; Primitives: both non-object
        if (!IsObject(a) && !IsObject(b))
            return a == b

        ; Mixed: object vs primitive
        if (!IsObject(a) || !IsObject(b))
            return false

        ; Array vs Array
        if (a is Array && b is Array)
        {
            if (a.Length != b.Length)
                return false
            Loop a.Length
            {
                if (!Assert._DeepEqual(a[A_Index], b[A_Index]))
                    return false
            }
            return true
        }

        ; Map vs Map
        if (a is Map && b is Map)
        {
            if (a.Count != b.Count)
                return false
            for k, v in a
            {
                if (!b.Has(k))
                    return false
                if (!Assert._DeepEqual(v, b[k]))
                    return false
            }
            return true
        }

        ; Different types (Array vs Map etc) or custom objects.
        ; For custom objects, we compare by reference. Asserts that
        ; compare custom objects should use getters or properties
        ; instead of comparing the whole instance.
        return a == b
    }

    static _Repr(value)
    {
        if (!IsObject(value))
        {
            if (Type(value) = "String")
                return '"' value '"'
            return String(value)
        }

        if (value is Array)
        {
            items := []
            for _, v in value
                items.Push(Assert._Repr(v))
            return "[" Assert._Join(items, ", ") "]"
        }

        if (value is Map)
        {
            pairs := []
            for k, v in value
                pairs.Push(Assert._Repr(k) ": " Assert._Repr(v))
            return "Map(" Assert._Join(pairs, ", ") ")"
        }

        return "<" Type(value) ">"
    }

    static _Join(arr, sep)
    {
        s := ""
        for i, v in arr
        {
            if (i > 1)
                s .= sep
            s .= v
        }
        return s
    }
}
