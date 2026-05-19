; ============================================================
; SpeedKalandra Test Suite - entry point
; ============================================================
;
; How to run:
;
;   "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" tests_v2\run_tests.ahk
;
; or double-click if the extension is associated with AHK v2.
;
; Filter tests:
;
;   AutoHotkey64.exe tests_v2\run_tests.ahk EventBus
;   AutoHotkey64.exe tests_v2\run_tests.ahk Duration
;
; runs only tests whose "ClassName::method" contains the substring.
;
; ============================================================
; Include order (CRITICAL):
;
;   1. Framework first.
;
;   2. SUT (System Under Test) - in dependency order:
;      core -> domain -> infra -> app -> ui
;      Within each layer, deps first.
;
;   3. Suites - each suite, at the end of the file, calls
;      TestRegistry.Register(Class).
;
;   4. Bootstrap - TestReporter.Init() + TestRunner.Run().

#Requires AutoHotkey v2.0
#SingleInstance Off
; Warnings go to OutputDebug, not MsgBox: headless runs (CI,
; SPEEDKALANDRA_TEST_NO_GUI=1) can't dismiss dialogs and AHK exits
; with a non-zero code if a MsgBox is attempted without an
; interactive session. View live warnings locally with DbgView.
#Warn All, OutputDebug
#NoTrayIcon

; ============================================================
; Boot-time diagnostics + unhandled-error handler
; ============================================================
;
; Installed BEFORE any #Include so two failure modes that previously
; sank a CI run without leaving any trace are now captured:
;
;   1. PARSE error in an included file. AHK still surfaces these via
;      a modal dialog in non-interactive sessions (where it hangs
;      forever). /ErrorStdOut on the AHK command line routes those
;      to stderr, which the workflow's `&` call captures in the
;      step output.
;
;   2. RUNTIME error during global-scope code (e.g. a static field
;      initializer in an included class, or top-level setup before
;      the bootstrap call). Without OnError, AHK would show a MsgBox
;      and hang. With OnError, the error goes to tests_boot.log AND
;      to stderr, then ExitApp(2) terminates loud.
;
; The boot log is a SEPARATE file from tests_output.log because
; TestReporter.Init() deletes tests_output.log on entry — a unified
; file would lose the boot trail. Both files are uploaded as CI
; artifacts by the workflow.

global SK_TEST_BOOT_LOG := A_ScriptDir "\tests_boot.log"
try FileDelete(SK_TEST_BOOT_LOG)
try FileAppend(
    "=== BOOT @ " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " ===`n"
    . "AhkPath:     " A_AhkPath "`n"
    . "AhkVersion:  " A_AhkVersion "`n"
    . "ScriptDir:   " A_ScriptDir "`n"
    . "WorkingDir:  " A_WorkingDir "`n"
    . "CI:          " EnvGet("CI") "`n"
    . "NO_GUI:      " EnvGet("SPEEDKALANDRA_TEST_NO_GUI") "`n`n",
    SK_TEST_BOOT_LOG, "UTF-8")

OnError(SkTestOnError)

SkTestOnError(err, mode) {
    global SK_TEST_BOOT_LOG

    ; Build the error message step by step. AHK v2 ternaries inside
    ; concatenation chains parse, but with several nested branches the
    ; intent gets opaque — plain ifs are easier to read and harder to
    ; misparse if someone later edits this.
    if IsObject(err) {
        errType := Type(err)
        errMsg  := err.HasOwnProp("Message") ? err.Message : "?"
        msg     := "UNHANDLED ERROR [" mode "]: " errType ": " errMsg
        if err.HasOwnProp("File")
        {
            line := err.HasOwnProp("Line") ? err.Line : "?"
            msg .= "`n  at " err.File ":" line
        }
        if err.HasOwnProp("Stack") && err.Stack != ""
            msg .= "`n  stack:`n" err.Stack
    } else {
        msg := "UNHANDLED ERROR [" mode "]: " String(err)
    }

    try FileAppend("`n" msg "`n", SK_TEST_BOOT_LOG, "UTF-8")
    ; Also write to stderr ("**") so the workflow step output shows
    ; the failure inline, not just via the uploaded artifact.
    try FileAppend(msg "`n", "**")
    ; Exit non-zero. Code 2 distinguishes "unhandled error in the
    ; suite harness" from code 1 ("tests ran and some failed").
    ExitApp(2)
    ; Returning 1 suppresses AHK's default MsgBox — critical for
    ; non-interactive sessions where the dialog would hang forever.
    return 1
}


