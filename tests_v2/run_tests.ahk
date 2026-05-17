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
#Warn All, MsgBox
#NoTrayIcon

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
; SUT - app/services (Wave 5a: pure services / with simple state)
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
#Include ..\src_v2\app\services\run_export_service.ahk
#Include ..\src_v2\app\services\run_import_service.ahk

; ------------------------------------------------------------
; SUT - ui/ (Wave 7: UI layer)
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
; SUT - app/ (Wave 8: composition root)
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

#Include ..\src_v2\app\app.ahk

; ------------------------------------------------------------
; Suites - Wave 1: core/
; ------------------------------------------------------------
#Include unit\core\event_bus_tests.ahk
#Include unit\core\clock_tests.ahk
#Include unit\core\null_logger_tests.ahk
#Include unit\core\in_memory_logger_tests.ahk
#Include unit\core\log_service_tests.ahk

; ------------------------------------------------------------
; Suites - Wave 2: domain/
; ------------------------------------------------------------
#Include unit\domain\duration_tests.ahk
#Include unit\domain\ids_tests.ahk
#Include unit\domain\window_state_tests.ahk
#Include unit\domain\run_state_tests.ahk
#Include unit\domain\xp_rules_tests.ahk
#Include unit\domain\overlay_layout_tests.ahk
#Include unit\domain\app_settings_tests.ahk

; ------------------------------------------------------------
; Suites - Wave 3: infra/io/
; ------------------------------------------------------------
#Include unit\infra\io\atomic_write_tests.ahk
#Include unit\infra\io\text_encoding_tests.ahk
#Include unit\infra\io\ini_file_tests.ahk
#Include unit\infra\io\csv_file_tests.ahk
#Include unit\infra\io\json_file_tests.ahk
#Include unit\infra\io\run_export_format_tests.ahk

; ------------------------------------------------------------
; Suites - Wave 4: infra/ (repositories)
; ------------------------------------------------------------
#Include unit\infra\zones_catalog_tests.ahk
#Include unit\infra\personal_best_repository_tests.ahk
#Include unit\infra\run_state_repository_tests.ahk
#Include unit\infra\run_history_repository_tests.ahk
#Include unit\infra\settings_repository_tests.ahk

; ------------------------------------------------------------
; Suites - Wave 5a: app/services (pure)
; ------------------------------------------------------------
#Include unit\app\services\xp_service_tests.ahk
#Include unit\app\services\app_tick_emitter_tests.ahk
#Include unit\app\services\hud_pixel_scanner_tests.ahk
#Include unit\app\services\loading_totals_service_tests.ahk
#Include unit\app\services\timer_service_tests.ahk
#Include unit\app\services\act_checkpoint_tracker_tests.ahk
#Include unit\app\services\run_stats_recorder_tests.ahk
#Include unit\app\services\personal_best_service_tests.ahk
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

; ------------------------------------------------------------
; Suites - Wave 7: ui/
; ------------------------------------------------------------
#Include unit\ui\theme_tests.ahk
#Include unit\ui\hotkey_formatter_tests.ahk
#Include unit\ui\widget_base_tests.ahk
#Include unit\ui\layout_widget_base_tests.ahk

; ------------------------------------------------------------
; Suites - Wave 8: integration (end-to-end)
; ------------------------------------------------------------
#Include integration\speedkalandra_app_integration_tests.ahk

; ------------------------------------------------------------
; Bootstrap
; ------------------------------------------------------------
TestReporter.Init()
TestRunner.Run()
