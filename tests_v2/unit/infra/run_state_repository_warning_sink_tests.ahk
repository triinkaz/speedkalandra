; ============================================================
; RunStateRepository.LoadZoneTotals warning-taxonomy tests
; ============================================================
;
; LoadZoneTotals follows a graded failure taxonomy (see
; ARCHITECTURE.md \u00a7 14):
;
;   File missing         \u2192 silent return empty
;   FileRead throws      \u2192 Warn + return empty
;   Line malformed       \u2192 skip silently
;   All lines malformed  \u2192 Warn (file likely corrupt)
;
; The FileRead-throws case is not directly testable without file
; lock/permission control (and AHK has no clean way to simulate
; that). The other three are covered here. The corrupt-file case
; uses a file that's non-empty but where no line matches the
; "name=positive_integer" shape.
;
; The save-failure path through the injected WarningSink IS
; covered (`save_warns_when_atomic_writer_fails`) by pointing the
; zone-totals path at a non-existent directory so AtomicWriter's
; FileWrite throws. The clear-failure path is NOT covered \u2014
; forcing FileDelete to throw needs Win32 sharing-violation
; plumbing that isn't worth the test complexity for a path that
; is already covered manually in production by the surrounding
; SaveZoneTotals failure handling.
;
; Constructor sink validation (Map() rejected by WarningSink.Resolve)
; is asserted at the end of the suite.


class RunStateRepositoryWarningSinkTests extends TestCase
{
    iniPath := ""
    zonesPath := ""
    ini := ""
    sink := ""
    repo := ""

