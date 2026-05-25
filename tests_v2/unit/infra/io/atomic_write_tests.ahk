; ============================================================
; AtomicWriter tests
; ============================================================
;
; AtomicWriter.WriteAll(path, content, encoding := "UTF-8")
;   - Creates the directory if necessary
;   - Writes to <path>.tmp and then FileMoves to <path>
;   - Overwrites an existing destination
;   - Truncates any orphan .tmp on open (FileOpen "w" mode)
;   - Accepts empty content (creates an empty file)
;   - Default encoding UTF-8, but accepts UTF-16 and others
;   - Throws OSError when FileOpen / .Write / FileMove fail

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
        ; Regression: previous implementation used FileDelete +
        ; FileAppend. A silent FileDelete failure (file lock by
        ; antivirus, sharing violation) would have left the .tmp
        ; alive and FileAppend would have CONCATENATED the new
        ; content onto the stale bytes — silently corrupting the
        ; FileMove destination. The new FileOpen("w") path is
        ; truncation-by-open, eliminating that class entirely.
        ; This test exercises the case where the new content is
        ; SMALLER than the orphan residue: the old append-mode
        ; would have produced [residue][new], visibly longer than
        ; just [new]. Truncate guarantees the final file is
        ; exactly [new] (+BOM).
        "write_all_truncates_stale_tmp_smaller_than_residue",
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
            ".tmp should have been renamed to the final path")
    }

    write_all_accepts_empty_content()
    {
        path := Fixtures.TempPath("txt")
        AtomicWriter.WriteAll(path, "")
        Assert.True(FileExist(path))
        ; FileAppend("") with UTF-8 creates a file with BOM (3 bytes)
        Assert.True(FileGetSize(path) <= 3,
            "Empty file only contains BOM (0-3 bytes)")
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

        ; Simulates an orphan .tmp from a previously crashed execution
        FileAppend("ORPHAN_RESIDUE", tmpPath, "UTF-8")
        Assert.True(FileExist(tmpPath))

        AtomicWriter.WriteAll(path, "fresh content")

        ; Final content must be just "fresh content"
        ; (without orphan-appended residue)
        Assert.Equal("fresh content", Fixtures.FileReadAll(path))
        Assert.False(FileExist(tmpPath), ".tmp was consumed by FileMove")
    }

    write_all_truncates_stale_tmp_smaller_than_residue()
    {
        ; The most diagnostic case for the truncate-on-open
        ; contract: orphan residue is LONGER than the new content.
        ; A buggy implementation that opened in append mode (or
        ; failed to truncate for any reason) would produce a final
        ; file containing [residue][new], which is strictly longer
        ; than [new] alone — a byte-count assertion catches it.
        ;
        ; Using UTF-8-RAW for the new write so the read-back has no
        ; BOM overhead, making the byte-count assertion exact.
        path := Fixtures.TempPath("txt")
        tmpPath := path ".tmp"
        Fixtures.RegisterTempPath(tmpPath)

        ; ~80 bytes of stale content in the orphan
        staleContent := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        FileAppend(staleContent, tmpPath, "UTF-8-RAW")
        Assert.True(FileGetSize(tmpPath) >= 80, "pre-condition: orphan is at least 80 bytes")

        ; New content is 13 bytes; with truncation the final file
        ; is exactly 13 bytes (+ optional UTF-8 BOM = 16). Without
        ; truncation it'd be 80+13 = 93+ bytes.
        AtomicWriter.WriteAll(path, "fresh content", "UTF-8-RAW")

        Assert.True(FileExist(path))
        Assert.False(FileExist(tmpPath))
        Assert.Equal("fresh content", Fixtures.FileReadAll(path),
            "final content must be exactly the new write, no stale residue")
        Assert.True(FileGetSize(path) < 80,
            "final file must be smaller than the orphan was (proves truncate happened)")
    }

    write_all_respects_utf16_encoding()
    {
        path := Fixtures.TempPath("txt")
        AtomicWriter.WriteAll(path, "utf-16 content", "UTF-16")

        ; Reads as UTF-16 and compares
        content := FileRead(path, "UTF-16")
        Assert.Equal("utf-16 content", content)

        ; Verifies the UTF-16 LE BOM (FF FE) in the first 2 bytes
        raw := FileRead(path, "RAW")
        Assert.Equal(0xFF, NumGet(raw, 0, "UChar"))
        Assert.Equal(0xFE, NumGet(raw, 1, "UChar"))
    }
}

TestRegistry.Register(AtomicWriterTests)
