; ============================================================
; DeathStatsDialogTests
; ============================================================
;
; Headless smoke tests for the dialog. Covers constructor wiring,
; the Cmd.OpenDeathStatsRequested subscription path, idempotent
; Open/Close, the headless gate (no real Gui object built), the
; mode toggle (live <-> alltime, scanner integration), and the
; static FormatBar helper used by the ASCII bar column.
;
; The full visual layout (column widths, dropdown rebuild on
; Refresh, Filter -> ListView wiring) is not exercised here --
; that would require a real Gui and a manual eye on the output.
; Headless mode early-returns from Open() before _BuildGui, so
; the runtime checks below confirm the gate works and the public
; contract holds across construction/lifecycle.
;
; Mode toggle tests use the public ToggleAlltimeMode() hook,
; which fires the same code path the button OnEvent does. The
; cfg.logFile + cfg.characterName fields drive the scan inputs,
; so each test that exercises the toggle sets them to a tiny
; fixture Client.txt created via Fixtures.TempFile.


class DeathStatsDialogTests extends TestCase
{
    deathLogPath := ""
    catalogPath  := ""
    deathLog     := ""
    catalog      := ""
    statsSvc     := ""
    scanner      := ""
    cfg          := ""
    bus          := ""
    dialog       := ""

    static CATALOG_CONTENT := "
    (LTrim
        name;internal_id;act;is_town
        Mud Burrow;G1_1;1;0
        The Riverbank;G2_5;2;0
        Clearfell Encampment;G1_town;1;1
    )"

    Setup()
    {
        this.deathLogPath := Fixtures.TempPath("csv")
        this.deathLog     := DeathLogRepository(this.deathLogPath)

        this.catalogPath := Fixtures.TempFile(DeathStatsDialogTests.CATALOG_CONTENT, "csv")
        this.catalog     := ZonesCatalog(this.catalogPath)

        this.statsSvc := DeathStatsService(this.deathLog, this.catalog)
        this.scanner  := DeathLogScanner(this.catalog)
        this.cfg      := AppSettings.Defaults()
        this.bus      := Fixtures.MakeBus()
        this.dialog   := DeathStatsDialog(this.bus, this.statsSvc, this.scanner, this.cfg, true)
    }

    Teardown()
    {
        try this.dialog.Close()
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor type-checks ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_stats_svc_not_death_stats_service",
        "constructor_throws_when_scanner_not_death_log_scanner",
        "constructor_throws_when_cfg_not_app_settings",
        "constructor_subscribes_to_open_command",

        ; --- Lifecycle ---
        "is_open_false_initially",
        "open_in_headless_marks_is_open_true",
        "headless_open_does_not_build_gui",
        "open_via_command_publishes_marks_is_open_true",
        "close_resets_is_open_to_false",
        "close_is_idempotent",
        "open_is_idempotent_when_already_open",

        ; --- Mode toggle (LT2) ---
        "get_mode_starts_as_live",
        "is_in_alltime_mode_false_initially",
        "toggle_alltime_with_valid_log_switches_to_alltime_and_caches_result",
        "toggle_alltime_back_to_live_clears_mode_and_cache",
        "toggle_with_missing_log_file_stays_in_live_silently_in_headless",
        "open_resets_mode_to_live_after_alltime",
        "alltime_scan_ignores_cfg_character_and_counts_every_death",

        ; --- Export (LT3) ---
        "format_export_csv_empty_array_returns_only_header",
        "format_export_csv_non_array_returns_only_header",
        "format_export_csv_single_row_emits_header_and_one_data_line",
        "format_export_csv_multiple_rows_preserves_order_from_perzone",
        "format_export_csv_quotes_data_fields",
        "format_export_csv_escapes_internal_quotes_in_zone_name",
        "write_export_to_path_returns_false_when_no_alltime_result",
        "write_export_to_path_writes_csv_file_with_header_and_rows",

        ; --- Static FormatBar helper ---
        "format_bar_zero_count_returns_empty",
        "format_bar_equal_to_max_returns_full_bar",
        "format_bar_half_max_returns_half_bar",
        "format_bar_clamps_above_max",
        "format_bar_at_least_one_block_when_count_positive_below_threshold",
        "format_bar_zero_max_returns_empty_defensive",
        "format_bar_non_number_inputs_return_empty"
    ]