; ------------------------------------------------------------
; Framework
; ------------------------------------------------------------
#Include framework\assert.ahk
#Include framework\test_case.ahk
#Include framework\test_registry.ahk
#Include framework\test_reporter.ahk
#Include framework\test_runner.ahk
#Include framework\fixtures.ahk

; ------------------------------------------------------------
; SUT - core
; ------------------------------------------------------------
#Include ..\src_v2\version.ahk
#Include ..\src_v2\core\log_service.ahk
#Include ..\src_v2\core\event_bus.ahk
#Include ..\src_v2\core\clock.ahk
#Include ..\src_v2\core\warning_sink.ahk

; ------------------------------------------------------------
; SUT - domain
; (values first, then composites; AppSettings last because it
; depends on WindowState and OverlayLayout)
; ------------------------------------------------------------
#Include ..\src_v2\domain\values\duration.ahk
#Include ..\src_v2\domain\values\ids.ahk
#Include ..\src_v2\domain\window_state.ahk
#Include ..\src_v2\domain\overlay_layout.ahk
#Include ..\src_v2\domain\run_state.ahk
#Include ..\src_v2\domain\xp_rules.ahk
#Include ..\src_v2\domain\app_settings.ahk

; ------------------------------------------------------------
; SUT - infra/io
; (atomic_write first since it's a dep of many; json/csv/text_encoding
; use AtomicWriter; run_export_format uses JsonFile + JsonBool/Null)
; ------------------------------------------------------------
#Include ..\src_v2\infra\io\atomic_write.ahk
#Include ..\src_v2\infra\io\text_encoding.ahk
#Include ..\src_v2\infra\io\ini_file.ahk
#Include ..\src_v2\infra\io\csv_file.ahk
#Include ..\src_v2\infra\io\json_file.ahk
#Include ..\src_v2\infra\io\run_export_format.ahk

; ------------------------------------------------------------
; SUT - infra/ (repositories)
; (all depend on IniFile/AtomicWriter already included above;
; settings_repository depends on AppSettings/WindowState/OverlayLayout
; from the domain)
; ------------------------------------------------------------
#Include ..\src_v2\infra\zones_catalog.ahk
#Include ..\src_v2\infra\personal_best_repository.ahk
#Include ..\src_v2\infra\run_state_repository.ahk
#Include ..\src_v2\infra\run_history_repository.ahk
#Include ..\src_v2\infra\settings_repository.ahk

; ------------------------------------------------------------
; SUT - app/bus (Events + Commands enums: deps of all services)
; ------------------------------------------------------------
#Include ..\src_v2\app\bus\events.ahk
#Include ..\src_v2\app\bus\commands.ahk

