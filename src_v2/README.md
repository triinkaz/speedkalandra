# src_v2 — Arquitetura SpeedKalandra (v17.15)

Tracker minimalista de speedruns PoE2. Composition Root + EventBus + Services + Domain.

> **Decisões historicas e contexto da demolicao**: ver `ARCHITECTURE.md` na raiz (>240KB, mistura estado atual e historico de ondas).

## Layout atual

```
src_v2/
├── core/                          ; Infraestrutura básica
│   ├── event_bus.ahk              ; Pub/sub sincrono
│   ├── log_service.ahk            ; Logger com rotacao de log + WARN/ERROR counters
│   └── clock.ahk                  ; RealClock + FakeClock
│
├── domain/                        ; Modelos puros (sem I/O)
│   ├── values/
│   │   ├── duration.ahk
│   │   └── ids.ahk                ; helpers de runId
│   ├── app_settings.ahk           ; Aglomerado raiz de configuracao
│   ├── overlay_layout.ahk         ; OverlayPosition + OverlayLayout (Compact/Micro/Steve)
│   ├── run_state.ahk              ; State persistido de run em andamento (crash recovery)
│   ├── window_state.ahk           ; microLocked, steveLocked
│   └── xp_rules.ahk               ; Tabela de XP por nivel + helpers
│
├── infra/                         ; I/O
│   ├── io/                        ; ini_file, csv_file, json_file, atomic_write, text_encoding
│   ├── settings_repository.ahk    ; AppSettings <-> speedkalandra.ini
│   ├── run_state_repository.ahk   ; RunState <-> data/run_state.ini + zone_totals.txt
│   ├── run_history_repository.ahk ; Runs finalizadas <-> data/runs/{runId}.ini
│   ├── personal_best_repository.ahk ; PBs <-> data/personal_bests.ini
│   └── zones_catalog.ahk          ; Parser de data/zones.csv (77 zonas PoE2)
│
├── app/                           ; Orquestracao
│   ├── bus/
│   │   ├── commands.ahk           ; Constantes de comando (Cmd.*)
│   │   └── events.ahk             ; Constantes de evento (Evt.*)
│   ├── services/                  ; ~20 services (lifecycle, detection, plot, etc)
│   └── app.ahk                    ; Composition Root (SpeedKalandraApp)
│
└── ui/                            ; GUIs
    ├── theme.ahk                  ; Paleta de cores + Font helpers
    ├── widget_base.ahk            ; Base class de widgets GDI+
    ├── layout_widget_base.ahk     ; Base class de layouts (Compact/Micro/Steve)
    ├── compact_layout_widget.ahk  ; Overlay COMPACT (720x80)
    ├── micro_layout_widget.ahk    ; Overlay MICRO (200x32)
    ├── steve_layout_widget.ahk    ; Overlay STEVE (v17.14, the happy whale)
    ├── settings_dialog.ahk
    ├── line_chart_renderer.ahk
    ├── run_stats_plot_dialog.ahk
    └── run_history_dialog.ahk
```

## Convencoes

| Item                    | Convencao            | Exemplo            |
| ----------------------- | -------------------- | ------------------ |
| Classes                 | `PascalCase`         | `EventBus`         |
| Metodos publicos        | `PascalCase`         | `Subscribe()`      |
| Metodos privados        | `_PascalCase`        | `_Log()`           |
| Propriedades publicas   | `camelCase`          | `isRunning`        |
| Propriedades privadas   | `_camelCase`         | `_subs`, `_clock`  |
| Constantes              | `UPPER_SNAKE_CASE`   | `MAX_LOG_SIZE`     |
| Arquivos                | `snake_case.ahk`     | `event_bus.ahk`    |

## Como rodar

```
AutoHotkey.exe speedkalandra.ahk
```

Esse eh o entrypoint definitivo. Requer AutoHotkey v2.

## Sem testes automatizados (v17.15)

A suite legada (~2500 testes) referenciava classes que foram pra `_LIXEIRA/` durante a demolicao das Ondas 1-6. Foi arquivada em `_LIXEIRA/onda_7_tests_obsoletas/` e nao migrada. Decisao deliberada pra ir pra producao sem cobertura automatica nesta versao. Reescrita planejada pra Onda 8.

## Status da migracao

**v17.15: production-ready.** A demolicao em ondas (1-6) eliminou o paradigma anterior (sistema de rota campaign_route.ini, editor de rota, splits por step, targets, replay engine, summaries CSV, gem planner, build planner) e reconstruiu o app minimalista atual:

| Onda | Escopo | Status |
|------|--------|--------|
| 0 | Extracao de boss_catalog.ini + zones.csv | ✅ |
| 1 | Demolicao paradigma de rota (8 sub-ondas) | ✅ |
| 2 | BossFightTracker + BossTimerService standalone | ✅ |
| 3 | ZoneTrackingService + ZonesCatalog | ✅ |
| 4 | 2 widgets (Compact + Micro) | ✅ |
| 5 | RunStatsPlotBuilder + RunStatsRecorder | ✅ |
| 6 | TimerService + RunService + AutoFinalize + composition root reconstruido | ✅ |
| 7 | AutoStart + GamePauseDetection (desconectado em v17.5) + cleanup | ✅ |
| 8 | VendorRegex slots no Compact widget + StevenTheHappyWhale layout (v17.14) | ✅ |
| 7-cleanup | Auditoria de producao + bug fixes (v17.15) | ✅ |

## Decisoes de design importantes

### EventBus tolerante

Cada service publica eventos (`Evt.RunStarted`, `Evt.ZoneChanged`, ...) e/ou subscreve a comandos (`Cmd.NewRunRequested`, ...). Handler que estoura em um subscriber nao impede os demais (`try/catch` em `Publish` com log). Unsubscribe seguro durante Publish via clone do array. **Apos Unsubscribe que esvazia o subscriber list, a key eh deletada do Map** (evita leak em sessoes longas com ciclos Stop/Start — v17.15 Bug #22).

### Headless mode em widgets e dialogs

Toda UI aceita flag `_headless := true` no construtor. Em headless, `Show()`/`Open()` viram no-op e a parte testavel (estado, validacao, transformacoes) fica acessivel via API publica. Usado pelo (extinto) test harness; preservado para reintroducao de testes futuros.

### Composition Root unificado

`SpeedKalandraApp` (`src_v2/app/app.ahk`) eh o unico lugar onde objetos sao instanciados e ligados. Todo o resto recebe deps por construtor. Pra entender o app inteiro, basta ler `app.ahk` de cima a baixo.

### Persistencia atomica (best effort)

`infra/io/atomic_write.ahk` implementa write-via-tempfile + FileMove com REPLACE_EXISTING. **Nao eh totalmente atomico no Windows** (delete-then-rename internamente), risco aceito pra app de desktop single-thread. Cobre 99% dos casos de crash mid-write.

### Zones catalog manual

`data/zones.csv` (77 zonas, formato ponto-virgula com header) eh editado a mao. O pipeline RePoE legacy foi descartado na demolicao. Adicionar zonas novas requer editar o CSV manualmente.
