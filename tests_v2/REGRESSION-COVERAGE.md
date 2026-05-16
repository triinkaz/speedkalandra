# SpeedKalandra — Regression Coverage Matrix

Mapeia bugs catalogados (auditoria interna pré-release + os encontrados nas Waves de teste) aos testes que comprovam o fix. Útil pra garantir que nenhum bug volta silenciosamente em refactor futuro.

Convenção:
- **Auditoria #N**: bugs da auditoria interna pré-release (numeração legada v17.15)
- **Wave #N**: bugs descobertos durante a construção do test suite (numeração interna deste doc)

---

## Bugs da auditoria pré-release

### 🔴 Bloqueadores

| #     | Sintoma                                                  | Fix em                                            | Regression test                                                                                                                          |
| ----- | -------------------------------------------------------- | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| #1    | Tempo da última zona perdido em FinalizeRun              | `zone_tracking_service.ahk::_OnTimerStopped`      | `ZoneTrackingServiceTests::timer_stopped_flushes_active_zone_before_zeroing`, `…::run_completed_flushes_active_zone_to_totals`            |
| #2    | `deathCount` inflado por kills de boss                   | `log_monitor_service.ahk` filtro `_characterName` | `LogMonitorServiceTests::death_not_published_when_does_not_match_character`, `…::death_not_published_when_character_name_empty`           |
| #4    | AutoStart wipe de run hidratada após reload              | `auto_start_service.ahk::__New(.., runService)`   | `AutoStartServiceTests::constructor_run_active_false_when_no_run_service_provided`, `…::constructor_queries_run_service_when_provided`    |
| #7    | Atomicidade de PBs                                       | `personal_best_repository.ahk::Save`              | `PersonalBestRepositoryTests::save_does_not_leave_tmp_behind`, `…::save_creates_file`, `…::roundtrip_load_save_preserves_pbs`              |
| #25   | `Map has no method Count` (catch enriquecido)            | `app.ahk` (try/catch com What/Line/File)          | Sem test direto (lógica de mensagem de erro). Coberto indiretamente por `SpeedKalandraAppIntegrationTests::constructor_*` (não throws).   |
| #33–34| Surface de WARN/ERROR no boot                            | `log_service.ahk` (`_warnCount`/`_errorCount`)    | `LogServiceTests::warn_counter_increments_regardless_of_min_level`, `…::error_counter_increments_regardless_of_min_level`, `…::reset_counts_zeroes_warn_and_error_counters` |

### 🟠 Pré-v1.0

| #   | Sintoma                                                | Fix em                                       | Regression test                                                                                                  |
| --- | ------------------------------------------------------ | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| #3  | Collision de runId no mesmo segundo                    | `run_service.ahk::_GenerateRunId` (+ms)      | `RunServiceTests::new_run_generates_run_id_in_yyyyMMdd_HHmmss_nnn_format`                                         |
| #5  | Prompt bloqueante sem pausar timer                     | `app.ahk::_PromptHydratedRun`                | Headless skip — não testado direto. Funcionalidade pulada em `SpeedKalandraAppIntegrationTests` (headless=true). Mesmo padrão de skip aplicado ao setup dialog do Client.txt em v0.1.3. |
| #8  | `try` sem `catch` (múltiplos)                          | Vários services                              | Sem test direto (padrão de código). Coberto pela ausência de logs silenciados em tests existentes.                |
| #9  | Riverbank reseta level a cada entry                    | `app.ahk::_OnZoneEnteredForLevel` + flag     | `SpeedKalandraAppIntegrationTests::bug9_*` (Wave 9)                                                                |
| #11 | autoStartRegex default em inglês                       | `app_settings.ahk`                           | `AppSettingsTests::defaults_auto_finalize_and_auto_start_regexes_empty`                                            |
| #12 | Test suite obsoleta                                    | Movido pra `_LIXEIRA/`                       | N/A (cleanup)                                                                                                      |
| #27 | Doc de atomicidade enganosa                            | `atomic_write.ahk` (só doc)                  | N/A (só comentário)                                                                                                |
| #32 | Log sem rotação                                        | `log_service.ahk::_RotateIfTooBig`           | `LogServiceTests::constructor_rotates_existing_log_over_5mb`, `…::constructor_does_not_rotate_when_log_under_threshold` |

### 🟡 Limpeza

