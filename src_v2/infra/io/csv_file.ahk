; ============================================================
; CsvFile — leitura/escrita CSV no formato do tracker
; ============================================================
;
; Formato do projeto:
;   - Separador: ';' (porque alguns campos do log tem virgula)
;   - Encoding: UTF-8
;   - Cada campo entre aspas duplas: "valor1";"valor2";"valor3"
;   - Aspas internas escapadas como duas aspas: "ele disse ""oi""."
;   - Primeira linha eh header (key=column name)
;   - LF no fim de cada linha (`n)
;
; Exemplos reais (splits.csv com 16 campos):
;   "2026-04-25 07:20:55";"20260425_072055";"Default";"Unknown";"1";...
;
; Uso:
;   csv := CsvFile(SPLITS_FILE)
;   csv.EnsureHeader(["timestamp", "run_id", "profile", ...])
;   csv.AppendRow(["2026-...", "20260425_072055", ...])
;
;   for _, fields in csv.ReadAllRows()  ; pula header automaticamente
;       ProcessFields(fields)
;
; Erros isolados — leitura de arquivo inexistente retorna [] (nao
; estoura), igual o legado faz hoje.

class CsvFile
{
    path     := ""
    expected := 0   ; numero esperado de colunas (0 = nao validar)

    __New(path, expectedColumns := 0)
    {
        if (path = "")
            throw ValueError("CsvFile: 'path' obrigatorio")
        this.path     := path
        this.expected := expectedColumns
        this._EnsureDir()
    }

    ; ------------------------------------------------------------
    ; EnsureHeader(headerArray)
    ;   Se o arquivo nao existe, cria com a linha de cabecalho.
    ;   Se existe, nao mexe (preserva conteudo).
    ; ------------------------------------------------------------
    EnsureHeader(headerArray)
    {
        if !IsObject(headerArray) || headerArray.Length = 0
            throw ValueError("CsvFile.EnsureHeader: 'headerArray' deve ser Array nao-vazio")

        if FileExist(this.path)
            return false

        ; Header SEM aspas (compatibilidade com legado)
        line := ""
        for i, col in headerArray
            line .= (i > 1 ? ";" : "") . col
        FileAppend(line "`n", this.path, "UTF-8")

        ; NOTA: NAO auto-configurar 'expected' a partir do header.
        ; Se o usuario passou CsvFile(path) sem 'expectedColumns', a intencao
        ; foi "sem validacao". Auto-detectar baseado no header rouba essa
        ; decisao e contradiz o teste "AppendRow no validation when expected zero".
        ; Quem quer validacao: passa explicitamente CsvFile(path, N).
        return true
    }

    ; ------------------------------------------------------------
    ; AppendRow(fields)
    ;   Acrescenta uma linha. Cada campo eh enquoted ("...") e
    ;   aspas internas viram "" (duplas). Termina com `n.
    ; ------------------------------------------------------------
    AppendRow(fields)
    {
        if !IsObject(fields)
            throw TypeError("CsvFile.AppendRow: 'fields' deve ser Array")
        if (this.expected > 0 && fields.Length != this.expected)
            throw ValueError("CsvFile.AppendRow: esperava " this.expected " colunas, recebi " fields.Length)

        line := CsvFile._FormatRow(fields)
        FileAppend(line, this.path, "UTF-8")
    }

    ; ------------------------------------------------------------
    ; WriteAllRows(headerArray, rowsList)
    ;   Refactor R10: rewrite completo do CSV em UMA escrita atomica.
    ;   Substitui o pattern legado (FileDelete + EnsureHeader +
    ;   loop AppendRow) que era vulneravel a corrupcao em crash.
    ;
    ;   Builda buffer com header (sem aspas, igual EnsureHeader)
    ;   + N linhas formatadas via _FormatRow, e escreve via
    ;   AtomicWriter (.tmp + FileMove).
    ;
    ;   Args:
    ;     headerArray : Array<string>, nomes das colunas
    ;     rowsList    : Array<Array<*>>, cada elemento eh row
    ;
    ;   Validação de colunas: cada row precisa ter expected colunas
    ;   se 'expectedColumns' foi configurado no construtor (ValueError
    ;   antes de tocar disco — nada parcial chega no .tmp).
    ; ------------------------------------------------------------
    WriteAllRows(headerArray, rowsList)
    {
        if !IsObject(headerArray) || headerArray.Length = 0
            throw ValueError("CsvFile.WriteAllRows: 'headerArray' deve ser Array nao-vazio")
        if !IsObject(rowsList)
            throw TypeError("CsvFile.WriteAllRows: 'rowsList' deve ser Array")

        ; Valida todas as rows ANTES de tocar disco (early throw)
        if (this.expected > 0)
        {
            for idx, row in rowsList
            {
                if !IsObject(row)
                    throw TypeError("CsvFile.WriteAllRows: row #" idx " deve ser Array")
                if (row.Length != this.expected)
                    throw ValueError("CsvFile.WriteAllRows: row #" idx " tem " row.Length " colunas, esperava " this.expected)
            }
        }

        ; Build buffer: header (formato sem aspas, paridade EnsureHeader)
        buffer := ""
        for i, col in headerArray
            buffer .= (i > 1 ? ";" : "") . col
        buffer .= "`n"

        ; Append cada row formatada
        for _, row in rowsList
            buffer .= CsvFile._FormatRow(row)

        ; Escreve atomico
        AtomicWriter.WriteAll(this.path, buffer, "UTF-8")
    }

    ; ------------------------------------------------------------
    ; ReadAllRows() -> Array<Array<string>>
    ;   Le o arquivo inteiro, pula a primeira linha (header), e
    ;   retorna uma lista de listas com os campos parseados.
    ;   Linhas com numero errado de colunas sao puladas (nao estoura)
    ;   se 'expectedColumns' foi configurado no construtor.
    ;   Retorna [] se o arquivo nao existe.
    ; ------------------------------------------------------------
    ReadAllRows()
    {
        rows := []
        if !FileExist(this.path)
            return rows

        raw := FileRead(this.path, "UTF-8")
        raw := StrReplace(raw, "`r`n", "`n")
        lines := StrSplit(raw, "`n")

        for index, line in lines
        {
            ; pula header e linhas vazias
            if (index = 1 || Trim(line) = "")
                continue
            fields := CsvFile._ParseLine(line)
            if (this.expected > 0 && fields.Length < this.expected)
                continue
            rows.Push(fields)
        }
        return rows
    }

    ; ------------------------------------------------------------
    ; CountDataRows() -> int (numero de linhas excluindo header)
    ; ------------------------------------------------------------
    CountDataRows()
    {
        if !FileExist(this.path)
            return 0
        raw := FileRead(this.path, "UTF-8")
        raw := StrReplace(raw, "`r`n", "`n")
        raw := RTrim(raw, "`n")
        if (raw = "")
            return 0
        total := StrSplit(raw, "`n").Length
        return Max(0, total - 1)   ; menos o header
    }

    Exists()  => FileExist(this.path) != ""
    GetPath() => this.path

    ; ------------------------------------------------------------
    ; Estaticos: parse e format de uma linha (publicos para testes
    ; e para reuso por repositorios sem instanciar CsvFile).
    ; ------------------------------------------------------------
    static ParseLine(line) => CsvFile._ParseLine(line)
    static FormatRow(fields) => CsvFile._FormatRow(fields)
    static EscapeField(value) => CsvFile._EscapeField(value)

    ; ============================================================
    ; Internos
    ; ============================================================

    ; _ParseLine — parser stateful que lida com:
    ;   - Campos entre aspas: "valor"
    ;   - Aspas internas: ""
    ;   - Separadores ';' fora de aspas
    ;   - Campos sem aspas (back-compat com header e legado)
    static _ParseLine(line)
    {
        out := []
        if (line = "")
            return out

        len := StrLen(line)
        i := 1
        current := ""
        inQuotes := false
        sawQuotes := false   ; lembra se o campo abriu com aspas

        while (i <= len)
        {
            ch := SubStr(line, i, 1)

            if inQuotes
            {
                if (ch = '"')
                {
                    ; aspas dentro: pode ser fim do campo ou aspas escapadas ("")
                    if (i < len && SubStr(line, i + 1, 1) = '"')
                    {
                        current .= '"'
                        i += 2
                        continue
                    }
                    inQuotes := false
                    i += 1
                    continue
                }
                current .= ch
                i += 1
                continue
            }

            ; fora de aspas
            if (ch = '"')
            {
                inQuotes  := true
                sawQuotes := true
                i += 1
                continue
            }
            if (ch = ";")
            {
                out.Push(current)
                current   := ""
                sawQuotes := false
                i += 1
                continue
            }
            current .= ch
            i += 1
        }

        out.Push(current)
        return out
    }

    static _EscapeField(value)
    {
        s := String(value)
        ; Sempre enquoted, com aspas internas duplicadas
        s := StrReplace(s, '"', '""')
        return '"' s '"'
    }

    static _FormatRow(fields)
    {
        line := ""
        for i, f in fields
            line .= (i > 1 ? ";" : "") . CsvFile._EscapeField(f)
        return line "`n"
    }

    _EnsureDir()
    {
        SplitPath(this.path, , &dir)
        if (dir != "" && !DirExist(dir))
        {
            try DirCreate(dir)
        }
    }
}