    ; ============================================================
    ; Helpers
    ; ============================================================

    ; Builds a minimal Client.txt fixture with the given lines
    ; joined by `n. The body always ends with a newline so the
    ; last line has the same terminator as preceding ones.
    _ClientTxt(lines)
    {
        body := ""
        for _, line in lines
            body .= line . "`n"
        return Fixtures.TempFile(body, "txt")
    }

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        Assert.Throws(TypeError, () =>
            DeathStatsDialog("not a bus", this.statsSvc, this.scanner, this.cfg))
    }

    constructor_throws_when_stats_svc_not_death_stats_service()
    {
        Assert.Throws(TypeError, () =>
            DeathStatsDialog(this.bus, "not a svc", this.scanner, this.cfg))
        Assert.Throws(TypeError, () =>
            DeathStatsDialog(this.bus, Map(), this.scanner, this.cfg))
    }

    constructor_throws_when_scanner_not_death_log_scanner()
    {
        Assert.Throws(TypeError, () =>
            DeathStatsDialog(this.bus, this.statsSvc, "not a scanner", this.cfg))
        Assert.Throws(TypeError, () =>
            DeathStatsDialog(this.bus, this.statsSvc, Map(), this.cfg))
    }

    constructor_throws_when_cfg_not_app_settings()
    {
        Assert.Throws(TypeError, () =>
            DeathStatsDialog(this.bus, this.statsSvc, this.scanner, "not a cfg"))
        Assert.Throws(TypeError, () =>
            DeathStatsDialog(this.bus, this.statsSvc, this.scanner, Map()))
    }

    constructor_subscribes_to_open_command()
    {
        ; The dialog subscribes to Cmd.OpenDeathStatsRequested in its
        ; constructor. Setup just created one, so the bus should have
        ; >= 1 subscriber on that command.
        Assert.True(this.bus.Subscribers(Commands.OpenDeathStatsRequested) >= 1)
    }

    ; ============================================================
    ; Lifecycle
    ; ============================================================

    is_open_false_initially()
    {
        Assert.False(this.dialog.IsOpen())
    }

    open_in_headless_marks_is_open_true()
    {
        this.dialog.Open()
        Assert.True(this.dialog.IsOpen())
    }

    headless_open_does_not_build_gui()
    {
        ; In headless mode Open() early-returns before _BuildGui;
        ; the _gui field must stay empty. This is the contract the
        ; tests-without-X11 environment depends on.
        this.dialog.Open()
        Assert.Equal("", this.dialog._gui,
            "headless Open must not instantiate a real Gui")
    }

    open_via_command_publishes_marks_is_open_true()
    {
        ; The whole point of subscribing in __New: publishing the
        ; command should land on the dialog without any caller
        ; knowing about it directly.
        Assert.False(this.dialog.IsOpen())
        this.bus.Publish(Commands.OpenDeathStatsRequested, Map())
        Assert.True(this.dialog.IsOpen(),
            "Publishing OpenDeathStatsRequested opens the dialog")
    }

    close_resets_is_open_to_false()
    {
        this.dialog.Open()
        Assert.True(this.dialog.IsOpen())
        this.dialog.Close()
        Assert.False(this.dialog.IsOpen())
    }

    close_is_idempotent()
    {
        ; Close on a never-opened dialog is a no-op. Close after
        ; Close is also a no-op. Both paths must not throw.
        this.dialog.Close()
        this.dialog.Close()
        Assert.False(this.dialog.IsOpen())
    }

    open_is_idempotent_when_already_open()
    {
        ; In headless mode the second Open is also a no-op (returns
        ; true, leaves IsOpen=true). The branch that calls Refresh
        ; on re-open is gated by `this._gui` being non-empty, which
        ; never happens headless.
        this.dialog.Open()
        this.dialog.Open()
        Assert.True(this.dialog.IsOpen())
    }

    ; ============================================================
    ; Mode toggle (LT2)
    ; ============================================================

    get_mode_starts_as_live()
    {
        Assert.Equal("live", this.dialog.GetMode())
    }

    is_in_alltime_mode_false_initially()
    {
        Assert.False(this.dialog.IsInAlltimeMode())
    }

    toggle_alltime_with_valid_log_switches_to_alltime_and_caches_result()
    {
        ; Fixture: a single SCENE + two deaths in Mud Burrow.
        logPath := this._ClientTxt([
            "[INFO Client] [SCENE] Set Source [Mud Burrow]",
            "[INFO Client] : Hero has been slain.",
            "[INFO Client] : Hero has been slain."
        ])
        this.cfg.logFile := logPath
        this.cfg.characterName := "Hero"

        this.dialog.Open()
        Assert.Equal("live", this.dialog.GetMode())

        this.dialog.ToggleAlltimeMode()
        Assert.Equal("alltime", this.dialog.GetMode())
        Assert.True(this.dialog.IsInAlltimeMode())
        Assert.True(IsObject(this.dialog._alltimeResult),
            "alltime result must be cached after successful toggle")
        Assert.Equal(2, this.dialog._alltimeResult["totalDeaths"])
    }

    toggle_alltime_back_to_live_clears_mode_and_cache()
    {
        logPath := this._ClientTxt([
            "[INFO] [SCENE] Set Source [Mud Burrow]",
            "[INFO] : Hero has been slain."
        ])
        this.cfg.logFile := logPath
        this.cfg.characterName := "Hero"

        this.dialog.Open()
        this.dialog.ToggleAlltimeMode()
        Assert.Equal("alltime", this.dialog.GetMode())

        ; Second toggle: back to live.
        this.dialog.ToggleAlltimeMode()
        Assert.Equal("live", this.dialog.GetMode())
        Assert.Equal("", this.dialog._alltimeResult,
            "alltime cache must be cleared on back-to-live")
    }

    toggle_with_missing_log_file_stays_in_live_silently_in_headless()
    {
        ; Point cfg at a guaranteed-nonexistent path. In production
        ; the user sees a MsgBox; in headless _DoAlltimeScan returns
        ; false silently and the mode stays "live". The test pins
        ; that contract so wiring regressions surface as test fails
        ; rather than as silent UI bugs.
        this.cfg.logFile := A_Temp . "\sk_test_nonexistent_log_"
                              . Random(1, 999999999) . ".txt"
        this.cfg.characterName := "Hero"

        this.dialog.Open()
        this.dialog.ToggleAlltimeMode()   ; must not throw
        Assert.Equal("live", this.dialog.GetMode(),
            "failed scan keeps mode at live")
        Assert.Equal("", this.dialog._alltimeResult,
            "failed scan leaves cache empty")
    }

    open_resets_mode_to_live_after_alltime()
    {
        ; Toggle to alltime, then Close + Open: must come back as
        ; live. The contract is "the alltime view is a deliberate
        ; per-session opt-in" — sticky-across-sessions would feel
        ; like the app silently changed data sources.
        logPath := this._ClientTxt([
            "[INFO] [SCENE] Set Source [Mud Burrow]",
            "[INFO] : Hero has been slain."
        ])
        this.cfg.logFile := logPath
        this.cfg.characterName := "Hero"

        this.dialog.Open()
        this.dialog.ToggleAlltimeMode()
        Assert.Equal("alltime", this.dialog.GetMode())

        this.dialog.Close()
        this.dialog.Open()
        Assert.Equal("live", this.dialog.GetMode(),
            "fresh Open() must reset mode to live")
        Assert.Equal("", this.dialog._alltimeResult,
            "fresh Open() must clear any cached alltime result")
    }

    alltime_scan_ignores_cfg_character_and_counts_every_death()
    {
        ; All-time view deliberately drops the cfg.characterName
        ; filter — it's meant to surface every death the log
        ; records, across every character the player ever ran.
        ; Current PoE2 builds do not emit `has been slain` for
        ; bosses, so dropping the filter does not pollute the
        ; result with monster kills. Pinned here rather than only
        ; in DeathLogScannerTests because the dialog's
        ; _DoAlltimeScan is the production seam wiring the empty
        ; filter into the scan call — if a future change
        ; reintroduces a per-character filter, this test catches it.
        logPath := this._ClientTxt([
            "[INFO] [SCENE] Set Source [Mud Burrow]",
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain.",
            "[INFO] : OtherChar has been slain.",
            "[INFO] : The Devourer has been slain."
        ])
        this.cfg.logFile := logPath
        ; cfg.characterName is set to "Hero" but the all-time view
        ; must ignore it and count all four `has been slain` lines.
        this.cfg.characterName := "Hero"

        this.dialog.Open()
        this.dialog.ToggleAlltimeMode()
        Assert.Equal(4, this.dialog._alltimeResult["totalDeaths"],
            "all four deaths counted, not just Hero's")
    }

    ; ============================================================
    ; Export (LT3)
    ; ============================================================

    format_export_csv_empty_array_returns_only_header()
    {
        out := DeathStatsDialog.FormatExportCsv([])
        Assert.Equal("zoneName;count`n", out,
            "empty perZone returns just the header line")
    }

    format_export_csv_non_array_returns_only_header()
    {
        ; Defensive against caller error: a future bug that hands
        ; the formatter "" or Map() instead of an Array should NOT
        ; corrupt the file with a stack trace or empty body. The
        ; header-only output makes the failure visible (the user
        ; sees a file with no data rows) without crashing the
        ; export flow.
        Assert.Equal("zoneName;count`n", DeathStatsDialog.FormatExportCsv(""))
        Assert.Equal("zoneName;count`n", DeathStatsDialog.FormatExportCsv(Map()))
        Assert.Equal("zoneName;count`n", DeathStatsDialog.FormatExportCsv(0))
    }

    format_export_csv_single_row_emits_header_and_one_data_line()
    {
        perZone := [Map("zoneName", "Mud Burrow", "count", 3)]
        out := DeathStatsDialog.FormatExportCsv(perZone)
        Assert.Equal("zoneName;count`n`"Mud Burrow`";`"3`"`n", out)
    }

    format_export_csv_multiple_rows_preserves_order_from_perzone()
    {
        ; perZone arrives sorted by count desc from the scanner;
        ; the formatter must preserve that order verbatim (no
        ; alphabetic reordering). The user reads the file top-down
        ; expecting the same order they see in the dialog.
        perZone := [
            Map("zoneName", "Cemetery of the Eternals", "count", 5),
            Map("zoneName", "Mud Burrow",               "count", 3),
            Map("zoneName", "The Riverbank",            "count", 1)
        ]
        out := DeathStatsDialog.FormatExportCsv(perZone)
        ; Lines split on LF (the header is line 1).
        lines := StrSplit(out, "`n")
        Assert.Equal("zoneName;count",               lines[1])
        Assert.Equal("`"Cemetery of the Eternals`";`"5`"", lines[2])
        Assert.Equal("`"Mud Burrow`";`"3`"",          lines[3])
        Assert.Equal("`"The Riverbank`";`"1`"",       lines[4])
    }

    format_export_csv_quotes_data_fields()
    {
        ; All data rows must be wrapped in double quotes (project
        ; convention — CsvFile.FormatRow does this). Even the
        ; numeric count gets quoted; consistency with deaths.csv
        ; (which the dialog otherwise reads) matters more than
        ; "strict CSV" type purity.
        out := DeathStatsDialog.FormatExportCsv([
            Map("zoneName", "Mud Burrow", "count", 42)
        ])
        Assert.True(InStr(out, "`"Mud Burrow`";`"42`"") > 0,
            "zone and count both quoted: got " . out)
    }

    format_export_csv_escapes_internal_quotes_in_zone_name()
    {
        ; Internal `"` is doubled per CsvFile.EscapeField. A zone
        ; name with a quote in it (unlikely in practice but possible
        ; if PoE2 ever ships one) must survive a roundtrip through
        ; the same parser that reads deaths.csv.
        perZone := [Map("zoneName", "Weird `"Zone`" Name", "count", 1)]
        out := DeathStatsDialog.FormatExportCsv(perZone)
        Assert.True(InStr(out, "`"Weird `"`"Zone`"`" Name`"") > 0,
            "internal quote escaped via doubling: got " . out)
    }

    write_export_to_path_returns_false_when_no_alltime_result()
    {
        ; Dialog never toggled to alltime, _alltimeResult is "".
        ; _WriteExportToPath must reject silently rather than
        ; writing an empty/header-only file the caller didn't ask
        ; for. The button is hidden in live mode (covered visually,
        ; not by an assert here), but the helper still has to
        ; defend itself in case a future bug calls it directly.
        path := Fixtures.TempPath("csv")
        ok := this.dialog._WriteExportToPath(path)
        Assert.False(ok, "returns false without an alltime cache")
        Assert.False(FileExist(path) != "",
            "no file should have been written")
    }

    write_export_to_path_writes_csv_file_with_header_and_rows()
    {
        ; End-to-end: toggle alltime over a tiny Client.txt fixture,
        ; then write the resulting cache to disk and read it back.
        ; Roundtrip is the test the dialog/scanner unit-tests can't
        ; do on their own: it pins the contract that what the user
        ; sees in the dialog is what they get in the file.
        logPath := this._ClientTxt([
            "[INFO] [SCENE] Set Source [Mud Burrow]",
            "[INFO] : Hero has been slain.",
            "[INFO] : Hero has been slain.",
            "[INFO] [SCENE] Set Source [The Riverbank]",
            "[INFO] : Hero has been slain."
        ])
        this.cfg.logFile := logPath
        this.cfg.characterName := "Hero"

        this.dialog.Open()
        this.dialog.ToggleAlltimeMode()
        Assert.Equal(3, this.dialog._alltimeResult["totalDeaths"],
            "sanity: alltime scan produced 3 deaths")

        exportPath := Fixtures.TempPath("csv")
        ok := this.dialog._WriteExportToPath(exportPath)
        Assert.True(ok, "export succeeded")
        Assert.True(FileExist(exportPath) != "", "file exists on disk")

        content := FileRead(exportPath, "UTF-8")
        Assert.True(InStr(content, "zoneName;count") = 1,
            "header is the first line: " . content)
        Assert.True(InStr(content, "`"Mud Burrow`";`"2`"") > 0,
            "Mud Burrow row present with count 2")
        Assert.True(InStr(content, "`"The Riverbank`";`"1`"") > 0,
            "Riverbank row present with count 1")
    }

    ; ============================================================
    ; FormatBar static helper
    ; ============================================================

    format_bar_zero_count_returns_empty()
    {
        Assert.Equal("", DeathStatsDialog.FormatBar(0, 10, 30))
    }

    format_bar_equal_to_max_returns_full_bar()
    {
        ; count == maxCount -> bar fills the maxChars width.
        bar := DeathStatsDialog.FormatBar(10, 10, 30)
        Assert.Equal(30, StrLen(bar))
    }

    format_bar_half_max_returns_half_bar()
    {
        ; count = half of max -> bar is ~half of maxChars (rounded).
        bar := DeathStatsDialog.FormatBar(5, 10, 30)
        ; Round(5/10 * 30) = 15
        Assert.Equal(15, StrLen(bar))
    }

    format_bar_clamps_above_max()
    {
        ; Defensive against caller error: count > maxCount should
        ; clamp to maxChars, not overflow.
        bar := DeathStatsDialog.FormatBar(100, 10, 30)
        Assert.Equal(30, StrLen(bar))
    }

    format_bar_at_least_one_block_when_count_positive_below_threshold()
    {
        ; count = 1, maxCount = 100, maxChars = 30
        ; -> Round(1/100*30) = 0, but we want at least one block so
        ; the zone is visibly NOT zero on the chart.
        bar := DeathStatsDialog.FormatBar(1, 100, 30)
        Assert.Equal(1, StrLen(bar))
    }

    format_bar_zero_max_returns_empty_defensive()
    {
        ; All-zero dataset -> maxCount=0. Must not divide by zero.
        Assert.Equal("", DeathStatsDialog.FormatBar(5, 0, 30))
        Assert.Equal("", DeathStatsDialog.FormatBar(0, 0, 30))
    }

    format_bar_non_number_inputs_return_empty()
    {
        ; Defensive: any non-numeric input returns empty rather
        ; than throwing (caller could pass an unexpected type
        ; through a Map lookup; bar-rendering should never crash
        ; the redraw of the whole list).
        Assert.Equal("", DeathStatsDialog.FormatBar("five", 10, 30))
        Assert.Equal("", DeathStatsDialog.FormatBar(5, "ten", 30))
        Assert.Equal("", DeathStatsDialog.FormatBar(5, 10, "thirty"))
    }
}

TestRegistry.Register(DeathStatsDialogTests)
