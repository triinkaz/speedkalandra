; ============================================================
; LogService — log estruturado para uso em todo o app
; ============================================================
;
; Uso:
;     log := LogService(A_ScriptDir "\data\speedkalandra.log", "INFO")
;     log.Info("App iniciado")
;     log.Warn("Algo estranho", "TimerService")
;     log.Error("Falha critica", "LogMonitor")
;
; Convencao:
;   - Cada modulo passa seu nome como `context` para facilitar grep no log
;   - Logger nunca pode estourar: erros internos cadem em OutputDebug
;
; Nivel minimo:
;   DEBUG < INFO < WARN < ERROR
;   minLevel="INFO" filtra DEBUG. minLevel="DEBUG" mostra tudo.
;
; Para testes, use NullLogger (zero overhead) ou InMemoryLogger
; (captura linhas em array para asserts).
;
; ------------------------------------------------------------
; BUFFERING (refactor R7):
;
; LogService aceita `bufferSize` no construtor:
;   - 1 (default): flush imediato em cada linha. Compat com testes
;     que verificam conteudo do arquivo imediatamente apos log call.
;   - N > 1: bufferiza INFO/DEBUG ate N linhas, depois Flush.
;     WARN/ERROR sempre flush imediato (preserva ordem ao flushar
;     buffer pendente antes da linha critica).
;
; Producao usa N=32 pra reduzir I/O syscalls. Crash entre flushes
; perde ate' 32 linhas INFO/DEBUG — nao critico porque WARN/ERROR
; sempre passam imediatamente. Plus: app.Stop() chama Flush(),
; e OnExit handler no entrypoint tambem (cobre exit normal e ctrl-C).
;
; ------------------------------------------------------------
; Interface implicita (duck-typed): qualquer objeto com
; Debug/Info/Warn/Error com assinatura (msg, context := "")
; pode ser usado como logger.
; ------------------------------------------------------------

class LogService
{
    static LEVEL_DEBUG := 0
    static LEVEL_INFO  := 1
    static LEVEL_WARN  := 2
    static LEVEL_ERROR := 3