    Setup()
    {
        this.iniPath := Fixtures.TempPath("ini")
        ; The zone totals path is derived from the INI path with the
        ; same base name + "_zones.txt" suffix.
        SplitPath(this.iniPath, , &dir, , &nameNoExt)
        this.zonesPath := (dir != "" ? dir "\" : "") nameNoExt "_zones.txt"

        this.ini := IniFile(this.iniPath)
        this.sink := InMemoryWarningSink()
        this.repo := RunStateRepository(this.ini, this.sink)
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- LoadZoneTotals taxonomy ---
        "load_returns_empty_silently_when_file_missing",
        "load_skips_malformed_lines_silently_when_some_are_valid",
        "load_warns_when_file_non_empty_but_no_valid_lines",
        "load_does_not_warn_on_empty_file",
        "load_does_not_warn_when_file_has_only_blank_lines",

        ; --- SaveZoneTotals / ClearZoneTotals ---
        "save_does_not_warn_on_happy_path",
        "clear_does_not_warn_when_file_missing",
        "clear_does_not_warn_on_happy_path",

        ; --- SaveZoneTotals failure (AtomicWriter throws) ---
        "save_warns_when_atomic_writer_fails",

        ; --- Constructor sink validation ---
        "constructor_throws_when_warning_sink_lacks_warn_method"
    ]

    ; ============================================================
    ; LoadZoneTotals taxonomy
    ; ============================================================

    load_returns_empty_silently_when_file_missing()
    {
        ; The setup did NOT create the zones file. Loading must be
        ; silent \u2014 a fresh install / brand-new run has no totals
        ; persisted yet, and that's not an error condition.
        result := this.repo.LoadZoneTotals()

        Assert.Equal(0, result.Count)
        Assert.Equal(0, this.sink.Count())
    }

    load_skips_malformed_lines_silently_when_some_are_valid()
    {
        ; A user that edited the file by hand may have introduced a
        ; broken line; as long as at least one valid line is parsed,
        ; the missing entries are skipped silently \u2014 a WARN per
        ; malformed line would flood the log.
        content := "Mud Burrow=215000`r`n"
                .  "this line is broken`r`n"
                .  "=999`r`n"               ; empty zone name
                .  "Clearfell=180000`r`n"
                .  "Bad Zone=not-a-number`r`n"
        FileAppend(content, this.zonesPath, "UTF-8")

        result := this.repo.LoadZoneTotals()

        Assert.Equal(2, result.Count)
        Assert.Equal(215000, result["Mud Burrow"])
        Assert.Equal(180000, result["Clearfell"])
        Assert.Equal(0, this.sink.Count())   ; silent skip
    }

    load_warns_when_file_non_empty_but_no_valid_lines()
    {
        ; Every non-empty line is malformed. The file is present and
        ; non-empty but produced zero entries \u2014 likely corruption,
        ; not manual editing. The WARN surfaces this.
        content := "garbage line one`r`n"
                .  "garbage line two`r`n"
                .  "=`r`n"
                .  "totally broken=not-a-number`r`n"
        FileAppend(content, this.zonesPath, "UTF-8")

        result := this.repo.LoadZoneTotals()

        Assert.Equal(0, result.Count)
        Assert.Equal(1, this.sink.Count())
        Assert.True(this.sink.HasMessage("corrupt"))
    }

    load_does_not_warn_on_empty_file()
    {
        ; Empty file should not trigger the corrupt-file WARN \u2014
        ; "no non-empty lines" is different from "every non-empty
        ; line failed to parse".
        FileAppend("", this.zonesPath, "UTF-8")

        result := this.repo.LoadZoneTotals()

        Assert.Equal(0, result.Count)
        Assert.Equal(0, this.sink.Count())
    }

    load_does_not_warn_when_file_has_only_blank_lines()
    {
        FileAppend("`r`n`r`n   `r`n", this.zonesPath, "UTF-8")

        result := this.repo.LoadZoneTotals()

        Assert.Equal(0, result.Count)
        Assert.Equal(0, this.sink.Count())
    }

    ; ============================================================
    ; SaveZoneTotals / ClearZoneTotals \u2014 happy paths stay silent
    ; ============================================================

    save_does_not_warn_on_happy_path()
    {
        this.repo.SaveZoneTotals(Map("Mud Burrow", 215000))
        Assert.Equal(0, this.sink.Count())
    }

    clear_does_not_warn_when_file_missing()
    {
        ; ClearZoneTotals is a no-op when the file doesn't exist;
        ; that's the normal path on a fresh install and must not warn.
        this.repo.ClearZoneTotals()
        Assert.Equal(0, this.sink.Count())
    }

    clear_does_not_warn_on_happy_path()
    {
        this.repo.SaveZoneTotals(Map("Mud Burrow", 215000))
        this.repo.ClearZoneTotals()
        Assert.Equal(0, this.sink.Count())
    }

    save_warns_when_atomic_writer_fails()
    {
        ; Force AtomicWriter to fail by pointing the zone totals
        ; path at a location whose "parent directory" is actually a
        ; file that already exists. AtomicWriter creates missing
        ; parent dirs (covered by its own happy-path tests), but
        ; cannot create a dir on top of an existing file — DirCreate
        ; throws OSError. The repo's catch routes the exception
        ; through the WarningSink.
        parentAsFile := Fixtures.TempPath("txt")
        FileAppend("not a directory", parentAsFile, "UTF-8")
        bogus := parentAsFile . "\zones.txt"
        this.repo._zoneTotalsPath := bogus

        this.repo.SaveZoneTotals(Map("Mud Burrow", 215000))

        Assert.Equal(1, this.sink.Count())
        Assert.True(this.sink.HasMessage("SaveZoneTotals failed"))
    }

    constructor_throws_when_warning_sink_lacks_warn_method()
    {
        ; Map() is an object, looks plausible in a wiring bug, but
        ; doesn't satisfy the WarningSink duck-typed contract. The
        ; constructor (via WarningSink.Resolve) must reject it.
        path := Fixtures.TempPath("ini")
        ini := IniFile(path)
        Assert.Throws(TypeError, () => RunStateRepository(ini, Map("not", "a sink")))
    }
}


TestRegistry.Register(RunStateRepositoryWarningSinkTests)