| #   | Sintoma                                            | Fix em                                          | Regression test                                                                                       |
| --- | -------------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| #13 | Diretórios vazios                                  | Movidos pra `_LIXEIRA/`                         | N/A                                                                                                    |
| #14 | Services não instanciados                          | Movidos pra `_LIXEIRA/`                         | N/A                                                                                                    |
| #15 | Settings de features mortas                        | `app_settings.ahk` removeu keys                 | `AppSettingsTests::defaults_*` (não menciona keys removidas)                                            |
| #16 | Hotkey `^!g` + classe `GamePauseHotkeyHelpers`     | `speedkalandra.ahk` removido                    | N/A (cleanup)                                                                                          |
| #17 | `#Warn All, Off`                                   | `speedkalandra.ahk` `#Warn VarUnset`            | N/A (config)                                                                                           |
| #18 | `ReplayClock` dead code                            | `core/clock.ahk` removido                       | N/A (cleanup)                                                                                          |
| #19 | `_FormatMs` duplicado                              | `Duration.FormatMs(ms)` static (v0.1.2)         | `DurationTests::format_ms_*` (9 tests cobrindo o contrato). 4 callers refatorados pra delegar. |
| #20 | Comentários "Smoke fix Turno N"                    | `log_monitor_service.ahk` reescritos            | N/A (só comentário)                                                                                    |
| #21 | SCENE pra ZoneChanged (PoE2 não emite "entered")   | `log_monitor_service.ahk`                       | `LogMonitorServiceTests::scene_also_publishes_zone_changed_event_bug_21`, `…::scene_with_*_is_filtered` |
| #22 | EventBus deixa keys vazias no Unsubscribe          | `event_bus.ahk::Unsubscribe`                    | `EventBusTests::unsubscribing_last_handler_removes_key_from_internal_map`                              |
| #24 | `_ComputeTotalsHash` ordem do Map                  | Descartado (Map preserva ordem)                 | N/A                                                                                                    |
| #29 | `README-DIST.txt` hotkey/cor errada                | `build-dist.ps1`                                | N/A (build script)                                                                                     |
| #30 | Build não embute versão                            | `src_v2/version.ahk::Version.STRING` (v0.1.2)   | N/A (display-only). Propagado pra tray IconTip, Settings dialog title, Plot subheader. |
| #31 | OverlayModeService subscreve a comandos mortos     | `overlay_mode_service.ahk` removeu subs         | `OverlayModeServiceTests::constructor_subscribes_to_3_commands` (validates count)                       |

---

## Features v0.1.3 (UX improvements)

Não são bugs — são comportamentos novos cobertos por tests pra blindar contra regressões futuras. Catalogados aqui pra que refactors mantenham os 4 invariantes intencionais.

| Feature | Implementação | Regression test |
| ------- | -------------- | --------------- |
| Setup dialog do Client.txt na 1ª execução (app não roda sem path válido) | `app.ahk::_PromptLogFileSetupIfNeeded` + helpers `_SetupBrowseLog`/`_SetupValidatePath`. Chamado em `Start()` entre `_ShowDisclaimerIfNeeded` e `_PromptHydratedRun`. Cancel → `ExitApp()`. | Headless skip (UI puro). Testes integration usam `headless=true` que pula o dialog na primeira linha do método — mesma estratégia do disclaimer e do hydrated run prompt. |
| Edit do Settings dialog com altura fixa (`h22`) pra não auto-expandir com path longo | `settings_dialog.ahk::_AddEdit` opts string contains `h22` | N/A (UI-only, sem comportamento testável) |
| Death penalty aplicada no timer real-time (antes só no plot post-finalize) | Novo `TimerService.AddPenaltyMs(ms)` + handler `app.ahk::_OnDeathApplyTimerPenalty` subscrito a `Evt.DeathDetected` em `_WireEventHandlers` | `TimerServiceTests::add_penalty_ms_*` (13 tests cobrindo: retorno true/false por tipo de input, comportamento em RUNNING/PAUSED/IDLE, não congelamento do timer, ausência de eventos publicados, coerção float→int, múltiplas aplicações, sobrevivência ao Pause/Resume). `SpeedKalandraAppIntegrationTests::death_penalty_*` (6 tests cobrindo: happy path, 4 guards do handler, múltiplas mortes, valor custom de `cfg.deathPenaltyMs`). |
| Campo "Patch" removido do Settings dialog (mantido internamente como `cfg.gamePatch="Unknown"` pra retrocompat) | `settings_dialog.ahk` (Label+Edit+save removidos), `run_stats_plot_dialog.ahk` (Patch tirado do subTxt). `AppSettings.gamePatch` mantido como field interno. | N/A (UI removal). `AppSettingsTests` continua passando porque o field permanece em AppSettings com default. |

---

## Bugs descobertos durante construção do test suite

### Wave 4 (infra)

