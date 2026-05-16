; ============================================================
; AtomicWriter tests
; ============================================================
;
; AtomicWriter.WriteAll(path, content, encoding := "UTF-8")
;   - Cria diretorio se necessario
;   - Escreve em <path>.tmp e depois FileMove pra <path>
;   - Sobrescreve destino existente
;   - Cleanup defensivo: deleta .tmp orfao antes de escrever
;   - Aceita content vazio (cria arquivo vazio)
;   - Encoding default UTF-8, mas aceita UTF-16 e outros

class AtomicWriterTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        "write_all_creates_file_with_content",
        "write_all_overwrites_existing_file",
        "write_all_does_not_leave_tmp_file_behind",
        "write_all_accepts_empty_content",
        "write_all_creates_parent_directory_if_missing",
        "write_all_throws_value_error_on_empty_path",
        "write_all_throws_value_error_on_whitespace_path",
        "write_all_cleans_up_orphaned_tmp_before_writing",
        "write_all_respects_utf16_encoding",
    ]

    write_all_creates_file_with_content()
    {
        path := Fixtures.TempPath("txt")
        AtomicWriter.WriteAll(path, "hello world")
        Assert.True(FileExist(path))
        Assert.Equal("hello world", Fixtures.FileReadAll(path))
    }

    write_all_overwrites_existing_file()
    {
        path := Fixtures.TempFile("original content")
        AtomicWriter.WriteAll(path, "replaced")
        Assert.Equal("replaced", Fixtures.FileReadAll(path))
    }

    write_all_does_not_leave_tmp_file_behind()
    {
        path := Fixtures.TempPath("txt")
        AtomicWriter.WriteAll(path, "anything")
        Assert.False(FileExist(path ".tmp"),
            ".tmp deve ter sido renomeado pra path final")
    }

    write_all_accepts_empty_content()
    {
        path := Fixtures.TempPath("txt")
        AtomicWriter.WriteAll(path, "")
        Assert.True(FileExist(path))
        ; FileAppend("") com UTF-8 cria arquivo com BOM (3 bytes)
        Assert.True(FileGetSize(path) <= 3,
            "Arquivo vazio so tem BOM (0-3 bytes)")
    }

    write_all_creates_parent_directory_if_missing()
    {
        tmpDir := Fixtures.TempDir()
        nestedPath := tmpDir "\sub\dir\nested.txt"
        AtomicWriter.WriteAll(nestedPath, "deep")
        Assert.True(FileExist(nestedPath))
        Assert.Equal("deep", Fixtures.FileReadAll(nestedPath))
    }

    write_all_throws_value_error_on_empty_path()
    {
        Assert.Throws(ValueError, () => AtomicWriter.WriteAll("", "content"))
    }

    write_all_throws_value_error_on_whitespace_path()
    {
        Assert.Throws(ValueError, () => AtomicWriter.WriteAll("   ", "content"))
    }

    write_all_cleans_up_orphaned_tmp_before_writing()
    {
        path := Fixtures.TempPath("txt")
        tmpPath := path ".tmp"
        Fixtures.RegisterTempPath(tmpPath)

        ; Simula .tmp orfao de execucao anterior crashada
        FileAppend("ORPHAN_RESIDUE", tmpPath, "UTF-8")
        Assert.True(FileExist(tmpPath))

        AtomicWriter.WriteAll(path, "fresh content")

        ; Conteudo final deve ser apenas "fresh content"
        ; (sem residuo do orfao appendado)
        Assert.Equal("fresh content", Fixtures.FileReadAll(path))
        Assert.False(FileExist(tmpPath), ".tmp foi consumido pelo FileMove")
    }

    write_all_respects_utf16_encoding()
    {
        path := Fixtures.TempPath("txt")
        AtomicWriter.WriteAll(path, "utf-16 content", "UTF-16")

        ; Le como UTF-16 e compara
        content := FileRead(path, "UTF-16")
        Assert.Equal("utf-16 content", content)

        ; Verifica BOM UTF-16 LE (FF FE) nos primeiros 2 bytes
        raw := FileRead(path, "RAW")
        Assert.Equal(0xFF, NumGet(raw, 0, "UChar"))
        Assert.Equal(0xFE, NumGet(raw, 1, "UChar"))
    }
}

TestRegistry.Register(AtomicWriterTests)
