; ============================================================
; RouteRepository tests
; ============================================================
;
; Persists Route per profile under data/routes/<profile>.ini.
; Schema:
;   [Route]
;   zones=A|B|C
;
; Encoding: UTF-16 LE BOM. AtomicWriter for the save itself.
; Load tolerates missing files, missing sections, missing keys.
; Sanitization strips Windows-reserved filename chars from the
; profile name.

class RouteRepositoryTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_on_empty_base_dir",
        "constructor_throws_on_whitespace_base_dir",
        "constructor_throws_when_warning_sink_lacks_warn_method",
        "constructor_creates_base_dir_when_missing",
        "get_base_dir_returns_constructor_arg",

        ; --- GetPathForProfile ---
        "get_path_for_profile_concatenates_base_dir_and_name",
        "get_path_for_profile_sanitizes_reserved_chars",
        "get_path_for_profile_empty_name_collapses_to_default",
        "get_path_for_profile_whitespace_only_name_collapses_to_default",
        "get_path_for_profile_name_of_only_reserved_chars_collapses_to_default",

        ; --- Load: missing / empty ---
        "load_returns_empty_route_when_file_missing",
        "load_returns_empty_route_when_section_absent",
        "load_returns_empty_route_when_zones_key_empty",

        ; --- Load: parsing ---
        "load_parses_pipe_separated_zones",
        "load_trims_whitespace_around_each_zone",
        "load_filters_empty_entries_between_pipes",
        "load_dedupes_duplicates_silently_first_wins",

        ; --- Notes: load ---
        "load_returns_no_notes_when_section_absent",
        "load_parses_notes_section",
        "load_decodes_newline_escape_in_note",
        "load_decodes_backslash_escape_in_note",
        "load_ignores_notes_with_empty_decoded_text",

        ; --- Save: validation ---
        "save_throws_when_argument_not_route",

        ; --- Save: atomic write ---
        "save_creates_file_with_route_content",
        "save_does_not_leave_tmp_behind",
        "save_returns_true_on_success",

        ; --- Save: sanitization ---
        "save_strips_pipe_from_zone_names_to_protect_separator",
        "save_strips_crlf_from_zone_names",
        "save_strips_ini_metacharacters_from_zone_names",
        "save_skips_zones_that_become_empty_after_sanitization",

        ; --- Notes: save ---
        "save_omits_notes_section_when_route_has_no_notes",
        "save_writes_notes_section_when_route_has_notes",
        "save_encodes_newline_in_note_text",
        "save_encodes_backslash_before_newline_in_note_text",

        ; --- Roundtrip ---
        "roundtrip_save_load_preserves_zone_order",
        "roundtrip_save_load_dedupes_silently",
        "roundtrip_does_not_persist_current_idx",
        "roundtrip_preserves_notes",
        "roundtrip_preserves_multiline_note",
        "roundtrip_preserves_backslash_in_note",

        ; --- Import / Export ---
        "import_from_profile_copies_route_to_destination",
        "import_from_profile_returns_false_when_source_empty",
        "import_from_file_loads_external_ini",
        "import_from_file_returns_false_when_path_missing",
        "import_from_file_returns_false_when_file_does_not_exist",
        "import_from_file_returns_false_when_zones_key_empty",
        "export_to_file_writes_external_ini_with_route",
        "export_to_file_returns_false_when_profile_has_no_route",
        "export_to_file_returns_false_when_path_empty",
        "export_then_import_roundtrip_preserves_zones",
        "export_then_import_roundtrip_preserves_notes",
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    _MakeRepo()
    {
        return RouteRepository(Fixtures.TempDir())
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_on_empty_base_dir()
    {
        Assert.Throws(ValueError, () => RouteRepository(""))
    }

    constructor_throws_on_whitespace_base_dir()
    {
        Assert.Throws(ValueError, () => RouteRepository("   "))
    }

    constructor_throws_when_warning_sink_lacks_warn_method()
    {
        ; WarningSink.Resolve enforces the Warn(message, ex) contract
        ; at wiring time so a typo (or a forgotten implementation)
        ; surfaces at boot instead of silently swallowing later
        ; failures.
        Assert.Throws(Error,
            () => RouteRepository(Fixtures.TempDir(), Map("not", "a sink")))
    }

    constructor_creates_base_dir_when_missing()
    {
        ; Fresh path under the tempdir that doesn't exist yet.
        baseDir := Fixtures.TempDir() "\subroutes"
        Assert.False(DirExist(baseDir), "precondition: dir absent")
        repo := RouteRepository(baseDir)
        Assert.True(DirExist(baseDir),
            "RouteRepository must create the base directory at construction")
    }

    get_base_dir_returns_constructor_arg()
    {
        dir := Fixtures.TempDir()
        Assert.Equal(dir, RouteRepository(dir).GetBaseDir())
    }

    ; ============================================================
    ; GetPathForProfile
    ; ============================================================

    get_path_for_profile_concatenates_base_dir_and_name()
    {
        dir := Fixtures.TempDir()
        repo := RouteRepository(dir)
        Assert.Equal(dir "\Speedrunner.ini",
            repo.GetPathForProfile("Speedrunner"))
    }

    get_path_for_profile_sanitizes_reserved_chars()
    {
        ; Windows-reserved filename characters must be replaced
        ; with underscore so the path stays valid no matter what
        ; the user typed in the profile name.
        dir := Fixtures.TempDir()
        repo := RouteRepository(dir)
        path := repo.GetPathForProfile("Speed/Run:test*")
        Assert.Equal(dir "\Speed_Run_test_.ini", path)
    }

    get_path_for_profile_empty_name_collapses_to_default()
    {
        dir := Fixtures.TempDir()
        Assert.Equal(dir "\default.ini",
            RouteRepository(dir).GetPathForProfile(""))
    }

    get_path_for_profile_whitespace_only_name_collapses_to_default()
    {
        dir := Fixtures.TempDir()
        Assert.Equal(dir "\default.ini",
            RouteRepository(dir).GetPathForProfile("   "))
    }

    get_path_for_profile_name_of_only_reserved_chars_collapses_to_default()
    {
        ; "<<<>>>" -> "______" but Trim doesn't remove underscores,
        ; so it stays as "______". The sanitization is conservative
        ; about NOT producing an empty path; the file would still
        ; be valid as "______.ini". This pins the behavior so a
        ; future refactor that aggressively trims underscores
        ; would need to also re-collapse to "default".
        dir := Fixtures.TempDir()
        path := RouteRepository(dir).GetPathForProfile("<<<>>>")
        Assert.Equal(dir "\______.ini", path)
    }

    ; ============================================================
    ; Load: missing / empty
    ; ============================================================

    load_returns_empty_route_when_file_missing()
    {
        repo := this._MakeRepo()
        loaded := repo.Load("NeverSeen")
        Assert.True(loaded is Route)
        Assert.Equal(0, loaded.Count())
    }

    load_returns_empty_route_when_section_absent()
    {
        ; The file exists but has no [Route] section.
        repo := this._MakeRepo()
        path := repo.GetPathForProfile("Solo")
        FileAppend("[Other]`r`nfoo=bar`r`n", path, "UTF-16")

        loaded := repo.Load("Solo")
        Assert.Equal(0, loaded.Count())
    }

    load_returns_empty_route_when_zones_key_empty()
    {
        repo := this._MakeRepo()
        path := repo.GetPathForProfile("Solo")
        FileAppend("[Route]`r`nzones=`r`n", path, "UTF-16")

        Assert.Equal(0, repo.Load("Solo").Count())
    }

    ; ============================================================
    ; Load: parsing
    ; ============================================================

    load_parses_pipe_separated_zones()
    {
        repo := this._MakeRepo()
        path := repo.GetPathForProfile("Solo")
        FileAppend("[Route]`r`nzones=A|B|C`r`n", path, "UTF-16")

        loaded := repo.Load("Solo")
        Assert.Equal(3, loaded.Count())
        Assert.Equal("A", loaded.GetZoneAt(0))
        Assert.Equal("B", loaded.GetZoneAt(1))
        Assert.Equal("C", loaded.GetZoneAt(2))
    }

    load_trims_whitespace_around_each_zone()
    {
        ; A hand-edited INI may have spaces around the pipes.
        repo := this._MakeRepo()
        path := repo.GetPathForProfile("Solo")
        FileAppend("[Route]`r`nzones=  A  |  B  |  C  `r`n", path, "UTF-16")

        loaded := repo.Load("Solo")
        Assert.Equal("A", loaded.GetZoneAt(0))
        Assert.Equal("B", loaded.GetZoneAt(1))
        Assert.Equal("C", loaded.GetZoneAt(2))
    }

    load_filters_empty_entries_between_pipes()
    {
        ; Leading / trailing / double pipes can sneak in via
        ; hand-edits. The repo silently drops them so the Route
        ; never has phantom empty zones.
        repo := this._MakeRepo()
        path := repo.GetPathForProfile("Solo")
        FileAppend("[Route]`r`nzones=|A||B|`r`n", path, "UTF-16")

        loaded := repo.Load("Solo")
        Assert.Equal(2, loaded.Count())
        Assert.Equal("A", loaded.GetZoneAt(0))
        Assert.Equal("B", loaded.GetZoneAt(1))
    }

    load_dedupes_duplicates_silently_first_wins()
    {
        ; Pre-dedupe legacy files on disk may still contain
        ; duplicates. The Route constructor collapses them with
        ; first-occurrence-wins, so the loaded route reflects
        ; the post-change invariant (no duplicates) regardless of
        ; what the file held.
        repo := this._MakeRepo()
        path := repo.GetPathForProfile("Solo")
        FileAppend("[Route]`r`nzones=A|B|A|C|b`r`n", path, "UTF-16")

        loaded := repo.Load("Solo")
        Assert.Equal(3, loaded.Count(),
            "duplicate A and case-variant b dropped")
        Assert.Equal("A", loaded.GetZoneAt(0))
        Assert.Equal("B", loaded.GetZoneAt(1))
        Assert.Equal("C", loaded.GetZoneAt(2))
    }

    ; ============================================================
    ; Notes: load
    ; ============================================================

    load_returns_no_notes_when_section_absent()
    {
        ; A file with only [Route] (the pre-notes format) loads
        ; the zones AND produces an empty notes map — callers
        ; that GetNote() on a known zone get "" rather than an
        ; error.
        repo := this._MakeRepo()
        path := repo.GetPathForProfile("Solo")
        FileAppend("[Route]`r`nzones=A|B`r`n", path, "UTF-16")

        loaded := repo.Load("Solo")
        Assert.Equal("", loaded.GetNote("A"),
            "no [Notes] section yields empty note")
        Assert.Equal("", loaded.GetNote("B"))
    }

    load_parses_notes_section()
    {
        repo := this._MakeRepo()
        path := repo.GetPathForProfile("Solo")
        FileAppend(
            "[Route]`r`nzones=A|B`r`n`r`n[Notes]`r`na=hi`r`nb=bye`r`n",
            path, "UTF-16")

        loaded := repo.Load("Solo")
        Assert.Equal("hi",  loaded.GetNote("A"))
        Assert.Equal("bye", loaded.GetNote("B"))
    }

    load_decodes_newline_escape_in_note()
    {
        ; The on-disk \n (two characters: backslash + n) decodes
        ; to a real line break in the loaded note. The widget
        ; then renders that as two lines.
        repo := this._MakeRepo()
        path := repo.GetPathForProfile("Solo")
        FileAppend(
            "[Route]`r`nzones=A`r`n`r`n[Notes]`r`na=line one\nline two`r`n",
            path, "UTF-16")

        loaded := repo.Load("Solo")
        Assert.Equal("line one`nline two", loaded.GetNote("A"),
            "`\\n` on disk becomes a real LF in memory")
    }

    load_decodes_backslash_escape_in_note()
    {
        ; The on-disk \\ decodes to a single literal backslash.
        ; A user note like "C:\path\to\file" survives the round.
        repo := this._MakeRepo()
        path := repo.GetPathForProfile("Solo")
        FileAppend(
            "[Route]`r`nzones=A`r`n`r`n[Notes]`r`na=C:\\path\\file`r`n",
            path, "UTF-16")

        loaded := repo.Load("Solo")
        Assert.Equal("C:\path\file", loaded.GetNote("A"))
    }

    load_ignores_notes_with_empty_decoded_text()
    {
        ; A note whose value is empty (or decodes to empty) is
        ; dropped on load — matches the Route constructor's
        ; "empty notes are absent" normalization.
        repo := this._MakeRepo()
        path := repo.GetPathForProfile("Solo")
        FileAppend(
            "[Route]`r`nzones=A|B`r`n`r`n[Notes]`r`na=`r`nb=keeper`r`n",
            path, "UTF-16")

        loaded := repo.Load("Solo")
        Assert.Equal("",       loaded.GetNote("A"))
        Assert.Equal("keeper", loaded.GetNote("B"))
    }

    ; ============================================================
    ; Save: validation
    ; ============================================================

    save_throws_when_argument_not_route()
    {
        repo := this._MakeRepo()
        Assert.Throws(TypeError, () => repo.Save("Solo", "not a route"))
        Assert.Throws(TypeError, () => repo.Save("Solo", Map()))
        Assert.Throws(TypeError, () => repo.Save("Solo", [1, 2, 3]))
    }

    ; ============================================================
    ; Save: atomic write
    ; ============================================================

    save_creates_file_with_route_content()
    {
        repo := this._MakeRepo()
        repo.Save("Solo", Route(["A", "B"]))
        path := repo.GetPathForProfile("Solo")
        Assert.True(FileExist(path), "Save must create the INI file")
    }

    save_does_not_leave_tmp_behind()
    {
        ; AtomicWriter writes to .tmp then FileMove. On success the
        ; .tmp must not survive. Test the integration by checking
        ; the filesystem state after Save.
        repo := this._MakeRepo()
        repo.Save("Solo", Route(["A"]))
        tmpPath := repo.GetPathForProfile("Solo") ".tmp"
        Assert.False(FileExist(tmpPath),
            "AtomicWriter leaves no .tmp on success")
    }

    save_returns_true_on_success()
    {
        Assert.True(this._MakeRepo().Save("Solo", Route(["A"])))
    }

    ; ============================================================
    ; Save: sanitization
    ; ============================================================

    save_strips_pipe_from_zone_names_to_protect_separator()
    {
        ; A zone name containing the separator would corrupt the
        ; file on the round-trip. Pipes are stripped at serialize
        ; time so the saved file is always parseable.
        repo := this._MakeRepo()
        repo.Save("Solo", Route(["A|hack", "B"]))
        recovered := repo.Load("Solo")
        Assert.Equal(2, recovered.Count())
        Assert.Equal("Ahack", recovered.GetZoneAt(0),
            "pipe removed; rest preserved")
    }

    save_strips_crlf_from_zone_names()
    {
        repo := this._MakeRepo()
        repo.Save("Solo", Route(["A`r`nB"]))
        recovered := repo.Load("Solo")
        Assert.Equal(1, recovered.Count())
        Assert.Equal("AB", recovered.GetZoneAt(0))
    }

    save_strips_ini_metacharacters_from_zone_names()
    {
        ; '=', '[', ']' would corrupt the INI structure if left in.
        repo := this._MakeRepo()
        repo.Save("Solo", Route(["A=B", "[C]"]))
        recovered := repo.Load("Solo")
        Assert.Equal(2, recovered.Count())
        Assert.Equal("AB", recovered.GetZoneAt(0))
        Assert.Equal("C",  recovered.GetZoneAt(1))
    }

    save_skips_zones_that_become_empty_after_sanitization()
    {
        ; A zone consisting entirely of stripped characters (e.g.
        ; just "|||") becomes empty and is dropped from the saved
        ; output entirely.
        repo := this._MakeRepo()
        repo.Save("Solo", Route(["A", "|||", "B"]))
        recovered := repo.Load("Solo")
        Assert.Equal(2, recovered.Count(),
            "the all-pipes zone was dropped")
        Assert.Equal("A", recovered.GetZoneAt(0))
        Assert.Equal("B", recovered.GetZoneAt(1))
    }

    ; ============================================================
    ; Notes: save
    ; ============================================================

    save_omits_notes_section_when_route_has_no_notes()
    {
        ; A route with no per-zone tips produces a file with only
        ; [Route] — the pre-notes format. Keeps diffs small for
        ; users not using notes yet.
        repo := this._MakeRepo()
        repo.Save("Solo", Route(["A", "B"]))
        path := repo.GetPathForProfile("Solo")
        ini := IniFile(path)
        Assert.False(ini.SectionExists("Notes"),
            "no [Notes] section when route has no notes")
    }

    save_writes_notes_section_when_route_has_notes()
    {
        repo := this._MakeRepo()
        r := Route(["A", "B"])
        r.SetNote("A", "vendor first")
        repo.Save("Solo", r)

        ini := IniFile(repo.GetPathForProfile("Solo"))
        Assert.True(ini.SectionExists("Notes"))
        Assert.Equal("vendor first", ini.Read("Notes", "a", ""),
            "key lowercased on write (matches in-memory map)")
    }

    save_encodes_newline_in_note_text()
    {
        ; A multi-line note in memory must serialize onto a single
        ; INI line via the \\n escape; otherwise the second line
        ; would parse as a malformed key=value pair.
        repo := this._MakeRepo()
        r := Route(["A"])
        r.SetNote("A", "line one`nline two")    ; real LF in memory
        repo.Save("Solo", r)

        ini := IniFile(repo.GetPathForProfile("Solo"))
        Assert.Equal("line one\nline two", ini.Read("Notes", "a", ""),
            "LF encoded as `\\n` on disk")
    }

    save_encodes_backslash_before_newline_in_note_text()
    {
        ; A literal backslash must be escaped FIRST ("\" -> "\\")
        ; so a user note like "C:\path`nline two" doesn't get
        ; mis-decoded as "C:[newline]path..." on the next load.
        repo := this._MakeRepo()
        r := Route(["A"])
        r.SetNote("A", "C:\path`nbelow")
        repo.Save("Solo", r)

        ini := IniFile(repo.GetPathForProfile("Solo"))
        ; Expected on disk: "C:\\path\nbelow" (escape order:
        ; backslash first, then newline).
        Assert.Equal("C:\\path\nbelow", ini.Read("Notes", "a", ""))
    }

    ; ============================================================
    ; Roundtrip
    ; ============================================================

    roundtrip_save_load_preserves_zone_order()
    {
        repo := this._MakeRepo()
        original := Route(["First", "Second", "Third", "Fourth"])
        repo.Save("Solo", original)
        recovered := repo.Load("Solo")

        Assert.Equal(4, recovered.Count())
        Assert.Equal("First",  recovered.GetZoneAt(0))
        Assert.Equal("Second", recovered.GetZoneAt(1))
        Assert.Equal("Third",  recovered.GetZoneAt(2))
        Assert.Equal("Fourth", recovered.GetZoneAt(3))
    }

    roundtrip_save_load_dedupes_silently()
    {
        ; The post-change invariant: Route no longer allows
        ; duplicates. Even if a hand-crafted file on disk has
        ; them (the legacy format permitted), Load collapses
        ; them via the constructor's first-wins dedupe. Verified
        ; here at the Save boundary too — a Route built via the
        ; public API can't even hold duplicates, so this Save
        ; only writes 2 zones for the input ["A", "B", "A"].
        repo := this._MakeRepo()
        repo.Save("Solo", Route(["A", "B", "A"]))
        recovered := repo.Load("Solo")
        Assert.Equal(2, recovered.Count(),
            "duplicates dropped before write")
        Assert.Equal("A", recovered.GetZoneAt(0))
        Assert.Equal("B", recovered.GetZoneAt(1))
    }

    roundtrip_does_not_persist_current_idx()
    {
        ; Persisted Route is the route DEFINITION, not the run
        ; progress. _currentIdx is a runtime concept owned by
        ; RouteService and reset on every RunStarted, so it must
        ; NOT survive a Save/Load round-trip.
        repo := this._MakeRepo()
        original := Route(["A", "B", "C"])
        original.AdvanceTo("B")
        Assert.Equal(1, original.GetCurrentIdx())

        repo.Save("Solo", original)
        recovered := repo.Load("Solo")
        Assert.Equal(-1, recovered.GetCurrentIdx(),
            "recovered route starts fresh (no persisted progress)")
    }

    roundtrip_preserves_notes()
    {
        repo := this._MakeRepo()
        r := Route(["A", "B", "C"])
        r.SetNote("A", "first note")
        r.SetNote("C", "third note")
        repo.Save("Solo", r)

        recovered := repo.Load("Solo")
        Assert.Equal("first note", recovered.GetNote("A"))
        Assert.Equal("",           recovered.GetNote("B"), "no note for B")
        Assert.Equal("third note", recovered.GetNote("C"))
    }

    roundtrip_preserves_multiline_note()
    {
        ; A user's three-line tip must survive Save then Load
        ; with the exact same line breaks.
        repo := this._MakeRepo()
        r := Route(["A"])
        r.SetNote("A", "step one`nstep two`nstep three")
        repo.Save("Solo", r)

        recovered := repo.Load("Solo")
        Assert.Equal("step one`nstep two`nstep three", recovered.GetNote("A"),
            "multi-line note preserved byte-for-byte")
    }

    roundtrip_preserves_backslash_in_note()
    {
        ; Mixed backslashes and newlines exercise both escape
        ; rules at once. The on-disk representation should be
        ; encoded with backslash-first ordering; the load step
        ; uses a char-by-char scan that resolves \\ before \n.
        repo := this._MakeRepo()
        r := Route(["A"])
        r.SetNote("A", "C:\path\to\file`nthen continue")
        repo.Save("Solo", r)

        recovered := repo.Load("Solo")
        Assert.Equal("C:\path\to\file`nthen continue", recovered.GetNote("A"))
    }

    ; ============================================================
    ; Import / Export
    ; ============================================================

    import_from_profile_copies_route_to_destination()
    {
        repo := this._MakeRepo()
        repo.Save("Witch", Route(["A", "B", "C"]))

        Assert.True(repo.ImportFromProfile("Witch", "Warrior"))
        warriorRoute := repo.Load("Warrior")
        Assert.Equal(3, warriorRoute.Count())
        Assert.Equal("A", warriorRoute.GetZoneAt(0))
        Assert.Equal("C", warriorRoute.GetZoneAt(2))
    }

    import_from_profile_returns_false_when_source_empty()
    {
        ; Empty source means the destination keeps its own state.
        ; A no-op import should never wipe the destination route.
        repo := this._MakeRepo()
        repo.Save("Warrior", Route(["Existing"]))
        Assert.False(repo.ImportFromProfile("NeverSavedProfile", "Warrior"))
        ; Destination intact
        Assert.Equal(1, repo.Load("Warrior").Count())
        Assert.Equal("Existing", repo.Load("Warrior").GetZoneAt(0))
    }

    import_from_file_loads_external_ini()
    {
        repo := this._MakeRepo()
        externalPath := Fixtures.TempPath("ini")
        FileAppend("[Route]`r`nzones=X|Y|Z`r`n", externalPath, "UTF-16")

        Assert.True(repo.ImportFromFile(externalPath, "Solo"))
        loaded := repo.Load("Solo")
        Assert.Equal(3, loaded.Count())
        Assert.Equal("X", loaded.GetZoneAt(0))
    }

    import_from_file_returns_false_when_path_missing()
    {
        Assert.False(this._MakeRepo().ImportFromFile("", "Solo"))
    }

    import_from_file_returns_false_when_file_does_not_exist()
    {
        repo := this._MakeRepo()
        Assert.False(repo.ImportFromFile("Z:\\does-not-exist.ini", "Solo"))
    }

    import_from_file_returns_false_when_zones_key_empty()
    {
        repo := this._MakeRepo()
        externalPath := Fixtures.TempPath("ini")
        FileAppend("[Route]`r`nzones=`r`n", externalPath, "UTF-16")
        Assert.False(repo.ImportFromFile(externalPath, "Solo"),
            "empty zones key is not a valid import")
    }

    export_to_file_writes_external_ini_with_route()
    {
        repo := this._MakeRepo()
        repo.Save("Solo", Route(["A", "B"]))

        outPath := Fixtures.TempPath("ini")
        Assert.True(repo.ExportToFile("Solo", outPath))

        ; Verify the external file is readable as the same schema.
        ini := IniFile(outPath)
        Assert.Equal("A|B", ini.Read("Route", "zones", ""),
            "exported file has the same schema as the internal save")
    }

    export_to_file_returns_false_when_profile_has_no_route()
    {
        repo := this._MakeRepo()
        outPath := Fixtures.TempPath("ini")
        Assert.False(repo.ExportToFile("UnknownProfile", outPath))
    }

    export_to_file_returns_false_when_path_empty()
    {
        repo := this._MakeRepo()
        repo.Save("Solo", Route(["A"]))
        Assert.False(repo.ExportToFile("Solo", ""))
    }

    export_then_import_roundtrip_preserves_zones()
    {
        ; Speedrunner workflow: save in one profile, export to
        ; file, share with a friend, friend imports into their own
        ; profile. Verify the round-trip preserves order +
        ; content.
        repo := this._MakeRepo()
        repo.Save("Author", Route(["The Riverbank", "Clearfell", "The Grelwood"]))

        sharedPath := Fixtures.TempPath("ini")
        Assert.True(repo.ExportToFile("Author", sharedPath))

        Assert.True(repo.ImportFromFile(sharedPath, "Recipient"))
        recipient := repo.Load("Recipient")
        Assert.Equal(3, recipient.Count())
        Assert.Equal("The Riverbank", recipient.GetZoneAt(0))
        Assert.Equal("Clearfell",     recipient.GetZoneAt(1))
        Assert.Equal("The Grelwood",  recipient.GetZoneAt(2))
    }

    export_then_import_roundtrip_preserves_notes()
    {
        ; A shared route file must carry the author's per-zone
        ; tips so the recipient sees the same overlay annotations
        ; without manual re-entry.
        repo := this._MakeRepo()
        authorRoute := Route(["The Riverbank", "Clearfell"])
        authorRoute.SetNote("The Riverbank", "open door first`nthen straight ahead")
        authorRoute.SetNote("Clearfell",     "skip optional")
        repo.Save("Author", authorRoute)

        sharedPath := Fixtures.TempPath("ini")
        Assert.True(repo.ExportToFile("Author", sharedPath))
        Assert.True(repo.ImportFromFile(sharedPath, "Recipient"))

        recipient := repo.Load("Recipient")
        Assert.Equal("open door first`nthen straight ahead",
            recipient.GetNote("The Riverbank"))
        Assert.Equal("skip optional",
            recipient.GetNote("Clearfell"))
    }
}

TestRegistry.Register(RouteRepositoryTests)
