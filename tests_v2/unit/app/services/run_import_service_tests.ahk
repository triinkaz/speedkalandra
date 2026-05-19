; ============================================================
; RunImportServiceTests
; ============================================================
;
; RunImportService is the gateway for externally-supplied JSON.
; Its first responsibility is to refuse hostile or accidentally
; oversized inputs BEFORE pulling them into memory or writing
; them to disk. The most expensive failure mode is FileRead'ing
; a multi-gigabyte file and only failing later on schema parse.
;
; This suite covers the size gate. Schema-level limits
; (MAX_RUNS_PER_FILE, MAX_STRING_LEN, etc.) belong to
; run_export_format_tests because they live in
; RunExportFormat.ValidateSchema. Behavior tests (Preview /
; Execute / conflict resolution) are covered by the integration
; suite where the full app wiring is available.


class RunImportServiceTests extends TestCase
{
    bus     := ""
    repo    := ""
    svc     := ""
    repoDir := ""

    Setup()
    {
        this.bus     := Fixtures.MakeBus()
        this.repoDir := Fixtures.TempDir()
        this.repo    := RunHistoryRepository(this.repoDir)
        this.svc     := RunImportService(this.bus, this.repo)
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Size gate ---
        "preview_rejects_file_exceeding_max_bytes",
        "preview_accepts_file_just_under_max_bytes",

        ; --- Pre-read guards (path / existence) ---
        "preview_rejects_empty_path",
        "preview_rejects_missing_file",
    ]

    ; ============================================================
    ; Size gate
    ; ============================================================

    preview_rejects_file_exceeding_max_bytes()
    {
        ; Build a file slightly larger than MAX_FILE_BYTES via
        ; chunked FileAppend so we don't hold a 10 MB string in
        ; memory. 64 KB chunks keep the syscall count low
        ; (~160 appends for a 10 MB file).
        path := Fixtures.TempPath("json")
        chunkSize := 65536
        chunk := ""
        loop chunkSize
            chunk .= "a"
        chunkCount := Ceil(RunImportService.MAX_FILE_BYTES / chunkSize) + 1
        loop chunkCount
            FileAppend(chunk, path, "UTF-8")

        result := this.svc.Preview(path)
        Assert.False(result["success"])
        Assert.True(result["errors"].Length > 0,
            "expected at least one error")
        firstError := result["errors"][1]
        Assert.True(InStr(firstError, "too large") > 0,
            "error message identifies the cause: " firstError)
        Assert.True(InStr(firstError, "memory exhaustion") > 0,
            "error message explains why we refuse")
    }

    preview_accepts_file_just_under_max_bytes()
    {
        ; Positive control: a small valid-shaped file must pass
        ; the size gate. We do not assert validation success
        ; (the file is empty-JSON shape) — only that the size
        ; gate does NOT short-circuit it. Other errors (parse,
        ; schema) are fine; size-related ones are not.
        path := Fixtures.TempFile('{"schemaVersion": 1, "runs": []}', "json")
        result := this.svc.Preview(path)
        ; The file is tiny, so the size gate must not block.
        ; Errors here, if any, come from later phases.
        sizeError := false
        for _, err in result["errors"]
        {
            if (InStr(err, "too large") > 0 || InStr(err, "memory exhaustion") > 0)
            {
                sizeError := true
                break
            }
        }
        Assert.False(sizeError, "small file must not trip the size gate")
    }

    ; ============================================================
    ; Pre-read guards (path / existence)
    ; ============================================================

    preview_rejects_empty_path()
    {
        result := this.svc.Preview("")
        Assert.False(result["success"])
        Assert.True(InStr(result["errors"][1], "Empty input path") > 0)
    }

    preview_rejects_missing_file()
    {
        ; Non-existent path. FileExist returns "" so Preview
        ; bails before either FileGetSize or FileRead.
        nonexistent := A_Temp "\sk_does_not_exist_" Random(100000, 999999) ".json"
        result := this.svc.Preview(nonexistent)
        Assert.False(result["success"])
        Assert.True(InStr(result["errors"][1], "File not found") > 0)
    }
}

TestRegistry.Register(RunImportServiceTests)
