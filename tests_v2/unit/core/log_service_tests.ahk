; ============================================================
; LogService tests
; ============================================================
;
; Cobre as propriedades documentadas no header do log_service.ahk:
;
;   - Niveis: DEBUG < INFO < WARN < ERROR, filtragem via minLevel
;   - SetMinLevel dinamico
;   - Format: [yyyy-MM-dd HH:mm:ss] LEVEL [Ctx] msg`n
;             (context vazio omite os colchetes)
;   - Buffer: bufferSize=1 (default) flush imediato, N>1 acumula
;   - WARN/ERROR: flush imediato, sempre apos drain do buffer pendente
;                 (preserva ordem cronologica)
;   - Counters de WARN/ERROR: contam INDEPENDENTE de minLevel
;   - Rotacao (Bug #32): se log existente > 5MB no construtor,
;     renomeia pra .log.old (sobrescreve .old anterior)
;
; Convencao: `srvLog` em vez de `log` pra nao colidir com global.

class LogServiceTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Construtor: validacao ---
        "constructor_rejects_buffer_size_zero",
        "constructor_rejects_buffer_size_negative",
        "constructor_rejects_buffer_size_non_number",

        ; --- Construtor: filesystem ---
        "constructor_creates_parent_directory_if_missing",
        "constructor_does_not_create_log_file_until_first_write",

        ; --- Construtor: rotacao (Bug #32) ---
        "constructor_rotates_existing_log_over_5mb",
        "constructor_rotation_overwrites_existing_old_file",
        "constructor_does_not_rotate_when_log_under_threshold",
        "constructor_does_not_rotate_when_log_does_not_exist",

        ; --- Niveis e filtro ---
        "info_writes_to_file_with_default_buffer",
        "warn_writes_to_file_with_default_buffer",
        "error_writes_to_file_with_default_buffer",
        "debug_filtered_out_when_min_level_is_info",
        "debug_written_when_min_level_is_debug",
        "set_min_level_changes_filter_dynamically",

        ; --- Formato ---
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
    ; Construtor: validacao
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
    ; Construtor: filesystem
    ; ============================================================

    constructor_creates_parent_directory_if_missing()
    {
        tmpDir := Fixtures.TempDir()
        nestedPath := tmpDir "\sub1\sub2\log.txt"

        srvLog := LogService(nestedPath, "INFO")
        srvLog.Info("anything")
        srvLog.Flush()

        Assert.True(FileExist(nestedPath),
            "LogService deveria ter criado o caminho intermediario")
    }

    constructor_does_not_create_log_file_until_first_write()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "INFO")
        Assert.False(FileExist(path),
            "Arquivo so deveria existir depois do primeiro append")
    }

    ; ============================================================
    ; Construtor: rotacao (Bug #32)
    ; ============================================================

    constructor_rotates_existing_log_over_5mb()
    {
        path := Fixtures.TempPath("log")
        oldPath := path ".old"
        Fixtures.RegisterTempPath(oldPath)

        ; Cria conteudo > 5MB (5MB + 100 bytes, preenchido com 'A')
        buf := Buffer(LogService.MAX_LOG_SIZE + 100, 65)
        f := FileOpen(path, "w")
        f.RawWrite(buf)
        f.Close()
        Assert.True(FileGetSize(path) > LogService.MAX_LOG_SIZE,
            "Pre-condicao: arquivo deve estar acima do threshold")

        ; Rotacao acontece no construtor
        srvLog := LogService(path, "INFO")

        Assert.True(FileExist(oldPath),
            ".log.old deveria existir apos rotacao")
        Assert.False(FileExist(path),
            "Log principal deveria ter sido renomeado (sem appends ainda)")
        Assert.True(FileGetSize(oldPath) > LogService.MAX_LOG_SIZE,
            ".log.old eh o arquivo original (5MB+)")
    }

    constructor_rotation_overwrites_existing_old_file()
    {
        path := Fixtures.TempPath("log")
        oldPath := path ".old"
        Fixtures.RegisterTempPath(oldPath)

        ; .log.old PRE-existente com conteudo pequeno
        FileAppend("old content from before", oldPath, "UTF-8")
        Assert.True(FileGetSize(oldPath) < 100)

        ; Arquivo principal > 5MB
        buf := Buffer(LogService.MAX_LOG_SIZE + 100, 65)
        f := FileOpen(path, "w")
        f.RawWrite(buf)
        f.Close()

        ; Rotacao deve apagar .old velho e renomear o novo grande
        srvLog := LogService(path, "INFO")

        Assert.True(FileExist(oldPath))
        Assert.True(FileGetSize(oldPath) > LogService.MAX_LOG_SIZE,
            ".log.old agora e' o arquivo grande (substituiu o pequeno)")
    }

    constructor_does_not_rotate_when_log_under_threshold()
    {
        path := Fixtures.TempPath("log")
        oldPath := path ".old"
        Fixtures.RegisterTempPath(oldPath)

        FileAppend("small content", path, "UTF-8")
        sizeBefore := FileGetSize(path)

        srvLog := LogService(path, "INFO")

        Assert.True(FileExist(path), "Log principal deve continuar intacto")
        Assert.Equal(sizeBefore, FileGetSize(path),
            "Conteudo nao deve ter mudado (sem rotacao)")
        Assert.False(FileExist(oldPath),
            ".log.old nao deveria existir (rotacao nao rolou)")
    }

    constructor_does_not_rotate_when_log_does_not_exist()
    {
        path := Fixtures.TempPath("log")
        oldPath := path ".old"
        Fixtures.RegisterTempPath(oldPath)

        ; Nao cria arquivo - construtor deve ser fine
        srvLog := LogService(path, "INFO")

        Assert.False(FileExist(path))
        Assert.False(FileExist(oldPath))
    }

    ; ============================================================
    ; Niveis e filtro
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
            "DEBUG nao deve aparecer com minLevel INFO")
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
        ; Apenas as 2 anteriores + ainda apenas a primeira INFO que passou
        ; Espera: 1 linha (debug visible1) - INFO/WARN agora filtrados
        Assert.Equal(1, Fixtures.FileLineCount(path))
    }

    ; ============================================================
    ; Formato
    ; ============================================================

    log_line_format_contains_timestamp_level_context_msg()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG")
        srvLog.Info("hello world", "TestCtx")

        content := Fixtures.FileReadAll(path)
        ; Formato esperado: [yyyy-MM-dd HH:mm:ss] INFO [TestCtx] hello world
        matched := RegExMatch(content,
            "^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] INFO \[TestCtx\] hello world")
        Assert.True(matched > 0,
            "Formato nao bate, veio: " content)
    }

    empty_context_omits_context_brackets()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "DEBUG")
        srvLog.Info("no context here")

        content := Fixtures.FileReadAll(path)
        ; Com context vazio: [...ts...] INFO msg (sem [] entre level e msg)
        Assert.True(InStr(content, "] INFO no context here") > 0,
            "Sem context deveria nao ter colchetes vazios, veio: " content)
        Assert.False(InStr(content, "[] ") > 0,
            "Nao deveria existir '[] ' (colchetes vazios)")
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
            "1/3 - ainda em buffer")
        srvLog.Info("line2")
        Assert.Equal(0, Fixtures.FileLineCount(path),
            "2/3 - ainda em buffer")
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
            "2 INFO bufferadas + 1 WARN imediato")

        content  := Fixtures.FileReadAll(path)
        posFirst := InStr(content, "first_info")
        posSec   := InStr(content, "second_info")
        posWarn  := InStr(content, "the_warning")

        Assert.True(posFirst > 0,                "first_info presente")
        Assert.True(posSec   > posFirst,         "second_info depois de first")
        Assert.True(posWarn  > posSec,           "WARN depois das INFO (ordem cronologica)")
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
        Assert.True(posErr > posInf, "ERROR depois das pendentes")
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
            "Flush em buffer vazio nao deveria criar arquivo")
    }

    ; ============================================================
    ; Counters
    ; ============================================================

    warn_counter_increments_regardless_of_min_level()
    {
        path := Fixtures.TempPath("log")
        srvLog := LogService(path, "ERROR")   ; filtra ate WARN

        srvLog.Warn("filtered out of file")
        srvLog.Warn("also filtered")

        Assert.Equal(2, srvLog.GetWarnCount(),
            "Counter deve contar mesmo com WARN filtrado")
        Assert.Equal(0, Fixtures.FileLineCount(path),
            "Mas nada deve ter ido pro arquivo")
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
