; ============================================================
; CsvFile tests
; ============================================================
;
; Formato do projeto:
;   - Separador: ';'
;   - Encoding: UTF-8
;   - Header sem aspas: col1;col2;col3
;   - Data rows enquoted: "v1";"v2";"v3"
;   - Aspas internas escapadas como duas aspas: "ele disse ""oi"""
;   - LF (`n) no fim de cada linha
;
; Nomenclatura: `csvInst` em vez de `csvFile` pra nao colidir com a classe.

class CsvFileTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Construtor ---
        "constructor_throws_on_empty_path",
        "constructor_creates_parent_directory",

        ; --- EnsureHeader ---
        "ensure_header_creates_file_when_missing",
        "ensure_header_returns_true_on_first_create",
        "ensure_header_returns_false_when_file_exists",
        "ensure_header_does_not_overwrite_existing",
        "ensure_header_writes_columns_separated_by_semicolons",
        "ensure_header_throws_on_empty_array",
        "ensure_header_throws_on_non_array",

        ; --- AppendRow ---
        "append_row_writes_quoted_fields_separated_by_semicolons",
        "append_row_terminates_line_with_lf",
        "append_row_escapes_internal_quotes_as_double_quotes",
        "append_row_throws_on_non_array",
        "append_row_throws_when_expected_columns_mismatch",
        "append_row_does_not_validate_when_expected_is_zero",

        ; --- WriteAllRows ---
        "write_all_rows_writes_header_and_rows_atomically",
        "write_all_rows_overwrites_existing_file",
        "write_all_rows_validates_rows_before_touching_disk",
        "write_all_rows_throws_on_empty_header",
        "write_all_rows_throws_on_non_array_rows_list",

        ; --- ReadAllRows ---
        "read_all_rows_skips_header",
        "read_all_rows_parses_quoted_fields",
        "read_all_rows_returns_empty_for_missing_file",
        "read_all_rows_skips_empty_lines",
        "read_all_rows_skips_rows_with_wrong_column_count_when_expected",

        ; --- CountDataRows ---
        "count_data_rows_excludes_header",
        "count_data_rows_returns_zero_for_missing_file",
        "count_data_rows_returns_zero_for_header_only_file",

        ; --- Static helpers ---
        "parse_line_handles_quoted_fields",
        "parse_line_handles_escaped_quotes_inside_field",
        "parse_line_handles_unquoted_fields",
        "parse_line_handles_empty_input",
        "format_row_returns_quoted_semicolon_separated_with_lf",
        "escape_field_doubles_internal_quotes",
        "exists_true_after_ensure_header",
        "get_path_returns_constructor_arg",
    ]

    ; ============================================================
    ; Construtor
    ; ============================================================

    constructor_throws_on_empty_path()
    {
        Assert.Throws(ValueError, () => CsvFile(""))
    }

    constructor_creates_parent_directory()
    {
        tmpDir := Fixtures.TempDir()
        nested := tmpDir "\sub\dir\data.csv"
        csvInst := CsvFile(nested)
        SplitPath(nested, , &dir)
        Assert.True(DirExist(dir))
    }

    ; ============================================================
    ; EnsureHeader
    ; ============================================================

    ensure_header_creates_file_when_missing()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        csvInst.EnsureHeader(["a", "b", "c"])
        Assert.True(FileExist(path))
    }

    ensure_header_returns_true_on_first_create()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        Assert.True(csvInst.EnsureHeader(["a", "b"]))
    }

    ensure_header_returns_false_when_file_exists()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        csvInst.EnsureHeader(["a", "b"])
        Assert.False(csvInst.EnsureHeader(["a", "b"]),
            "Segunda chamada deveria detectar arquivo existente")
    }

    ensure_header_does_not_overwrite_existing()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        csvInst.EnsureHeader(["original", "header"])
        csvInst.EnsureHeader(["different", "header", "extra"])

        content := Fixtures.FileReadAll(path)
        Assert.Contains("original;header", content)
        Assert.False(InStr(content, "different;header;extra") > 0)
    }

    ensure_header_writes_columns_separated_by_semicolons()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        csvInst.EnsureHeader(["col1", "col2", "col3"])

        content := Fixtures.FileReadAll(path)
        Assert.Contains("col1;col2;col3", content)
    }

    ensure_header_throws_on_empty_array()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        Assert.Throws(ValueError, () => csvInst.EnsureHeader([]))
    }

    ensure_header_throws_on_non_array()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        Assert.Throws(ValueError, () => csvInst.EnsureHeader("not an array"))
    }

    ; ============================================================
    ; AppendRow
    ; ============================================================

    append_row_writes_quoted_fields_separated_by_semicolons()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        csvInst.EnsureHeader(["a", "b"])
        csvInst.AppendRow(["val1", "val2"])

        content := Fixtures.FileReadAll(path)
        Assert.Contains('"val1";"val2"', content)
    }

    append_row_terminates_line_with_lf()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        csvInst.EnsureHeader(["a"])
        csvInst.AppendRow(["x"])

        content := Fixtures.FileReadAll(path)
        ; Header LF + row LF = 2 newlines
        nlCount := 0
        Loop Parse, content
        {
            if (A_LoopField = "`n")
                nlCount += 1
        }
        Assert.Equal(2, nlCount)
    }

    append_row_escapes_internal_quotes_as_double_quotes()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        csvInst.EnsureHeader(["msg"])
        csvInst.AppendRow(['ele disse "oi"'])

        content := Fixtures.FileReadAll(path)
        Assert.Contains('"ele disse ""oi"""', content)
    }

    append_row_throws_on_non_array()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        Assert.Throws(TypeError, () => csvInst.AppendRow("not array"))
    }

    append_row_throws_when_expected_columns_mismatch()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path, 3)   ; expected 3 columns
        Assert.Throws(ValueError, () => csvInst.AppendRow(["only", "two"]))
        Assert.Throws(ValueError, () => csvInst.AppendRow(["a", "b", "c", "d"]))
    }

    append_row_does_not_validate_when_expected_is_zero()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)   ; expected=0 -> sem validacao
        csvInst.AppendRow(["any", "number", "of", "columns"])
        Assert.True(FileExist(path))
    }

    ; ============================================================
    ; WriteAllRows
    ; ============================================================

    write_all_rows_writes_header_and_rows_atomically()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)

        csvInst.WriteAllRows(["c1", "c2"], [
            ["a1", "a2"],
            ["b1", "b2"]
        ])

        content := Fixtures.FileReadAll(path)
        Assert.Contains("c1;c2",       content)
        Assert.Contains('"a1";"a2"',   content)
        Assert.Contains('"b1";"b2"',   content)

        ; .tmp nao deve ficar pra tras
        Assert.False(FileExist(path ".tmp"))
    }

    write_all_rows_overwrites_existing_file()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        csvInst.EnsureHeader(["old", "header"])
        csvInst.AppendRow(["old", "row"])

        csvInst.WriteAllRows(["new", "header"], [["new", "row"]])

        content := Fixtures.FileReadAll(path)
        Assert.Contains("new;header",   content)
        Assert.Contains('"new";"row"',  content)
        Assert.False(InStr(content, "old;header") > 0,
            "Conteudo antigo deveria ter sido removido")
    }

    write_all_rows_validates_rows_before_touching_disk()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path, 3)   ; expected 3 columns

        ; Segunda row tem 2 colunas em vez de 3
        Assert.Throws(ValueError, () => csvInst.WriteAllRows(
            ["c1", "c2", "c3"],
            [
                ["a", "b", "c"],
                ["d", "e"]
            ]
        ))

        Assert.False(FileExist(path),
            "Validation falhou -> arquivo nao deveria existir")
    }

    write_all_rows_throws_on_empty_header()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        Assert.Throws(ValueError, () => csvInst.WriteAllRows([], [["a"]]))
    }

    write_all_rows_throws_on_non_array_rows_list()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        Assert.Throws(TypeError, () => csvInst.WriteAllRows(["c1"], "not array"))
    }

    ; ============================================================
    ; ReadAllRows
    ; ============================================================

    read_all_rows_skips_header()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        csvInst.WriteAllRows(
            ["c1", "c2"],
            [
                ["a1", "a2"],
                ["b1", "b2"]
            ]
        )

        rows := csvInst.ReadAllRows()
        Assert.Equal(2, rows.Length, "Header nao deve aparecer")
    }

    read_all_rows_parses_quoted_fields()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        csvInst.WriteAllRows(
            ["c1", "c2"],
            [["val one", "val two"]]
        )

        rows := csvInst.ReadAllRows()
        Assert.Equal(["val one", "val two"], rows[1])
    }

    read_all_rows_returns_empty_for_missing_file()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        Assert.Equal(0, csvInst.ReadAllRows().Length)
    }

    read_all_rows_skips_empty_lines()
    {
        path := Fixtures.TempPath("csv")
        ; Escreve manual: header + linha vazia + row + linha vazia
        content := "c1;c2`n`n" '"a";"b"' "`n`n"
        FileAppend(content, path, "UTF-8")
        Fixtures.RegisterTempPath(path)

        csvInst := CsvFile(path)
        rows := csvInst.ReadAllRows()
        Assert.Equal(1, rows.Length, "Linhas vazias devem ser puladas")
    }

    read_all_rows_skips_rows_with_wrong_column_count_when_expected()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path, 3)
        ; Cria manualmente uma row com menos colunas (sem validacao no append)
        FileAppend("c1;c2;c3`n" '"a";"b";"c"' "`n" '"x";"y"' "`n", path, "UTF-8")

        rows := csvInst.ReadAllRows()
        Assert.Equal(1, rows.Length, "Row com menos colunas que expected deve ser pulada")
    }

    ; ============================================================
    ; CountDataRows
    ; ============================================================

    count_data_rows_excludes_header()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        csvInst.WriteAllRows(
            ["c"],
            [["r1"], ["r2"], ["r3"]]
        )
        Assert.Equal(3, csvInst.CountDataRows())
    }

    count_data_rows_returns_zero_for_missing_file()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        Assert.Equal(0, csvInst.CountDataRows())
    }

    count_data_rows_returns_zero_for_header_only_file()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        csvInst.EnsureHeader(["c1", "c2"])
        Assert.Equal(0, csvInst.CountDataRows())
    }

    ; ============================================================
    ; Static helpers
    ; ============================================================

    parse_line_handles_quoted_fields()
    {
        fields := CsvFile.ParseLine('"a";"b";"c"')
        Assert.Equal(["a", "b", "c"], fields)
    }

    parse_line_handles_escaped_quotes_inside_field()
    {
        fields := CsvFile.ParseLine('"he said ""hi""";"ok"')
        Assert.Equal(['he said "hi"', "ok"], fields)
    }

    parse_line_handles_unquoted_fields()
    {
        fields := CsvFile.ParseLine("a;b;c")
        Assert.Equal(["a", "b", "c"], fields)
    }

    parse_line_handles_empty_input()
    {
        Assert.Equal(0, CsvFile.ParseLine("").Length)
    }

    format_row_returns_quoted_semicolon_separated_with_lf()
    {
        line := CsvFile.FormatRow(["a", "b", "c"])
        Assert.Equal('"a";"b";"c"' "`n", line)
    }

    escape_field_doubles_internal_quotes()
    {
        result := CsvFile.EscapeField('ele disse "oi"')
        Assert.Equal('"ele disse ""oi"""', result)
    }

    exists_true_after_ensure_header()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        csvInst.EnsureHeader(["a"])
        Assert.True(csvInst.Exists())
    }

    get_path_returns_constructor_arg()
    {
        path := Fixtures.TempPath("csv")
        csvInst := CsvFile(path)
        Assert.Equal(path, csvInst.GetPath())
    }
}

TestRegistry.Register(CsvFileTests)