; ------------------------------------------------------------
; SUT - app/services
; Order by dependency: state-only -> bus-only -> bus+clock/timer
; -> with repos -> with catalog+cfg
; ------------------------------------------------------------
#Include ..\src_v2\app\services\xp_service.ahk
#Include ..\src_v2\app\services\app_tick_emitter.ahk
#Include ..\src_v2\app\services\hud_pixel_scanner.ahk
#Include ..\src_v2\app\services\loading_totals_service.ahk
#Include ..\src_v2\app\services\timer_service.ahk
#Include ..\src_v2\app\services\act_checkpoint_tracker.ahk
#Include ..\src_v2\app\services\run_stats_recorder.ahk
#Include ..\src_v2\app\services\personal_best_service.ahk
#Include ..\src_v2\app\services\run_stats_plot_builder.ahk
#Include ..\src_v2\app\services\zone_tracking_service.ahk
#Include ..\src_v2\app\services\log_monitor_service.ahk
#Include ..\src_v2\app\services\loading_detection_service.ahk
#Include ..\src_v2\app\services\run_service.ahk
#Include ..\src_v2\app\services\auto_start_service.ahk
#Include ..\src_v2\app\services\auto_finalize_service.ahk
#Include ..\src_v2\app\services\overlay_mode_service.ahk
#Include ..\src_v2\app\services\overlay_mode_applier.ahk
#Include ..\src_v2\app\services\hotkey_service.ahk
#Include ..\src_v2\app\services\focus_auto_pause_service.ahk
#Include ..\src_v2\app\services\overlay_interaction_service.ahk
#Include ..\src_v2\app\services\event_trace_logger.ahk
#Include ..\src_v2\app\services\run_export_service.ahk
#Include ..\src_v2\app\services\run_import_service.ahk

; ------------------------------------------------------------
; SUT - ui/
; Order: pure ones (Theme, HotkeyFormatter) first
; ------------------------------------------------------------
#Include ..\src_v2\ui\theme.ahk
#Include ..\src_v2\ui\hotkey_formatter.ahk
#Include ..\src_v2\ui\widget_base.ahk
#Include ..\src_v2\ui\layout_widget_base.ahk
#Include ..\src_v2\ui\line_chart_renderer.ahk
#Include ..\src_v2\ui\compact_layout_widget.ahk
#Include ..\src_v2\ui\micro_layout_widget.ahk
#Include ..\src_v2\ui\steve_layout_widget.ahk
#Include ..\src_v2\ui\settings_dialog.ahk
#Include ..\src_v2\ui\run_stats_plot_dialog.ahk
#Include ..\src_v2\ui\run_history_dialog.ahk
#Include ..\src_v2\ui\export_options_dialog.ahk
#Include ..\src_v2\ui\import_preview_dialog.ahk

