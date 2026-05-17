; ============================================================
; Fixtures - helpers shared between tests
; ============================================================
;
; Usage pattern:
;
;   Setup()
;   {
;       this.bus    := Fixtures.MakeBus()
;       this.clock  := Fixtures.MakeFakeClock()
;       this.tmpDir := Fixtures.TempDir()
;       this.iniFile := Fixtures.TempFile("[Section]`nKey=value", "ini")
;   }
;
;   Teardown()
;   {
;       Fixtures.CleanupAll()
;   }
;
; TempDir / TempFile / TempPath register the path in a pool.
; CleanupAll wipes everything from the pool (recursively for dirs).
; Calling CleanupAll in every Teardown avoids leftover junk in A_Temp
; as a suite grows.
;
; MakeBus returns EventBus(NullLogger) - the EventBus is enough for
; most tests; when you need to inspect the log, swap in the
; InMemoryLogger in Setup:
;
;   this.memLog := InMemoryLogger()
;   this.bus    := EventBus(this.memLog)
;
; (NOTE: do not use `log` as a local in tests - it collides with a
; global in some project file and triggers #Warn LocalSameAsGlobal.
; Use `memLog`, `srvLog`, `nullLog`.)

class Fixtures
{
    static _tempPaths := []

    ; ============================================================
    ; Tempfiles / tempdirs / temppaths
    ; ============================================================

    ; Creates a temporary directory, registers it for cleanup, returns the path.
    static TempDir()
    {
        Loop
        {
            path := A_Temp "\sk_test_" Random(100000, 999999)
            if !FileExist(path) && !DirExist(path)
            {
                DirCreate(path)
                Fixtures._tempPaths.Push(path)
                return path
            }
        }
    }

    ; Creates a temporary file with optional content. Registers it for
    ; cleanup. Returns the path.
    static TempFile(content := "", extension := "txt")
    {
        Loop
        {
            path := A_Temp "\sk_test_" Random(100000, 999999) "." extension
            if !FileExist(path)
                break
        }
        FileAppend(content, path, "UTF-8")
        Fixtures._tempPaths.Push(path)
        return path
    }

    ; Generates a unique path WITHOUT creating the file. Useful when
    ; the SUT is the one that should create the file (e.g.: LogService
    ; creates on the first append, rotation happens in the constructor
    ; before the append). Registers it for cleanup anyway - if the SUT
    ; doesn't create it, CleanupAll is a no-op on this path. If it
    ; does, the file is deleted.
    static TempPath(extension := "tmp")
    {
        Loop
        {
            path := A_Temp "\sk_test_" Random(100000, 999999) "." extension
            if !FileExist(path)
            {
                Fixtures._tempPaths.Push(path)
                return path
            }
        }
    }

    ; Registers an external path in the cleanup pool. Useful when the
    ; SUT creates derived files (e.g.: LogService creates .log.old).
    static RegisterTempPath(path)
    {
        Fixtures._tempPaths.Push(path)
    }

    static CleanupAll()
    {
        for _, path in Fixtures._tempPaths
        {
            try
            {
                if DirExist(path)
                    DirDelete(path, true)
                else if FileExist(path)
                    FileDelete(path)
            }
            catch
            {
                ; ignore - tempfile may have vanished for other reasons
            }
        }
        Fixtures._tempPaths := []
    }

    ; ============================================================
    ; File inspection (useful in I/O tests)
    ; ============================================================

    ; Counts newlines (`n) in the file. LogService always ends each
    ; entry with `n, so this counts effective entries. Returns 0 if
    ; the file doesn't exist or is empty.
    static FileLineCount(path)
    {
        if !FileExist(path)
            return 0
        content := FileRead(path, "UTF-8")
        if (content = "")
            return 0
        count := 0
        Loop Parse, content
        {
            if (A_LoopField = "`n")
                count += 1
        }
        return count
    }

    ; Reads the whole file as a UTF-8 string. Returns "" if it doesn't exist.
    static FileReadAll(path)
    {
        if !FileExist(path)
            return ""
        return FileRead(path, "UTF-8")
    }

    ; ============================================================
    ; Factories for common objects
    ; ============================================================

    static MakeBus()
    {
        return EventBus(NullLogger())
    }

    static MakeBusWithLog(&logOut)
    {
        logOut := InMemoryLogger()
        return EventBus(logOut)
    }

    static MakeFakeClock(initialMs := 0, initialNow := "20260101000000")
    {
        return FakeClock(initialNow, initialMs)
    }

    static MakeNullLogger()
    {
        return NullLogger()
    }

    static MakeInMemoryLogger()
    {
        return InMemoryLogger()
    }
}
