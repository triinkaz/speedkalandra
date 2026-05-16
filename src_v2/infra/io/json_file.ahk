; ============================================================
; JsonFile — escrita de arquivos JSON (Fase B2.1)
; ============================================================
;
; Espelha CsvFile/IniFile: instance-based com path no construtor.
;
; FILOSOFIA:
;   - Escrita primeiro, leitura fica pra fase futura quando precisarmos
;     re-importar runs exportadas.
;   - Pretty-print por default (indent=2 espacos) — UX prioriza
;     inspecao manual em editor de texto.
;   - Encoding sempre UTF-8 (consistente com CsvFile).
;
; TIPOS SUPORTADOS no value de entrada:
;   - String  -> JSON string com escape (")
;   - Number  -> JSON number literal (sem aspas)
;   - JsonBool(true|false) -> JSON true|false (boolean nativo)
;   - JsonNull() -> JSON null
;   - Map     -> JSON object {...}
;   - Array   -> JSON array [...]
;
; CONVENCAO DE BOOLEANS:
;   AHK v2 trata `true` como 1 e `false` como 0. Sem distincao
;   entre "1 numero" vs "true booleano". Pra serializar bool
;   explicito como `true`/`false`, use `JsonBool(value)` wrapper.
;   Senao, valores numericos viram numeros JSON (1, 0).
;
; CONSTRUCAO:
;   jf := JsonFile(path)
;
; USO:
;   jf.Write(Map("name", "Run1", "active", JsonBool(true)))
;   ; Resultado em disco:
;   ; {
;   ;   "name": "Run1",
;   ;   "active": true
;   ; }
;
; STATIC HELPERS:
;   JsonFile.Stringify(value, indent := 2) -> string com JSON
;   JsonFile.EscapeString(s) -> string com escapes (sem as aspas)


class JsonNull
{
    ; Marker class — sem campos, sem metodos. Uso:
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
            throw ValueError("JsonFile: 'path' obrigatorio")
        this._path := path
    }

    GetPath() => this._path

    ; Write(value, indent := 2) — serializa value e escreve no path.
    ; Overwrites file completamente (sem append). UTF-8.
    ; Refactor R10: usa AtomicWriter pra evitar corrupção por crash
    ; entre FileDelete e FileAppend (gap visivel onde arquivo desaparecia).
    Write(value, indent := 2)
    {
        json := JsonFile.Stringify(value, indent)
        AtomicWriter.WriteAll(this._path, json, "UTF-8")
    }

    ; ============================================================
    ; Static API
    ; ============================================================

    ; Stringify(value, indent := 2) — converte value em string JSON.
    ;   indent = 0  -> minified (sem espacos extras)
    ;   indent >= 1 -> pretty-printed (newlines + indent espacos)
    static Stringify(value, indent := 2)
    {
        n := IsNumber(indent) ? Integer(indent + 0) : 2
        if (n < 0)
            n := 0
        return JsonFile._SerializeValue(value, n, 0)
    }

    ; ============================================================
    ; Parse(jsonStr) — le string JSON e retorna estrutura AHK (v0.1.0)
    ; ============================================================
    ;
    ; Mapeamento de tipos JSON -> AHK:
    ;   JSON object   -> Map
    ;   JSON array    -> Array
    ;   JSON string   -> String (com unescape de \n, \t, \uXXXX, etc)
    ;   JSON number   -> Integer (se nao tem `.` nem expoente) ou Float
    ;   JSON true     -> 1 (AHK trata 1/0 como bool nativo)
    ;   JSON false    -> 0
    ;   JSON null     -> "" (string vazia eh o "nulo" idiomatico em AHK)
    ;
    ; CAVEAT: roundtrip Stringify(Parse(s)) nao preserva JsonBool/
    ; JsonNull wrappers — eles viram 1/0/"" puros. Pra nosso caso de
    ; uso (importar buildResult exportado), isso eh OK porque os
    ; dados sao primitivos.
    ;
    ; Throws Error com mensagem clara em JSON malformado, indicando
    ; posicao (1-indexed). Caller deve usar try/catch.
    static Parse(jsonStr)
    {
        if !(jsonStr is String) && !IsNumber(jsonStr)
            throw TypeError("JsonFile.Parse: input deve ser string")
        text := String(jsonStr)
        state := Map("text", text, "pos", 1, "len", StrLen(text))
        JsonFile._ParseSkipWS(state)
        if (state["pos"] > state["len"])
            throw Error("JsonFile.Parse: input vazio")
        result := JsonFile._ParseValue(state)
        JsonFile._ParseSkipWS(state)
        if (state["pos"] <= state["len"])
        {
            ch := SubStr(text, state["pos"], 1)
            throw Error("JsonFile.Parse: conteudo extra apos JSON na posicao "
                . state["pos"] " (char '" ch "')")
        }
        return result
    }

    ; EscapeString(s) — retorna string com escapes JSON SEM as aspas
    ; envolventes. Util pra debug ou composicao manual.
    static EscapeString(s)
    {
        ; Internamente usa _SerializeString e tira as aspas.
        full := JsonFile._SerializeString(s)
        return SubStr(full, 2, StrLen(full) - 2)
    }

    ; ============================================================
    ; Helpers privados de serializacao
    ; ============================================================

    static _SerializeValue(v, indent, depth)
    {
        ; --- Wrappers explicitos primeiro ---
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
            ; Objetos sem suporte: tenta extrair via ToMap se houver
            if v.HasMethod("ToMap")
            {
                m := v.ToMap()
                if (m is Map)
                    return JsonFile._SerializeMap(m, indent, depth)
            }
            throw TypeError("JsonFile: tipo de objeto nao suportado (" Type(v) ")")
        }

        ; --- Primitivos ---
        ; AHK v2: vazio sem tipo concreto -> tratamos como null pra
        ; manter JSON valido (em vez de string vazia).
        if (v = "" && !IsNumber(v))
            return '""'    ; string vazia explicita
        if IsNumber(v)
        {
            ; Integer ou Float
            ; Format: numbers em AHK v2 ja serializam direito como string
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
    ; Helpers privados do Parse
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
            throw Error("JsonFile.Parse: fim inesperado de input")
        ch := SubStr(state["text"], state["pos"], 1)
        if (ch = "{")
            return JsonFile._ParseObject(state)
        if (ch = "[")
            return JsonFile._ParseArray(state)
        if (ch = '"')
            return JsonFile._ParseString(state)
        if (ch = "-" || (Ord(ch) >= 48 && Ord(ch) <= 57))
            return JsonFile._ParseNumber(state)
        ; Literais: true/false/null
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
        throw Error("JsonFile.Parse: char inesperado '" ch "' na posicao "
            . state["pos"])
    }

    static _ParseObject(state)
    {
        state["pos"] += 1   ; pula '{'
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
                throw Error("JsonFile.Parse: esperava string-key em object na posicao "
                    . state["pos"])
            key := JsonFile._ParseString(state)
            JsonFile._ParseSkipWS(state)
            if (state["pos"] > state["len"] || SubStr(state["text"], state["pos"], 1) != ":")
                throw Error("JsonFile.Parse: esperava ':' apos key '" key "' na posicao "
                    . state["pos"])
            state["pos"] += 1
            value := JsonFile._ParseValue(state)
            result[key] := value
            JsonFile._ParseSkipWS(state)
            if (state["pos"] > state["len"])
                throw Error("JsonFile.Parse: object nao fechado")
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
            throw Error("JsonFile.Parse: esperava ',' ou '}' em object, achou '"
                . ch "' na posicao " state["pos"])
        }
    }

    static _ParseArray(state)
    {
        state["pos"] += 1   ; pula '['
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
                throw Error("JsonFile.Parse: array nao fechado")
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
            throw Error("JsonFile.Parse: esperava ',' ou ']' em array, achou '"
                . ch "' na posicao " state["pos"])
        }
    }

    static _ParseString(state)
    {
        ; Assume primeiro char eh '"'
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
                    throw Error("JsonFile.Parse: escape incompleto no fim do input")
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
                        throw Error("JsonFile.Parse: \\uXXXX incompleto na posicao " pos)
                    hex := SubStr(text, pos + 2, 4)
                    if !RegExMatch(hex, "^[0-9A-Fa-f]{4}$")
                        throw Error("JsonFile.Parse: \\uXXXX invalido '" hex "' na posicao " pos)
                    code := Integer("0x" hex)
                    out .= Chr(code)
                    pos += 6
                }
                else
                {
                    throw Error("JsonFile.Parse: escape desconhecido '\\" esc "' na posicao " pos)
                }
                continue
            }
            if (Ord(ch) < 32)
                throw Error("JsonFile.Parse: char de controle nao escapado na posicao " pos)
            out .= ch
            pos += 1
        }
        throw Error("JsonFile.Parse: string nao fechada")
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
        ; v0.1.0: renomeado de `isFloat` pra `numIsFloat` (case-insensitive
        ; collision com builtin function `IsFloat` disparava #Warn).
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
            throw Error("JsonFile.Parse: numero invalido na posicao " start)
        return numIsFloat ? Float(numStr) : Integer(numStr)
    }
}
