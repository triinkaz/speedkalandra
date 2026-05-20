; ============================================================
; CsvFile — CSV read/write in the tracker's format
; ============================================================
;
; Project format:
;   - Separator: ';' (because some log fields contain commas)
;   - Encoding: UTF-8
;   - Each field wrapped in double quotes: "val1";"val2";"val3"
;   - Internal quotes escaped as two quotes: "he said ""hi""."
;   - First line is the header (key = column name)
;   - LF at the end of each line (`n)
;
; Real examples (splits.csv with 16 fields):
;   "2026-04-25 07:20:55";"20260425_072055";"Default";"Unknown";"1";...
;
; Usage:
;   csv := CsvFile(SPLITS_FILE)
;   csv.EnsureHeader(["timestamp", "run_id", "profile", ...])
;   csv.AppendRow(["2026-...", "20260425_072055", ...])
;
;   for _, fields in csv.ReadAllRows()  ; automatically skips header
;       ProcessFields(fields)
;
; Errors are isolated — reading a non-existent file returns [] (does
; not throw), same as the legacy code does today.

class CsvFile
{
    path     := ""
    expected := 0   ; expected number of columns (0 = do not validate)

    __New(path, expectedColumns := 0)
    {
        if (path = "")
            throw ValueError("CsvFile: 'path' is required")
        this.path     := path
        this.expected := expectedColumns
        this._EnsureDir()
    }

    ; ------------------------------------------------------------
    ; EnsureHeader(headerArray)
    ;   If the file does not exist, creates it with the header line.
    ;   If it exists, does nothing (preserves content).
    ; ------------------------------------------------------------
    EnsureHeader(headerArray)
    {
        if !IsObject(headerArray) || headerArray.Length = 0
            throw ValueError("CsvFile.EnsureHeader: 'headerArray' must be a non-empty Array")

        if FileExist(this.path)
            return false

        ; Header WITHOUT quotes (legacy compatibility)
        line := ""
        for i, col in headerArray
            line .= (i > 1 ? ";" : "") . col
        FileAppend(line "`n", this.path, "UTF-8")

        ; NOTE: do NOT auto-configure 'expected' from the header.
        ; If the user passed CsvFile(path) without 'expectedColumns', the
        ; intent was "no validation". Auto-detecting based on the header
        ; would steal that decision and contradict the test "AppendRow no
        ; validation when expected zero". Whoever wants validation passes
        ; CsvFile(path, N) explicitly.
        return true
    }

    ; ------------------------------------------------------------
    ; AppendRow(fields)
    ;   Appends a line. Each field is quoted ("...") and internal
    ;   quotes are doubled (""). Ends with `n.
    ; ------------------------------------------------------------
    AppendRow(fields)
    {
        if !IsObject(fields)
            throw TypeError("CsvFile.AppendRow: 'fields' must be an Array")
        if (this.expected > 0 && fields.Length != this.expected)
            throw ValueError("CsvFile.AppendRow: expected " this.expected " columns, got " fields.Length)

        line := CsvFile._FormatRow(fields)
        FileAppend(line, this.path, "UTF-8")
    }

    ; ------------------------------------------------------------
    ; WriteAllRows(headerArray, rowsList)
    ;   Refactor R10: full rewrite of the CSV in ONE atomic write.
    ;   Replaces the legacy pattern (FileDelete + EnsureHeader +
    ;   AppendRow loop) that was vulnerable to corruption on crash.
    ;
    ;   Builds a buffer with header (no quotes, same as EnsureHeader)
    ;   + N lines formatted via _FormatRow, and writes via
    ;   AtomicWriter (.tmp + FileMove).
    ;
    ;   Args:
    ;     headerArray : Array<string>, column names
    ;     rowsList    : Array<Array<*>>, each element is a row
    ;
    ;   Column validation: each row must have expected columns
    ;   if 'expectedColumns' was configured in the constructor (ValueError
    ;   before touching disk — nothing partial reaches the .tmp).
    ; ------------------------------------------------------------
    WriteAllRows(headerArray, rowsList)
    {
        if !IsObject(headerArray) || headerArray.Length = 0
            throw ValueError("CsvFile.WriteAllRows: 'headerArray' must be a non-empty Array")
        if !IsObject(rowsList)
            throw TypeError("CsvFile.WriteAllRows: 'rowsList' must be an Array")

        ; Validate all rows BEFORE touching disk (early throw)
        if (this.expected > 0)
        {
            for idx, row in rowsList
            {
                if !IsObject(row)
                    throw TypeError("CsvFile.WriteAllRows: row #" idx " must be an Array")
                if (row.Length != this.expected)
                    throw ValueError("CsvFile.WriteAllRows: row #" idx " has " row.Length " columns, expected " this.expected)
            }
        }

        ; Build buffer: header (no-quote format, parity with EnsureHeader)
        ; Local name is `outBuffer` (not `buffer`) to avoid a
        ; case-insensitive collision with the builtin class `Buffer`
        ; which triggers #Warn.
        outBuffer := ""
        for i, col in headerArray
            outBuffer .= (i > 1 ? ";" : "") . col
        outBuffer .= "`n"

        ; Append each formatted row
        for _, row in rowsList
            outBuffer .= CsvFile._FormatRow(row)

        ; Atomic write
        AtomicWriter.WriteAll(this.path, outBuffer, "UTF-8")
    }

    ; ------------------------------------------------------------
    ; ReadAllRows() -> Array<Array<string>>
    ;   Reads the whole file, skips the first line (header), and
    ;   returns a list of lists with the parsed fields.
    ;   Lines with the wrong column count are skipped (does not throw)
    ;   if 'expectedColumns' was configured in the constructor.
    ;   Returns [] if the file does not exist.
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
            ; skip header and empty lines
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
    ; CountDataRows() -> int (number of lines excluding the header)
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
        return Max(0, total - 1)   ; minus the header
    }

    Exists()  => FileExist(this.path) != ""
    GetPath() => this.path

    ; ------------------------------------------------------------
    ; Statics: parse and format a single line (public for tests
    ; and for reuse by repositories without instantiating CsvFile).
    ; ------------------------------------------------------------
    static ParseLine(line) => CsvFile._ParseLine(line)
    static FormatRow(fields) => CsvFile._FormatRow(fields)
    static EscapeField(value) => CsvFile._EscapeField(value)

    ; ============================================================
    ; Internals
    ; ============================================================

    ; _ParseLine — stateful parser that handles:
    ;   - Quoted fields: "value"
    ;   - Internal quotes: ""
    ;   - ';' separators outside of quotes
    ;   - Unquoted fields (back-compat with header and legacy)
    static _ParseLine(line)
    {
        out := []
        if (line = "")
            return out

        len := StrLen(line)
        i := 1
        current := ""
        inQuotes := false
        sawQuotes := false   ; remembers whether the field opened with quotes

        while (i <= len)
        {
            ch := SubStr(line, i, 1)

            if inQuotes
            {
                if (ch = '"')
                {
                    ; quote inside: may be end of field or escaped quote ("")
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

            ; outside of quotes
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
        ; Always quoted, with internal quotes doubled
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