; ------------------------------------------------------------
; SUT - app/ (composition root)
; ------------------------------------------------------------
; Stubs of global helpers that normally live in speedkalandra.ahk
; (entry point) — in tests we don't have that file, but app.ahk
; references these symbols in paths that run even in headless mode
; (wrapped in try). Defined as no-ops here to satisfy the parser.
SpeedKalandraTrayAddUndoItem() {
    ; no-op in headless
}
SpeedKalandraTrayRemoveUndoItem() {
    ; no-op in headless
}
SpeedKalandraMsgBox(text, title := "", options := "") {
    ; no-op in headless — returns "Cancel" so code that expects
    ; "Yes" treats it as a denial (destructive path doesn't run in tests)
    return "Cancel"
}

#Include ..\src_v2\app\boot_prompts.ahk
#Include ..\src_v2\app\run_snapshot_saver.ahk
#Include ..\src_v2\app\run_state_persister.ahk
#Include ..\src_v2\app\live_reconfiguration_handlers.ahk

#Include ..\src_v2\app\app.ahk

; ------------------------------------------------------------
; Suites - core/
; ------------------------------------------------------------
#Include unit\core\event_bus_tests.ahk
#Include unit\core\clock_tests.ahk
#Include unit\core\null_logger_tests.ahk
#Include unit\core\in_memory_logger_tests.ahk
#Include unit\core\log_service_tests.ahk
#Include unit\core\warning_sink_tests.ahk

; ------------------------------------------------------------
; Suites - domain/
; ------------------------------------------------------------
#Include unit\domain\duration_tests.ahk
#Include unit\domain\ids_tests.ahk
#Include unit\domain\window_state_tests.ahk
#Include unit\domain\run_state_tests.ahk
#Include unit\domain\xp_rules_tests.ahk
#Include unit\domain\overlay_layout_tests.ahk
#Include unit\domain\app_settings_tests.ahk

; ------------------------------------------------------------
; Suites - infra/io/
; ------------------------------------------------------------
#Include unit\infra\io\atomic_write_tests.ahk
#Include unit\infra\io\text_encoding_tests.ahk
#Include unit\infra\io\ini_file_tests.ahk
#Include unit\infra\io\csv_file_tests.ahk
#Include unit\infra\io\json_file_tests.ahk
#Include unit\infra\io\run_export_format_tests.ahk

; ------------------------------------------------------------
; Suites - infra/ (repositories)
; ------------------------------------------------------------
#Include unit\infra\zones_catalog_tests.ahk
#Include unit\infra\personal_best_repository_tests.ahk
#Include unit\infra\run_state_repository_tests.ahk
#Include unit\infra\run_state_repository_warning_sink_tests.ahk
#Include unit\infra\run_history_repository_tests.ahk
#Include unit\infra\settings_repository_tests.ahk

; ------------------------------------------------------------
; Suites - app/services
; ------------------------------------------------------------
#Include unit\app\services\xp_service_tests.ahk
#Include unit\app\services\app_tick_emitter_tests.ahk
#Include unit\app\services\hud_pixel_scanner_tests.ahk
#Include unit\app\services\loading_totals_service_tests.ahk
#Include unit\app\services\timer_service_tests.ahk
#Include unit\app\services\act_checkpoint_tracker_tests.ahk
#Include unit\app\services\run_stats_recorder_tests.ahk
#Include unit\app\services\personal_best_service_tests.ahk
#Include unit\app\services\personal_best_service_warning_sink_tests.ahk
#Include unit\app\services\run_stats_plot_builder_tests.ahk
#Include unit\app\services\zone_tracking_service_tests.ahk
#Include unit\app\services\log_monitor_service_tests.ahk
#Include unit\app\services\loading_detection_service_tests.ahk
#Include unit\app\services\run_service_tests.ahk
#Include unit\app\services\auto_start_service_tests.ahk
#Include unit\app\services\auto_finalize_service_tests.ahk
#Include unit\app\services\overlay_mode_service_tests.ahk
#Include unit\app\services\overlay_mode_applier_tests.ahk
#Include unit\app\services\hotkey_service_tests.ahk
#Include unit\app\services\focus_auto_pause_service_tests.ahk
#Include unit\app\services\overlay_interaction_service_tests.ahk
#Include unit\app\services\event_trace_logger_tests.ahk
#Include unit\app\services\run_import_service_tests.ahk

; ------------------------------------------------------------
; Suites - app/ (composition-root collaborators)
; ------------------------------------------------------------
#Include unit\app\boot_prompts_tests.ahk
#Include unit\app\run_snapshot_saver_tests.ahk
#Include unit\app\run_state_persister_tests.ahk
#Include unit\app\live_reconfiguration_handlers_tests.ahk

; ------------------------------------------------------------
; Suites - ui/
; ------------------------------------------------------------
#Include unit\ui\theme_tests.ahk
#Include unit\ui\hotkey_formatter_tests.ahk
#Include unit\ui\widget_base_tests.ahk
#Include unit\ui\layout_widget_base_tests.ahk
#Include unit\ui\compact_layout_widget_tests.ahk
#Include unit\ui\run_stats_plot_dialog_tests.ahk

; ------------------------------------------------------------
; Suites - integration (end-to-end)
; ------------------------------------------------------------
#Include integration\speedkalandra_app_integration_tests.ahk

; ------------------------------------------------------------
; Bootstrap
; ------------------------------------------------------------
; CI diagnostic: marker between TestRegistry.Register() loop (each
; line writes "REG: ClassName" to tests_boot.log) and the bootstrap
; that follows. If the boot log ends with this line but no
; tests_output.log was produced, the failure is INSIDE
; TestReporter.Init(). If the boot log stops at some REG: line
; without this marker, the file registered AFTER that one is the
; culprit.
try FileAppend("-- bootstrap starting --`n", A_ScriptDir "\tests_boot.log", "UTF-8")

TestReporter.Init()
TestRunner.Run()
