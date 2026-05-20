; ============================================================
; speedkalandra.ahk - entry point
; ============================================================

#Requires AutoHotkey v2.0
#SingleInstance Force
; Enables the VarUnset warning (variable used without an assigned
; value) with silent output to OutputDebug. Other warnings
; (LocalSameAsGlobal, Unreachable, ClassOverwrite) stay off as
; they're too noisy in the current code. VarUnset is the one that
; catches real bugs.
#Warn VarUnset, OutputDebug

A_TrayMenu.Delete()
A_TrayMenu.Add("Settings",          (*) => app.bus.Publish(Commands.OpenSettingsRequested, Map()))
A_TrayMenu.Add("Run plot",          (*) => app.bus.Publish(Commands.OpenRunStatsPlotRequested, Map()))
A_TrayMenu.Add("Run history",       (*) => app.bus.Publish(Commands.OpenRunHistoryRequested, Map()))
A_TrayMenu.Add()
A_TrayMenu.Add("Reset PBs",         (*) => app.bus.Publish(Commands.ResetPersonalBestsRequested, Map()))
A_TrayMenu.Add()
A_TrayMenu.Add("Reload",            (*) => Reload())
A_TrayMenu.Add("Exit",              (*) => ExitApp())
A_TrayMenu.Default := "Settings"
A_IconTip := "SpeedKalandra " Version.STRING

; ============================================================
; Tray helpers: dynamic "Undo last save" item
;
; Added by app.ahk after a successful save. Removed after 60s via
; an internal SetTimer in the app, or after the user clicks it.
;
; Uses Insert to insert BEFORE "Settings" — becomes the first item
; in the menu, ensuring visual prominence.
; ============================================================
SpeedKalandraTrayAddUndoItem()
{
    ; Idempotent: removes first if it already existed
    try A_TrayMenu.Delete("Undo last save")
    try A_TrayMenu.Insert("Settings", "Undo last save",
        (*) => app.UndoLastSave())
}

SpeedKalandraTrayRemoveUndoItem()
{
    try A_TrayMenu.Delete("Undo last save")
}

; ============================================================
; SpeedKalandraMsgBox - MsgBox wrapper with TopMost
;
; PROBLEM IT SOLVES:
;   AHK's default MsgBox does NOT inherit AlwaysOnTop from the dialog
;   that invokes it. Result: confirmations (Delete run, Reset PBs,
;   Replace PBs, etc.) open BEHIND the dialog that called them —
;   the user thinks the program froze.
;
; FIX:
;   Adds the MB_TOPMOST flag (0x40000 = 262144 decimal) which puts
;   the MsgBox always on top, including over AlwaysOnTop overlays.
;
; USAGE:
;   Replace MsgBox(text, title, options) with
;           SpeedKalandraMsgBox(text, title, options).
;   Identical signature — same return ("Yes", "No", "OK", etc.).
;
; NOTE: apply this to calls inside any dialog/widget that may have
; coexisting AlwaysOnTop overlays/dialogs. TrayTips do NOT need it
; (they are notifications, not modals).
; ============================================================
SpeedKalandraMsgBox(text, title := "", options := "")
{
    optsStr := Trim(String(options))
    if (optsStr = "")
        optsStr := "0x40000"
    else
        optsStr .= " 0x40000"
    return MsgBox(text, title, optsStr)
}


#Include "src_v2\core\clock.ahk"
#Include "src_v2\core\event_bus.ahk"
#Include "src_v2\core\log_service.ahk"
#Include "src_v2\core\warning_sink.ahk"

#Include "src_v2\version.ahk"

#Include "src_v2\domain\values\duration.ahk"
#Include "src_v2\domain\values\ids.ahk"
#Include "src_v2\domain\game_processes.ahk"

#Include "src_v2\infra\io\text_encoding.ahk"
#Include "src_v2\infra\io\atomic_write.ahk"
#Include "src_v2\infra\io\csv_file.ahk"
#Include "src_v2\infra\io\ini_file.ahk"
#Include "src_v2\infra\io\json_file.ahk"
#Include "src_v2\infra\io\run_export_format.ahk"

#Include "src_v2\domain\xp_rules.ahk"
#Include "src_v2\domain\window_state.ahk"
#Include "src_v2\domain\overlay_layout.ahk"
#Include "src_v2\domain\run_state.ahk"
#Include "src_v2\domain\app_settings.ahk"