    ; v17.15 (Bug #32): tamanho maximo antes de rotacionar log.
    ; Quando log atinge esse tamanho, renomeia pra .log.old (sobrescreve
    ; .old anterior) e comeca um novo arquivo. Mantem historico curto
    ; (uma rotacao = ate 10MB total) e evita arquivo crescer indefinidamente.
    static MAX_LOG_SIZE := 5 * 1024 * 1024   ; 5MB

    _logFile    := ""
    _minLevel   := 1   ; INFO
    _bufferSize := 1   ; sem buffer por default (compat testes)
    _buffer     := ""  ; Array<string> de linhas pendentes
    _warnCount  := 0   ; contador de WARN logados desde criacao/ResetCounts
    _errorCount := 0   ; contador de ERROR logados desde criacao/ResetCounts

    __New(logFile, minLevel := "INFO", bufferSize := 1)
    {
        if !IsNumber(bufferSize) || bufferSize < 1
            throw ValueError("LogService: bufferSize deve ser inteiro >= 1")
        this._logFile    := logFile
        this._minLevel   := this._ParseLevel(minLevel)
        this._bufferSize := bufferSize
        this._buffer     := []
        this._EnsureLogDir()
        ; v17.15 (Bug #32): rotaciona log se passou de MAX_LOG_SIZE
        ; antes de comecar a escrever novas linhas.
        this._RotateIfTooBig()
    }

    Debug(msg, context := "") => this._Log(LogService.LEVEL_DEBUG, "DEBUG", msg, context)
    Info(msg, context := "")  => this._Log(LogService.LEVEL_INFO,  "INFO",  msg, context)
    Warn(msg, context := "")  => this._Log(LogService.LEVEL_WARN,  "WARN",  msg, context)
    Error(msg, context := "") => this._Log(LogService.LEVEL_ERROR, "ERROR", msg, context)

    SetMinLevel(level)
    {
        this._minLevel := this._ParseLevel(level)
    }

    ; ============================================================
    ; Counters de severidade (WARN/ERROR)
    ;
    ; Contam INDEPENDENTEMENTE do minLevel — eventos aconteceram
    ; mesmo que o display esteja filtrado. Util pra surface no boot:
    ; emitir TrayTip quando o boot teve warnings/errors.
    ;
    ; Resetam via ResetCounts (ex: depois de mostrar TrayTip de boot,
    ; pra que warnings durante runtime nao acumulem na contagem).
    ; ============================================================
    GetWarnCount()  => this._warnCount
    GetErrorCount() => this._errorCount

    ResetCounts()
    {
        this._warnCount  := 0
        this._errorCount := 0
    }

    ; ============================================================
    ; Flush() — escreve buffer pendente no arquivo.
    ;
    ; Idempotente: chamado em buffer vazio eh no-op.
    ; Chamado por:
    ;   - app.Stop() ao desligar normalmente
    ;   - OnExit handler no entrypoint (cobre Ctrl-C, fechar app)
    ;   - Internamente quando buffer atinge bufferSize
    ;   - Internamente antes de cada WARN/ERROR (preserva ordem)
    ; ============================================================
    Flush()
    {
        this._FlushInternal()
    }

    _Log(numericLevel, levelName, msg, context)
    {
        ; Conta WARN/ERROR INDEPENDENTEMENTE do minLevel. Aconteceu o
        ; evento, conta — mesmo que o display esteja filtrado.
        if (numericLevel = LogService.LEVEL_WARN)
            this._warnCount += 1
        else if (numericLevel = LogService.LEVEL_ERROR)
            this._errorCount += 1

        if (numericLevel < this._minLevel)
            return

        ts   := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
        ctx  := (context != "") ? "[" context "] " : ""
        line := "[" ts "] " levelName " " ctx msg "`n"

        ; WARN/ERROR: flush buffer primeiro (preserva ordem cronologica)
        ; e escreve linha imediatamente. Mensagens criticas nao podem
        ; esperar buffer encher — user pode estar diagnosticando crash.
        if (numericLevel >= LogService.LEVEL_WARN)
        {
            this._FlushInternal()
            this._WriteDirect(line)
            OutputDebug(line)
            return
        }

        ; INFO/DEBUG: append ao buffer
        this._buffer.Push(line)
        if (this._buffer.Length >= this._bufferSize)
            this._FlushInternal()
    }

    _FlushInternal()
    {
        if (this._buffer.Length = 0)
            return

        ; Concatena linhas em chunk único pra reduzir syscalls (1 FileAppend
        ; em vez de N). Clear ANTES do write — se write falhar, buffer ja
        ; foi consumido (perda controlada vs retry-loop infinito).
        chunk := ""
        for _, line in this._buffer
            chunk .= line
        this._buffer := []
        this._WriteDirect(chunk)
    }

    _WriteDirect(content)
    {
        try
        {
            FileAppend(content, this._logFile, "UTF-8")
        }
        catch as e
        {
            ; Logger NUNCA pode quebrar a aplicacao.
            ; Fallback: cuspe em OutputDebug e segue a vida.
            OutputDebug("LogService falhou: " e.Message " | conteudo: " content)
        }
    }

    _ParseLevel(level)
    {
        switch level
        {
            case "DEBUG", 0: return LogService.LEVEL_DEBUG
            case "INFO",  1: return LogService.LEVEL_INFO
            case "WARN",  2: return LogService.LEVEL_WARN
            case "ERROR", 3: return LogService.LEVEL_ERROR
        }
        return LogService.LEVEL_INFO
    }

    _EnsureLogDir()
    {
        SplitPath(this._logFile, , &dir)
        if (dir != "" && !DirExist(dir))
        {
            try DirCreate(dir)
        }
    }

    ; ============================================================
    ; _RotateIfTooBig (v17.15 - Bug #32)
    ;
    ; Verifica tamanho do log no boot. Se passou de MAX_LOG_SIZE,
    ; renomeia pra .log.old (sobrescreve .old anterior se existir)
    ; e o proximo FileAppend cria fresh.
    ;
    ; Falhas silenciam pra OutputDebug — logger nao pode quebrar app.
    ; ============================================================
    _RotateIfTooBig()
    {
        if (this._logFile = "" || !FileExist(this._logFile))
            return
        try
        {
            size := FileGetSize(this._logFile)
            if (size < LogService.MAX_LOG_SIZE)
                return
            oldPath := this._logFile ".old"
            if FileExist(oldPath)
            {
                try FileDelete(oldPath)
            }
            FileMove(this._logFile, oldPath)
        }
        catch as ex
        {
            OutputDebug("LogService._RotateIfTooBig falhou: " ex.Message)
        }
    }
}

; ------------------------------------------------------------
; NullLogger — implementacao no-op para testes ou contextos
; onde logging e indesejavel
; ------------------------------------------------------------
class NullLogger
{
    Debug(msg, context := "") => 0
    Info(msg, context := "")  => 0
    Warn(msg, context := "")  => 0
    Error(msg, context := "") => 0
    Flush() => 0   ; no-op (R7) — simetria com LogService
    GetWarnCount()  => 0   ; simetria com LogService
    GetErrorCount() => 0
    ResetCounts()   => 0
}

; ------------------------------------------------------------
; InMemoryLogger — captura linhas em array, ideal para asserts
; ------------------------------------------------------------
class InMemoryLogger
{
    entries := []   ; Array of Map(level, msg, context, ts)

    Debug(msg, context := "") => this._Capture("DEBUG", msg, context)
    Info(msg, context := "")  => this._Capture("INFO",  msg, context)
    Warn(msg, context := "")  => this._Capture("WARN",  msg, context)
    Error(msg, context := "") => this._Capture("ERROR", msg, context)

    GetWarnCount()
    {
        n := 0
        for _, e in this.entries
        {
            if (e["level"] = "WARN")
                n += 1
        }
        return n
    }

    GetErrorCount()
    {
        n := 0
        for _, e in this.entries
        {
            if (e["level"] = "ERROR")
                n += 1
        }
        return n
    }

    ResetCounts() => this.Clear()

    Clear()
    {
        this.entries := []
    }

    HasEntry(levelName, msgSubstring := "")
    {
        for _, entry in this.entries
        {
            if (entry["level"] != levelName)
                continue
            if (msgSubstring = "" || InStr(entry["msg"], msgSubstring))
                return true
        }
        return false
    }

    _Capture(levelName, msg, context)
    {
        this.entries.Push(Map(
            "level",   levelName,
            "msg",     msg,
            "context", context,
            "ts",      A_Now
        ))
    }

    Flush() => 0   ; no-op (R7) — InMemoryLogger nao tem buffer, mas
                   ; precisa do metodo pra duck-typing com LogService
}