| # | Sintoma | Fix em | Regression test |
| - | ------- | ------ | --------------- |
| W4.1 | PersonalBest INI escrito em UTF-8 mas `IniRead` precisa UTF-16 LE BOM | `personal_best_repository.ahk::Save` mudou de "UTF-8" pra "UTF-16" | `PersonalBestRepositoryTests::iniread_key_lookup_works_in_utf16_le_bom_but_not_utf8_bom` (documenta pitfall AHK) |

### Wave 5a (services puros)

| # | Sintoma | Fix em | Regression test |
| - | ------- | ------ | --------------- |
| W5.1 | `_MapToDebugStr` com keys integer comparava `m[k]` (int) vs string keys, retornava ausência | (test framework) | Coberto por `LoadingDetectionServiceTests` (uses keys integer no Map de pontos) |
| W5.2 | `_SafeCategoryLabel` escopo-dependente — lookup dinâmico via `%"..."%` falhava em testes isolados sem builder no escopo | `run_history_repository.ahk::_SafeCategoryLabel` fallback hardcoded | `RunHistoryRepositoryTests::safe_category_label_fallback_for_known_categories`, `…::safe_category_label_passes_through_unknown` |

### Wave 9 (este doc)

| # | Sintoma | Fix em | Regression test |
| - | ------- | ------ | --------------- |
| W9.1 | `MigrateIniToUtf8` corrompia `IniRead` (footgun latente) | `text_encoding.ahk` (API removida) | `TextEncodingTests::bug2_convert_utf16_to_utf8_was_removed`, `…::bug2_migrate_ini_to_utf8_was_removed` |
| W9.2 | `LoadingDetectionService._End` descartava timeouts (> maxMs sumia silenciosamente) | `loading_detection_service.ahk::_End` removeu filtro `> maxMs` | `LoadingDetectionServiceTests::tick_timeout_publishes_loading_measured`, `…::bug5_loading_100s_publishes_with_real_duration`, `…::bug5_loading_300s_publishes_with_real_duration` |

---

## Pitfalls do AutoHotkey v2 (não-bugs, mas comportamentos não-óbvios)

Catalogados pra evitar reintroduzir:

| Pitfall                                                                                      | Doc / Regression                                                                            |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `IniRead` key-lookup só funciona em UTF-16 LE BOM (UTF-8 BOM retorna default silenciosamente) | `PersonalBestRepositoryTests::iniread_key_lookup_works_in_utf16_le_bom_but_not_utf8_bom`     |
| Variáveis locais com nome de builtin (`Run`, `File`, `Edit`, `Buffer`) disparam `#Warn All`  | Pitfall #4 no README do projeto. Convenção: `run` → `runItem`, `file` → `selectedFile`, `edit` → `editCtrl` |
| Variáveis locais com nome de classe (case-insensitive!) — `runId` vs class `RunId`           | Convenção: `runId` → `currentRunId`. Aplicado em ~10 arquivos durante Wave 8.                |
| `throw` não cabe em arrow function (parser AHK v2)                                            | Pitfall #1 no README                                                                         |
| Closure-in-loop captura por referência (não valor)                                            | `CompactLayoutWidget::_BindVendorButton` usa método helper pra criar escopo                  |
| Object-literal com método: arrow `() => …` precisa receber `this` como primeiro param        | Pitfall #11 no README                                                                        |
| `IniWrite` cria UTF-16 LE BOM por default em arquivos novos                                   | Documentado em `IniFile.__New` e `text_encoding.ahk`                                          |
| Single-line `if` sem braces com `:=` pode confundir parser                                    | Convenção: sempre usar braces multi-line. Pitfall #12 no README                              |
| `\"` não é escape válido em AHK v2 — use `""` (duplica) ou aspas simples `'...'` como delimitador externo | Descoberto na Wave 9 ao tentar `"texto \"The Riverbank\""`. Convencão adotada: aspas simples dentro de string entre aspas duplas |

---

## Como manter este doc atualizado

1. **Ao fixar um bug**: adicione linha na tabela apropriada com link pro test.
2. **Ao adicionar um test que cobre comportamento de bug**: marque `RegressionFor: #N` no docstring do test.
3. **Bugs ainda pendentes**: marcar com 🚧 na coluna "Fix em" e referenciar issue/comment.
4. **Pitfalls do AHK descobertos**: adicionar na seção final com test que documenta.

Pra rodar todo o suite:
```
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" tests_v2\run_tests.ahk
```

Pra rodar só tests de regression específicos:
```
AutoHotkey64.exe tests_v2\run_tests.ahk bug9
AutoHotkey64.exe tests_v2\run_tests.ahk regression
```
