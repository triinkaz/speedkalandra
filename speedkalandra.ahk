; ============================================================
; speedkalandra.ahk - entry point (Onda 6)
; ============================================================

#Requires AutoHotkey v2.0
#SingleInstance Force
; v17.15 (Bug #17): habilita warning de VarUnset (variavel usada sem
; valor atribuido) com output silencioso em OutputDebug. Outros warnings
; (LocalSameAsGlobal, Unreachable, ClassOverwrite) ficam off por serem
; ruidosos demais no codigo atual. VarUnset eh o que pega bug real.
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
; Tray helpers: "Undo last save" item dinamico (v17.14)
;
; Adicionado pelo app.ahk apos save com sucesso. Removido apos 60s
; via SetTimer interno do app, ou apos o user clicar nele.
;
; Usa Insert pra inserir ANTES de "Settings" — vira o primeiro item
; do menu, garantindo destaque visual.
; ============================================================
SpeedKalandraTrayAddUndoItem()
{
    ; Idempotente: remove primeiro se ja existia
    try A_TrayMenu.Delete("Undo last save")
    try A_TrayMenu.Insert("Settings", "Undo last save",
        (*) => app.UndoLastSave())
}

SpeedKalandraTrayRemoveUndoItem()
{
    try A_TrayMenu.Delete("Undo last save")
}


#Include "src_v2\core\clock.ahk"
#Include "src_v2\core\event_bus.ahk"
#Include "src_v2\core\log_service.ahk"

#Include "src_v2\version.ahk"

#Include "src_v2\domain\values\duration.ahk"
#Include "src_v2\domain\values\ids.ahk"

#Include "src_v2\infra\io\text_encoding.ahk"
#Include "src_v2\infra\io\atomic_write.ahk"
#Include "src_v2\infra\io\csv_file.ahk"
#Include "src_v2\infra\io\ini_file.ahk"
#Include "src_v2\infra\io\json_file.ahk"

#Include "src_v2\domain\xp_rules.ahk"
#Include "src_v2\domain\window_state.ahk"
#Include "src_v2\domain\overlay_layout.ahk"
#Include "src_v2\domain\run_state.ahk"
#Include "src_v2\domain\app_settings.ahk"

#Include "src_v2\infra\zones_catalog.ahk"
#Include "src_v2\infra\settings_repository.ahk"
#Include "src_v2\infra\run_state_repository.ahk"
#Include "src_v2\infra\run_history_repository.ahk"
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
#Include "src_v2\app\services\auto_finalize_service.ahk"
#Include "src_v2\app\services\auto_start_service.ahk"
#Include "src_v2\app\services\overlay_mode_service.ahk"
#Include "src_v2\app\services\overlay_mode_applier.ahk"
#Include "src_v2\app\services\overlay_interaction_service.ahk"
#Include "src_v2\app\services\focus_auto_pause_service.ahk"

#Include "src_v2\ui\theme.ahk"
#Include "src_v2\ui\widget_base.ahk"
#Include "src_v2\ui\layout_widget_base.ahk"
#Include "src_v2\ui\compact_layout_widget.ahk"
#Include "src_v2\ui\micro_layout_widget.ahk"
#Include "src_v2\ui\steve_layout_widget.ahk"
#Include "src_v2\ui\settings_dialog.ahk"
#Include "src_v2\ui\line_chart_renderer.ahk"
#Include "src_v2\ui\run_stats_plot_dialog.ahk"
#Include "src_v2\ui\run_history_dialog.ahk"

#Include "src_v2\app\app.ahk"

global app := SpeedKalandraApp()
app.Start()

OnExit(SpeedKalandraOnExitHandler)

; ============================================================
; OnExit handler
;
; Antes de chamar app.Stop, envia keyup defensivo dos modifiers.
; Previne o famoso bug do AHK "stuck modifier": se o script sai
; (Reload, ExitApp, crash) enquanto o user ainda esta fisicamente
; segurando Ctrl/Alt/Shift por uma hotkey, ou se algum hook do AHK
; deixou modifier em estado inconsistente, o jogo pode interpretar
; aquele modifier como permanentemente pressionado.
;
; {Blind} faz com que o keyup nao seja revertido mesmo se o user
; ainda esta fisicamente apertando o modifier — e como o script
; esta saindo, nao ha re-aplicacao do down depois.
;
; Documentacao oficial recomenda esse padrao:
;   https://www.autohotkey.com/docs/v2/lib/Send.htm#Blind
; ============================================================
SpeedKalandraOnExitHandler(reason, code)
{
    try Send "{Blind}{Ctrl up}{Alt up}{Shift up}{LWin up}{RWin up}"
    try app.Stop()
}

^!q::ExitApp()

; v17.15 (Bug #16): hotkey ^!g e classe GamePauseHotkeyHelpers
; removidas. Eram pra debug do GamePauseDetectionService, que foi
; desconectado em v17.5 e o arquivo do service agora vive em
; _LIXEIRA/. Sem o service ativo, a hotkey so mostrava MsgBox
; de erro — 150 linhas de codigo morto removidas.
