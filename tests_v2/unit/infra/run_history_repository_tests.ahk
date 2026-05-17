; ============================================================
; RunHistoryRepository tests
; ============================================================
;
; Persists finalized runs as 1 INI per run at `<dir>/{runId}.ini`.
; Sections: [meta], [totals], [checkpoints], [details].
; Details serialized as a pipe-delimited line with `\|`/`\\` escape.
;
; Naming: we use `runItem`/`currentRun` instead of `run` to avoid
; the case-insensitive collision with the builtin function `Run`.

class RunHistoryRepositoryTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_on_empty_dir",
        "constructor_creates_directory",
        "get_dir_returns_constructor_arg",

        ; --- Save: validation ---
        "save_returns_false_when_not_object",
        "save_returns_false_when_run_id_empty",
        "save_returns_false_when_total_ms_below_threshold",
        "save_returns_true_on_success",

        ; --- Save: file creation ---
        "save_creates_file_for_run_id",
        "save_writes_meta_section",
        "save_writes_totals_section",
        "save_writes_checkpoints_section",
        "save_writes_details_section_with_count",

        ; --- Save: re-save consistency ---
        "save_overwrites_previous_save_for_same_run_id",

        ; --- ListRunIds ---
        "list_run_ids_returns_empty_when_dir_missing",
        "list_run_ids_extracts_run_id_without_extension",
        "list_run_ids_ignores_non_ini_files",
        "list_run_ids_respects_max_n",

        ; --- Load ---
        "load_returns_empty_string_when_run_id_missing",
        "load_parses_meta_fields",
        "load_parses_totals",
        "load_parses_checkpoints_with_regex",
        "load_parses_details_array",
        "load_details_include_safe_category_label",

        ; --- LoadSummaries ---
        "load_summaries_returns_meta_and_totals_without_details",
        "load_summaries_respects_max_n",

        ; --- Delete ---
        "delete_returns_false_when_run_id_missing",
        "delete_removes_file_and_returns_true",

        ; --- Static helpers ---
        "serialize_detail_format_matches_pipe_layout",
        "serialize_detail_escapes_pipe_and_backslash",
        "parse_detail_roundtrip_with_serialize",
        "parse_detail_returns_empty_for_empty_line",
        "parse_detail_returns_empty_for_too_few_parts",
        "split_escaped_respects_escape_sequences",
        "escape_unescape_roundtrip",
        "safe_category_label_fallback_for_known_categories",
        "safe_category_label_passes_through_unknown",
    ]

    ; ============================================================
    ; Helper
    ; ============================================================

    _MakeBuildResult(runId := "20260512_142345")
    {
        return Map(
            "runId",         runId,
            "profile",       "Default",
            "patch",         "0.2.0",
            "firstTs",       "2026-05-12 14:23:45",
            "totalMs",       3719000,
            "deathCount",    3,
            "maxActReached", 2,
            "totals",        Map("mapa", 2918000, "cidade", 226000, "loading", 44000, "morte", 450000),
            "actCheckpoints", Map(1, 1725000, 2, 3719000),
            "details", [
                Map("category", "mapa",   "label", "Mud Burrow",
                    "ms", 184321, "note", "Act 1", "timestamp", "2026-05-12 14:24:00"),
                Map("category", "cidade", "label", "Clearfell Encampment",
                    "ms", 95000,  "note", "Act 1", "timestamp", "")
            ]
        )
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_on_empty_dir()
    {
        Assert.Throws(ValueError, () => RunHistoryRepository(""))
    }

    constructor_creates_directory()
    {
        tmpDir := Fixtures.TempDir()
        nested := tmpDir "\runs"
        repo := RunHistoryRepository(nested)
        Assert.True(DirExist(nested))
    }

    get_dir_returns_constructor_arg()
    {
        tmpDir := Fixtures.TempDir()
        repo := RunHistoryRepository(tmpDir)
        Assert.Equal(tmpDir, repo.GetDir())
    }

    ; ============================================================
    ; Save: validation
    ; ============================================================

    save_returns_false_when_not_object()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        Assert.False(repo.Save("not an object"))
        Assert.False(repo.Save(42))
    }

    save_returns_false_when_run_id_empty()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        currentRun := this._MakeBuildResult()
        currentRun["runId"] := ""
        Assert.False(repo.Save(currentRun))
    }

    save_returns_false_when_total_ms_below_threshold()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        currentRun := this._MakeBuildResult()
        currentRun["totalMs"] := 500   ; < 1000ms minimum
        Assert.False(repo.Save(currentRun))
    }

    save_returns_true_on_success()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        Assert.True(repo.Save(this._MakeBuildResult()))
    }

    ; ============================================================
    ; Save: file creation
    ; ============================================================

    save_creates_file_for_run_id()
    {
        tmpDir := Fixtures.TempDir()
        repo := RunHistoryRepository(tmpDir)
        repo.Save(this._MakeBuildResult("20260512_142345"))
        Assert.True(FileExist(tmpDir "\20260512_142345.ini"))
    }

    save_writes_meta_section()
    {
        tmpDir := Fixtures.TempDir()
        repo := RunHistoryRepository(tmpDir)
        repo.Save(this._MakeBuildResult())

        ini := IniFile(tmpDir "\20260512_142345.ini")
        Assert.Equal("20260512_142345",     ini.Read("meta", "runId"))
        Assert.Equal("Default",             ini.Read("meta", "profile"))
        Assert.Equal("0.2.0",               ini.Read("meta", "patch"))
        Assert.Equal("2026-05-12 14:23:45", ini.Read("meta", "firstTs"))
        Assert.Equal("3719000",             ini.Read("meta", "totalMs"))
        Assert.Equal("3",                   ini.Read("meta", "deathCount"))
        Assert.Equal("2",                   ini.Read("meta", "maxActReached"))
    }

    save_writes_totals_section()
    {
        tmpDir := Fixtures.TempDir()
        repo := RunHistoryRepository(tmpDir)
        repo.Save(this._MakeBuildResult())

        ini := IniFile(tmpDir "\20260512_142345.ini")
        Assert.Equal("2918000", ini.Read("totals", "mapa"))
        Assert.Equal("226000",  ini.Read("totals", "cidade"))
        Assert.Equal("44000",   ini.Read("totals", "loading"))
        Assert.Equal("450000",  ini.Read("totals", "morte"))
    }

    save_writes_checkpoints_section()
    {
        tmpDir := Fixtures.TempDir()
        repo := RunHistoryRepository(tmpDir)
        repo.Save(this._MakeBuildResult())

        ini := IniFile(tmpDir "\20260512_142345.ini")
        Assert.Equal("1725000", ini.Read("checkpoints", "Act1Ms"))
        Assert.Equal("3719000", ini.Read("checkpoints", "Act2Ms"))
    }

    save_writes_details_section_with_count()
    {
        tmpDir := Fixtures.TempDir()
        repo := RunHistoryRepository(tmpDir)
        repo.Save(this._MakeBuildResult())

        ini := IniFile(tmpDir "\20260512_142345.ini")
        Assert.Equal("2", ini.Read("details", "count"))
        Assert.Contains("mapa",   ini.Read("details", "0"))
        Assert.Contains("cidade", ini.Read("details", "1"))
    }

    ; ============================================================
    ; Save: re-save consistency
    ; ============================================================

    save_overwrites_previous_save_for_same_run_id()
    {
        tmpDir := Fixtures.TempDir()
        repo := RunHistoryRepository(tmpDir)

        ; Save 1: 2 details
        repo.Save(this._MakeBuildResult())

        ; Save 2: 1 detail (overwrites) - same runId
        replacement := this._MakeBuildResult()
        replacement["details"] := [
            Map("category", "mapa", "label", "OnlyOne", "ms", 1000, "note", "", "timestamp", "")
        ]
        replacement["totalMs"] := 9999999
        repo.Save(replacement)

        loaded := repo.Load("20260512_142345")
        Assert.Equal(1,       loaded["details"].Length, "Re-save must replace, not accumulate")
        Assert.Equal(9999999, loaded["totalMs"])
    }

    ; ============================================================
    ; ListRunIds
    ; ============================================================

    list_run_ids_returns_empty_when_dir_missing()
    {
        ; Create repo pointing to a subdir that will exist (constructor
        ; creates it), then delete manually.
        tmpDir := Fixtures.TempDir()
        subDir := tmpDir "\nonexistent_subdir"
        ; Doesn't use the constructor (which creates), but we need
        ; ListRunIds on a missing dir. Workaround: create repo, then
        ; delete manually.
        repo := RunHistoryRepository(subDir)
        DirDelete(subDir, false)
        Assert.Equal(0, repo.ListRunIds().Length)
    }

    list_run_ids_extracts_run_id_without_extension()
    {
        tmpDir := Fixtures.TempDir()
        repo := RunHistoryRepository(tmpDir)
        repo.Save(this._MakeBuildResult("20260512_142345"))
        repo.Save(this._MakeBuildResult("20260513_100000"))

        ids := repo.ListRunIds()
        Assert.Equal(2, ids.Length)
        ; Bug #12 fix: runIds must not have ".ini" appended.
        ; `runId` collides with the `RunId` class -> we use `currentRunId`.
        for _, currentRunId in ids
        {
            Assert.False(InStr(currentRunId, ".ini") > 0,
                "runId must not contain '.ini': " currentRunId)
        }
    }

    list_run_ids_ignores_non_ini_files()
    {
        tmpDir := Fixtures.TempDir()
        repo := RunHistoryRepository(tmpDir)
        repo.Save(this._MakeBuildResult("20260512_142345"))
        ; Creates a .txt in the dir
        FileAppend("not an ini", tmpDir "\garbage.txt", "UTF-8")

        ids := repo.ListRunIds()
        Assert.Equal(1, ids.Length, ".txt should be ignored")
    }

    list_run_ids_respects_max_n()
    {
        tmpDir := Fixtures.TempDir()
        repo := RunHistoryRepository(tmpDir)
        repo.Save(this._MakeBuildResult("20260512_100000"))
        repo.Save(this._MakeBuildResult("20260513_100000"))
        repo.Save(this._MakeBuildResult("20260514_100000"))

        Assert.Equal(2, repo.ListRunIds(2).Length)
    }

    ; ============================================================
    ; Load
    ; ============================================================

    load_returns_empty_string_when_run_id_missing()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        Assert.Equal("", repo.Load("nonexistent_id"))
    }

    load_parses_meta_fields()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        repo.Save(this._MakeBuildResult())

        loaded := repo.Load("20260512_142345")
        Assert.Equal("20260512_142345",     loaded["runId"])
        Assert.Equal("Default",             loaded["profile"])
        Assert.Equal("0.2.0",               loaded["patch"])
        Assert.Equal("2026-05-12 14:23:45", loaded["firstTs"])
        Assert.Equal(3719000,               loaded["totalMs"])
        Assert.Equal(3,                     loaded["deathCount"])
        Assert.Equal(2,                     loaded["maxActReached"])
    }

    load_parses_totals()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        repo.Save(this._MakeBuildResult())

        loaded := repo.Load("20260512_142345")
        Assert.Equal(2918000, loaded["totals"]["mapa"])
        Assert.Equal(226000,  loaded["totals"]["cidade"])
        Assert.Equal(44000,   loaded["totals"]["loading"])
        Assert.Equal(450000,  loaded["totals"]["morte"])
    }

    load_parses_checkpoints_with_regex()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        repo.Save(this._MakeBuildResult())

        loaded := repo.Load("20260512_142345")
        Assert.Equal(1725000, loaded["actCheckpoints"][1])
        Assert.Equal(3719000, loaded["actCheckpoints"][2])
    }

    load_parses_details_array()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        repo.Save(this._MakeBuildResult())

        loaded := repo.Load("20260512_142345")
        Assert.Equal(2, loaded["details"].Length)
        Assert.Equal("mapa",                loaded["details"][1]["category"])
        Assert.Equal("Mud Burrow",          loaded["details"][1]["label"])
        Assert.Equal(184321,                loaded["details"][1]["ms"])
        Assert.Equal("Act 1",               loaded["details"][1]["note"])
        Assert.Equal("2026-05-12 14:24:00", loaded["details"][1]["timestamp"])
    }

    load_details_include_safe_category_label()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        repo.Save(this._MakeBuildResult())

        loaded := repo.Load("20260512_142345")
        ; categoryLabel comes from the fallback (RunStatsPlotBuilder not included):
        ;   mapa -> "Map", cidade -> "Town"
        Assert.Equal("Map",  loaded["details"][1]["categoryLabel"])
        Assert.Equal("Town", loaded["details"][2]["categoryLabel"])
    }

    ; ============================================================
    ; LoadSummaries
    ; ============================================================

    load_summaries_returns_meta_and_totals_without_details()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        repo.Save(this._MakeBuildResult())

        summaries := repo.LoadSummaries()
        Assert.Equal(1, summaries.Length)
        Assert.Equal("20260512_142345", summaries[1]["runId"])
        Assert.Equal(2918000,           summaries[1]["totals"]["mapa"])
        Assert.Equal(0, summaries[1]["details"].Length,
            "Summaries must bring empty details (optimization)")
    }

    load_summaries_respects_max_n()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        repo.Save(this._MakeBuildResult("20260512_100000"))
        repo.Save(this._MakeBuildResult("20260513_100000"))
        repo.Save(this._MakeBuildResult("20260514_100000"))

        summaries := repo.LoadSummaries(2)
        Assert.Equal(2, summaries.Length)
    }

    ; ============================================================
    ; Delete
    ; ============================================================

    delete_returns_false_when_run_id_missing()
    {
        repo := RunHistoryRepository(Fixtures.TempDir())
        Assert.False(repo.Delete("nonexistent"))
    }

    delete_removes_file_and_returns_true()
    {
        tmpDir := Fixtures.TempDir()
        repo := RunHistoryRepository(tmpDir)
        repo.Save(this._MakeBuildResult())
        path := tmpDir "\20260512_142345.ini"
        Assert.True(FileExist(path))

        Assert.True(repo.Delete("20260512_142345"))
        Assert.False(FileExist(path))
    }

    ; ============================================================
    ; Static helpers
    ; ============================================================

    serialize_detail_format_matches_pipe_layout()
    {
        detail := Map(
            "category", "mapa", "label", "Mud Burrow",
            "ms", 100, "note", "Act 1", "timestamp", "ts"
        )
        line := RunHistoryRepository._SerializeDetail(detail)
        Assert.Equal("mapa|Mud Burrow|100|Act 1|ts", line)
    }

    serialize_detail_escapes_pipe_and_backslash()
    {
        detail := Map(
            "category", "mapa",
            "label",    "Zone|With|Pipes",
            "ms",       100,
            "note",     "back\slash",
            "timestamp", ""
        )
        line := RunHistoryRepository._SerializeDetail(detail)
        ; Pipe becomes \|, backslash becomes \\
        Assert.Contains("Zone\|With\|Pipes", line)
        Assert.Contains("back\\slash",       line)
    }

    parse_detail_roundtrip_with_serialize()
    {
        original := Map(
            "category",  "mapa",
            "label",     "Mud Burrow",
            "ms",        184321,
            "note",      "Act 1",
            "timestamp", "2026-05-12 14:24:00"
        )
        line := RunHistoryRepository._SerializeDetail(original)
        parsed := RunHistoryRepository._ParseDetail(line)

        Assert.Equal(original["category"],  parsed["category"])
        Assert.Equal(original["label"],     parsed["label"])
        Assert.Equal(original["ms"],        parsed["ms"])
        Assert.Equal(original["note"],      parsed["note"])
        Assert.Equal(original["timestamp"], parsed["timestamp"])
    }

    parse_detail_returns_empty_for_empty_line()
    {
        Assert.Equal("", RunHistoryRepository._ParseDetail(""))
    }

    parse_detail_returns_empty_for_too_few_parts()
    {
        ; Only has 2 parts (needs >= 3)
        Assert.Equal("", RunHistoryRepository._ParseDetail("only|two"))
    }

    split_escaped_respects_escape_sequences()
    {
        ; "a\|b|c" -> ["a|b", "c"]
        parts := RunHistoryRepository._SplitEscaped("a\|b|c", "|")
        Assert.Equal(2,    parts.Length)
        Assert.Equal("a|b", parts[1])
        Assert.Equal("c",   parts[2])
    }

    escape_unescape_roundtrip()
    {
        original := "a|b\c|d"
        escaped := RunHistoryRepository._Escape(original)
        unescaped := RunHistoryRepository._Unescape(escaped)
        Assert.Equal(original, unescaped)
    }

    safe_category_label_fallback_for_known_categories()
    {
        Assert.Equal("Map",     RunHistoryRepository._SafeCategoryLabel("mapa"))
        Assert.Equal("Town",    RunHistoryRepository._SafeCategoryLabel("cidade"))
        Assert.Equal("Loading", RunHistoryRepository._SafeCategoryLabel("loading"))
        Assert.Equal("Deaths",  RunHistoryRepository._SafeCategoryLabel("morte"))
    }

    safe_category_label_passes_through_unknown()
    {
        ; Unknown category -> returns the string itself
        Assert.Equal("custom_cat", RunHistoryRepository._SafeCategoryLabel("custom_cat"))
    }
}

TestRegistry.Register(RunHistoryRepositoryTests)
