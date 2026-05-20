; ============================================================
; JsonFile — JSON file writing
; ============================================================
;
; Mirrors CsvFile/IniFile: instance-based with path in the constructor.
;
; PHILOSOPHY:
;   - Write first; reading was added later for re-importing exported
;     runs.
;   - Pretty-print by default (indent=2 spaces) — UX prioritizes
;     manual inspection in a text editor.
;   - Always UTF-8 encoding (consistent with CsvFile).
;
; SUPPORTED TYPES in the input value:
;   - String  -> JSON string with escapes (")
;   - Number  -> JSON number literal (no quotes)
;   - JsonBool(true|false) -> JSON true|false (native boolean)
;   - JsonNull() -> JSON null
;   - Map     -> JSON object {...}
;   - Array   -> JSON array [...]
;
; BOOLEAN CONVENTION:
;   AHK v2 treats `true` as 1 and `false` as 0. There is no distinction
;   between "1 number" vs "true boolean". To serialize an explicit
;   bool as `true`/`false`, use the `JsonBool(value)` wrapper.
;   Otherwise, numeric values become JSON numbers (1, 0).
;
; CONSTRUCTION:
;   jf := JsonFile(path)
;
; USAGE:
;   jf.Write(Map("name", "Run1", "active", JsonBool(true)))
;   ; Result on disk:
;   ; {
;   ;   "name": "Run1",
;   ;   "active": true
;   ; }
;
; STATIC HELPERS:
;   JsonFile.Stringify(value, indent := 2) -> JSON string
;   JsonFile.EscapeString(s) -> escaped string (without quotes)


class JsonNull
{
    ; Marker class — no fields, no methods. Usage:
    ;   Map("key", JsonNull())  ->  "key": null
}


class JsonBool
{
    value := false
    __New(v)
    {
        this.value := !!v
    }
}


class JsonFile
{
    _path := ""

    __New(path)
    {
        if (Trim(String(path)) = "")
            throw ValueError("JsonFile: 'path' is required")
        this._path := path
    }

    GetPath() => this._path

    ; Write(value, indent := 2) — serializes value and writes to path.
    ; Overwrites file completely (no append). UTF-8.
    ; Refactor R10: uses AtomicWriter to avoid corruption on crash
    ; between FileDelete and FileAppend (visible gap where the file
    ; would disappear).
    Write(value, indent := 2)
    {
        json := JsonFile.Stringify(value, indent)
        AtomicWriter.WriteAll(this._path, json, "UTF-8")
    }

    ; ============================================================
    ; Static API
    ; ============================================================

    ; Stringify(value, indent := 2) — converts value into a JSON string.
    ;   indent = 0  -> minified (no extra spaces)
    ;   indent >= 1 -> pretty-printed (newlines + indent spaces)
    static Stringify(value, indent := 2)
    {
        n := IsNumber(indent) ? Integer(indent + 0) : 2
        if (n < 0)
            n := 0
        return JsonFile._SerializeValue(value, n, 0)
    }

    ; ============================================================
    ; Parse(jsonStr) — reads JSON string and returns an AHK structure
    ; ============================================================
    ;
    ; JSON type -> AHK type mapping:
    ;   JSON object   -> Map
    ;   JSON array    -> Array
    ;   JSON string   -> String (with unescape of \n, \t, \uXXXX, etc.)
    ;   JSON number   -> Integer (if no `.` and no exponent) or Float
    ;   JSON true     -> 1 (AHK treats 1/0 as native bool)
    ;   JSON false    -> 0
    ;   JSON null     -> "" (empty string is the idiomatic "null" in AHK)
    ;
    ; CAVEAT: Stringify(Parse(s)) roundtrip does not preserve JsonBool/
    ; JsonNull wrappers — they become plain 1/0/"". For our use case
    ; (importing exported buildResult), this is OK because the data
    ; is primitive.
    ;
    ; Throws Error with a clear message on malformed JSON, indicating
    ; position (1-indexed). Caller must use try/catch.
    static Parse(jsonStr)
    {
        if !(jsonStr is String) && !IsNumber(jsonStr)
            throw TypeError("JsonFile.Parse: input must be a string")
        text := String(jsonStr)
        state := Map("text", text, "pos", 1, "len", StrLen(text))
        JsonFile._ParseSkipWS(state)
        if (state["pos"] > state["len"])
            throw Error("JsonFile.Parse: empty input")
        result := JsonFile._ParseValue(state)
        JsonFile._ParseSkipWS(state)
        if (state["pos"] <= state["len"])
        {
            ch := SubStr(text, state["pos"], 1)
            throw Error("JsonFile.Parse: extra content after JSON at position "
                . state["pos"] " (char '" ch "')")
        }
        return result
    }

    ; EscapeString(s) — returns the string with JSON escapes WITHOUT
    ; the surrounding quotes. Useful for debug or manual composition.
    static EscapeString(s)
    {
        ; Internally uses _SerializeString and strips the quotes.
        full := JsonFile._SerializeString(s)
        return SubStr(full, 2, StrLen(full) - 2)
    }

    ; ============================================================
    ; Private serialization helpers
    ; ============================================================

    static _SerializeValue(v, indent, depth)
    {
        ; --- Explicit wrappers first ---
        if IsObject(v)
        {
            if (v is JsonNull)
                return "null"
            if (v is JsonBool)
                return v.value ? "true" : "false"
            if (v is Map)
                return JsonFile._SerializeMap(v, indent, depth)
            if (v is Array)
                return JsonFile._SerializeArray(v, indent, depth)
            ; Unsupported objects: try to extract via ToMap if available
            if v.HasMethod("ToMap")
            {
                m := v.ToMap()
                if (m is Map)
                    return JsonFile._SerializeMap(m, indent, depth)
            }
            throw TypeError("JsonFile: unsupported object type (" Type(v) ")")
        }

        ; --- Primitives ---
        ; AHK v2: empty value with no concrete type -> we treat it as
        ; null to keep JSON valid (rather than an empty string).
        if (v = "" && !IsNumber(v))
            return '""'    ; explicit empty string
        if IsNumber(v)
        {
            ; Integer or Float
            ; Format: numbers in AHK v2 already serialize cleanly as strings
            return v . ""
        }
        ; String
        return JsonFile._SerializeString(v . "")
    }

    static _SerializeMap(m, indent, depth)
    {
        if (m.Count = 0)
            return "{}"

        isPretty := indent > 0
        nl := isPretty ? "`n" : ""
        sep := isPretty ? ": " : ":"
        childIndent := JsonFile._Indent(depth + 1, indent)
        closingIndent := JsonFile._Indent(depth, indent)

        out := "{" . nl
        first := true
        for k, v in m
        {
            if !first
                out .= "," . nl
            out .= childIndent
            out .= JsonFile._SerializeString(k . "")
            out .= sep
            out .= JsonFile._SerializeValue(v, indent, depth + 1)
            first := false
        }
        out .= nl . closingIndent . "}"
        return out
    }

    static _SerializeArray(arr, indent, depth)
    {
        if (arr.Length = 0)
            return "[]"

        isPretty := indent > 0
        nl := isPretty ? "`n" : ""
        childIndent := JsonFile._Indent(depth + 1, indent)
        closingIndent := JsonFile._Indent(depth, indent)

        out := "[" . nl
        for i, v in arr
        {
            if (i > 1)
                out .= "," . nl
            out .= childIndent
            out .= JsonFile._SerializeValue(v, indent, depth + 1)
        }
        out .= nl . closingIndent . "]"
        return out
    }

    static _SerializeString(s)
    {
        out := '"'
        i := 1
        len := StrLen(s)
        while (i <= len)
        {
            ch := SubStr(s, i, 1)
            code := Ord(ch)
            if (ch = '"')
                out .= '\"'
            else if (ch = "\")
                out .= "\\"
            else if (code = 10)        ; `n
                out .= "\n"
            else if (code = 13)        ; `r
                out .= "\r"
            else if (code = 9)         ; `t
                out .= "\t"
            else if (code = 8)         ; `b
                out .= "\b"
            else if (code = 12)        ; `f
                out .= "\f"
            else if (code < 32)
                out .= Format("\u{:04X}", code)
            else
                out .= ch
            i += 1
        }
        out .= '"'
        return out
    }

    static _Indent(level, spacesPerLevel)
    {
        if (spacesPerLevel <= 0 || level <= 0)
            return ""
        out := ""
        total := level * spacesPerLevel
        loop total
            out .= " "
        return out
    }

    ; ============================================================
    ; Private Parse helpers
    ; ============================================================

    static _ParseSkipWS(state)
    {
        text := state["text"]
        len := state["len"]
        pos := state["pos"]
        while (pos <= len)
        {
            ch := SubStr(text, pos, 1)
            code := Ord(ch)
            if (code = 32 || code = 9 || code = 10 || code = 13)
            {
                pos += 1
                continue
            }
            break
        }
        state["pos"] := pos
    }

    static _ParseValue(state)
    {
        JsonFile._ParseSkipWS(state)
        if (state["pos"] > state["len"])
            throw Error("JsonFile.Parse: unexpected end of input")
        ch := SubStr(state["text"], state["pos"], 1)
        if (ch = "{")
            return JsonFile._ParseObject(state)
        if (ch = "[")
            return JsonFile._ParseArray(state)
        if (ch = '"')
            return JsonFile._ParseString(state)
        if (ch = "-" || (Ord(ch) >= 48 && Ord(ch) <= 57))
            return JsonFile._ParseNumber(state)
        ; Literals: true/false/null
        if (SubStr(state["text"], state["pos"], 4) = "true")
        {
            state["pos"] += 4
            return 1
        }
        if (SubStr(state["text"], state["pos"], 5) = "false")
        {
            state["pos"] += 5
            return 0
        }
        if (SubStr(state["text"], state["pos"], 4) = "null")
        {
            state["pos"] += 4
            return ""
        }
        throw Error("JsonFile.Parse: unexpected char '" ch "' at position "
            . state["pos"])
    }

    static _ParseObject(state)
    {
        state["pos"] += 1   ; skip '{'
        result := Map()
        JsonFile._ParseSkipWS(state)
        if (state["pos"] <= state["len"] && SubStr(state["text"], state["pos"], 1) = "}")
        {
            state["pos"] += 1
            return result
        }
        loop
        {
            JsonFile._ParseSkipWS(state)
            if (state["pos"] > state["len"] || SubStr(state["text"], state["pos"], 1) != '"')
                throw Error("JsonFile.Parse: expected string-key in object at position "
                    . state["pos"])
            key := JsonFile._ParseString(state)
            JsonFile._ParseSkipWS(state)
            if (state["pos"] > state["len"] || SubStr(state["text"], state["pos"], 1) != ":")
                throw Error("JsonFile.Parse: expected ':' after key '" key "' at position "
                    . state["pos"])
            state["pos"] += 1
            value := JsonFile._ParseValue(state)
            result[key] := value
            JsonFile._ParseSkipWS(state)
            if (state["pos"] > state["len"])
                throw Error("JsonFile.Parse: object not closed")
            ch := SubStr(state["text"], state["pos"], 1)
            if (ch = ",")
            {
                state["pos"] += 1
                continue
            }
            if (ch = "}")
            {
                state["pos"] += 1
                return result
            }
            throw Error("JsonFile.Parse: expected ',' or '}' in object, got '"
                . ch "' at position " state["pos"])
        }
    }

    static _ParseArray(state)
    {
        state["pos"] += 1   ; skip '['
        result := []
        JsonFile._ParseSkipWS(state)
        if (state["pos"] <= state["len"] && SubStr(state["text"], state["pos"], 1) = "]")
        {
            state["pos"] += 1
            return result
        }
        loop
        {
            value := JsonFile._ParseValue(state)
            result.Push(value)
            JsonFile._ParseSkipWS(state)
            if (state["pos"] > state["len"])
                throw Error("JsonFile.Parse: array not closed")
            ch := SubStr(state["text"], state["pos"], 1)
            if (ch = ",")
            {
                state["pos"] += 1
                continue
            }
            if (ch = "]")
            {
                state["pos"] += 1
                return result
            }
            throw Error("JsonFile.Parse: expected ',' or ']' in array, got '"
                . ch "' at position " state["pos"])
        }
    }

    static _ParseString(state)
    {
        ; Assumes first char is '"'
        state["pos"] += 1
        text := state["text"]
        len := state["len"]
        pos := state["pos"]
        out := ""
        while (pos <= len)
        {
            ch := SubStr(text, pos, 1)
            if (ch = '"')
            {
                state["pos"] := pos + 1
                return out
            }
            if (ch = "\")
            {
                if (pos + 1 > len)
                    throw Error("JsonFile.Parse: incomplete escape at end of input")
                esc := SubStr(text, pos + 1, 1)
                if (esc = '"')
                {
                    out .= '"'
                    pos += 2
                }
                else if (esc = "\")
                {
                    out .= "\"
                    pos += 2
                }
                else if (esc = "/")
                {
                    out .= "/"
                    pos += 2
                }
                else if (esc = "n")
                {
                    out .= Chr(10)
                    pos += 2
                }
                else if (esc = "r")
                {
                    out .= Chr(13)
                    pos += 2
                }
                else if (esc = "t")
                {
                    out .= Chr(9)
                    pos += 2
                }
                else if (esc = "b")
                {
                    out .= Chr(8)
                    pos += 2
                }
                else if (esc = "f")
                {
                    out .= Chr(12)
                    pos += 2
                }
                else if (esc = "u")
                {
                    if (pos + 5 > len)
                        throw Error("JsonFile.Parse: incomplete \\uXXXX at position " pos)
                    hex := SubStr(text, pos + 2, 4)
                    if !RegExMatch(hex, "^[0-9A-Fa-f]{4}$")
                        throw Error("JsonFile.Parse: invalid \\uXXXX '" hex "' at position " pos)
                    code := Integer("0x" hex)
                    out .= Chr(code)
                    pos += 6
                }
                else
                {
                    throw Error("JsonFile.Parse: unknown escape '\\" esc "' at position " pos)
                }
                continue
            }
            if (Ord(ch) < 32)
                throw Error("JsonFile.Parse: unescaped control char at position " pos)
            out .= ch
            pos += 1
        }
        throw Error("JsonFile.Parse: string not closed")
    }

    static _ParseNumber(state)
    {
        text := state["text"]
        len := state["len"]
        start := state["pos"]
        pos := start
        if (SubStr(text, pos, 1) = "-")
            pos += 1
        while (pos <= len)
        {
            ch := SubStr(text, pos, 1)
            code := Ord(ch)
            if (code >= 48 && code <= 57)   ; 0-9
            {
                pos += 1
                continue
            }
            break
        }
        ; Local name is `numIsFloat` (not `isFloat`) to avoid a
        ; case-insensitive collision with the builtin function
        ; `IsFloat` which triggers #Warn.
        numIsFloat := false
        if (pos <= len && SubStr(text, pos, 1) = ".")
        {
            numIsFloat := true
            pos += 1
            while (pos <= len)
            {
                code := Ord(SubStr(text, pos, 1))
                if (code >= 48 && code <= 57)
                {
                    pos += 1
                    continue
                }
                break
            }
        }
        if (pos <= len)
        {
            ch := SubStr(text, pos, 1)
            if (ch = "e" || ch = "E")
            {
                numIsFloat := true
                pos += 1
                if (pos <= len)
                {
                    sign := SubStr(text, pos, 1)
                    if (sign = "+" || sign = "-")
                        pos += 1
                }
                while (pos <= len)
                {
                    code := Ord(SubStr(text, pos, 1))
                    if (code >= 48 && code <= 57)
                    {
                        pos += 1
                        continue
                    }
                    break
                }
            }
        }
        numStr := SubStr(text, start, pos - start)
        state["pos"] := pos
        if (numStr = "" || numStr = "-")
            throw Error("JsonFile.Parse: invalid number at position " start)
        return numIsFloat ? Float(numStr) : Integer(numStr)
    }
}