#Include "src_v2\infra\zones_catalog.ahk"
#Include "src_v2\infra\settings_repository.ahk"
#Include "src_v2\infra\run_state_repository.ahk"
#Include "src_v2\infra\run_history_repository.ahk"
#Include "src_v2\infra\death_log_repository.ahk"
#Include "src_v2\infra\personal_best_repository.ahk"

#Include "src_v2\app\bus\events.ahk"
#Include "src_v2\app\bus\commands.ahk"

#Include "src_v2\app\services\app_tick_emitter.ahk"
#Include "src_v2\app\services\hotkey_service.ahk"
#Include "src_v2\app\services\hud_pixel_scanner.ahk"
#Include "src_v2\app\services\xp_service.ahk"
#Include "src_v2\app\services\timer_service.ahk"
#Include "src_v2\app\services\run_service.ahk"
#Include "src_v2\app\services\log_monitor_service.ahk"
#Include "src_v2\app\services\zone_tracking_service.ahk"
#Include "src_v2\app\services\loading_detection_service.ahk"
#Include "src_v2\app\services\loading_totals_service.ahk"
#Include "src_v2\app\services\personal_best_service.ahk"
#Include "src_v2\app\services\act_checkpoint_tracker.ahk"
#Include "src_v2\app\services\run_stats_recorder.ahk"
#Include "src_v2\app\services\run_stats_plot_builder.ahk"
#Include "src_v2\app\services\death_stats_service.ahk"
#Include "src_v2\app\services\death_log_scanner.ahk"
#Include "src_v2\app\services\auto_finalize_service.ahk"
#Include "src_v2\app\services\auto_start_service.ahk"
#Include "src_v2\app\services\overlay_mode_service.ahk"
#Include "src_v2\app\services\overlay_mode_applier.ahk"
#Include "src_v2\app\services\overlay_interaction_service.ahk"
#Include "src_v2\app\services\focus_auto_pause_service.ahk"
#Include "src_v2\app\services\event_trace_logger.ahk"
#Include "src_v2\app\services\run_export_service.ahk"
#Include "src_v2\app\services\run_import_service.ahk"

#Include "src_v2\ui\theme.ahk"
#Include "src_v2\ui\widget_base.ahk"
#Include "src_v2\ui\layout_widget_base.ahk"
#Include "src_v2\ui\compact_layout_widget.ahk"
#Include "src_v2\ui\micro_layout_widget.ahk"
#Include "src_v2\ui\steve_layout_widget.ahk"
#Include "src_v2\ui\hotkey_formatter.ahk"
#Include "src_v2\ui\settings_dialog.ahk"
#Include "src_v2\ui\line_chart_renderer.ahk"
#Include "src_v2\ui\run_stats_plot_dialog.ahk"
#Include "src_v2\ui\run_history_dialog.ahk"
#Include "src_v2\ui\death_stats_dialog.ahk"
#Include "src_v2\ui\export_options_dialog.ahk"
#Include "src_v2\ui\import_preview_dialog.ahk"

#Include "src_v2\app\boot_prompts.ahk"
#Include "src_v2\app\run_snapshot_saver.ahk"
#Include "src_v2\app\run_state_persister.ahk"
#Include "src_v2\app\live_reconfiguration_handlers.ahk"

#Include "src_v2\app\app.ahk"

global app := SpeedKalandraApp()
app.Start()

OnExit(SpeedKalandraOnExitHandler)

; ============================================================
; OnExit handler
;
; Before calling app.Stop, sends a defensive keyup of the modifiers.
; Prevents the famous AHK "stuck modifier" bug: if the script exits
; (Reload, ExitApp, crash) while the user is still physically
; holding Ctrl/Alt/Shift for a hotkey, or if some AHK hook left a
; modifier in an inconsistent state, the game can interpret that
; modifier as permanently pressed.
;
; {Blind} ensures the keyup is not reverted even if the user is
; still physically pressing the modifier — and since the script is
; exiting, there's no re-application of the down afterwards.
;
; Official documentation recommends this pattern:
;   https://www.autohotkey.com/docs/v2/lib/Send.htm#Blind
; ============================================================
SpeedKalandraOnExitHandler(reason, code)
{
    try Send "{Blind}{Ctrl up}{Alt up}{Shift up}{LWin up}{RWin up}"
    try app.Stop()
}

; Note: there is no global Exit hotkey on purpose. Use the tray
; menu "Exit" item to close the app. An earlier `^!q::ExitApp()`
; was removed because on ABNT2 / international keyboards AltGr+Q
; (which the OS reports as LCtrl+RAlt+Q) was triggering it by
; accident and closing the app mid-run.
