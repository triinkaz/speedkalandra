; ============================================================
; LogService — structured logging for use across the app
; ============================================================
;
; Usage:
;     log := LogService(A_ScriptDir "\data\speedkalandra.log", "INFO")
;     log.Info("App started")
;     log.Warn("Something odd", "TimerService")
;     log.Error("Critical failure", "LogMonitor")
;
; Convention:
;   - Each module passes its name as `context` to ease grepping the log
;   - Logger must never throw: internal errors fall back to OutputDebug
;
; Minimum level:
;   DEBUG < INFO < WARN < ERROR
;   minLevel="INFO" filters out DEBUG. minLevel="DEBUG" shows everything.
;
; For tests, use NullLogger (zero overhead) or InMemoryLogger
; (captures lines into an array for asserts).
;
; ------------------------------------------------------------
; BUFFERING (refactor R7):
;
; LogService accepts `bufferSize` in the constructor:
;   - 1 (default): immediate flush on each line. Compatible with tests
;     that check file contents immediately after a log call.
;   - N > 1: buffers INFO/DEBUG up to N lines, then Flush.
;     WARN/ERROR always flush immediately (preserves order by flushing
;     pending buffer before the critical line).
;
; Production uses N=32 to reduce I/O syscalls. A crash between flushes
; loses up to 32 INFO/DEBUG lines — not critical because WARN/ERROR
; always go through immediately. Plus: app.Stop() calls Flush(),
; and the OnExit handler in the entrypoint does too (covers normal
; exit and ctrl-C).
;
; ------------------------------------------------------------
; Implicit interface (duck-typed): any object with
; Debug/Info/Warn/Error with signature (msg, context := "")
; can be used as a logger.
; ------------------------------------------------------------

class LogService
{
    static LEVEL_DEBUG := 0
    static LEVEL_INFO  := 1
    static LEVEL_WARN  := 2
    static LEVEL_ERROR := 3

