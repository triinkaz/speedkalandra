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
}
