; ============================================================
; LogService tests
; ============================================================
;
; Covers the properties documented in the log_service.ahk header:
;
;   - Levels: DEBUG < INFO < WARN < ERROR, filtered via minLevel
;   - Dynamic SetMinLevel
;   - Format: [yyyy-MM-dd HH:mm:ss] LEVEL [Ctx] msg`n
;             (empty context omits the brackets)
;   - Buffer: bufferSize=1 (default) flushes immediately, N>1 accumulates
;   - WARN/ERROR: immediate flush, always after draining the pending
;                 buffer (preserves chronological order)
;   - WARN/ERROR counters: count INDEPENDENT of minLevel
;   - Rotation (Bug #32): if existing log > 5MB at construction,
;     rename to .log.old (overwrites previous .old)
;
; Convention: `srvLog` instead of `log` to avoid colliding with a global.

class LogServiceTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor: validation ---
        "constructor_rejects_buffer_size_zero",
        "constructor_rejects_buffer_size_negative",
        "constructor_rejects_buffer_size_non_number",

        ; --- Constructor: filesystem ---
        "constructor_creates_parent_directory_if_missing",
        "constructor_does_not_create_log_file_until_first_write",

        ; --- Constructor: rotation (Bug #32) ---
        "constructor_rotates_existing_log_over_5mb",
        "constructor_rotation_overwrites_existing_old_file",
        "constructor_does_not_rotate_when_log_under_threshold",
        "constructor_does_not_rotate_when_log_does_not_exist",

        ; --- Levels and filter ---
        "info_writes_to_file_with_default_buffer",
        "warn_writes_to_file_with_default_buffer",
        "error_writes_to_file_with_default_buffer",
        "debug_filtered_out_when_min_level_is_info",
        "debug_written_when_min_level_is_debug",
        "set_min_level_changes_filter_dynamically",

        ; --- Format ---
        "log_line_format_contains_timestamp_level_context_msg",
        "empty_context_omits_context_brackets",

        ; --- Buffer ---
        "buffer_holds_info_until_size_reached",
        "buffer_flushes_when_size_reached",
        "warn_flushes_pending_buffer_before_writing_preserving_order",
        "error_flushes_pending_buffer_before_writing_preserving_order",

        ; --- Flush ---
        "flush_writes_pending_buffer_immediately",
        "flush_on_empty_buffer_is_noop_and_does_not_create_file",

        ; --- Counters ---
        "warn_counter_increments_regardless_of_min_level",
        "error_counter_increments_regardless_of_min_level",
        "info_and_debug_do_not_increment_warn_error_counters",
        "reset_counts_zeroes_warn_and_error_counters",
    ]

    ; ============================================================
    ; Constructor: validation
    ; ============================================================

    constructor_rejects_buffer_size_zero()
    {
        path := Fixtures.TempPath("log")
        Assert.Throws(ValueError, () => LogService(path, "INFO", 0))
    }

    constructor_rejects_buffer_size_negative()
    {
        path := Fixtures.TempPath("log")
        Assert.Throws(ValueError, () => LogService(path, "INFO", -1))
    }

    constructor_rejects_buffer_size_non_number()
    {
        path := Fixtures.TempPath("log")
        Assert.Throws(ValueError, () => LogService(path, "INFO", "abc"))
    }

    ; ============================================================
    ; Constructor: filesystem
    ; ============================================================

    constructor_creates_parent_directory_if_missing()
    {
        tmpDir := Fixtures.TempDir()
        nestedPath := tmpDir "\sub1\sub2\log.txt"

        srvLog := LogService(nestedPath, "INFO")
        srvLog.Info("anything")
        srvLog.Flush()

        Assert.True(FileExist(nestedPath),
            "LogService should have created the intermediate path")
    }

    constructor_does_not_create_log_file_until_first_write()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "INFO")
        Assert.False(FileExist(path),
            "File should only exist after the first append")
    }

    ; ============================================================
    ; Constructor: rotation (Bug #32)
    ; ============================================================

    constructor_rotates_existing_log_over_5mb()
    {
        path := Fixtures.TempPath("log")
        oldPath := path ".old"
        Fixtures.RegisterTempPath(oldPath)

        ; Creates content > 5MB (5MB + 100 bytes, filled with 'A')
        buf := Buffer(LogService.MAX_LOG_SIZE + 100, 65)
        f := FileOpen(path, "w")
        f.RawWrite(buf)
        f.Close()
        Assert.True(FileGetSize(path) > LogService.MAX_LOG_SIZE,
            "Pre-condition: file must be over the threshold")

        ; Rotation happens in the constructor
        srvLog := LogService(path, "INFO")

        Assert.True(FileExist(oldPath),
            ".log.old should exist after rotation")
        Assert.False(FileExist(path),
            "Main log should have been renamed (no appends yet)")
        Assert.True(FileGetSize(oldPath) > LogService.MAX_LOG_SIZE,
            ".log.old is the original file (5MB+)")
    }

    constructor_rotation_overwrites_existing_old_file()
    {
        path := Fixtures.TempPath("log")
        oldPath := path ".old"
        Fixtures.RegisterTempPath(oldPath)

        ; Pre-existing .log.old with small content
        FileAppend("old content from before", oldPath, "UTF-8")
        Assert.True(FileGetSize(oldPath) < 100)

        ; Main file > 5MB
        buf := Buffer(LogService.MAX_LOG_SIZE + 100, 65)
        f := FileOpen(path, "w")
        f.RawWrite(buf)
        f.Close()

        ; Rotation must delete the old .old and rename the new big one
        srvLog := LogService(path, "INFO")

        Assert.True(FileExist(oldPath))
        Assert.True(FileGetSize(oldPath) > LogService.MAX_LOG_SIZE,
            ".log.old is now the big file (replaced the small one)")
    }

    constructor_does_not_rotate_when_log_under_threshold()
    {
        path := Fixtures.TempPath("log")
        oldPath := path ".old"
        Fixtures.RegisterTempPath(oldPath)

        FileAppend("small content", path, "UTF-8")
        sizeBefore := FileGetSize(path)

        srvLog := LogService(path, "INFO")

        Assert.True(FileExist(path), "Main log must remain intact")
        Assert.Equal(sizeBefore, FileGetSize(path),
            "Content must not have changed (no rotation)")
        Assert.False(FileExist(oldPath),
            ".log.old should not exist (rotation did not happen)")
    }

    constructor_does_not_rotate_when_log_does_not_exist()
    {
        path := Fixtures.TempPath("log")
        oldPath := path ".old"
        Fixtures.RegisterTempPath(oldPath)

        ; Does not create the file - constructor should be fine
        srvLog := LogService(path, "INFO")

        Assert.False(FileExist(path))
        Assert.False(FileExist(oldPath))
    }

    ; ============================================================
    ; Levels and filter
    ; ============================================================

    info_writes_to_file_with_default_buffer()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG")
        srvLog.Info("hello")
        Assert.Equal(1, Fixtures.FileLineCount(path))
    }

    warn_writes_to_file_with_default_buffer()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG")
        srvLog.Warn("hello")
        Assert.Equal(1, Fixtures.FileLineCount(path))
    }

    error_writes_to_file_with_default_buffer()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG")
        srvLog.Error("hello")
        Assert.Equal(1, Fixtures.FileLineCount(path))
    }

    debug_filtered_out_when_min_level_is_info()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "INFO")
        srvLog.Debug("hidden")
        srvLog.Flush()
        Assert.Equal(0, Fixtures.FileLineCount(path),
            "DEBUG must not appear with minLevel INFO")
    }

    debug_written_when_min_level_is_debug()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG")
        srvLog.Debug("visible")
        Assert.Equal(1, Fixtures.FileLineCount(path))
    }

    set_min_level_changes_filter_dynamically()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "INFO")

        srvLog.Debug("hidden1")
        Assert.Equal(0, Fixtures.FileLineCount(path))

        srvLog.SetMinLevel("DEBUG")
        srvLog.Debug("visible1")
        Assert.Equal(1, Fixtures.FileLineCount(path))

        srvLog.SetMinLevel("ERROR")
        srvLog.Info("hidden2")
        srvLog.Warn("hidden3")
        ; Only the previous 2 + still just the first INFO that went through
        ; Expected: 1 line (debug visible1) - INFO/WARN now filtered
        Assert.Equal(1, Fixtures.FileLineCount(path))
    }

    ; ============================================================
    ; Format
    ; ============================================================

    log_line_format_contains_timestamp_level_context_msg()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG")
        srvLog.Info("hello world", "TestCtx")

        content := Fixtures.FileReadAll(path)
        ; Expected format: [yyyy-MM-dd HH:mm:ss] INFO [TestCtx] hello world
        matched := RegExMatch(content,
            "^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] INFO \[TestCtx\] hello world")
        Assert.True(matched > 0,
            "Format does not match, got: " content)
    }

    empty_context_omits_context_brackets()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG")
        srvLog.Info("no context here")

        content := Fixtures.FileReadAll(path)
        ; With empty context: [...ts...] INFO msg (no [] between level and msg)
        Assert.True(InStr(content, "] INFO no context here") > 0,
            "Without context there should be no empty brackets, got: " content)
        Assert.False(InStr(content, "[] ") > 0,
            "There should not exist '[] ' (empty brackets)")
    }

    ; ============================================================
    ; Buffer
    ; ============================================================

    buffer_holds_info_until_size_reached()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG", 3)

        srvLog.Info("line1")
        Assert.Equal(0, Fixtures.FileLineCount(path),
            "1/3 - still in buffer")
        srvLog.Info("line2")
        Assert.Equal(0, Fixtures.FileLineCount(path),
            "2/3 - still in buffer")
    }

    buffer_flushes_when_size_reached()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG", 3)

        srvLog.Info("line1")
        srvLog.Info("line2")
        srvLog.Info("line3")   ; 3/3 - flush
        Assert.Equal(3, Fixtures.FileLineCount(path))
    }

    warn_flushes_pending_buffer_before_writing_preserving_order()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG", 10)

        srvLog.Info("first_info")
        srvLog.Info("second_info")
        Assert.Equal(0, Fixtures.FileLineCount(path), "Buffer 2/10")

        srvLog.Warn("the_warning")

        Assert.Equal(3, Fixtures.FileLineCount(path),
            "2 buffered INFO + 1 immediate WARN")

        content  := Fixtures.FileReadAll(path)
        posFirst := InStr(content, "first_info")
        posSec   := InStr(content, "second_info")
        posWarn  := InStr(content, "the_warning")

        Assert.True(posFirst > 0,                "first_info present")
        Assert.True(posSec   > posFirst,         "second_info after first")
        Assert.True(posWarn  > posSec,           "WARN after INFOs (chronological order)")
    }

    error_flushes_pending_buffer_before_writing_preserving_order()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG", 10)

        srvLog.Debug("pre_debug")
        srvLog.Info("pre_info")
        srvLog.Error("the_error")

        content := Fixtures.FileReadAll(path)
        posDbg := InStr(content, "pre_debug")
        posInf := InStr(content, "pre_info")
        posErr := InStr(content, "the_error")
        Assert.True(posDbg > 0)
        Assert.True(posInf > posDbg)
        Assert.True(posErr > posInf, "ERROR after the pending ones")
    }

    ; ============================================================
    ; Flush
    ; ============================================================

    flush_writes_pending_buffer_immediately()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG", 5)

        srvLog.Info("buffered1")
        srvLog.Info("buffered2")
        Assert.Equal(0, Fixtures.FileLineCount(path))

        srvLog.Flush()
        Assert.Equal(2, Fixtures.FileLineCount(path))
    }

    flush_on_empty_buffer_is_noop_and_does_not_create_file()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG", 5)
        srvLog.Flush()
        Assert.False(FileExist(path),
            "Flush on an empty buffer should not create the file")
    }

    ; ============================================================
    ; Counters
    ; ============================================================

    warn_counter_increments_regardless_of_min_level()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "ERROR")   ; filters out WARN

        srvLog.Warn("filtered out of file")
        srvLog.Warn("also filtered")

        Assert.Equal(2, srvLog.GetWarnCount(),
            "Counter must count even with WARN filtered out")
        Assert.Equal(0, Fixtures.FileLineCount(path),
            "But nothing should have gone to the file")
    }

    error_counter_increments_regardless_of_min_level()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "ERROR")

        srvLog.Error("e1")
        srvLog.Error("e2")
        srvLog.Error("e3")

        Assert.Equal(3, srvLog.GetErrorCount())
    }

    info_and_debug_do_not_increment_warn_error_counters()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG")

        srvLog.Debug("d")
        srvLog.Info("i")
        srvLog.Debug("d2")

        Assert.Equal(0, srvLog.GetWarnCount())
        Assert.Equal(0, srvLog.GetErrorCount())
    }

    reset_counts_zeroes_warn_and_error_counters()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG")

        srvLog.Warn("w")
        srvLog.Error("e")
        Assert.Equal(1, srvLog.GetWarnCount())
        Assert.Equal(1, srvLog.GetErrorCount())

        srvLog.ResetCounts()

        Assert.Equal(0, srvLog.GetWarnCount())
        Assert.Equal(0, srvLog.GetErrorCount())
    }
}

TestRegistry.Register(LogServiceTests)