    ; v17.15 (Bug #32): maximum size before rotating the log.
    ; When the log reaches this size, it is renamed to .log.old
    ; (overwriting any previous .old) and a new file is started. Keeps
    ; a short history (one rotation = up to 10MB total) and prevents
    ; the file from growing indefinitely.
    static MAX_LOG_SIZE := 5 * 1024 * 1024   ; 5MB

    _logFile    := ""
    _minLevel   := 1   ; INFO
    _bufferSize := 1   ; no buffer by default (test compat)
    _buffer     := ""  ; Array<string> of pending lines
    _warnCount  := 0   ; counter of WARNs logged since creation/ResetCounts
    _errorCount := 0   ; counter of ERRORs logged since creation/ResetCounts
    _currentDate := "" ; v0.1.4: "YYYYMMDD" of last write — used for daily rotation

    __New(logFile, minLevel := "INFO", bufferSize := 1)
    {
        if !IsNumber(bufferSize) || bufferSize < 1
            throw ValueError("LogService: bufferSize must be an integer >= 1")
        this._logFile    := logFile
        this._minLevel   := this._ParseLevel(minLevel)
        this._bufferSize := bufferSize
        this._buffer     := []
        this._currentDate := FormatTime(A_Now, "yyyyMMdd")
        this._EnsureLogDir()
        ; v17.15 (Bug #32): rotate log if it has exceeded MAX_LOG_SIZE
        ; before starting to write new lines.
        this._RotateIfTooBig()
        ; v0.1.4: also rotate if the existing log was last touched on a
        ; previous day. Keeps daily history under .log.YYYYMMDD names.
        this._RotateIfNewDay()
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
    ; Severity counters (WARN/ERROR)
    ;
    ; Counted INDEPENDENTLY of minLevel — events happened even if
    ; the display is filtered. Useful to surface on boot: emit a
    ; TrayTip when boot had warnings/errors.
    ;
    ; Reset via ResetCounts (e.g. after showing the boot TrayTip,
    ; so warnings during runtime don't accumulate in the count).
    ; ============================================================
    GetWarnCount()  => this._warnCount
    GetErrorCount() => this._errorCount

    ResetCounts()
    {
        this._warnCount  := 0
        this._errorCount := 0
    }

    ; ============================================================
    ; Flush() — writes pending buffer to the file.
    ;
    ; Idempotent: called on an empty buffer is a no-op.
    ; Called by:
    ;   - app.Stop() on normal shutdown
    ;   - OnExit handler in the entrypoint (covers Ctrl-C, closing the app)
    ;   - Internally when the buffer reaches bufferSize
    ;   - Internally before each WARN/ERROR (preserves order)
    ; ============================================================
    Flush()
    {
        this._FlushInternal()
    }

    _Log(numericLevel, levelName, msg, context)
    {
        ; Count WARN/ERROR INDEPENDENTLY of minLevel. The event
        ; happened, so it counts — even if the display is filtered.
        if (numericLevel = LogService.LEVEL_WARN)
            this._warnCount += 1
        else if (numericLevel = LogService.LEVEL_ERROR)
            this._errorCount += 1

        if (numericLevel < this._minLevel)
            return

        ; v0.1.4: check daily rotation on each write. Inexpensive
        ; (FormatTime + string compare) and avoids depending on a
        ; SetTimer to rotate at midnight.
        this._RotateIfNewDay()

        ts   := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
        ctx  := (context != "") ? "[" context "] " : ""
        line := "[" ts "] " levelName " " ctx msg "`n"

        ; WARN/ERROR: flush buffer first (preserves chronological order)
        ; and write line immediately. Critical messages cannot wait for
        ; the buffer to fill — user may be diagnosing a crash.
        if (numericLevel >= LogService.LEVEL_WARN)
        {
            this._FlushInternal()
            this._WriteDirect(line)
            OutputDebug(line)
            return
        }

        ; INFO/DEBUG: append to buffer
        this._buffer.Push(line)
        if (this._buffer.Length >= this._bufferSize)
            this._FlushInternal()
    }

    _FlushInternal()
    {
        if (this._buffer.Length = 0)
            return

        ; Concatenate lines into a single chunk to reduce syscalls (1 FileAppend
        ; instead of N). Clear BEFORE the write — if the write fails, the buffer
        ; has already been consumed (controlled loss vs infinite retry loop).
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
            ; Logger must NEVER break the application.
            ; Fallback: dump to OutputDebug and move on.
            OutputDebug("LogService failed: " e.Message " | content: " content)
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
    ; Checks log size on boot. If it has exceeded MAX_LOG_SIZE,
    ; renames it to .log.old (overwriting any previous .old)
    ; and the next FileAppend creates a fresh one.
    ;
    ; Failures fall back to OutputDebug — logger must not break the app.
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
            OutputDebug("LogService._RotateIfTooBig failed: " ex.Message)
        }
    }

    ; ============================================================
    ; _RotateIfNewDay (v0.1.4)
    ;
    ; Rotates the active log when the date changes. Called on each
    ; write — a string compare per line is negligible compared to the
    ; FileAppend syscall.
    ;
    ; When the date stamp on disk is older than today, the log is
    ; renamed to "<base>.log.YYYYMMDD" (the date of the previous
    ; session) and a new log starts fresh. Old daily files stay on
    ; disk — the user can clean them up manually. This is intentional
    ; (history is cheap, accidental loss isn't).
    ;
    ; Date detection works from the file's last-modified timestamp,
    ; not from the in-memory _currentDate cache. The cache only avoids
    ; redundant FileGetTime calls on consecutive writes within the
    ; same day.
    ; ============================================================
    _RotateIfNewDay()
    {
        if (this._logFile = "")
            return
        today := FormatTime(A_Now, "yyyyMMdd")
        ; Fast path: same day as the last write — nothing to do.
        if (today = this._currentDate)
            return
        this._currentDate := today

        ; Slow path: only relevant when the file already exists. A
        ; brand-new file on a brand-new day has no previous-day content.
        if !FileExist(this._logFile)
            return
        try
        {
            ; Last-modified timestamp; AHK returns local "yyyyMMddHHmmss".
            fileTime := FileGetTime(this._logFile, "M")
            fileDate := SubStr(fileTime, 1, 8)
            if (fileDate = today)
                return   ; file is from today, do not rotate

            ; Flush buffer BEFORE moving the file, otherwise pending
            ; lines would be appended to the new (empty) log.
            this._FlushInternal()

            rotatedPath := this._logFile "." fileDate
            ; If a rotated file with the same date already exists
            ; (unlikely — means the app was already restarted today
            ; with stale cache), delete to avoid FileMove failing.
            if FileExist(rotatedPath)
                try FileDelete(rotatedPath)
            FileMove(this._logFile, rotatedPath)
        }
        catch as ex
        {
            OutputDebug("LogService._RotateIfNewDay failed: " ex.Message)
        }
    }
}

; ------------------------------------------------------------
; NullLogger — no-op implementation for tests or contexts
; where logging is undesirable
; ------------------------------------------------------------
class NullLogger
{
    Debug(msg, context := "") => 0
    Info(msg, context := "")  => 0
    Warn(msg, context := "")  => 0
    Error(msg, context := "") => 0
    Flush() => 0   ; no-op (R7) — symmetry with LogService
    GetWarnCount()  => 0   ; symmetry with LogService
    GetErrorCount() => 0
    ResetCounts()   => 0
}

; ------------------------------------------------------------
; InMemoryLogger — captures lines into an array, ideal for asserts
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

    Flush() => 0   ; no-op (R7) — InMemoryLogger has no buffer, but
                   ; needs the method to duck-type with LogService
}
