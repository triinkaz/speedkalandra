; ============================================================
; Assert - asserções para os testes do SpeedKalandra
; ============================================================
;
; Toda asserção falha estourando AssertionFailed (extends Error).
; O TestRunner diferencia AssertionFailed (fail) de outros throws (errored).
;
; API publica:
;   Assert.True(actual, message := "")
;   Assert.False(actual, message := "")
;   Assert.Equal(expected, actual, message := "")        comparacao profunda
;   Assert.NotEqual(expected, actual, message := "")
;   Assert.Near(expected, actual, tolerance, message := "")
;   Assert.Contains(needle, haystack, message := "")     string ou array
;   Assert.IsType(expectedClass, actual, message := "")  usa `is`
;   Assert.Throws(expectedClass, fn, message := "")
;   Assert.Fail(message)
;
; Equal faz deep compare para Array e Map. Para outros objetos,
; cai em comparacao por referencia (==).
;
; Convencao de mensagem: Assert.Equal(esperado, observado, "contexto")
; — primeiro argumento eh sempre o esperado, segundo o observado.

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
        Assert._Throw("Esperava true, veio " Assert._Repr(actual), message)
    }

    static False(actual, message := "")
    {
        if (!actual)
            return
        Assert._Throw("Esperava false, veio " Assert._Repr(actual), message)
    }

    static Equal(expected, actual, message := "")
    {
        if (Assert._DeepEqual(expected, actual))
            return
        Assert._Throw(
            "Esperava " Assert._Repr(expected) ", veio " Assert._Repr(actual),
            message
        )
    }

    static NotEqual(expected, actual, message := "")
    {
        if (!Assert._DeepEqual(expected, actual))
            return
        Assert._Throw(
            "Esperava != " Assert._Repr(expected) ", mas eh igual",
            message
        )
    }

    static Near(expected, actual, tolerance, message := "")
    {
        if (!IsNumber(expected) || !IsNumber(actual) || !IsNumber(tolerance))
            Assert._Throw("Near exige numeros, veio expected=" Type(expected) " actual=" Type(actual), message)
        diff := Abs(expected - actual)
        if (diff <= tolerance)
            return
        Assert._Throw(
            "Esperava " expected " +- " tolerance ", veio " actual " (delta " diff ")",
            message
        )
    }

    static Contains(needle, haystack, message := "")
    {
        ; haystack pode ser string (InStr) ou array (linear search)
        if (haystack is Array)
        {
            for _, item in haystack
            {
                if (Assert._DeepEqual(needle, item))
                    return
            }
            Assert._Throw(
                "Array nao contem " Assert._Repr(needle) ": " Assert._Repr(haystack),
                message
            )
        }
        else if (Type(haystack) = "String")
        {
            if (InStr(haystack, needle))
                return
            Assert._Throw(
                "String nao contem " Assert._Repr(needle) ": " Assert._Repr(haystack),
                message
            )
        }
        else
        {
            Assert._Throw("Contains nao suporta haystack do tipo " Type(haystack), message)
        }
    }

    static IsType(expectedClass, actual, message := "")
    {
        if (actual is expectedClass)
            return
        actualType := IsObject(actual) ? Type(actual) : Type(actual)
        Assert._Throw(
            "Esperava instancia de " expectedClass.Prototype.__Class ", veio " actualType,
            message
        )
    }

    static Throws(expectedClass, fn, message := "")
    {
        ; BoundFunc e Closure sao subclasses de Func em AHK v2, entao
        ; `fn is Func` cobre os tres casos comuns. Outros callables
        ; (Class constructors, objetos com __Call) devem ser wrappeados
        ; numa arrow funcao antes de serem passados aqui.
        if (!IsObject(fn) || !(fn is Func))
            Assert._Throw("Throws exige callable (Func/Closure/BoundFunc), veio " Type(fn), message)
        try
        {
            fn()
        }
        catch as e
        {
            if (e is expectedClass)
                return
            Assert._Throw(
                "Esperava throw de " expectedClass.Prototype.__Class
                . ", veio " Type(e) ": " e.Message,
                message
            )
        }
        Assert._Throw(
            "Esperava throw de " expectedClass.Prototype.__Class ", nao houve throw",
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
        ; Primitivos: ambos nao-objeto
        if (!IsObject(a) && !IsObject(b))
            return a == b

        ; Misto: objeto vs primitivo
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

        ; Tipos diferentes (Array vs Map etc) ou objetos custom
        ; Para objetos custom, comparamos por referencia.
        ; Asserts que comparem objetos custom devem usar getters
        ; ou propriedades em vez de comparar a instancia inteira.
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
