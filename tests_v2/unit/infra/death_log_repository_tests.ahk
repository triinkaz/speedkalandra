; ============================================================
; DeathLogRepositoryTests
; ============================================================
;
; Covers the GSG § 3 persistence contract for an append-only CSV
; log: round-trip, missing file, malformed rows, CR/LF rejection,
; CSV-escape transparency for ';' and '"' inside values.
;
; Does NOT cover the upstream wiring (subscribing DeathDetected
; from the bus, reading the active zone) — that's the composition
; root's responsibility and is exercised by integration tests.


class DeathLogRepositoryTests extends TestCase
{
    path := ""
    sink := ""
    repo := ""

    Setup()
    {
        ; TempPath registers a unique path for cleanup but does NOT
        ; create the file — DeathLogRepository creates it lazily on
        ; the first Append via CsvFile.EnsureHeader, which is the
        ; production code path we want to exercise.
        this.path := Fixtures.TempPath("csv")
        this.sink := InMemoryWarningSink()
        this.repo := DeathLogRepository(this.path, this.sink)
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_rejects_empty_path",
        "constructor_accepts_empty_sink",
        "constructor_does_not_create_file",
        "get_path_returns_constructor_path",

        ; --- Append: happy path ---
        "append_creates_file_with_header_on_first_call",
        "append_returns_true_on_success",
        "append_persists_zone_with_default_ts_in_expected_format",
        "append_preserves_explicit_ts",
        "append_persists_patch_and_profile",
        "multiple_appends_preserve_order",

        ; --- Append: validation ---
        "append_rejects_empty_zone_name_silently",
        "append_rejects_zone_with_newline_and_warns",
        "append_rejects_zone_with_carriage_return_and_warns",

        ; --- Append: CSV-escape transparency ---
        "append_zone_with_semicolon_round_trips",
        "append_zone_with_double_quote_round_trips",

        ; --- LoadAll ---
        "load_all_empty_when_file_missing",
        "load_all_returns_field_names_in_expected_map_keys",
        "load_all_skips_malformed_rows_with_too_few_columns"
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_rejects_empty_path()
    {
        Assert.Throws(ValueError, () => DeathLogRepository(""))
        Assert.Throws(ValueError, () => DeathLogRepository("   "))
    }

    constructor_accepts_empty_sink()
    {
        ; Empty sinkOrEmpty resolves to NullWarningSink internally.
        ; The constructor must not throw and Append/LoadAll must work.
        repoNoSink := DeathLogRepository(Fixtures.TempPath("csv"))
        Assert.True(repoNoSink.Append("Cemetery of the Eternals", "0.4", "Default"))
        Assert.Equal(1, repoNoSink.LoadAll().Length)
    }

    constructor_does_not_create_file()
    {
        ; Lazy header creation: the file should not exist until the
        ; first successful Append. Important so a fresh install
        ; without any deaths doesn't carry an empty deaths.csv.
        Assert.False(FileExist(this.path) != "",
            "DeathLogRepository constructor must not create the file")
    }

    get_path_returns_constructor_path()
    {
        Assert.Equal(this.path, this.repo.GetPath())
    }

    ; ============================================================
    ; Append — happy path
    ; ============================================================

    append_creates_file_with_header_on_first_call()
    {
        this.repo.Append("Mud Burrow", "0.4", "Default")
        Assert.True(FileExist(this.path) != "",
            "Append must create the file lazily via EnsureHeader")
        content := FileRead(this.path, "UTF-8")
        Assert.True(InStr(content, "ts;zoneName;patch;profile") > 0,
            "Header line must be the first row, unquoted, semicolon-separated")
    }

    append_returns_true_on_success()
    {
        Assert.True(this.repo.Append("Mud Burrow", "0.4", "Default"))
    }

    append_persists_zone_with_default_ts_in_expected_format()
    {
        ; Default ts = FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss").
        ; Assertion is on the structural shape, not the exact second
        ; (the test would race the clock otherwise).
        this.repo.Append("Mud Burrow", "0.4", "Default")
        rows := this.repo.LoadAll()
        Assert.Equal(1, rows.Length)
        ts := rows[1]["ts"]
        Assert.True(RegExMatch(ts, "^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$") > 0,
            "Default ts must be 'YYYY-MM-DD HH:MM:SS', got '" ts "'")
    }

    append_preserves_explicit_ts()
    {
        explicitTs := "2026-05-20 14:32:11"
        this.repo.Append("Mud Burrow", "0.4", "Default", explicitTs)
        rows := this.repo.LoadAll()
        Assert.Equal(explicitTs, rows[1]["ts"])
    }

    append_persists_patch_and_profile()
    {
        this.repo.Append("Mud Burrow", "0.4", "MyBuild")
        rows := this.repo.LoadAll()
        Assert.Equal("0.4",     rows[1]["patch"])
        Assert.Equal("MyBuild", rows[1]["profile"])
    }

    multiple_appends_preserve_order()
    {
        this.repo.Append("Cemetery of the Eternals", "0.4", "Default", "2026-05-20 14:00:00")
        this.repo.Append("Mud Burrow",                "0.4", "Default", "2026-05-20 14:05:00")
        this.repo.Append("The Riverbank",             "0.4", "Default", "2026-05-20 14:10:00")
        rows := this.repo.LoadAll()
        Assert.Equal(3, rows.Length)
        Assert.Equal("Cemetery of the Eternals", rows[1]["zoneName"])
        Assert.Equal("Mud Burrow",               rows[2]["zoneName"])
        Assert.Equal("The Riverbank",            rows[3]["zoneName"])
    }

    ; ============================================================
    ; Append — validation
    ; ============================================================

    append_rejects_empty_zone_name_silently()
    {
        ; Empty zone is a legitimate upstream gap (death fired before
        ; ZoneChanged seeded the active zone); rejected without warn.
        Assert.False(this.repo.Append("",    "0.4", "Default"))
        Assert.False(this.repo.Append("   ", "0.4", "Default"),
            "Whitespace-only is treated as empty")
        Assert.Equal(0, this.sink.Count(),
            "Empty zone rejection must not warn (legitimate gap)")
        Assert.Equal(0, this.repo.LoadAll().Length,
            "Nothing should land on disk for empty zone")
    }

    append_rejects_zone_with_newline_and_warns()
    {
        ; CR/LF would split the row into two CSV lines on the next
        ; load — structurally broken. Reject with a warn so the
        ; upstream bug is visible.
        Assert.False(this.repo.Append("bad`nzone", "0.4", "Default"))
        Assert.True(this.sink.HasMessage("CR/LF"),
            "Newline rejection must warn for upstream-visibility")
        Assert.Equal(0, this.repo.LoadAll().Length)
    }

    append_rejects_zone_with_carriage_return_and_warns()
    {
        Assert.False(this.repo.Append("bad`rzone", "0.4", "Default"))
        Assert.True(this.sink.HasMessage("CR/LF"))
        Assert.Equal(0, this.repo.LoadAll().Length)
    }

    ; ============================================================
    ; Append — CSV-escape transparency
    ; ============================================================

    append_zone_with_semicolon_round_trips()
    {
        ; CsvFile uses ';' as the column separator. A zone name
        ; containing ';' must survive the quote-escape (every field
        ; is always double-quoted) and come back identical.
        weirdZone := "Zone;With;Semicolons"
        this.repo.Append(weirdZone, "0.4", "Default", "2026-05-20 14:00:00")
        rows := this.repo.LoadAll()
        Assert.Equal(1, rows.Length)
        Assert.Equal(weirdZone, rows[1]["zoneName"])
    }

    append_zone_with_double_quote_round_trips()
    {
        ; Internal double quotes are escaped as '""' by CsvFile.
        weirdZone := "Zone " . Chr(34) . "Quoted" . Chr(34) . " Name"
        this.repo.Append(weirdZone, "0.4", "Default", "2026-05-20 14:00:00")
        rows := this.repo.LoadAll()
        Assert.Equal(1, rows.Length)
        Assert.Equal(weirdZone, rows[1]["zoneName"])
    }

    ; ============================================================
    ; LoadAll
    ; ============================================================

    load_all_empty_when_file_missing()
    {
        ; Fresh repo, no Append yet → no file on disk → []
        Assert.Equal(0, this.repo.LoadAll().Length)
        Assert.Equal(0, this.sink.Count(),
            "Missing file is not a warn-worthy condition")
    }

    load_all_returns_field_names_in_expected_map_keys()
    {
        this.repo.Append("Mud Burrow", "0.4", "Default", "2026-05-20 14:00:00")
        row := this.repo.LoadAll()[1]
        Assert.True(row.Has("ts"))
        Assert.True(row.Has("zoneName"))
        Assert.True(row.Has("patch"))
        Assert.True(row.Has("profile"))
    }

    load_all_skips_malformed_rows_with_too_few_columns()
    {
        ; Simulate a torn last line by writing a CSV with one good
        ; row and one truncated row (only 2 columns). The truncated
        ; row should be dropped silently by ReadAllRows — partial
        ; lines from a crash do not abort the load.
        FileAppend(
            "ts;zoneName;patch;profile`n"
            . Chr(34) "2026-05-20 14:00:00" Chr(34) ";"
            . Chr(34) "Mud Burrow"          Chr(34) ";"
            . Chr(34) "0.4"                 Chr(34) ";"
            . Chr(34) "Default"             Chr(34) "`n"
            . Chr(34) "2026-05-20 14:05:00" Chr(34) ";"
            . Chr(34) "Truncated"           Chr(34) "`n",
            this.path, "UTF-8")
        rows := this.repo.LoadAll()
        Assert.Equal(1, rows.Length,
            "Truncated row (2 columns) must be skipped silently")
        Assert.Equal("Mud Burrow", rows[1]["zoneName"])
    }
}

TestRegistry.Register(DeathLogRepositoryTests)
