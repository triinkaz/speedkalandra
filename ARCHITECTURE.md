# SpeedKalandra — Arquitetura v2 (AHK)

> **Status atual (2026-05):** migração v1→v2 concluída. 2500+ testes. Pós-fase H, **algumas features foram removidas** retroativamente do código: Build/Gem Planner (com gem popup), Auto-fill boss regex no editor, Debug Injector, e o hotkey "Force Test Loading Visual". Referências históricas a `GemPlannerService`, `BossCatalog`, `DebugInjectorDialog`, `bosses_by_area.csv`, `build_planner_gems.csv`, `gem_recommendations.ini`, e hotkeys `^!g/^!l/^!d` documentam decisões passadas e não refletem o estado atual.
>
> Para o estado real, hotkeys, features e roadmap, ver [`README.md`](README.md) e [`src_v2/README.md`](src_v2/README.md).
>
> Este arquivo guarda o **histórico das decisões arquiteturais** tomadas durante o refactor. Trecho útil pra entender por que cada padrão foi escolhido. Não é mais o documento canônico do estado atual.

---

# Documento histórico — refactor v1 → v2

> Refatoração arquitetural mantendo AutoHotkey v2.
> **Status:** rascunho aguardando validação do Rafael.
> **Premissa:** os bugs e fragilidade do tracker hoje são arquiteturais. AHK v2 tem ferramentas suficientes (classes, OO, closures, OnMessage, OnEvent) pra resolver — falta aplicar disciplina.

---

## 1. Diagnóstico — por que mexer em qualquer coisa quebra outra

| Sintoma percebido                          | Causa raiz                                                                  |
| ------------------------------------------ | --------------------------------------------------------------------------- |
| "Mexi em X e quebrou Y, Z, W"              | ~50 globais (`gActs`, `gCursor`, `gWidgets`, `gRunBaseMs`, `gControls`, …) |
| "Não sei o que afeta o quê"                | Lógica espalhada em 15 arquivos sem hierarquia clara                        |
| "Bug aparece em runtime aleatório"         | Sem validação na entrada. Map vira string vira número silencioso            |
| "Editor é campo minado"                    | UI, validação, persistência misturadas no mesmo arquivo (298KB!)            |
| "Adicionar feature exige tocar 5 arquivos" | Acoplamento bilateral (UI conhece state, state conhece UI, log conhece tudo)|
| "Não consigo testar nada isolado"          | Tudo depende de globais — impossível instanciar uma peça sozinha            |

**Cada um desses é fixável em AHK v2.** A linguagem dá classes, encapsulamento, closures, OnEvent. O que faltou foi adotar o estilo.

---

## 2. O que AHK v2 PODE fazer (vs Python)

| Conceito                       | AHK v2                          | Como vamos usar                              |
| ------------------------------ | ------------------------------- | -------------------------------------------- |
| Classes / OO                   | ✅ nativo                        | Base de tudo. Cada componente é classe       |
| Encapsulamento (props/methods) | ✅ nativo                        | Acabar com globais                           |
| Closures / lambdas             | ✅ `.Bind()`, `(*) =>`           | Callbacks de evento                          |
| Try/catch                      | ✅                               | Bordas de I/O e parsing                      |
| Map/Array                      | ✅                               | Coleções genéricas                           |
| OnEvent / OnMessage            | ✅                               | Já usado, vai virar EventBus                 |
| Includes circulares            | ✅ tolerante                     | Carrega em ordem, classes resolvidas em runtime |
| **Tipos estáticos**            | ❌                               | Compensamos com factories que validam        |
| **Discriminated unions**       | ❌                               | Usa `kind` prop + `switch` manual            |
| **Pydantic-like**              | ❌                               | Escrevemos `Validate()` em cada model        |
| **mypy --strict**              | ❌                               | Sem checagem em compile. Disciplina manual   |
| **Generics**                   | ❌                               | Convenções de nome + docstring-comments      |

**Conclusão honesta:** vamos ter ~80% do que Python+Pydantic dariam. Os 20% que faltam (tipos estáticos, validation automática) compensamos com factories disciplinadas e testes manuais.

---

## 3. Princípios não-negociáveis

1. **Sem globais.** Tudo em classes. Composition Root único cria o app.
2. **Camadas com dependência uni-direcional.** UI → App → Domain. Infra implementa interfaces de Domain.
3. **Encapsulamento.** Estado é privado (`_propName`). Acesso via métodos.
4. **EventBus em vez de chamadas diretas.** UI publica `PauseRequested`; serviços consomem.
5. **Factories validam.** Construir um `Step` inválido **estoura na hora** de criar, não 5 chamadas depois.
6. **Imutabilidade onde dá.** Em vez de `step.objective := "novo"`, criar `step.With(objective: "novo")`.
7. **Falha alto.** Nada de `try` engolindo silencioso. `try` só na borda, com `log`.
8. **Strangler fig.** Estrutura nova cresce ao lado da antiga. Migração módulo por módulo.

---

## 4. As quatro camadas

```
┌──────────────────────────────────────────────────────────┐
│  UI            (Gui widgets, Editor, Settings, Manager)  │
│   src/ui/                                                │
└──────────────────────────────────────────────────────────┘
                     │  Publica Commands no bus
                     │  Subscreve Events no bus
                     ▼
┌──────────────────────────────────────────────────────────┐
│  App           (Services, EventBus, UseCases)            │
│   src/app/                                               │
└──────────────────────────────────────────────────────────┘
              │                    ▲
              │ usa                │ implementa
              ▼                    │
┌──────────────────────────┐  ┌────┴───────────────────────┐
│  Domain                  │  │  Infrastructure            │
│   src/domain/            │  │   src/infra/               │
│  (modelos puros + rules) │  │  (INI, CSV, Win32, Log)    │
└──────────────────────────┘  └────────────────────────────┘
```

### 4.1 Domain (`src/domain/`)

Classes puras. Não acessa INI, CSV, Win32, Gui. Roda em qualquer contexto.

```
domain/
├── models/
│   ├── step.ahk          ; class Step
│   ├── act.ahk           ; class Act
│   ├── profile.ahk       ; class Profile
│   ├── run.ahk           ; class Run, Split, Death
│   └── stats.ahk         ; class StepStats, RunStats
├── rules/
│   ├── completion.ahk    ; RegexCompletion, AndCompletion, TownCompletion
│   ├── xp.ahk            ; CalculateXpPenalty(level, areaLevel)
│   └── triggers.ahk      ; AndTriggerProgress, regex/scene/zone matchers
├── values/
│   └── duration.ahk      ; class Duration (ms + formatado)
└── repositories.ahk      ; "interfaces" (classes abstratas) que infra implementa
```

### 4.2 App (`src/app/`)

Orquestração. Service classes recebem deps por construtor. Falam pelo bus.

```
app/
├── bus/
│   ├── event_bus.ahk     ; class EventBus
│   ├── commands.ahk      ; nomes de Commands (PauseRequested, NewRunRequested...)
│   └── events.ahk        ; nomes de Events (RunPaused, StepCompleted...)
├── services/
│   ├── timer_service.ahk
│   ├── run_service.ahk
│   ├── campaign_service.ahk
│   ├── xp_service.ahk
│   ├── log_monitor_service.ahk
│   └── analytics_service.ahk
└── app.ahk               ; class SpeedKalandraApp (Composition Root)
```

### 4.3 Infrastructure (`src/infra/`)

I/O sujo. Implementa as "interfaces" do domain.

```
infra/
├── persistence/
│   ├── ini_repo.ahk         ; class IniRepository
│   ├── csv_run_repo.ahk     ; class CsvRunRepository
│   ├── csv_loading_repo.ahk
│   └── settings_repo.ahk
├── log_monitor/
│   ├── watcher.ahk          ; tail do Client.txt
│   └── line_parser.ahk      ; parsing das linhas conhecidas
├── window/
│   ├── poe_focus.ahk        ; detect POE2 foco
│   └── overlay_helpers.ahk  ; WS_EX flags, transparent helpers
└── clock.ahk                ; class Clock (real ou fake pra teste)
```

### 4.4 UI (`src/ui/`)

Gui widgets. Reage ao bus, emite Commands.

```
ui/
├── overlay/
│   ├── widget_base.ahk      ; class WidgetBase (drag/resize/persist)
│   ├── timer_widget.ahk     ; class TimerWidget extends WidgetBase
│   ├── zone_widget.ahk
│   ├── objective_widget.ahk
│   ├── splits_widget.ahk
│   ├── summary_widget.ahk
│   ├── xp_widget.ahk
│   ├── perf_widget.ahk
│   ├── actions_widget.ahk
│   └── widget_manager.ahk   ; class WidgetManagerPanel
├── editor/
│   ├── campaign_editor.ahk  ; class CampaignEditorWindow
│   ├── step_form.ahk
│   └── act_list.ahk
├── settings/
│   └── settings_dialog.ahk
└── theme.ahk                ; cores, fontes, tokens
```

---

## 5. EventBus — o coração da arquitetura

UI **nunca** chama `service.X()` direto. Em vez disso publica `Command` no bus. Service escuta, executa, publica `Event`. Outros componentes escutam `Event` e reagem.

### Implementação em AHK v2

```ahk
; src/app/bus/event_bus.ahk
class EventBus {
    _subs := Map()  ; eventName -> Array of callbacks

    Subscribe(eventName, callback) {
        if !this._subs.Has(eventName)
            this._subs[eventName] := []
        this._subs[eventName].Push(callback)
    }

    Unsubscribe(eventName, callback) {
        if !this._subs.Has(eventName)
            return
        for i, cb in this._subs[eventName] {
            if (cb = callback) {
                this._subs[eventName].RemoveAt(i)
                return
            }
        }
    }

    Publish(eventName, data := "") {
        if !this._subs.Has(eventName)
            return
        ; Clona pra permitir Unsubscribe durante Publish
        for _, cb in this._subs[eventName].Clone() {
            try {
                cb(data)
            } catch as e {
                ; Loggar mas não interromper outros subscribers
                LogError("Handler de '" eventName "' falhou: " e.Message)
            }
        }
    }
}
```

### Por que isso resolve "mudar X quebra Y, Z, W"

- Adicionar widget novo = `bus.Subscribe("RunPaused", handler)`. **Zero arquivo modificado.**
- Trocar UI = trocar quem publica/consome. Domain não nota.
- Logger novo (gravar em CSV) = mais um subscriber. Adiciona sem mexer em ninguém.
- Testar service = `bus.Publish("PauseRequested"); ` checar que `RunPaused` veio.

### Eventos como constantes (não strings mágicas)

```ahk
; src/app/bus/events.ahk
class Events {
    static RunStarted    := "RunStarted"
    static RunPaused     := "RunPaused"
    static RunResumed    := "RunResumed"
    static RunReset      := "RunReset"
    static StepCompleted := "StepCompleted"
    static ZoneChanged   := "ZoneChanged"
    static DeathDetected := "DeathDetected"
    static LevelUp       := "LevelUp"
    static AreaLevelChanged := "AreaLevelChanged"
}

class Commands {
    static PauseRequested      := "PauseRequested"
    static NewRunRequested     := "NewRunRequested"
    static ResetRunRequested   := "ResetRunRequested"
    static CompleteStepRequested := "CompleteStepRequested"
}
```

Uso: `bus.Publish(Events.RunPaused, Map("elapsed", 42000))`. Typo no nome estoura "undefined property" — ajuda mais que `bus.Publish("RunPasued")`.

---

## 6. Composition Root — único lugar onde tudo se conecta

```ahk
; poe2_campaign_tracker.ahk (entrypoint)
#Requires AutoHotkey v2.0
#SingleInstance Force

; Constantes globais (apenas paths, sem state)
INI_FILE     := A_ScriptDir "\poe2_tracker.ini"
SPLITS_FILE  := A_ScriptDir "\data\splits.csv"
DEATHS_FILE  := A_ScriptDir "\data\deaths.csv"
LOADING_FILE := A_ScriptDir "\data\loading.csv"
RUN_DIR      := A_ScriptDir "\runs"

; Includes (ordem não importa pra classes; importa pra funções top-level)
#Include "src\core\event_bus.ahk"
#Include "src\domain\..."        ; (todos os models)
#Include "src\infra\..."         ; (todos os repos)
#Include "src\app\services\..."  ; (todos os services)
#Include "src\ui\..."            ; (todos os widgets/editores)
#Include "src\app\app.ahk"

global app := SpeedKalandraApp()
app.Start()


; --- src/app/app.ahk ---
class SpeedKalandraApp {
    bus          := ""
    iniRepo      := ""
    runRepo      := ""
    settingsRepo := ""

    timerService    := ""
    runService      := ""
    campaignService := ""
    xpService       := ""
    logMonitor      := ""
    analytics       := ""

    widgetSystem := ""
    editor       := ""
    hotkeys      := ""

    __New() {
        ; --- Infrastructure (sem deps internas) ---
        this.bus          := EventBus()
        this.iniRepo      := IniRepository(INI_FILE)
        this.runRepo      := CsvRunRepository(SPLITS_FILE, DEATHS_FILE, RUN_DIR)
        this.settingsRepo := SettingsRepository(this.iniRepo)
        clock             := RealClock()

        ; --- App services (recebem repos + bus) ---
        this.timerService    := TimerService(this.bus, clock)
        this.runService      := RunService(this.runRepo, this.bus, clock)
        this.campaignService := CampaignService(this.iniRepo, this.bus)
        this.xpService       := XpService(this.bus)
        this.analytics       := AnalyticsService(this.runRepo)

        ; --- Infra que depende de bus ---
        this.logMonitor := LogMonitorService(
            this.settingsRepo.GetLogPath(),
            this.bus
        )

        ; --- UI ---
        this.widgetSystem := WidgetSystem(this.bus, this.iniRepo, this.settingsRepo)
        this.editor       := CampaignEditorWindow(this.campaignService, this.bus)
        this.hotkeys      := HotkeyService(this.bus, this.settingsRepo)
    }

    Start() {
        this.logMonitor.Start()
        this.widgetSystem.ShowAll()
        this.hotkeys.Register()
    }

    Stop() {
        this.logMonitor.Stop()
        this.widgetSystem.HideAll()
        this.hotkeys.Unregister()
    }
}
```

**Esse é o único lugar onde objetos são instanciados.** Todo o resto recebe deps por construtor. Globais reduzidas a constantes de path (`INI_FILE`, etc) + a referência única `app`.

---

## 7. Fluxo concreto — usuário aperta Pause

```
[ActionsWidget._OnPauseClick]
    └─→ this.bus.Publish(Commands.PauseRequested)
            │
            ▼
        [TimerService._OnPauseRequested]
            ├─ if !this.isRunning: return
            ├─ this.isPaused := true
            ├─ this.pausedAt := clock.Now()
            └─ bus.Publish(Events.RunPaused, Map(
                  "runId", this.currentRunId,
                  "elapsedMs", this.GetElapsedMs()
               ))
                    │
        ┌───────────┼───────────────────┬─────────────────────┐
        ▼           ▼                   ▼                     ▼
   [TimerWidget] [SplitsWidget]    [ActionsWidget]       [RunRepository]
   muda RUN     congela delta      ícone vira "▶"        registra pause split
   p/ amber     atual              (sem chamada direta!)
```

Cada componente faz o seu. **Adicionar quinto reagindo a `RunPaused` (ex: notificação Discord) = nova classe + uma linha de Subscribe. Zero arquivo modificado.**

---

## 8. Modelos de domínio — exemplos

### Value Object: Duration

```ahk
; src/domain/values/duration.ahk
class Duration {
    ms := 0

    __New(ms) {
        if (!IsNumber(ms) || ms < 0)
            throw ValueError("Duration.ms deve ser número >= 0, recebi: " ms)
        this.ms := ms
    }

    static Zero() => Duration(0)
    static FromSeconds(s) => Duration(s * 1000)

    Formatted() {
        totalSec := this.ms // 1000
        m := totalSec // 60
        s := Mod(totalSec, 60)
        return Format("{:02d}:{:02d}", m, s)
    }

    Plus(other) => Duration(this.ms + other.ms)
    Minus(other) => Duration(Max(0, this.ms - other.ms))
    Equals(other) => this.ms = other.ms
}
```

### Entity: Step com Factory

```ahk
; src/domain/models/step.ahk
class Step {
    id            := ""
    objective     := ""
    timed         := false
    mapName       := ""
    bossName      := ""
    completion    := ""    ; instância de RegexCompletion / AndCompletion / TownCompletion
    physicalZones := []
    areaLevel     := 0

    ; Factory que valida. Único lugar que cria Step.
    static FromMap(data) {
        if (!data.Has("id") || data["id"] = "")
            throw ValueError("Step requer 'id' não vazio")
        if (!data.Has("objective"))
            throw ValueError("Step '" data["id"] "' requer 'objective'")
        if (!data.Has("completion"))
            throw ValueError("Step '" data["id"] "' requer 'completion'")

        s := Step()
        s.id            := data["id"]
        s.objective     := data["objective"]
        s.timed         := data.Has("timed") ? !!data["timed"] : true
        s.mapName       := data.Has("mapName") ? data["mapName"] : ""
        s.bossName      := data.Has("bossName") ? data["bossName"] : ""
        s.completion    := CompletionRule.FromMap(data["completion"])
        s.physicalZones := data.Has("physicalZones") ? data["physicalZones"] : []
        s.areaLevel     := data.Has("areaLevel") ? Integer(data["areaLevel"]) : 0
        return s
    }

    ; Cópia imutável com modificações
    With(changes) {
        merged := Map()
        for k, v in this.OwnProps()
            merged[k] := v
        for k, v in changes
            merged[k] := v
        return Step.FromMap(merged)
    }

    IsTownStep() => this.completion is TownCompletion
}
```

### Discriminated Union: CompletionRule

```ahk
; src/domain/rules/completion.ahk
class CompletionRule {
    kind := ""

    static FromMap(data) {
        if (!data.Has("kind"))
            throw ValueError("CompletionRule requer 'kind'")
        switch data["kind"] {
            case "regex": return RegexCompletion.FromMap(data)
            case "and":   return AndCompletion.FromMap(data)
            case "town":  return TownCompletion.FromMap(data)
            default:      throw ValueError("CompletionRule.kind inválido: " data["kind"])
        }
    }
}

class RegexCompletion extends CompletionRule {
    kind    := "regex"
    pattern := ""

    static FromMap(data) {
        r := RegexCompletion()
        r.pattern := data["pattern"]
        return r
    }
}

class AndCompletion extends CompletionRule {
    kind     := "and"
    triggers := []   ; Array of Trigger

    static FromMap(data) {
        a := AndCompletion()
        for _, t in data["triggers"]
            a.triggers.Push(Trigger.FromMap(t))
        return a
    }
}

class TownCompletion extends CompletionRule {
    kind := "town"
    static FromMap(data) => TownCompletion()
}
```

Service usando pattern matching:

```ahk
; Em algum service:
IsStepComplete(step, line, sceneState, runState) {
    cr := step.completion
    if (cr is RegexCompletion)
        return RegExMatch(line, cr.pattern)
    if (cr is AndCompletion)
        return this._allTriggersMatched(cr.triggers, runState)
    if (cr is TownCompletion)
        return sceneState.isTown
    throw Error("Tipo de CompletionRule desconhecido: " Type(cr))
}
```

---

## 9. Service — exemplo TimerService

```ahk
; src/app/services/timer_service.ahk
class TimerService {
    _bus       := ""
    _clock     := ""

    isRunning  := false
    isPaused   := false
    _runStartMs := 0
    _pausedAt   := 0
    _pauseTotalMs := 0

    __New(bus, clock) {
        this._bus   := bus
        this._clock := clock

        ; Subscreve Commands
        bus.Subscribe(Commands.PauseRequested,    this._OnPauseRequested.Bind(this))
        bus.Subscribe(Commands.NewRunRequested,   this._OnNewRunRequested.Bind(this))
        bus.Subscribe(Commands.ResetRunRequested, this._OnResetRunRequested.Bind(this))
    }

    GetElapsedMs() {
        if !this.isRunning
            return 0
        if this.isPaused
            return this._pausedAt - this._runStartMs - this._pauseTotalMs
        return this._clock.Now() - this._runStartMs - this._pauseTotalMs
    }

    _OnNewRunRequested(data) {
        this.isRunning  := true
        this.isPaused   := false
        this._runStartMs := this._clock.Now()
        this._pauseTotalMs := 0

        this._bus.Publish(Events.RunStarted, Map(
            "startedAt", this._runStartMs
        ))
    }

    _OnPauseRequested(_) {
        if !this.isRunning
            return

        if this.isPaused {
            ; Resume
            this._pauseTotalMs += this._clock.Now() - this._pausedAt
            this.isPaused := false
            this._bus.Publish(Events.RunResumed, Map("elapsedMs", this.GetElapsedMs()))
        } else {
            ; Pause
            this._pausedAt := this._clock.Now()
            this.isPaused  := true
            this._bus.Publish(Events.RunPaused, Map("elapsedMs", this.GetElapsedMs()))
        }
    }

    _OnResetRunRequested(_) {
        if !this.isRunning
            return
        this.isRunning  := false
        this.isPaused   := false
        this._runStartMs := 0
        this._pauseTotalMs := 0
        this._bus.Publish(Events.RunReset, "")
    }
}
```

Note:
- Estado interno com prefixo `_` (convenção: privado).
- Sem `global gTimerActive`, `gTimerPaused`, `gRunBaseMs`. Encapsulado.
- Reage a Commands, publica Events. Não conhece nem UI nem repos.
- **Testável isolado:** `TimerService(FakeBus(), FakeClock())`.

---

## 10. Repository — exemplo

```ahk
; src/domain/repositories.ahk
; "Interfaces" — em AHK isso é só convenção via classe abstrata
class IRunRepository {
    Save(run)        => throw Error("not implemented")
    LoadAll()        => throw Error("not implemented")
    LoadById(runId)  => throw Error("not implemented")
    AppendSplit(runId, split) => throw Error("not implemented")
    AppendDeath(runId, death) => throw Error("not implemented")
}

; src/infra/persistence/csv_run_repo.ahk
class CsvRunRepository extends IRunRepository {
    _splitsFile := ""
    _deathsFile := ""
    _runDir     := ""

    __New(splitsFile, deathsFile, runDir) {
        this._splitsFile := splitsFile
        this._deathsFile := deathsFile
        this._runDir     := runDir
        this._EnsureHeaders()
    }

    AppendSplit(runId, split) {
        this._EnsureHeaders()
        line := this._SerializeSplit(runId, split)
        FileAppend(line, this._splitsFile, "UTF-8")
        ; Também escreve no run-specific
        runFile := this._runDir "\" runId ".csv"
        if !FileExist(runFile)
            FileAppend(this._SplitsHeader(), runFile, "UTF-8")
        FileAppend(line, runFile, "UTF-8")
    }

    LoadAll() {
        ; Lê splits.csv, agrupa por runId, retorna Array<Run>
        ; ...
    }

    _EnsureHeaders() { /* ... */ }
    _SerializeSplit(runId, split) { /* ... */ }
    _SplitsHeader() { /* ... */ }
}
```

UI/services nunca conhecem nomes de arquivo. Eles usam `runRepo.AppendSplit(...)`. Mudança de formato (JSON, SQLite no futuro) = trocar `CsvRunRepository` por outra classe no Composition Root. Zero impacto em outros arquivos.

---

## 11. UI Reativa — Widget escutando o bus

```ahk
; src/ui/overlay/widget_base.ahk
class WidgetBase {
    _bus     := ""
    _state   := ""    ; widgetState (topPct, leftPct, scale, visible, centered)
    _gui     := ""
    _ctrls   := Map()
    id       := ""    ; "timer", "zone", ...
    name     := ""    ; "Timer (Run/Etapa)"

    __New(id, name, bus, state) {
        this.id     := id
        this.name   := name
        this._bus   := bus
        this._state := state
    }

    Show() { /* cria gui */ }
    Hide() { /* destroi gui */ }
    ReRender() { this.Hide(); this.Show() }

    OnEvent(eventName, handler) {
        this._bus.Subscribe(eventName, handler)
    }
}

; src/ui/overlay/timer_widget.ahk
class TimerWidget extends WidgetBase {
    _runValCtrl   := ""
    _etapaValCtrl := ""
    _deltaValCtrl := ""

    __New(bus, state) {
        super.__New("timer", "Timer (Run/Etapa)", bus, state)
        ; Reage ao bus
        bus.Subscribe(Events.RunStarted, this._OnRunStarted.Bind(this))
        bus.Subscribe(Events.RunPaused,  this._OnRunPaused.Bind(this))
        bus.Subscribe(Events.RunResumed, this._OnRunResumed.Bind(this))
        bus.Subscribe(Events.StepCompleted, this._OnStepCompleted.Bind(this))
    }

    _OnRunPaused(data) {
        if !this._runValCtrl
            return
        ; muda visual, ex: cor amber
        this._runValCtrl.SetFont("c" Theme.amber)
    }

    _OnRunResumed(data) {
        if !this._runValCtrl
            return
        this._runValCtrl.SetFont("c" Theme.text)
    }

    ; Continua tendo ticks de refresh, mas pra atualizar números só
    Tick() {
        if !this._runValCtrl
            return
        this._runValCtrl.Text := this._GetCurrentRunText()
    }
}
```

Note:
- Widget **não conhece TimerService**. Conhece o bus.
- Reage a `RunPaused` mudando cor.
- Tick continua existindo pra atualizar o número (vem do timerService via property que widget consulta? Ou via evento periódico? Decidir — provavelmente o segundo).

### Fluxo do tick alternativo (publish periódico)

Em vez do widget consultar o service, um único timer global publica `Events.Tick` a cada 300ms com o estado atual:

```ahk
; AppTickEmitter — uma classe que roda SetTimer e emite Tick
class AppTickEmitter {
    _bus := ""
    _timerService := ""

    __New(bus, timerService) {
        this._bus := bus
        this._timerService := timerService
        SetTimer(this._Tick.Bind(this), 300)
    }

    _Tick() {
        this._bus.Publish(Events.Tick, Map(
            "runElapsedMs", this._timerService.GetElapsedMs(),
            "isRunning", this._timerService.isRunning,
            "isPaused", this._timerService.isPaused
        ))
    }
}
```

Widgets escutam `Events.Tick`, atualizam textos. Nenhum widget sabe de service. **Acoplamento zero.**

---

## 12. Strangler Fig — estratégia de migração

**Big-bang refactor é tão arriscado quanto big-bang rewrite.** Vamos crescer a estrutura nova ao lado da antiga, módulo por módulo:

```
SpeedKalandra/
├── src/                  ← código atual (legado)
│   ├── ui.ahk
│   ├── state.ahk
│   ├── timer.ahk
│   └── ...
└── src_v2/               ← código novo (cresce gradualmente)
    ├── core/
    ├── domain/
    ├── app/
    ├── infra/
    └── ui/
```

Em cada fase:
1. Cria peça nova em `src_v2/`
2. Adiciona ponte temporária: `src_v2` é instanciado em `poe2_campaign_tracker.ahk` com a parte legada coexistindo
3. Funcionalidade migrada usa nova
4. Quando equivalente comprovado, remove a antiga
5. Avança próxima peça

**Tracker nunca para de funcionar.** Em cada commit dá pra rodar e jogar.

No final (Fase 8), `src/` é deletada e `src_v2/` vira `src/`.

---

## 13. Roadmap de fases

### Fase 1 — Fundação (3-4 dias)
**Objetivo:** estrutura nova existir e compilar, sem mexer em nada legado.
- [ ] Criar `src_v2/` com pastas core/domain/app/infra/ui
- [ ] Implementar `EventBus` + testes manuais
- [ ] Implementar `Clock` (Real + Fake)
- [ ] Implementar classe-base `WidgetBase` (drag/resize/persistencia, equivalente ao `overlay_widgets.ahk` atual)
- [ ] Composition Root vazio rodando: `App.Start()` + `App.Stop()`
- [ ] **Critério de aceite:** tracker legado continua 100% funcional, nova estrutura coexiste sem conflito.

### Fase 2 — Domain Models (1 semana)
**Objetivo:** modelos imutáveis com factories validando.
- [ ] `Duration`, `AreaCode`, `StepId` (value objects)
- [ ] `Step`, `Act`, `Profile` (entities + Factory.FromMap)
- [ ] `Run`, `Split`, `Death`
- [ ] `CompletionRule` (Regex/And/Town discriminated)
- [ ] `Trigger` + `AndProgress`
- [ ] **Adapter** que converte representação atual (Map de campaign_data.ahk) → novos models
- [ ] **Critério:** carregar campanha atual via adapter funciona; objetos validam corretamente.

### Fase 3 — Repositórios (4-5 dias)
**Objetivo:** centralizar acesso a INI/CSV.
- [ ] `IniRepository` (substituir todos `IniRead/IniWrite` espalhados)
- [ ] `SettingsRepository` (envolve IniRepository, expõe métodos semânticos)
- [ ] `CsvRunRepository` (substituir AppendSplit, AppendDeath, etc.)
- [ ] `CsvLoadingRepository`
- [ ] **Critério:** novos repos lêem e gravam exatamente o que o legado lê e grava (validado com diff).

### Fase 4 — Services (1.5 semanas)
**Objetivo:** lógica de negócio em classes reativas.
- [ ] `TimerService` substitui `timer.ahk`
- [ ] `RunService` substitui parte de `state.ahk` (criação de run, registro de splits)
- [ ] `CampaignService` substitui parte de `state.ahk` (navegação de steps)
- [ ] `XpService` substitui `xp.ahk`
- [ ] `LogMonitorService` substitui `log_monitor.ahk` (publica eventos brutos no bus)
- [ ] `AnalyticsService` substitui parte de `stats.ahk`
- [ ] **Critério:** uma run completa sintética (lendo log de teste) produz mesmas estatísticas que legado.

### Fase 5 — Sync Engine (1 semana)
**Objetivo:** o coração lógico do tracker.
- [ ] `SyncEngine` consome `LogEvents`, decide step transitions, publica `StepCompleted`/`ZoneChanged`
- [ ] Migra Cemetery hub, AND triggers, completion regex
- [ ] **Critério:** logs gravados de runs antigas reproduzem os mesmos splits.

### Fase 6 — UI Reativa: Widgets (1.5 semanas)
**Objetivo:** widgets do overlay falando com bus.
- [ ] `WidgetBase` v2 (drag/resize/persistencia centralizado)
- [ ] Migra cada widget (timer, zone, ..., actions) — um por vez
- [ ] `WidgetManagerPanel` v2
- [ ] **Critério:** todos os 8 widgets funcionam idênticos ao atual mas via bus.

### Fase 7 — UI Reativa: Editor + Settings (2 semanas)
**Objetivo:** o pedaço mais complexo da UI.
- [ ] `CampaignEditorWindow` reescrito limpo (forms genéricos a partir de Step model)
- [ ] `SettingsDialog` reescrito
- [ ] Validação de rota integrada via `CampaignService`
- [ ] **Critério:** pode editar um Step do Ato 1, gravar, recarregar, render correto no overlay.

### Fase 8 — Demolição do legado (3-4 dias)
**Objetivo:** remover `src/` antigo.
- [ ] Conferir que nenhum `#Include "src/..."` resta
- [ ] Deletar `src/`
- [ ] Mover `src_v2/` → `src/`
- [ ] Atualizar `poe2_campaign_tracker.ahk` includes
- [ ] **Critério:** tracker funciona idêntico, código tem 50-60% menos linhas, 0 globais de estado.

**Total realista:** 8-10 semanas trabalhando consistente. Cada fase entrega algo testável e o tracker nunca quebra.

---

## 14. Limites honestos do AHK que vamos sentir

Quero deixar claro o que essa arquitetura **não conserta** porque não dá em AHK:

1. **Sem checagem em compile time.** Se eu chamar `step.objektive` (typo), só estoura em runtime. Compensamos com:
   - Factories validando na construção
   - Convenção: leitor/IDE busca usos antes de renomear
   - Testes manuais sistemáticos

2. **Sem `mypy` / linter rigoroso.** Não tem ferramenta que falhe o build em "passei string onde queria int". Compensamos com:
   - `Validate()` métodos em models
   - Type assertions nos pontos quentes (ex: `if !(x is Step) throw`)

3. **Sem generics.** `Array<Step>` em AHK é `Array` mesmo. Compensamos com:
   - Convenção de nome (`steps`, não `items`)
   - Comentários docstring `; @param Array<Step> steps`

4. **Threads limitados.** AHK só tem `SetTimer` e `OnMessage` como pseudo-concorrência. Compensamos:
   - EventBus síncrono (já era)
   - Operações pesadas (rebuild stats) com `SetTimer(fn, -1)` pra ceder

5. **Reflexão limitada.** Não dá pra "iterar sobre todos os campos de um BaseModel" como Pydantic. Compensamos com:
   - `OwnProps()` (limitado mas usável)
   - Schema explícito quando precisar de meta

**O que mesmo assim ganhamos vs hoje:**
- ✅ Sem globals de estado
- ✅ Encapsulamento + composição
- ✅ EventBus desacopla UI de core
- ✅ Cada peça testável isolada
- ✅ Adicionar feature = adicionar classe + Subscribe (não tocar 5 arquivos)
- ✅ Erro de validação na construção, não em runtime aleatório
- ✅ Schema versionado de INI/CSV via repos centralizados
- ✅ Editor de campanha reescrito limpo (não mais 298KB)

**Estimativa realista:** ~70% do ganho que Python+Pydantic dariam, com 0% do risco de migração de linguagem.

---

## 15. O que precisa ser decidido antes da Fase 1

1. **Aceita o plano de 8 fases?** Ou prefere consolidar em menos? (não recomendo — fases curtas = menos risco)
2. **Aceita a estratégia Strangler Fig (`src_v2/` ao lado de `src/`)?** Ou prefere refatorar in-place?
3. **Convenção de nomes:**
   - Métodos: `PascalCase` (AHK convention) ou `camelCase`?
   - Privados: `_propName` ou `propName`?
   - Eu sugiro: `PascalCase` pra métodos públicos, `_PascalCase` pra privados, `camelCase` pra propriedades.
4. **Onde gravar logs internos?** Hoje não tem sistema de log estruturado. Quero um `LogService` desde a Fase 1.
5. **Manter compatibilidade com poe2_tracker.ini atual?** Recomendo sim — repos novos lêem a chave atual + esquema atual.

---

## 16. Próximo passo

Tu valida essa proposta:
- O que faz sentido?
- O que parece over-engineered?
- Que parte tu acha que vai te incomodar?

Após acordo, começo pela **Fase 1 (Fundação)**: 3-4 dias, cria `src_v2/`, EventBus, Clock, App esqueleto, sem tocar em nada legado. Tu rodaria o tracker normal e veria a estrutura nova convivendo.

Sem código antes do v1 desse doc estar fechado entre nós.

---

## 17. Decisões tomadas durante a execução

Esta seção registra decisões importantes que surgiram **durante** a implementação das fases, fora das previstas no plano original. Funciona como um "diário de bordo" da arquitetura.

### 17.1 — Step v2 mantém estrutura plana (Fase 2)

O `Step` legado (`campaign_data.ahk`) tem 25 campos planos para completion: `completionMode`, `completionRegex`, `bossStartRegex`, `bossEndRegex`, `engageRegex`, `requiredFlag`, `completionFlag`, `physicalZones`, etc.

**Decisão:** preservar essa estrutura plana no `Step` v2 em vez de modelar como `CompletionRule` discriminada (`RegexCompletion` / `AndCompletion` / `TownCompletion`).

**Motivo:**
- Adapter `Map ↔ Step` fica trivial — 25 campos copiados 1:1.
- `sync_engine` legado pode ser portado quase 1:1 na Fase 4 sem precisar re-modelar regras antes da hora.
- Refatorar agora seria trabalho dobrado: re-modela, depois reescreve o engine consumindo o novo modelo.

**Onde acontece a refatoração:** Fase 5 (SyncEngine reescrito), quando já temos serviços funcionais consumindo rules e os testes garantem que a semântica está preservada.

### 17.2 — Domain models para configuração com regras (Fase 3)

Originalmente a Fase 3 trataria `Progress`, `RunState`, `WindowState`, `OverlayLayout` como `Map` retornado pelos repos. Decidimos modelar como **classes do domain**.

**Motivo:** todas têm invariantes que precisam ser validadas:
- `Progress`: cursor entre 1 e steps.Length+1; ActCompleted derivado de gDone.
- `RunState`: timestamps consistentes; runId válido se presente.
- `WindowState`: tamanhos não-negativos.
- `OverlayPosition`: scale entre 0.5 e 3.0; left/top em percentual.

Deixar como `Map` significaria validar em todo lugar que consome o repo. Modelar como classe move a validação para um lugar só (factory `FromMap`).

**Custo:** ~5 classes novas no domain. **Benefício:** repo não-pode retornar configuração inválida.

### 17.3 — Stats fica para a Fase 4 (não 3)

Originalmente o plano previa `StatsRepository` na Fase 3. Decidimos mover para a Fase 4 junto com `AnalyticsService`.

**Motivo:** stats não é "persistência" — é **computação derivada** de `splits.csv`. Não há um arquivo `stats.csv` separado a carregar. Logo, na Fase 4 o `AnalyticsService` recebe `RunRepository` e calcula stats em memória.

Se um dia quisermos cachear stats em arquivo (otimização), aí faz sentido criar um repo. Hoje seria invenção de problema.

### 17.4 — Migração estritamente paralela até Fase 8 (princípio reforçado)

O plano Strangler Fig original já dizia "src_v2 cresce ao lado de src", mas faltava clareza sobre **quem pode chamar quem** durante a migração.

**Princípio adicionado:** o legado **NUNCA** chama o novo. Em nenhum momento entre a Fase 1 e a Fase 8 o código de `src/` deve fazer `#Include` de `src_v2/` ou referenciar classes do v2.

**Motivo:** o tracker é usado em produção. Qualquer dependência do legado no v2 antes da hora vira risco real de derrubar o tracker enquanto o usuário está jogando. Na Fase 8 trocamos o entrypoint (`poe2_campaign_tracker.ahk`) num único commit — antes disso, os dois mundos coexistem em isolamento total.

**Implicação prática:** alguns serviços novos (Fase 4+) vão precisar **ler** globais legados temporariamente para receber input do mundo real. Isso é OK — leitura unidirecional do legado. O proibido é o legado depender do novo.

### 17.5 — Convenção de nomes para evitar colisões case-insensitive (regra dura)

O AHK v2 é **case-insensitive em identificadores**. Isso significa que um parâmetro chamado `iniFile` é o **mesmo identificador** que a classe `IniFile` — e dentro do escopo da função, o parâmetro **sombreia** a classe. Quando isso acontece, expressoes como `iniFile is IniFile` viram `valor is valor`, e como o lado direito não é mais uma classe, AHK estoura com `"Expected a Class but got a <Tipo>"`.

Caimos nesse bug duas vezes (Fase 2 com `step is Step`, Fase 3 com `iniFile is IniFile`). Para nunca mais cair:

**Regra dura:** parâmetros e variáveis locais nunca podem ter o mesmo nome (case-insensitive) que classes referenciadas no mesmo escopo. Use sufixo `Obj` ou abreviações de 2-3 letras.

**A regra vale pra QUALQUER classe usada como type check `is X` no escopo — não só domain models.** A tabela abaixo é histórica (registros das colisões já encontradas), não exaustiva. Antes de nomear parâmetro/local, conferir: “existe classe com esse nome no projeto?”.

| Classe          | NÃO usar (colide) | Usar              |
| --------------- | ----------------- | ----------------- |
| `Step`          | `step`            | `stepObj`, `s`    |
| `Act`           | `act`             | `actObj`          |
| `Run`           | `run`             | `runObj`, `r`     |
| `Split`         | `split`           | `splitObj`        |
| `Death`         | `death`           | `deathObj`        |
| `RunId`         | `runId`           | `runIdStr`, `id`  |
| `StepId`        | `stepId`          | `stepIdStr`       |
| `Progress`      | `progress`        | `progressObj`, `pr` |
| `RunState`      | `runState`        | `runStateObj`, `rs` |
| `WindowState`   | `windowState`     | `ws`              |
| `OverlayLayout` | `overlayLayout`   | `ol`              |
| `OverlayPosition` | `overlayPosition` | `op`            |
| `AppSettings`   | `appSettings`     | `cfg`, `appSet`   |
| `IniFile`       | `iniFile`         | `iniFileObj`, `ini` |
| `CsvFile`       | `csvFile`         | `csvFileObj`, `csv` |
| `Events`        | `events`          | `received`, `captured`, `eventList` |
| `EventBus`      | `eventBus`        | `bus`             |
| `TriggerMatcher` | `triggerMatcher` | `tmatcher`, `triggerMatcherObj` |
| `TimerService`  | `timerService`    | `timer`, `timerSvc` |
| `RunService`    | `runService`      | `runSvc`          |
| `CampaignService` | `campaignService` | `campaign`, `campaignSvc` |
| `SyncEngine`    | `syncEngine`      | `syncEng`         |
| `HotkeyService` | `hotkeyService`   | `hotkeySvc`       |
| `XpService`     | `xpService`       | `xp`              |
| `RouteAutomationService` | `routeAutomation` | `routeAuto`, `routeAutoSvc` |
| `RunRecordingWorkflow` | `runRecordingWorkflow` | `runRecWf`, `recWorkflow` |

**Atenção especial para campos de modelo:** `Split` tem campo `runId`, `Death` tem campo `stepId`, etc. Acessar `splitObj.runId` é OK (é propriedade, não variável local). O bug só ocorre quando um parâmetro/variável local *no mesmo escopo* tem o nome da classe.

**Detecção de runtime:** dois sintomas que indicam essa colisão:
1. `"Expected a Class but got a <X>"` — quando se usa `valor is Classe` e o parâmetro chamado `classe` sombreia a classe.
2. `"This local variable has not been assigned a value. A global declaration inside the function may be required."` — quando se faz `local := Classe.FromMap(...)` com `local` case-insensitive igual a `Classe`. AHK marca `local` como variável local não-inicializada e o lado direito (`Classe`) também é lida como ela mesma, ainda sem valor.

### 17.6 — Princípios da Fase 4 (Services)

A Fase 4 é a primeira em que entidades **mutáveis** com estado runtime aparecem (TimerService, RunService, etc). Para evitar que viremos os globais legados disfarçados de classe, adotamos princípios firmes:

1. **Services nunca acessam globais.** Tudo via construtor. `TimerService(clock, bus)` — e ponto.

2. **Services se comunicam via EventBus para *broadcast*, mas chamada direta para *delegação***. Exemplos:
   - **Broadcast** (varios podem reagir): `TimerService` publica `Evt.TimerStarted`. Widgets do overlay assinam para se atualizar; LogService assina para registrar.
   - **Delegação** (uma operação atomica): `RunService.NewRun()` chama `timer.ResetAll(true)` direto. Não faz sentido publicar `Cmd.ResetTimer` e ouvir, porque é um único fluxo síncrono. Forcar tudo via EventBus mascara o fluxo no debug.

   **Regra prática:** se a operação é "X aconteceu, mais de um interessado pode reagir", é evento. Se é "para A funcionar, B precisa fazer Y agora", é chamada direta.

3. **Services são mutáveis** (ao contrário dos domain models da Fase 2 que são imútaveis com factory). Mantêm estado runtime privado (timer ativo, run em curso). Acesso só por métodos públicos.

4. **Services não tocam UI**. Só publicam eventos. UI assina e renderiza. Servico que mostra `MsgBox` está errado.

5. **Services com dependência de tempo recebem `Clock`** (RealClock em prod, FakeClock em testes). Sem `Sleep`, sem `A_TickCount` direto.

6. **Confirmações destrutivas seguem fluxo Request/Confirm.** Para ações que precisam de confirmação do usuário (Cancel/Restart/Finalize Run), o service publica `Evt.XRequested`. Algum subscriber UI mostra dialog. Se confirmado, UI publica `Cmd.ConfirmX`. Service ouve esse comando e executa. Isso desacopla service da UI e permite testar sem MsgBox.

7. **Services podem ler globais legados temporariamente** (Strangler Fig — leitura unidirecional permitida até Fase 8). Por exemplo, `LogMonitorService` (Fase 4.6) precisa ler `gLogFile` legado pra saber qual Client.txt monitorar. Esse acoplamento sai junto com a demolição legada.

**Sub-fases acordadas:**

| #     | Service                              | Status |
| ----- | ------------------------------------ | ------ |
| 4.1   | TimerService                         | ✅     |
| 4.2   | AnalyticsService                     | ✅     |
| 4.3   | RunService                           | ✅     |
| 4.4.1 | CampaignService — núcleo             | ✅     |
| 4.4.2 | CampaignService — Undo stack         | ✅     |
| 4.4.3 | CampaignService — Route groups       | ✅     |
| 4.5   | XpService                            | ✅     |
| 4.6   | LogMonitorService                    | ✅     |

**Fase 4 concluída em 664 testes.**

### 17.7 — Encerramento da Fase 4 (Services)

A Fase 4 entregou **7 services** desacoplados, todos cobertos por testes unitários e prontos para serem orquestrados pela Fase 5 (Composition Root + SyncEngine). Decisões importantes registradas durante a execução:

**Sobre escopo (o que ficou *de fora* dos services e cai na Fase 5):**

- **Coordenação inter-service de Undo.** O `CampaignService.UndoLastAction()` reverte apenas seu próprio Progress + ObjectiveFlags. Se um subscriber reagiu ao `StepCompleted` criando um split no CSV, esse split *não é* revertido pelo undo do CampaignService. O SyncEngine da Fase 5 vai costurar undos múltiplos via comando `Cmd.UndoRequested` que coordena CampaignService + RunService + repositórios.
- **Cemetery special-case advance.** Lógica de "matei boss do Cemetery, pula direto pro próximo boss pendente ou pro gate" não está no CampaignService — ele faz auto-skip apenas baseado em `done` ou `optional`. Regras específicas de rota (Cemetery hub, AND triggers, completion regex de step) ficam no SyncEngine.
- **Auto-pause por Lost Focus, auto-start na fala do "Wounded Man", sync de zona à rota.** Tudo isso era responsabilidade do `log_monitor.ahk` legado. No v2, o `LogMonitorService` apenas publica eventos brutos (`SceneEntered`, `WindowFocusChanged`, etc) e o **App composition root** ou **SyncEngine** decide o que fazer.
- **Persistência de `objectiveFlags`.** O CampaignService mantém o Map em memória mas não persiste. Quem persiste é o `RunStateRepository` da Fase 3, e a costura entre os dois é responsabilidade do composition root da Fase 5.

**Sobre forma (padrões que se firmaram):**

- **Hydrate(...) é o ponto de entrada de boot.** Cada service que tem estado expõe um `Hydrate(args...)` chamado pela Composition Root no boot, recebendo o que veio do disco via repos. Isso isola a fase de boot da fase de runtime.
- **API direta vs. EventBus seguiu a regra do princípio 17.6.2.** Confirmações destrutivas (`CancelRun`, `RestartRun`, `FinalizeRun`) viraram chamada direta pelo callsite *após* a UI mostrar o dialog — não usamos o fluxo `Request/Confirm` para esses casos porque adicionava complexidade sem benefício real. O `Request/Confirm` continua válido para fluxos onde múltiplos UIs concorrentes podem solicitar a mesma ação.
- **Snapshots de undo são deep copy explícito.** Closures em AHK v2 capturam Maps por referência. Se um snapshot fosse shallow copy, mutações posteriores contaminariam o histórico. Cada service que mantém undo (até agora só CampaignService) tem clone manual dos Maps internos.
- **Services puramente funcionais não precisam de bus.** O `XpService` não tem dependência de bus nem de clock — é só estado + delegação para `XpRules`. Não inventamos dependências "para o futuro" — adicionamos quando o uso real exigir.

**Métricas:**

| Fase | Testes acumulados | Δ    |
| ---- | ----------------- | ---- |
| 1    | 42                | +42  |
| 2    | 163               | +121 |
| 3    | 418               | +255 |
| 4.1  | 459               | +41  |
| 4.2  | 483               | +24  |
| 4.3  | 517               | +34  |
| 4.4.1 | 555              | +38  |
| 4.4.2 | 572              | +17  |
| 4.4.3 | 604              | +32  |
| 4.5  | 628               | +24  |
| 4.6  | 664               | +36  |
| 5.1.a | 676              | +12  |
| 5.1.b | 689              | +13  |
| 6.1  | 746               | +57  |
| 6.2  | 782               | +36  |
| 6.3  | 806               | +24  |
| 6.4  | 828               | +22  |
| 6.5  | 843               | +15  |
| 6.6  | 891               | +48  |
| 5.2  | 913               | +22  |
| 5.3  | 938               | +25  |
| 5.4  | 1008              | +70  |
| 5.5  | 1056              | +48  |
| 5.6  | 1084              | +28  |
| 5.7  | 1111              | +27  |
| 5.8  | 1167              | +56  |
| 5.9  | 1202              | +35  |
| 5.10 | 1213              | +11  |

A Fase 5 começa de uma base sólida: cada service é uma caixa-preta testada, e o SyncEngine vai apenas conectar os fios.

### 17.8 — Decomposição e estratégia da Fase 5 (5.1 concluída)

O plano original descrevia a Fase 5 como "Sync Engine — 1 semana". Quando começamos a execução ficou claro que isso era uma estimativa otimista demais: a fase mistura **sete responsabilidades distintas**. Para evitar entregar um SyncEngine inflado e frágil, decompusemos:

| #   | Sub-fase                                                                | Status |
| --- | ----------------------------------------------------------------------- | ------ |
| 5.1 | Composition Root completo (instanciacao + Hydrate + subs + Stop persist)| ✅ 689 testes |
| 5.2 | SyncEngine base + zona→step (`FindBestMatchingStep`)                     | ✅ 913 testes |
| 5.3 | Boss fight timing (`bossStartRegex` / `bossEndRegex`)                   | ✅ 938 testes |
| 5.4 | Triggers OR (`\|\|`) e AND (`&&`) com `TriggerMatcher` stateful        | ✅ 1008 testes |
| 5.5 | Refator `Step` → `CompletionRule` discriminada                          | ✅ 1056 testes |
| 5.6 | Cemetery special-case + route group advance                             | ✅ 1084 testes |
| 5.7 | Undo coordenado (`Cmd.UndoRequested` orquestrando services)             | ✅ 1111 testes |
| 5.8 | Town visit timing                                                       | ✅ 1167 testes |
| 5.9 | Carry preservation (adendo de itens deferidos)                           | ✅ 1202 testes |
| 5.10 | Wire-up final do Composition Root                                       | ✅ 1213 testes |

**Decisão estratégica — Alternativa A: 5.1 → Fase 6 (Widgets) → 5.2–5.8.**

Depois de fechar a 5.1, optamos por pausar a Fase 5 e fazer a Fase 6 antes do SyncEngine. Razao: widgets só dependem de eventos publicados pelos services (que já existem desde a Fase 4) — não precisam do SyncEngine pra funcionar. Isso permite:

- Ter um app v2 **rodavel e com UI** muito antes do SyncEngine estar pronto.
- Validar a integração composition root ↔ widgets ↔ services com a complexidade real (drag/resize, persistence, theming) sem o ruído da lógica de sync.
- Quando voltarmos para 5.2+, já existirão widgets "vivos" reagindo a eventos do SyncEngine — facilita validar que o sync está publicando os eventos certos.

**Padrões que se firmaram na 5.1:**

- **Composition Root é dono da orquestração de boot e shutdown, não de negócio.** O `SpeedKalandraApp` instancia tudo, chama `Hydrate` na ordem certa e `Persist` na ordem certa. Não conhece regras de campanha, não calcula nada. Se em algum momento parecer que está "tomando decisões de negócio", é sinal de que falta um service intermediário (provavelmente o SyncEngine).

- **Stop persiste agregando estado de múltiplos services.** Cada service é dono do seu pedaço (timer baseMs no `TimerService`, character no `XpService`, flags no `CampaignService`), mas o `RunState` no INI agrega tudo. O composition root injeta `campaign.GetObjectiveFlags()` no `runState.objectiveFlags` antes de chamar `runService.Persist()`. Cada service mantém sua autonomia; a costura final fica em um lugar só.

- **Subscriptions são feitas no construtor, não no `Start`.** Listeners ficam vivos pela vida toda do app — não há unsubscribe no `Stop`. Mais simples, e como o EventBus morre junto com o app, não vaza nada.

- **Fat-arrow `(data) => this._OnXxx(data)` captura `this` corretamente em AHK v2.** Validado: 7 testes de subscriptions exercitam handlers que acessam `this.timer`, `this.xp`, `this._autoPausedByFocus` etc. É a forma idiomática de wirar event handlers no composition root.

- **Auto-pause/resume por focus loss é estado do composition root, não do TimerService.** O `_autoPausedByFocus` flag distingue pausa manual de pausa automática. O `TimerService` em si é "burro" — só sabe Pause/Resume. A política de quando fazer cada uma é do composition root, e pode ser trocada a qualquer momento sem mexer no service.

- **`RunService.Hydrate` cuida do `TimerService.Hydrate` internamente.** Quando um service é dono de outro (RunService coordena timer), `Hydrate` em cascata. O composition root chama `runService.Hydrate(rs)` e não precisa duplicar `timer.Hydrate(...)`. Quem hidrata é dono da operação.

### 17.9 — Decisões da Fase 6 ✅ COMPLETA (891 testes)

A Fase 6 entregou o overlay reativo — 8 widgets (timer, zone, objective, splits, summary, xp, perf, actions) + WidgetManager + HoverHideService. Decomposição final:

| #   | Sub-fase                                                                                       | Status |
| --- | ---------------------------------------------------------------------------------------------- | ------ |
| 6.1 | Foundation: `Theme`, `WidgetBase`, `AppTickEmitter`                                            | ✅ 746 testes |
| 6.2 | Timer + Zone + Objective widgets                                                                | ✅ 782 testes |
| 6.3 | Splits + Summary widgets                                                                        | ✅ 806 testes |
| 6.4 | Xp + Perf widgets                                                                               | ✅ 828 testes |
| 6.5 | Actions widget (único interativo — botoes publicam comandos no bus)                            | ✅ 843 testes |
| 6.6 | WidgetManager + HoverHideService                                                                | ✅ 891 testes |

**Decisões estratégicas tomadas durante a 6.1:**

- **Opção A para acesso a state: widget consulta service direto.** Widgets recebem refs pros services no construtor. Ao receber `Events.Tick`, consultam `timer.GetRunMs()`, `xp.GetCharacterLevel()`, etc. Bus continua sendo usado pra mudanças discretas (TimerPaused vira amber, ZoneChanged atualiza texto da zona) que precisam de re-render imediato. É menos puro que um snapshot em payload, mas muito mais simples e direto — espelha o legado, só que com refs nominais em vez de globais.

- **Drag/resize/close-click não entram na 6.1 (nem nas 6.2-6.5).** Decisão pragmática: drag exige `OnMessage(WM_LBUTTONDOWN)` global + handler que despacha pra widget certo, e isso complica testes. Os widgets são **estáticos** até a 6.6 — a interação com usuário (mover, redimensionar, ligar/desligar) acontece via `WidgetManager` que tem checkbox + slider + botão reset, e por baixo chama `widget.SetVisible/SetScale/SetPosition`. Se quisermos drag direto-na-tela depois, fica fácil adicionar via OnMessage no `WidgetManager` ou num futuro `WidgetCoordinator`.

- **GUI testing é via dependency inversion + mock subclass.** AHK v2 cria janela real ao chamar `Gui(...).Show()`, o que polui o ambiente de teste. Solução adotada: nos testes, criar `FakeWidget extends WidgetBase` que sobrescreve `Show()/Hide()` para apenas contar chamadas e setar `_gui := "fake-gui"`. Isso permite testar TODO o comportamento de mutators (SetVisible/SetScale/SetPosition + onPersist + ReRender) sem abrir nenhuma janela de fato. Renderização visual real é validada via smoke test manual rodando `speedkalandra_dev.ahk`.

- **`Theme.Color(name)` é strict (lança erro pra nome desconhecido).** Em vez de retornar uma cor de fallback silenciosa quando alguém digita `Theme.Color("reed")` (typo), o código estoura imediatamente. Mais barulhento na hora do erro, infinitamente mais fácil de debugar.

- **`AppTickEmitter` não passa payload no `Events.Tick`.** Decorrência da Opção A: o tick é apenas o sinal "atualize agora". Widgets consultam services. Mantém o emitter completamente desacoplado de quais services existem — ele só sabe `bus` e `intervalMs`.

- **`AppTickEmitter` expõe `Pulse()` público além de Start/Stop.** Pra testes evitarem dependencia de `SetTimer` real (que precisa de event loop), e pra prod ter capacidade de forçar refresh imediato após mudança de estado relevante (ex: após Hydrate no boot, antes mesmo do primeiro tick natural).

- **`OverlayPosition` usa `left`/`top` (sem sufixo `Pct`).** O legado usava `topPct/leftPct` em globais runtime mas serializava como `widgetId.top` / `widgetId.left` no INI. O `OverlayPosition` v2 unifica: nome de propriedade casa com nome de chave INI. Subjacente continua sendo percentual da tela.

- **WidgetBase é mutator-based, não event-driven, pra mudanças de visibility/scale/position.** As 3 mutators (`SetVisible`, `SetScale`, `SetPosition`) mutam `OverlayPosition` (referencia compartilhada com `AppSettings.overlay`) + chamam `onPersist` callback + chamam `Show/Hide/ReRender` apropriado. Isso é chamada direta porque o caller é sempre o WidgetManager (futuro) e a operação é "pra A funcionar, B precisa fazer Y agora" (princípio 17.6.2).

**Filosofia de testes da Fase 6:**

A Fase 6 introduz a primeira camada onde GUI testing é fundamentalmente complicado em AHK. Aceitamos que a fase terá menos testes proporcionalmente que outras fases (6.1 entregou +57 testes vs +121 da Fase 2 e +255 da Fase 3), e que **smoke test manual** (rodar `speedkalandra_dev.ahk` e ver os widgets aparecerem corretamente) é parte válida da estratégia. Os testes cobrem:

- Theme: cores, sizes, validacao
- WidgetBase: ciclo de vida via FakeWidget mock, todos os mutators, idempotency, persist callback
- AppTickEmitter: construtor, Pulse() (não depende de SetTimer real), Start/Stop com idempotency

Não cobrem (e não tentam cobrir):

- Que a Gui aparece com as dimensões certas em uma tela real
- Que o texto fica legível
- Que os controles estão nos lugares certos visualmente

Isso é verificado a olho.

**Nota da 6.2 — reincidência da convenção 17.5:**

A 6.2 caiu três vezes na convenção 17.5 (sombreamento case-insensitive de classe por variável local) durante o desenvolvimento, mesmo com a tabela de proibidos já documentada:

1. `appSettings := AppSettings.Defaults()` em helpers de teste — variável local sombreia a classe.
2. `appSettings` como **parâmetro de construtor** dos próprios widgets (`TimerWidget`, `ZoneWidget`) — a expressao `appSettings is AppSettings` virou `appSettings is appSettings`, retornando "expected class but got an AppSettings (instance)".
3. `progress := Progress.Empty()` em helpers `_HydrateRoute`/`_HydrateCampaignWithStep` — mesma classe de bug.

Lição reforada: a regra não se aplica só a variáveis locais dentro de métodos. **Parâmetros de construtor são variáveis locais do escopo `__New`** e também sombreiam classes. A convencão adotada é: parâmetro/local com nome de classe sempre recebe apelido (`cfg`, `pr`, `stepObj`) — nunca o nome direto.

Uma estratégia complementar que ajudou: **rodar testes cedo e em rajadas**. Cada round expunha apenas a primeira camada de bugs (porque todos os helpers falhavam na mesma linha), e iterar com fixes mostrou as camadas subsequentes.

**Nota da 6.3 — SummaryWidget e o gap dos eventos do sync_engine v2:**

A 6.3 trouxe à tona uma diferença importante entre os widgets: a maioria reage a eventos já publicados pelo sistema atual (TimerService, CampaignService, LogMonitorService), mas o **SummaryWidget depende de fatos que só serão publicados quando o sync_engine v2 vier (Fase 5.x)**. Especificamente: contadores de bosses, mapas e loading time só podem ser incrementados quando `Evt.SplitRecorded` for publicado pelo sync_engine — hoje no v2 ninguém grava splits.

Decisão: **SummaryWidget existe e funciona parcialmente**. Inicializa todos os contadores em zero, atualiza apenas `deaths` em tempo real (via `Evt.DeathDetected` que já é publicado pelo LogMonitorService), e apresenta `bosses/maps/loading` como zero. Quando o sync_engine v2 chegar, basta adicionar mais `bus.Subscribe` no construtor do SummaryWidget — o resto da arquitetura já está pronta.

Isso é deliberadamente diferente de "adiar o widget". Adiar significaria não ter SummaryWidget no overlay quando a 6.6 (WidgetManager) chegar — o usuário não veria a opção no painel. Implementar parcialmente significa: o usuário já vê o widget desde a 6.3, já pode posicioná-lo, já vê contador de deaths funcionando, e quando o sync_engine v2 ligar os outros eventos, os outros contadores "acordam" sem nenhuma alteração de UI. Princípio: **walking skeleton vale mais do que módulo perfeito que demora**.

O trade-off é que durante o intervalo entre 6.3 e Fase 5.x o usuário vê zeros que não sobem em uma run real. Isso é documentado com um TODO claro no `summary_widget.ahk` e a expectativa é razoável: o usuário está rodando o `speedkalandra_dev.ahk` em paralelo ao legado durante toda a transição.

**Nota da 6.4 — mapeamento status→cor no XpWidget:**

O `XpRules.Calculate()` retorna `XpPenaltyInfo` com campo `color` já preenchido como hex (`"22C55E"`, `"F59E0B"`, `"EF4444"`). Mas o XpWidget **ignora** esse campo e mapeia o `status` (`"ok"/"limit"/"penalty"`) para nomes do `Theme` (`"green"/"amber"/"red"`).

Motivo: as cores do XpRules são um pouco diferentes das do Theme (`22C55E` vs `4ADE80` para verde, por exemplo) — detalhe histórico do legado. Centralizar tudo no Theme garante que mudar a paleta global afeta o XpWidget também, sem precisar lembrar de tocar em mais um arquivo. É levemente menos eficiente (uma indireção a mais), mas o ganho de manutenção vale.

**Nota da 6.4 — PerfWidget herdou o padrão walking skeleton da 6.3:**

O PerfWidget calcula `gameplayPct/loadingPct` a partir de `_actLoadingMs` — um Map<actIndex, ms> que hoje está sempre vazio. Quando o sync_engine v2 publicar `Evt.SplitRecorded` com `actIndex` e `transitionMs`, basta um `bus.Subscribe` adicional que faz `this._actLoadingMs[actIdx] := this._actLoadingMs.Get(actIdx, 0) + transitionMs`. Mesmo princípio do SummaryWidget: implementação parcial é superior a adiamento porque o WidgetManager (6.6) já vai listar todos os 8 widgets, smoke test já mostra todos juntos, e a "ligação final" na Fase 5.x é trivial.

**Nota da 6.5 — ActionsWidget e o padrão de testabilidade de cliques:**

O ActionsWidget é o único widget interativo da Fase 6 — 4 botões que publicam Commands no bus quando clicados. Isso introduz uma dificuldade nova: como testar comportamento de clique sem GUI real? AHK v2 dispara `Click` events em `Text` controls com `OnEvent`, mas em testes não temos como simular o clique programaticamente sem instanciar Gui de verdade.

Solução adotada: **métodos públicos nomeados** (`TogglePause()`, `RequestNewRun()`, `RequestCancel()`, `OpenSettings()`) em vez de closures inline na fat-arrow do `OnEvent("Click")`. O botão chama o método via `btn.OnEvent("Click", (*) => this.TogglePause())`. Os testes chamam `widget.TogglePause()` direto e validam que o command correto foi publicado no bus via subscriber espíao.

Isso também é melhor desenho — separa **intenção** (método público que faz a coisa) de **trigger** (clique de botão que ativa o método). Outros triggers podem ser adicionados sem refactor: hotkey global, comando via outro widget, chamada programática do composition root — todos chamam o mesmo `TogglePause()`. O widget expõe ações como API; botões são apenas uma das formas de aciona-las.

**Também importante**: o widget não decide o que `TogglePause` significa — ele só publica `Commands.TimerToggleRequested`. Quem decide entre start/pause/resume é o subscriber do Command (composition root, em fase futura). Mantém o widget burro e o estado centralizado no service. Esse padrão de "command-as-intent" é o mesmo de toda a Fase 4: UI publica intenção, service traduz em ação.

**Nota da 6.6 — separação WidgetManager / HoverHideService:**

A 6.6 entregou DOIS componentes em vez de um, embora o legado tivesse tudo num arquivo só:

- **WidgetManager** é a UI de configuração (checkbox + slider + reset por widget) e o coordenador de mudanças nos widgets (delegando aos mutators do `WidgetBase`). Não roda timer.
- **HoverHideService** é um service assíncrono que pulsa a cada 80ms verificando qual widget está sob o cursor e aplicando `WinSetTransparent`. Não conhece UI de config.

A comunicação entre eles é via bus: o WidgetManager publica `Events.HoverHideToggled` quando o usuário toggleia o checkbox global, e o HoverHideService é subscriber. Esse desacoplamento é proposital — os dois têm ciclos de vida muito diferentes (UI cria sob demanda, service roda em loop) e juntar tudo na mesma classe complica testes (precisaria mockar timer + GUI ao mesmo tempo). Separar foi mais limpo do que aderir cegamente ao legado.

**Pegadinha: regra 17.5 fez sua quarta aparição.**

A Fase 6.6 caiu na convenção 17.5 mais uma vez — o construtor do `WidgetManager` declarei `__New(bus, appSettings, ...)` com parâmetro chamado `appSettings`. AHK v2 é case-insensitive em identificadores, então no escopo do método a variável local `appSettings` sombreou a classe `AppSettings`. A validação `if !(appSettings is AppSettings)` virou `if !(appSettings is appSettings)` — que falha com a mensagem `"Expected a Class but got an AppSettings"`. Todos os 22 testes que construíam um WidgetManager quebraram com a mesma mensagem.

O fix foi cirúrgico (renomear parâmetro pra `cfg`) mas o aprendizado é sistema: **a regra 17.5 não se cura por memória, ela se cura por convenção consistente**. Após essa quarta repetição, adicionei nota explícita no header do `widget_manager.ahk` documentando o motivo do nome `cfg`. A mesma tática deve ser aplicada em qualquer arquivo futuro que receba um `AppSettings` por parâmetro — nunca chamar de `appSettings`, sempre de `cfg`.

**Marco: Fase 6 completa significa overlay 100% migrado.**

Com 891 testes a Fase 6 fechou. Os 8 widgets do legado (`overlay_widgets.ahk`, ~50KB) estão em arquivos separados, cada um testado em isolamento, todos comunicando via bus. O `WidgetManager` e o `HoverHideService` substituem o painel global do legado e o timer de hover. O que resta pra desligar o overlay legado:

1. **Composition root precisa instanciar tudo isso** — hoje os widgets são classes orfas, ninguém as cria. Isso será feito quando a Fase 5 (SyncEngine) estiver completa e o `app.ahk` puder fazer o cabeamento final.
2. **Eventos do sync_engine v2 acordam SummaryWidget e PerfWidget** — hoje esses dois widgets têm contadores estruturalmente prontos mas zerados (walking skeleton). Quando 5.4 publicar `Evt.SplitRecorded` com `segmentType` e `transitionMs`, basta um `bus.Subscribe` adicional em cada um.
3. **Smoke test visual** — ASCII icons (`>`, `||`, `R`, `X`, `*`, `x`, `B`, `M`, `T`) podem virar Unicode (`▶⏸↻✕⚙☠⚔▦⏱`) após confirmar que renderizam bem com Segoe UI no overlay real.

Nenhum desses passos depende de mais testes — a Fase 6 entrega o que prometeu e a integração final é código de cabeamento (composition root) + verificação visual.

### 17.10 — Decisões da Fase 5.2 (SyncEngine base + zona→step)

A Fase 5.2 entregou o orquestrador central que conecta `Evt.ZoneChanged` (do LogMonitorService) ao avanço de cursor da campanha. É a primeira peça do SyncEngine — propósito enxuto (só "zona→step"), mas suficiente pra ressuscitar o automático mais frequente do tracker: o cursor andar sozinho conforme o jogador entra em zonas da rota.

**Logica forward-only:** O legado tinha múltiplas vias de sync (return-de-objetivo, town-completion, soft-switch dentro de grupo, cemetery special-case, etc). A 5.2 implementa só a via mais simples — `completionMode = "next_step"` (default da maioria dos steps) — e nunca volta cursor. Zona == step passado é noop. O resto fica para sub-fases próximas (5.5 refator de `Step→CompletionRule`, 5.6 cemetery).

**Semântica chave:** se o jogador está no step atual e entra na zona objetivo desse step, **o step não completa**. Step só fecha quando o jogador entra na zona do PRÓXIMO step da rota. Isso espelha o legado e faz sentido — a definição de "next_step" é "completou ao avançar pra cena seguinte". Sem essa nuance, qualquer pisada na zona-objetivo completaria o step prematuramente.

**Travessia de fronteira de ato:** quando o jogador pula muitos passos (ex: zona = `Keth` quando cursor está em `Riverbank`, atravessando todo o ato 1), o `_AdvanceCursorTo` itera `CompleteCurrentStep` ate o cursor passar do fim do ato (`stepIdx > steps.Length`). Nesse momento detecta a fronteira e chama `GoToStep(currActIdx + 1, 1)` para entrar no próximo ato. Sem essa lógica, o cursor ficaria em estado "fora do ato" e o loop sairia sem chegar no target.

**Quem reseta o que:** SyncEngine é explicitamente responsável por `TimerService.ResetSegment()` após cada step completo (cada novo step começa com 0ms no segment timer). Mas SyncEngine **não** chama `ResetAct()` — essa é responsabilidade do composition root subscrevendo `Evt.ActChanged` (que `GoToStep` já publica quando atravessa atos). Mantém SyncEngine focado em "o que ele decide" sem tomar responsabilidades transversais.

**Guard de 100 iterações:** o loop de avanço tem teto. Se algum motivo bizarro fizer `CampaignService.CompleteCurrentStep` retornar true sem realmente avançar cursor, o teto evita travamento. Em produção normal isso nunca acontece (a maior rota tem ~150 steps no total), mas como SyncEngine vai virar a máquina central e crescer com lógica complexa nas sub-fases próximas, o guard é cheap insurance.

**API pública `TryAdvanceToZone(zoneName)`:** o `_OnZoneChanged` event handler delega tudo pro `TryAdvanceToZone`. Isso permite que testes exercitem a lógica de avanço sem precisar publicar evento, e abre a porta pra um futuro `Cmd.ForceSyncToZone` (equivalente do `ForceSyncObjectiveToCurrentZone` legado). Padrão consistente com o `Pulse()` do AppTickEmitter e o `Flush()` do WidgetManager: método público nomeado pra ação discreta, com handler de evento sendo só um disparador.

**Próximas peças:** 5.3 vai ligar `Evt.RunStarted/Completed` ao SyncEngine (precisa zerar zona conhecida em RunReset, etc); 5.4 publica `Evt.SplitRecorded` quando step completa, alimentando `SummaryWidget` e `PerfWidget` que ainda estão em walking skeleton. Então a 5.4 vai ser o ponto onde dois widgets da Fase 6 "acordam" sem nenhuma alteração de UI.

### 17.11 — Decisões da Fase 5.3 (Boss fight timing)

A Fase 5.3 entregou o segundo grande pedaço do SyncEngine: detecção automática de início/fim de luta de boss via regex no log do jogo. É a primeira fase que materializa o pagamento da arquitetura desacoplada — um widget da Fase 6 (`SummaryWidget._bossesCount`) acordou de walking skeleton sem nenhuma alteração de UI, só um `bus.Subscribe(Evt.BossDefeated)`.

**`Evt.LogLineRead` como broadcast pattern:** até a 5.2 o `LogMonitorService` era "smart" — cada linha era parseada por extractors específicos e só eventos semânticos eram publicados (`CharacterLevelUp`, `ZoneChanged`, etc). Pra 5.3 precisei de algo diferente: parsing de regex configurável POR STEP, não linha conhecida. A solução foi adicionar um broadcast bruto: a cada linha, `_ProcessLine` agora publica `Evt.LogLineRead` com a linha crua ANTES de tentar os extractors específicos. Subscribers que precisam de matching custom (BossFightTracker agora, futuros parsers de triggers complexos) consomem isso. O LogMonitor continua "burro" sobre o conteúdo — só distribui.

**`BossFightTracker` separado do split recording:** o legado misturava "detectar boss fight" com "gravar split de boss" no mesmo código (`ProcessBossTriggerLine` chamava `RecordBossFightSplit` direto). Na v2 separei: BossFightTracker só detecta e publica eventos semânticos (`BossEngaged`, `BossDefeated`). Quem grava split no CSV pode ser introduzido depois (Fase 5.4 ou outra) sem mexer no tracker. Filosofia consistente com TimerService (só mede, não sabe sobre Run) e CampaignService (só muda cursor, não cria split).

**Cancel agressivo:** o tracker subscreve `Evt.StepStarted`, `Evt.StepCompleted`, `Evt.RunReset` e `Evt.RunCancelled` pra cancelar boss fight em curso. É redundante (se step muda, a próxima linha não vai bater os mesmos triggers), mas paga em clareza: a "luta de boss em curso" é um conceito acoplado ao step que originou ela, e qualquer evento que invalida esse contexto deve invalidar o tracker. Defesa em profundidade também via check `if (this._active && this._stepId != currentStep.id)` no event handler.

**Trigger matching minimal na 5.3, completo na 5.4:** o `MatchesTrigger(line, triggerText)` estático atual suporta só dois formatos: substring case-insensitive (default) e prefixo `regex:` / `re:`. O legado tinha 7 formatos (`phrase:`, `literal:`, `text:`, `exact:`, quoted strings, OR `||`, AND `&&` stateful). Os outros entram na Fase 5.4 quando serão extraídos pra uma classe `TriggerMatcher` separada (reusável por route triggers, engage triggers, etc). Por agora, o método está inline no BossFightTracker como `static MatchesTrigger` — quando virar classe própria, basta delegar.

**bossName fallback pra mapName:** Step v2 tem prop `bossName` opcional. Se vazia, fallback pro `mapName`. Espelha exato comportamento do legado (`gBossFightBossName := currentStep.bossName != "" ? currentStep.bossName : currentStep.mapName`). Aparece no payload de `Evt.BossEngaged` e `Evt.BossDefeated`.

**SummaryWidget acordou:** o `_bossesCount` ficou desde a 6.3 esperando um publisher. Bastou adicionar `_OnBoss(data) { this._bossesCount += 1; this._RefreshDisplay() }` e o `bus.Subscribe(Events.BossDefeated, ...)` no construtor. Zero mudança de layout, zero mudança de testes existentes — só dois testes novos confirmando que o contador incrementa e que outros contadores não são afetados. Esse é o tipo de payoff arquitetural que eu vinha vendendo desde a Fase 6: widgets desacoplados acordam quando o pipeline de eventos liga, sem refactor.

**Próximas peças:** 5.4 vai introduzir o sistema completo de triggers (OR/AND/quoted/prefixos) extraído numa classe `TriggerMatcher` reusável; o BossFightTracker vai delegar pra ela em vez de ter o matching inline. 5.4 também pode (a confirmar) introduzir `Evt.SplitRecorded` que vai acordar tanto o `PerfWidget` (loading time) quanto contadores de mapa do `SummaryWidget`.

### 17.12 — Decisões da Fase 5.4 (TriggerMatcher completo)

A Fase 5.4 entregou o engine de matching de triggers que estava prometido na 5.3 — o `BossFightTracker` tinha `static MatchesTrigger` inline com só dois formatos (substring + `regex:`/`re:`), e o legado precisava de 7 prefixos, OR, AND stateful, quoted strings e escape de pontuação. Em vez de inflar o BossFightTracker, extraímos pra `TriggerMatcher` reusável. Resultado: 1008 testes (+70 vs 5.3), e o BossFightTracker ficou efetivamente como cliente do matcher (delega `MatchesSingle` via método estático). Note que `Evt.SplitRecorded` que a nota "próximas peças" da 17.11 cogitava **não entrou na 5.4** — ficou pra uma sub-fase futura junto com a refator de `CompletionRule`.

**TriggerMatcher é classe instanciável, não puro static, por causa do AND stateful:** OR é stateless (qualquer condição satisfeita ⇒ true, agora), mas AND precisa rastrear quais condições já matcharam em chamadas anteriores. O estado vive em `_andProgress: Map<key, "1,3,5">` onde a key identifica o par (step, trigger) que está sendo rastreado e o valor é a lista ordenada de índices já satisfeitos. Cada caller (BossFightTracker hoje, route engagement futuro, completion triggers) instancia um matcher próprio — não há state global compartilhado. Os métodos puros (regex/phrase/quoted/escape/etc) ficam todos `static` na própria classe, o que mantem o teste de unidade barato (não precisa instanciar pra testar `IsBoundaryChar` ou `MatchesPhrase`).

**Filosofia "uma condição real por chamada" (espelha legado):** se a linha `"Miller has been slain in glory"` chega e o trigger é `"Miller && slain"`, o legado marca apenas UMA condição por chamada — não as duas de uma vez. A justificativa é semântica: AND representa **eventos sequenciais distintos no log**, não termos coincidentes na mesma string. Aceitar match múltiplo numa linha levaria a falsos positivos (a linha "the Miller fights for slain blood" satisfaria erroneamente "Miller && slain"). O legado errou no lado conservador e a v2 preserva: `_MatchesAnd` faz `break` após o primeiro match real no PASSO 2, salvando progresso parcial pra completar em chamadas futuras.

**Processamento em 2 passos no `_MatchesAnd`:** parts vazias e comentadas (`#`) são tratadas no PASSO 1 sem `break` — todas auto-matched de uma vez, porque são parsing artifacts (sintaxe `"A && && B"` ou `"Miller && # ignorado"`), não eventos a observar. Só no PASSO 2 entra a lógica "uma por chamada com break". Isso garante que `"A && && B"` é equivalente a `"A && B"` (a vazia auto-matcha gratuitamente) sem desperdiçar uma chamada inteira só pra "consumir" a vazia.

**Split defensivo via `Chr(1)`:** `StrSplit` em AHK v2 com delimiter multi-char tem comportamento ambíguo dependendo da versão. Substituímos `&&` por `Chr(1)` (caractere single, nunca aparece em log de jogo) antes do split, garantindo determinismo. Mesma técnica vale pra futuros parsers que precisem split por sequências multi-char.

**Bug clássico encontrado: `Map.Delete()` lança em key inexistente.** O fix do último teste falhando (`Test_Matches_AND_empty_or_commented_condition_auto_matches`, caso 2 — `"Miller && # ignorado"`) revelou que `Map.Delete(key)` em AHK v2 não é silencioso: ele lança `"Item has no value"`. O código original sempre deletava ao completar o AND, assumindo que o estado tinha sido salvo na chamada anterior — mas com vazias/comentadas auto-matched, o AND pode completar em UMA ÚNICA chamada (sem nunca ter passado pelo branch que salva progresso parcial). Fix: guardar `.Delete()` com `.Has()`, mesmo padrão já usado em `ResetAndProgress` e `GetAndProgress`. Lição pra anotar: em qualquer Map mutation que dependa de estado prévio, usar `Has()` antes — diferente de `dict.pop(default)` em Python ou `Dictionary.Remove` em C#, que são tolerantes a key faltando, AHK v2 é estrito.

**BossFightTracker agora aceita `matcher` opcional como 4º arg:** o construtor passou de `__New(bus, campaign, log)` para `__New(bus, campaign, log, matcher := "")`. Se o caller não passa, o tracker continua usando `static MatchesTrigger` inline (que delega pra `TriggerMatcher.MatchesSingle` agora). Se passa, instancia AND stateful via aquele matcher externo. Permite o composition root (Fase 5.x) compartilhar uma única instância de `TriggerMatcher` entre o BossFightTracker e futuros consumidores (route engagement, completion triggers), unificando o estado AND quando isso fizer sentido. Hoje cada consumidor pode ter o seu — a flexibilidade está disponível.

**Keys distintas para boss start/end:** o BossFightTracker usa `stepId_boss_start` e `stepId_boss_end` como keys do `_andProgress`, garantindo que o progresso AND do trigger de início NÃO contamina o trigger de fim do mesmo step. Sem essa separação, um AND parcialmente satisfeito no `bossStartTrigger` poderia "vazar" pro `bossEndTrigger` quando este também usa AND com termos sobrepostos.

**7 prefixos + quoted + escape — paridade total com legado:** `regex:`/`re:` (regex case-insensitive), `contains:`/`literal:`/`text:` (substring case-insensitive, todos sinônimos pra desambiguar a intenção do autor da rota), `phrase:` (word-bounded, suporta quotes internos), `exact:` (linha inteira igual), e quoted strings sem prefixo (vira `phrase:`). Default é substring com fallback regex silencioso (se a substring não bate mas o trigger é um regex válido que casa, aceita). Unescape de `\.` `\,` `\:` `\'` `\"` `\!` `\?` `\(` `\)` `\[` `\]` permite escapar pontuação em substring/phrase sem virar regex acidentalmente — ex: `"contains:attacks\!"` matcha literalmente `"attacks!"` em vez de tratar `!` como meta de regex.

**Próximas peças (5.5):** o refator `Step → CompletionRule` discriminada vai aposentar os campos planos (`completionMode`, `bossStartRegex`, `bossEndRegex`, `engageRegex`, `completionFlag`, etc) em favor de uma rule explícita: `NextStep(zoneName)`, `BossDefeated(startTrigger, endTrigger)`, `LineMatched(triggerText)`, `Manual()`. Essa mudança vai limpar muito o BossFightTracker e o SyncEngine — eles passam a despachar sobre o tipo de rule em vez de ler campos planos com semântica condicional. O `TriggerMatcher` já está pronto pra ser consumido por qualquer rule que precise de trigger matching.

### 17.13 — Decisões da Fase 5.5 (CompletionRule discriminada)

A Fase 5.5 entregou a `CompletionRule` discriminada como tipo de domínio. **Foi fechada em duas sub-fases (5.5.1 + 5.5.2)** e não nas quatro inicialmente planejadas, por razões que ficaram óbvias depois de mergulhar na implementação atual de BossFightTracker e SyncEngine. Resultado: 1056 testes (+48 vs 5.4), Step ganhou prop `completionRule` derivada, campos planos preservados.

**Cinco variants (não quatro): `NextStep`, `TownVisit`, `BossDefeated`, `LineMatched`, `Manual`.** O plano original previa quatro, sem `TownVisit` separado. Adicionamos a quinta porque distinguir tempo gasto em cidade do tempo de gameplay é central pro objetivo do tracker — "speedrun" é sobre tempo total descontando overhead de cidade. Sem `TownVisit` no nível da rule, a Fase 5.8 (town visit timing) precisaria re-discriminar steps por outro caminho. Com ela, dispatch é direto: `if rule.IsTownVisit() { aplicar timer separado }`. O custo é mínimo (uma factory + um predicate + 4 testes), o ganho é honestidade do tipo.

**Mapeamento dos 5 `completionMode` legados pros 5 variants:**

| `completionMode`     | Rule resultante                              |
| -------------------- | -------------------------------------------- |
| `next_step`          | `NextStep(mapName)`                          |
| `town`               | `TownVisit(mapName)`                         |
| `boss`               | `BossDefeated(bossStartRegex, bossEndRegex)` |
| `objective`          | `LineMatched(completionRegex)`               |
| `objective_return`   | `BossDefeated(bossStartRegex, bossEndRegex)` (híbrido — "return" fica em CampaignService) |

`objective_return` é o caso híbrido: legado codifica "derrote o boss, depois volte pro hub" num modo só. A rule só captura a parte boss; o aspecto "voltar pra hub" continua em `CampaignService` via `completionFlag` + route group logic (que já funcionava na 4.4.3, não foi tocado).

**Lenient fallback em vez de strict validation:** quando o modo exige regex (`boss`/`objective`/`objective_return`) mas o regex está vazio na config do step, `_BuildCompletionRule` retorna `Manual()` em vez de estourar exception. Justificativas:

1. **Paridade com legado.** O `BossFightTracker` da 5.3 já faz early return em regex vazio — config incompleta nunca crashou no legado. Strict validation diverge desse comportamento.
2. **Fricção zero em fixtures de teste.** Identifiquei 13 testes existentes que setam `completionMode = boss/objective_return/objective` sem regexes (test_campaign_service tem 11, test_legacy_adapter 1, test_step 2). Strict obrigaria refactor cosmético em todos. Lenient deixa todos verdes sem nenhuma mudança.
3. **Dispatch por predicate funciona naturalmente.** Consumers fazem `if rule.IsBossDefeated() { ... }`. `Manual()` não bate nesse predicate → comportamento idêntico ao "config incompleta = não detecta boss" do legado.

O trade-off é que erros de configuração ficam silenciosos. Aceitamos porque (a) o legado já era silencioso, (b) campos planos seguem disponíveis pra debug visual, (c) testes da rule cobrem ambos os caminhos (boss com regex → `BossDefeated`, boss sem regex → `Manual`).

**Aditividade total — campos planos preservados:** `Step` mantém os 25 campos legados intactos. `completionRule` é prop ADICIONAL, derivada em `FromMap` após todos os outros campos serem populados. Essa é a mesma estratégia strangler-fig que a 5.4 usou (mas em escala bem maior): consumers novos da 5.5 em diante vão usar `completionRule`; consumers antigos seguem com os planos. A demolição dos planos fica formalmente pra **Fase 8** — e antes disso, todos os consumidores precisam ter migrado pra rule. Hoje só `Step.FromMap` (que constrói a rule) usa de fato; nenhum service consome.

**Por que paramos em 5.5.2 (e não 5.5.3/5.5.4 originalmente planejados):** mergulhando em `BossFightTracker` e `SyncEngine` durante o planejamento da 5.5.3, descobri três coisas:

1. **`BossFightTracker` lê `bossStartRegex`/`bossEndRegex` independente de `completionMode`.** O test fixture `_MakeBossActs` cria step boss com `completionMode` default (`next_step`), não `boss`. Isso reflete um caso real do legado: "boss-no-meio-da-zona" onde o step completa por zone change MAS tem boss pra cronometrar. Fazer dispatch só em `rule.IsBossDefeated()` quebraria esse caso. Manter fallback pros campos planos seria adicionar código sem ganho.

2. **`SyncEngine` faz forward search por `step.mapName` indiscriminadamente** — não dispatch por completionMode. Refatorar pra `rule.zoneName` é trocar `step.mapName` por `rule.zoneName` (mesmo valor pra `NextStep`/`TownVisit`), com fallback pra `step.mapName` em rules sem zoneName (`BossDefeated`/`Manual`). Resultado: zero limpeza, mais uma indireção.

3. **Ortogonalidade real entre completion e boss-timing.** `completionRule` é "como o step COMPLETA". `bossStartRegex/EndRegex` é "tem boss pra cronometrar nesse step". São conceitos independentes — alguns steps têm os dois (boss step), alguns só timing (boss-no-meio-da-zona), alguns só completion (next_step puro), alguns nenhum. Forçar um único conceito perderia informação.

A frase original do plano ("isso vai limpar muito o BossFightTracker e SyncEngine") foi otimista. O ganho real do `CompletionRule` aparece quando aparece um consumer com **necessidade concreta de dispatch por modo** — e o consumer concreto disso é a **Fase 5.8** (town visit timing) que vai usar `rule.IsTownVisit()` pra distinguir tempo de cidade do tempo de gameplay. Until then, a rule fica disponível mas não consumida.

**Lição pra anotar:** planos de refator que prometem "limpar muito" precisam de inspeção do código real antes de virarem trabalho. Às vezes o ganho só aparece quando o consumer concreto chega — então a entrega correta é "prepara o tipo, pára na derivação, deixa o consumer chegar quando precisar". Foi o que fiz aqui. O custo de superdimensionar (4 sub-fases) seria código no-op em SyncEngine e BossFightTracker que precisaria ser desfeito em 5.8.

**Próximas peças:** 5.6 (Cemetery special-case + route group advance) precisa que o SyncEngine entenda grupos de rota — quando o jogador entra na zona de um "gate step" do grupo, todos os steps anteriores não-feitos do grupo são auto-skipped. CampaignService já expor as queries (`GetRouteGroupSteps`, `IsRouteGroupComplete`, `GetGroupHubStepId`, `GetGroupGateStepId`) desde a 4.4.3 — a 5.6 é o cabeamento delas no SyncEngine.

### 17.14 — Decisões da Fase 5.6 (route group dispatch + hub return + boss wire-up)

A Fase 5.6 trouxe o SyncEngine à paridade com o legado para o caso mais complexo da rota: route groups (Cemetery do Ato 1 PoE2 e similares). Foi entregue em **três sub-fases coordenadas** (5.6.1 + 5.6.2 + 5.6.3) que juntas fecham o ciclo automático "boss morto → retorno ao hub → step completa". Resultado: 1084 testes (+28 vs 5.5), três helpers privados novos no SyncEngine, zero quebra em testes existentes.

**"Cemetery" é naming histórico, não conceito.** O legado já tinha um comentário explícito sobre isso (linha 339 do `sync_engine.ahk` legado: "Genérico: qualquer zona pertencente a um routeGroup conta como 'grupo de cemetery'"). Cemetery foi o primeiro/principal use case (Ato 1 PoE2 tem o Cemetery hub com 3 chaves), mas a arquitetura desde sempre operou sobre a abstração genérica `routeGroup`. Em v2 a generalização ficou explícita: as queries de grupo do CampaignService (`GetRouteGroupSteps`, `IsRouteGroupComplete`, `GetGroupHubStepId`, `GetGroupGateStepId` — tudo da 4.4.3) operam sobre qualquer grupo, não existe código "cemetery-específico".

**Decomposição em três sub-fases coordenadas:**

| Sub | Comportamento | Δ testes |
| --- | ------------- | -------- |
| 5.6.1 | Soft-switch dentro do grupo via `_TrySoftSwitchWithinGroup` | +12 |
| 5.6.2 | Hub return → `objective_return` completion via `_TryCompleteOnHubReturn` | +10 |
| 5.6.3 | Wire-up `Evt.BossDefeated` → `SetFlag` via `_OnBossDefeated` | +6  |

**A ordem dos checks no `TryAdvanceToZone` importa:**

```
1. zona == current.mapName        → noop (early return)
2. hub return + flag setada       → complete current step (5.6.2)
3. soft-switch within group       → GoToStep cursor (5.6.1)
4. forward-only                   → cascade CompleteCurrentStep (5.2)
```

Hub return roda ANTES do soft-switch porque, se o step pode completar, completar é melhor que mover cursor (semanticamente: "jogador matou boss e voltou pra hub" = step terminou, não = jogador quer ir pra hub). Soft-switch roda ANTES do forward-only porque dentro do grupo a direção é livre (jogador pode visitar bosses em qualquer ordem). Forward-only continua intacto pra steps fora de grupos — zero alteração no comportamento da 5.2 quando `currentStep.routeGroup = ""`.

**Filtros do soft-switch (5.6.1) são aditivos e evitam regressões:**

1. **Mesmo grupo** — `stepObj.routeGroup = groupId` (current's group)
2. **mapName bate** — case-insensitive via `_NormalizeName`
3. **Não é o current** — idempotência (defesa em profundidade; o early-return da regra 1 já trata)
4. **Não está done** — `IsStepDone(stepObj.id)` falso (não regredir pra step concluído)
5. **Não é gate trancado** — se `stepObj.id = gateStepId` então `IsRouteGroupComplete(groupId)` deve ser true

A regra 4 é importante: jogador caminhando entre zonas pode passar por uma zona de boss já concluído — cursor não deve regredir pra esse step. A regra 5 espelha o legado (`IsCemeteryGateStepId(targetStep.id) && !CemeteryGateOpen()`): gate só desbloqueia quando todos os bosses do grupo têm `completionFlag` setada.

**Hub return (5.6.2) tem cinco filtros e cascateia naturalmente:**

```
stepObj.completionMode = "objective_return"   (modo do step)
stepObj.completionFlag != ""                  (flag definida)
campaign.IsFlagSet(stepObj.completionFlag)    (flag SETADA)
stepObj.routeGroup != ""                      (step em grupo)
hubStep.mapName normaliza == zona             (zona == hub)
```

Quando bate, chama `CompleteCurrentStep(durationMs)` simples — a cascata pra próximo pendente já é feita por `_FindNextPending` da 4.4.3 (pula `done` e `optional`). O efeito colateral elegante é que **quando o último boss do grupo completa, o cursor pula direto pro gate** sem código extra: `_FindNextPending` parte de `bossIdx + 1`, pula bosses done, encontra o gate (que não é done) e pára. Era o que eu chamava de "5.6.3 transição pro gate" no plano original — saiu de graça com as outras duas peças.

**Wire-up automatico do BossDefeated (5.6.3) fecha o ciclo:**

```
player engaja boss → LogLineRead → BossFightTracker → Evt.BossEngaged
player mata boss   → LogLineRead → BossFightTracker → Evt.BossDefeated
                                                       ↓
                              SyncEngine._OnBossDefeated
                                                       ↓
                              campaign.SetFlag(step.completionFlag, true)
player volta pro hub → ZoneChanged → SyncEngine._OnZoneChanged
                                                       ↓
                              _TryCompleteOnHubReturn (5.6.2)
                                                       ↓
                              CompleteCurrentStep + _FindNextPending
```

Tudo via barramento de eventos. **Não existe acoplamento direto entre BossFightTracker e CampaignService** — quem coordena os dois é o SyncEngine, e ele só conhece o bus + as APIs públicas dos services. A opção de colocar o wire-up no SyncEngine (vs. um outro listener dedicado) foi por economia: o SyncEngine já era o único que conhecia step.completionFlag em contexto orquestral, e adicionar mais um service-listener pra um único método de 8 linhas seria over-engineering.

**Defesa em profundidade no `_OnBossDefeated`:** payload sem `stepId`, `stepId` desconhecido, ou step sem `completionFlag` → no-op silencioso. Em produção esses casos não devem acontecer (BossFightTracker só publica BossDefeated quando achou o step), mas a robustez é barata. Idempotência adicional vem do `CampaignService.SetFlag` que nem chega a publicar `Evt.ObjectiveFlagSet` quando o valor não muda.

**Padrões de teste consolidados na 5.6:**

- **Privates testados diretamente quando isolamento exige.** O case "soft-switch declina, forward-only assume" tornou os asserts via API pública ambíguos (`result = true` não distingue qual fluxo passou). Solução: testar `_TrySoftSwitchWithinGroup` e `_TryCompleteOnHubReturn` diretamente para os filtros de declinio, e via `TryAdvanceToZone` pra caminhos felizes. AHK v2 não enforce privacidade (leading `_` é convenção), então testar privates é legítimo quando o comportamento é difícil de isolar via API pública.

- **Custom Step inline com id válido.** `StepId.MustBeValid` exige formato `a<digit>_<digits>_<...>`; ids como `"test_step"` são rejeitados. Testes de filtros do `_TryCompleteOnHubReturn` usam `"a9_99_test_step"` por convenção (ato 9 = sentinela de teste, não existe na rota real).

- **End-to-end com múltiplos eventos publicados.** O test `Test_BossDefeated_to_hubReturn_full_cycle` exercita 5.6.3 + 5.6.2 + cascata de cursor numa sequência BossDefeated → ZoneChanged. É o teste mais valioso da 5.6 porque verifica que os três pedacinhos se compoem corretamente — é a evidência direta de que o "ciclo automático" funciona como prometido.

**Fora do escopo (deferido com intenção):**

- **Carry preservation (`SetStoredStepCarry`/`PrepareCarryForTargetStep` do legado).** No legado, quando jogador troca de boss step sem completar (soft-switch), o tempo gasto na sub-area é "guardado" no step e restaurado quando jogador volta. Isso é refinamento de timer e não bloqueia o fluxo básico — sem ele, jogador perde o tempo gasto na sub-area pendente. Vai pra 5.7 ou 5.8.

- **Manual ForceSync via UI.** Legado tem `ForceSyncObjectiveToCurrentZone()` com confirmação via MsgBox. UI v2 ainda não existe — fica pra Fase 7.

- **Edge cases legados de "zona de boss já concluído → switch pra próximo pendente".** O legado tem `SwitchCemeteryObjective` com lógica específica pra esse caso. Em v2, a regra 4 do soft-switch (não regredir pra done) bloqueia naturalmente, e o próximo zone change — quando jogador efetivamente vai pra zona certa — dispara o soft-switch normal. **A combinação das três sub-fases simples emerge o comportamento correto sem precisar do código explícito do legado.**

**Lição pra anotar:** o legado tinha `HandleCemeteryGroupSceneV2` com 80+ linhas de lógica encadeada (boss-com-flag, boss-sem-flag, gate-já-feito, gate-grupo-completo, hub-default, etc). Em v2, **três helpers ortogonais de 20-30 linhas cada** cobrem todos os mesmos casos via combinação + ordem certa de checks. Quando o código legado é emaranhado com `if-elif-else` densamente acoplados, **tente decomposição ortogonal antes de tentar tradução literal**. A decomposição deixa cada pedaço mais simples, mais testável, e a integração entre eles emerge dos invariantes (forward-only intacto, _FindNextPending já cuida de skip de done, GoToStep já publica eventos certos) em vez de precisar ser codificada.

**Próximas peças:** 5.7 (Undo coordenado) vai conectar `Cmd.UndoRequested` orquestrando os services — CampaignService já tem undo stack desde 4.4.2, mas TimerService precisa coordenar restauração de carry/segment quando undo desfaz step completion. 5.8 (Town visit timing) vai ser o primeiro consumidor concreto de `CompletionRule.IsTownVisit()` da 5.5.

### 17.15 — Decisões da Fase 5.7 (Undo coordenado via subscribe)

A Fase 5.7 fechou o ciclo de undo cross-service. CampaignService já tinha undo stack própria desde 4.4.2 (snapshots de cursor/done/flags). A 5.7 trouxe TimerService pra mesma mecanica e conectou os dois via `Commands.UndoRequested`. Resultado: 1111 testes (+27 vs 5.6), três sub-fases coordenadas, **zero acoplamento direto entre services**.

**Subscribe-based, não orchestration.** A decisão central da 5.7 foi: cada service subscreve `Commands.UndoRequested` independentemente e auto-reverte seu próprio state. **Não existe "undo coordinator"** centralizando a chamada. Justificativas:

1. **Snapshots são ortogonais.** CampaignService gerencia cursor/done/flags; TimerService gerencia bases/ticks/active. Os campos são disjuntos, então restaurar um não afeta o outro. Ordem dos handlers é irrelevante.
2. **Auto-contained services.** Cada service é dono completo do seu undo stack — `Push`, `Pop`, `Clear` ficam internos. Quem subscreve só dispara `service.Undo()`, nada mais.
3. **Scaling-friendly.** Adicionar undo em services futuros (ex: XpService no futuro?) é trivial: novo `_undoStack` interno + subscribe no construtor. Zero mudança em quem já estava.
4. **Sem god class.** Se SyncEngine fosse o orquestrador, ele teria que conhecer detalhes de undo de todos services. Vira candidato a inchar com cada nova adição. Subscribe-based mantém SyncEngine focado em zone→step dispatch.

**Decomposição em três sub-fases:**

| Sub | Responsabilidade | Δ testes |
| --- | ---------------- | -------- |
| 5.7.1 | TimerService ganha undo de bases/ticks/state | +13 |
| 5.7.2 | CampaignService + TimerService subscrevem `Commands.UndoRequested` | +6  |
| 5.7.3 | SyncEngine chama `timer.PushUndoSnapshot()` antes de cada op em CampaignService | +8  |

**Snapshot captura TUDO mutável.** TimerService.PushUndoSnapshot guarda 8 campos: `active`, `paused`, 3 baseMs (run/act/segment), 3 startTicks. **Por que tudo?** Porque no momento do undo, o consumer pode ter qualquer combinação desses (timer pausado entre push e undo, segment resetado por outra operação, etc). Snapshot parcial deixaria o state inconsistente. Como os 8 campos são todos primitivos (Int + Bool), copia direta serve — sem deep clone necessário.

**Semântica sutil de Undo em timer ATIVO.** Quando o timer está rodando, `GetRunMs() = baseMs + (clock.Now - startTick)`. O snapshot captura ambos `baseMs` e `startTick` no momento do push. Quando o undo acontece DEPOIS de tempo passar, restaurar esses dois campos não "congela" o tempo aparente — o `clock.Now` continuou andando. Resultado: `GetRunMs()` pós-undo reflete `baseMs_restaurado + (now_atual - startTick_restaurado)`, que pode ser MAIOR que o `baseMs_restaurado` puro.

Isso é **comportamento intencional**, não bug: undo restaura o STATE, não regride o relógio físico. Em UX: jogador completou step, percebeu erro, deu undo — o tempo do segmento volta a contar de onde tinha parado, não congela. É a mesma semântica do legado, e é o que o jogador espera. **Testes que verificam state interno** (ex: `_runBaseMs` voltou pra 0) acessam o campo privado diretamente; testes que verificam tempo aparente lidam com a equação completa.

**SyncEngine garante alinhamento das stacks.** A 5.7.3 acrescenta `timer.PushUndoSnapshot()` em quatro pontos do SyncEngine, cada um imediatamente antes de uma chamada que muta CampaignService:

```
_AdvanceCursorTo  -> antes de GoToStep    (act boundary)
_AdvanceCursorTo  -> antes de CompleteCurrentStep (cascade per-step)
_TrySoftSwitchWithinGroup -> antes de GoToStep
_TryCompleteOnHubReturn   -> antes de CompleteCurrentStep
```

O acoplamento aqui é mínimo: SyncEngine só chama um método público do TimerService. Stacks ficam alinhadas porque CampaignService internamente faz seu próprio `_PushSnapshot()` no início de cada um desses métodos. **Cada chamada do SyncEngine = 1 snapshot em cada stack.** Cascade de 3 completes = 3 snapshots em cada. Travessia de ato em meio a cascade = 4 snapshots (3 completes + 1 GoToStep).

**MAX_UNDO=25 alinhado com CampaignService.** Mesmo limite, mesma semântica de "trim oldest". Como as stacks crescem em paralelo (push pareado), elas também descartam em paralelo. Não existe cenário em que campaign trimou e timer não, ou vice-versa, dado que cada operação adiciona exatamente 1 em cada.

**ResetAll/ResetCampaign limpam stacks.** Tanto `TimerService.ResetAll()` quanto `CampaignService.ResetCampaign()` zeram seus respectivos undo stacks. Reset é nao-undoable (mesmo padrão do legado). Não conectei `Reset` cross-service no v2 porque cada um tem trigger próprio (RunReset events ainda não estão totalmente conectados — fica pra Composition Root da 5.1.b já fez para alguns casos, e a 5.8 vai precisar ajustar pra TimerService.ResetAll quando RunReset acontece).

**Padrões de teste consolidados na 5.7:**

- **Acesso direto a campo privado** (`svc._runBaseMs`) é legítimo quando o campo público (`GetRunMs()`) tem cálculo derivado que mascara o state interno. Caso real: `Test_Undo_restores_runBaseMs_after_advance` precisa verificar que `_runBaseMs` voltou pra 0, mas `GetRunMs()` reflete o cálculo `baseMs + (now - startTick)` que não é 0 com timer ativo. AHK v2 não enforce private (leading `_` é convenção), e isolar testes à API pública nem sempre faz sentido pra invariantes internos.

- **End-to-end test do ciclo coordenado** é o mais valioso. `Test_5_7_3_undo_command_reverts_both_services` exercita: push (via TryAdvanceToZone) → stacks crescem em paralelo → publish Cmd.UndoRequested → ambos services revertem em paralelo. Esse é o invariante que justifica toda a 5.7.

- **Cascade com múltiplos undos** prova que cada `Cmd.UndoRequested` reverte 1 nível coerente. `Test_5_7_3_multiple_undos_restore_progressively` cascateia 2 completes (Riverbank → Clearfell → Grelwood), depois faz 2 undos consecutivos e verifica que o cursor regrediu progressivamente. 3o undo é no-op (stacks vazias).

**Fora do escopo (deferido com intenção):**

- **Carry preservation (`SetStoredStepCarry`/`PrepareCarryForTargetStep` do legado).** Quando jogador troca de boss step sem completar (soft-switch), o tempo gasto na sub-area deveria ser "guardado" e restaurado quando voltar. Isso requer um `Map<stepId, ms>` no TimerService + subscriber em `Evt.StepStarted`. É refinamento de UX, não bloqueia o ciclo básico. Vai pra 5.8 ou pós-Fase-5.

- **UI undo button.** A UI v2 ainda não existe. Em produção futura, o Composition Root vai expor `bus.Publish(Commands.UndoRequested, Map())` pra ser chamado quando UI/hotkey pedir. Por enquanto testes publicam diretamente.

- **Persistência de undo stacks.** Stacks ficam em memória, perdem ao fechar app. Persistir snapshot stacks no INI traria over-engineering pra uma feature que o user provavelmente prefere zerar entre sessões de qualquer jeito.

**Lição pra anotar:** **Subscribe-based para comandos cross-service é mais escalável que orchestration.** No legado, undo era uma única função gigante que conhecia detalhes de timer + campaign + UI. Em v2, cada service é um quadrado independente que escuta o mesmo comando. Adicionar uma terceira coisa que precisa de undo (carry stack, futuro) vira: novo subscribe + novo Push/Undo interno. Zero refactor em código existente. Esse é o pay-off real do pub/sub que justifica o overhead de event bus em arquitetura limpa.

**Próxima peça:** 5.8 (Town visit timing) vai ser o primeiro consumidor concreto de `CompletionRule.IsTownVisit()` da 5.5. Distinguir tempo de cidade do tempo de gameplay é central pro objetivo do tracker ("speedrun" é tempo total descontando overhead de cidade). Carry preservation pode ou não entrar na 5.8 dependendo do escopo.

### 17.16 — Decisões da Fase 5.8 (Town visit timing) — Fase 5 fechada

A Fase 5.8 fechou a Fase 5 inteira. Resultado: 1167 testes passando (+56 vs 5.7), três sub-fases coordenadas, **um conceito de modelagem corrigido em relação ao planejado**. Decomposição:

| Sub | Responsabilidade | Δ testes |
| --- | ---------------- | -------- |
| 5.8.1 | `TownZonesRepository` lê `data/town_zones.txt`, expõe `IsTownName(zoneName)` case-insensitive com lazy-load | +20 |
| 5.8.2 | `TownVisitTracker` service: subscribe a `Evt.ZoneChanged`, abre/fecha visitas, acumula `townTotals[actIndex]` em paralelo ao timer principal | +29 |
| 5.8.3 | Testes de integração end-to-end TownVisitTracker ↔ RunStateRepository (a infra de persistência já existia) | +7 |

**Correção de design importante: detecção de cidade é por LISTA, não por completionMode.** Em planos da 5.5 (e na frase final do parágrafo 17.13) eu escrevi que "5.8 vai usar `CompletionRule.IsTownVisit()`". Isso era um equívoco que só ficou claro ao reler o legado:

- `CompletionRule.TownVisit` modela **"step completa quando jogador entra em cidade"** — é sobre COMPLETION SEMANTICS. Steps tipo `a1_05_get_to_lachlann` cuja completion é "chegar em Lachlann".
- `TownVisitTracker` modela **"tempo gasto em cidade"** — é sobre TRACKING METRIC. Quanto tempo o jogador passou em zonas-cidade durante a run, independente de qual step está ativo.

São **conceitos ortogonais**. Um step pode ter `completionMode = "town"` E ainda assim a entrada em cidade gerar uma visita rastreada. Ou um jogador pode entrar em cidade sem nenhum step ativo do tipo town (ex: voltou pra repor poções no meio de outro objetivo). A métrica de tempo em cidade é paralela e independente da rota.

Por isso a 5.8 introduz `TownZonesRepository` consumindo `data/town_zones.txt` — um arquivo texto puro com a lista explícita de cidades. É a mesma fonte que o legado usa (`gTownZones`), e mantém compatibilidade com edição manual. **Quando alguém for ler 17.13 procurando "como 5.8 usa CompletionRule", a resposta correta é: não usa.**

**TownVisitTracker como serviço novo, não extensão do TimerService.** Considerei adicionar contagem de cidade ao TimerService (ele já tem `_clock`, já sabe pause/resume). Decidi por serviço separado por dois motivos:

1. **TimerService é mecânica genérica.** Run/act/segment são conceitos abstratos de cronômetro. "Visita à cidade" é semântica de domínio do POE2 — mistura mecânica e negócio.
2. **Composability.** TownVisitTracker pode ser ativado/desativado independentemente sem mexer na mecânica do timer principal. Em uma futura UI "esconder métricas de cidade", basta desligar o tracker.

O custo é um construtor adicional + subscribe pareado — baixo, e o ganho de separação vale.

**Tracking é paralelo ao timer principal, não pausa run/act/segment.** Decisão explícita: o jogador entrar em cidade NUNCA pausa o timer principal. Tempo em cidade é métrica informativa pura, somada em `townTotals[actIndex]` mas sem efeito sobre o tempo da run/etapa. Isso espelha o legado (que tem comentário `"tempo informativo; run/etapa continuam contando pelo timer principal"`) e respeita a semântica de speedrun: tempo total é o que conta, com cidade sendo overhead diagnosticado separado.

**Snapshot do ato no Start, não no End.** Quando uma visita abre, o tracker captura `_visitActIndex` do `_currentActIndex` corrente. Mudança de ato durante a visita NÃO migra a contagem — tudo soma no ato em que a visita começou. Isso evita ambiguidade quando jogador está em cidade enquanto cursor avança (ex: AreaLevelChanged dispara ActChanged; visita ainda é "do ato anterior"). Pequeno detalhe importante porque torna o invariante TESTE de "tempo de cidade do ato N" determinístico.

**TimerPaused fecha visita; TimerStopped cancela.** Decisão que MELHORA o legado:

- **TimerPaused:** fecha a visita ativa imediatamente (soma elapsed até a pausa). Quando timer retoma, próxima `Evt.ZoneChanged` em cidade abre nova visita. Resultado: tempo pausado NÃO é contado.
- **TimerStopped:** cancela visita ativa sem somar. Tempo órfão (entre Start e Stop) é descartado — run encerrada não entra em estatísticas.

O legado tinha um bug nesse ponto: visita aberta antes de pausa continuava aberta, e quando o jogador saia da cidade depois (ainda pausado), o `ClosePhysicalTownVisit` somava o `A_TickCount - gTownVisitStartTick` cheio, incluindo tempo pausado. **Resultado:** métricas infladas se o jogador pausava em cidade. Em v2 isso está corrigido pela reação ao `Evt.TimerPaused`. Anotado explicitamente nos comentários do `TownVisitTracker` pra não virarmos esse comportamento sem intenção no futuro.

**Hydrate ignora `townVisitActive` do disco.** O `RunState` carrega `townVisitActive`/`townVisitName`/`townVisitActIndex` quando lê o INI, e o tracker poderia em tese restaurar essa visita. **Decidi explicitamente que não:** o tempo entre a última sessão e o boot é ambíguo (jogador pode ter saido da cidade, fechado o jogo, ido fazer outra coisa). Restaurar uma visita "ativa" no boot e contar o `now - startedAt_persistido` daria números absurdos. Sempre começa fresh; próxima `Evt.ZoneChanged` reabre se for cidade.

A persistência dos `townTotals` continua intacta através de sessões — o que não atravessa é a visita ATIVA. Os totais são o que importa pra métrica.

**Persistência já existia desde Fase 3.** Surpresa positiva ao implementar a 5.8.3: `RunState.townTotals` + `RunStateRepository._LoadTownTotals`/`_SaveTownTotals` já estavam prontos desde a Fase 3, quando modelei o RunState completo de uma vez (princípio: "o domínio modela o que existe, não o que está conectado"). A 5.8.3 então virou só validação do CICLO COMPLETO via testes de integração end-to-end. Sete testes que exercitam: tracker acumula → `GetTownTotals()` → `RunState` → `Repository.Save` → arquivo → `Repository.Load` → `Tracker.Hydrate`. Round-trip exato preservado, orphan removal funciona, hydrate cancela visita ativa por defesa.

**Convenção 17.5 expandida com `events`.** Durante a 5.8.2 fui mordido por um bug clássico: nomeei uma variável local `events := []` dentro de um teste, e como AHK v2 é case-insensitive, isso sombreou a referência da classe `Events` no escopo do método. Linhas seguintes que usavam `Events.TownVisitStarted` falharam com erro "Array has no property TownVisitStarted". A convenção 17.5 listava `step`/`act`/`run`/`progress`/`appSettings` como nomes proibidos. **Adicionar `events` à lista — e por extensão, `commands`, `clock`, `bus`, `cfg` quando classes correspondentes existem.** Em geral: qualquer identificador que coincide com nome de classe global no v2 vira variant ou sufixo (`evtLog`, `cmdQueue`, `busLocal`).

**Fora do escopo (deferido com intenção):**

- **CSV split por visita (`RecordTownSplit`).** O legado grava cada visita encerrada como linha em `data/splits.csv` com `segment_type="town"`. Em v2, a 5.8 acumula em memória + INI; não escreve no CSV. Vai entrar quando o `AnalyticsService` ou similar for ampliado pra consumir `Evt.TownVisitEnded` e gravar splits históricos. É trabalho de Fase 7 (Editor + Settings) ou próprio de uma 5.9 futura.

- **Carry preservation deferida desde 5.6.** Continua deferida. Não cabia em 5.7 (undo não resolve carry) nem em 5.8 (escopo de cidade, não de carry). Provavelmente vira primeira sub-fase de uma Fase 5.9 ou parte da Fase 7 quando precisar.

- **Wire-up no Composition Root.** A 5.8 montou as peças: `TownZonesRepository` instanciável + `TownVisitTracker` instanciável + `RunState.townTotals` persistido. O Composition Root da 5.1.b ainda NÃO instancia o tracker. Adicionar isso vai ser umas 5 linhas no `app.ahk` quando a Fase 6+ precisar. Não faço agora porque o tracker testado isoladamente é suficiente pra fechar a Fase 5.

**Lição pra anotar:** **Listas curadas em arquivos texto é o padrão certo pra domínios pequenos e estáveis.** Um repo de cidades poderia ter sido um `Set<string>` hardcoded, ou um `[Towns]` no INI principal, ou uma tabela em algum lugar. O legado escolheu arquivo texto plástico com `#` para comentários, e essa escolha aguenta perfeitamente o caso de uso: a lista é pequena (4-10 zonas), mutável manualmente, versão-controlável via Git, editável sem ferramenta. Manter o formato em v2 preservou compat e simplificou o `TownZonesRepository`. Quando o domínio for pequeno e raramente mudar, não sobre-engenheirar com schemas.

**Próxima fase:** **Fase 5 fechada**. As próximas fronteiras são (a) Fase 7 (Editor + Settings GUI) que vai precisar consumir muito do que foi construído na Fase 4-5, e (b) Fase 8 (Demolição do legado) que começa a deletar `src/` arquivo por arquivo conforme `src_v2/` cobre tudo. Antes da 8, talvez faça sentido uma 5.9 com itens deferidos (carry preservation, CSV split por visita, wire-up final do Composition Root) ou consolidar isso na Fase 7. Decisão pra próxima sessão.

### 17.17 — Decisões da Fase 5.9 (Carry preservation — adendo de itens deferidos)

A 5.9 foi aberta DEPOIS da Fase 5 ter sido oficialmente fechada na 5.8. É um adendo enxuto que recolheu uma pendência herdada desde a 5.6 e que a 5.7 e 5.8 deferiram explicitamente: **carry preservation** (`SetStoredStepCarry`/`PrepareCarryForTargetStep` do legado). Resultado: 1202 testes passando (+35 vs 5.8), três sub-fases, **escopo deliberadamente pequeno** pra não virar Fase 6.

**Por que 5.9 e não Fase 7 ou ad-hoc?** Carry preservation é funcionalidade de RUNTIME (TimerService + SyncEngine), não de UI. Colocá-la na Fase 7 (Editor + Settings) misturaria preocupações. Colocá-la dentro de outra fase já fechada apagaria história. Numerar como 5.9 mantém: (a) provênia clara dela como adendo da Fase 5, não como sub-fase planejada do começo; (b) fica imediatamente óbvio em qualquer commit/teste qual fase introduziu; (c) deixa Fase 7 limpa pra UI.

**Decomposição em três sub-fases:**

| Sub | Responsabilidade | Δ testes |
| --- | ---------------- | -------- |
| 5.9.1 | TimerService ganha state + API de carry, snapshot/undo cobre carry | +19 |
| 5.9.2 | SyncEngine integra ciclo no soft-switch + cleanup após complete | +8  |
| 5.9.3 | Testes end-to-end TimerService ↔ RunStateRepository (a infra já existia) | +8  |

**Semântica do carry: dois conceitos disjuntos no mesmo service.** Decisão central da 5.9.1 foi modelar carry como DOIS campos:

1. **`_activeStepCarryMs`** — carry HERDADO no segment atual. Adicionado a `GetSegmentMs()` pra dar o tempo TOTAL no step incluindo visitas anteriores. Zerado por `ResetSegment`/`ResetAll`/`PrepareCarryForStep` quando o step alvo não tem carry guardado.
2. **`_stepCarryMap`** — Map<stepId, ms> com carry GUARDADO por step. Usado quando jogador faz soft-switch entre boss steps de um route group e quer recuperar tempo investido depois.

A distinção evita o erro do legado, onde `gActiveStepCarryMs` + `gStepCarryMs[stepId]` eram tratados em funções diferentes (`GetCurrentStepSplitElapsedMs` vs `SetStoredStepCarry`) sem clareza de qual era "ativo" vs "guardado". Em v2: `_activeStepCarryMs` é apenas o atual ativo; o map contém só carry GUARDADO esperando ser consumido. `PrepareCarryForStep(stepId)` é a transição (transfere do map pro ativo, removendo do map). `ResetSegment` zera o ativo mas não toca no map.

**`ResetSegment` ZERA `_activeStepCarryMs`. Sempre.** Decisão não-óbvia. A alternativa seria ResetSegment preservar o carry ativo. Razões pra escolher zerar:

- **Caso comum vence mais.** Em 90% das chamadas (cascade complete, act boundary, hub return), não existe carry pra preservar. Zerar é corretude.
- **Quando QUEREMOS preservar (soft-switch), o caller faz explícito.** SyncEngine guarda o `GetSegmentMs()` ANTES do reset via `SetStepCarry`. O fluxo correto é: `SetStepCarry(origin.id, GetSegmentMs())` → `GoToStep` → `ResetSegment` → `PrepareCarryForStep(target.id)`. Quatro passos explícitos > comportamento mágico.
- **Erros são detectáveis.** Se alguém esquecer de chamar `SetStepCarry` antes do reset em soft-switch, o carry vira 0 e o teste de "voltar pra step preservado" falha imediatamente.

**SyncEngine é o único orquestrador.** TimerService NUNCA chama `SetStepCarry` ou `PrepareCarryForStep` por iniciativa própria — é puramente reativo. Toda a lógica de "quando guardar/restaurar" está em SyncEngine, especificamente em:

- `_TrySoftSwitchWithinGroup` — 4 passos do fluxo acima
- `_AdvanceCursorTo` (cascade complete) — `ClearStepCarry` após cada `CompleteCurrentStep`
- `_TryCompleteOnHubReturn` — `ClearStepCarry` após `CompleteCurrentStep`

O `ClearStepCarry` após complete é cleanup defensivo. Se o step foi alvo de soft-switch antes (carry guardado no map) E depois completou por outro caminho (cascade, hub return), o carry no map fica órfão. Limpar evita: (a) ressuscitação de tempo morto se o step for revisitado depois (não deveria, mas defesa em profundidade), (b) bytes desperdiçados na persistência.

**Snapshot do undo INCLUI carry. Deep clone do Map.** A 5.7.1 já capturava bases + ticks + active/paused. A 5.9.1 estendeu pra incluir `_activeStepCarryMs` + clone do `_stepCarryMap`. Sem isso, undo de soft-switch revertia cursor mas não o carry guardado — jogador faria undo e o tempo investido em boss_a continuaria "guardado" pra um futuro retorno que nunca ia acontecer (vidas paralelas no carry map).

O clone é raso (Map<stepId, ms> com keys+values primitivos), mas é NECESSÁRIO porque AHK Map é referenciado por padrão. Sem clone, `Push` salvaria a referência ao mesmo Map e subsequente `SetStepCarry` mutaria o snapshot. Anotado explícito em comentário do `PushUndoSnapshot`.

**Persistência já existia desde Fase 3 (de novo).** Padrão que se repete: `RunState.activeStepCarryMs` + `RunState.stepCarryMs` + `_ParseCarryMap`/`_FormatCarryMap` em `RunStateRepository` já estavam prontos desde a Fase 3, quando modelei o RunState completo. A 5.9.3 então virou só validação de ciclo via 8 testes de integração end-to-end. **Princípio reafirmado:** modelar domínio completo de uma vez paga dividendos quando a UI ou lógica começa a usá-lo — e pode ser que você já tenha o que precisa sem perceber.

**Hydrate com parâmetros opcionais nomeados.** A assinatura do `Hydrate` da Fase 4 era `Hydrate(runMs, actMs, segmentMs)`. Acrescentar carry obrigatoriamente quebraria todos os call sites. Solução: parâmetros opcionais com default seguro:

```ahk
Hydrate(runMs := 0, actMs := 0, segmentMs := 0, activeCarryMs := 0, carryMap := "")
```

Callers existentes continuam funcionando exatamente igual. Caller novo (Composition Root no boot) passa todos os 5. Filtro de `carryMap` (rejeita ms<=0 ou stepId vazio) acontece dentro do Hydrate — RunStateRepository pode passar Map sujo sem perigo.

**Cenário realista preservado em teste end-to-end.** O último teste da 5.9.3 (`Test_softSwitch_state_survives_persistence`) é o mais valioso da fase. Simula:

1. Jogador faz soft-switch boss_a → boss_b (10s preservados)
2. App fecha (Save)
3. App abre (Load + Hydrate)
4. Jogador volta pra boss_a (PrepareCarryForStep)
5. Carry de 10s ativo de novo no segment

Isso prova que toda a cadeia funciona: TimerService API + RunState campo + RunStateRepository serialização + ParseCarryMap. Um único teste cobre 4 camadas. É o tipo de teste que justifica o overhead de testes integração.

**Fora do escopo (continua deferido):**

- **CSV split por visita de cidade** (`RecordTownSplit` do legado). Vai pra Fase 7 ou à medida que `AnalyticsService` precisar.
- **Wire-up final do Composition Root.** O `app.ahk` ainda não instancia `TownVisitTracker` ou `TownZonesRepository`, e não passa `townTotals`/`carryMap` no Hydrate. Adicionar isso serão ~10 linhas na Fase 7 quando a UI começar a consumir esses estados. Mantido fora deliberadamente porque sem UI consumindo, não há impacto visível — e a 5.9 quer permanecer enxuta.

**Lição pra anotar:** **Adendos numerados (5.9 após 5.8 fechada) são uma ferramenta válida quando: (a) o trabalho é pequeno, (b) cabe na mesma fase semanticamente, e (c) história importa.** Alternativas pioram: bagunçar uma fase já fechada (apaga história), abrir uma fase nova só pra isso (over-engineer), enfiar em fase futura tematicamente diferente (mistura escopo). 5.9 é honesta sobre o que é: "isso era pra estar na 5, mas saímos da 5; voltei pra fechar".

**Próxima fase real:** Fase 7 (Editor + Settings GUI) ou Fase 8 (demolição do legado). Decisão pra próxima sessão.

### 17.18 — Decisões da Fase 5.10 (Wire-up final do Composition Root)

A 5.10 fechou uma dívida acumulada que vinha desde a 5.2: o `SpeedKalandraApp` ficou parado na 5.1.b enquanto Fases 5.2-5.9 construíam services novos (`SyncEngine`, `BossFightTracker`, `TownVisitTracker`, `TownZonesRepository`, `TriggerMatcher`) sem integrá-los ao Composition Root. Cada um era testado isoladamente, mas o entrypoint dev (`speedkalandra_dev.ahk`) bootava um app que **não tinha SyncEngine, não tinha BossFightTracker, não tinha tracker de cidade**. Resultado: 1213 testes passando (+11 vs 5.9), `speedkalandra_dev.ahk` boota app v2 plenamente funcional pela primeira vez.

**Por que essa dívida acumulou.** Decisão consciente — cada sub-fase 5.2 a 5.9 manteve foco em entregar SEU pedacinho com testes isolados, sem precisar atualizar o cabeamento global a cada vez. Isso preservou velocidade: cada sub-fase tinha entregas claras e rápidas, sem "e também precisa atualizar o app.ahk" como tax overhead. Mas chegou um momento em que ignorar a dívida virava pior: a 5.9 fechou e não havia ninguém chamando carry preservation; a 5.8 fechou e ninguém chamava townTracker. Antes de Fase 7 (UI) ou Fase 8 (demolição), tinha que zerar.

**Decomposição em duas sub-fases (não três, conforme proposto inicialmente):**

| Sub | Responsabilidade | Δ testes |
| --- | ---------------- | -------- |
| 5.10.1 | Instanciação + wire-up no `app.ahk` + entrypoint dev atualizado | +5 |
| 5.10.2 | Hydrate completo no Start + Persist completo no Stop + round-trip end-to-end | +6 |

Na prática fiz tudo numa só passada — fase mais pequena que parece dar pra dividir. As sub-fases são organização de **ESCOPO**, não de **commits**.

**`RunService.Hydrate` repassa carry pro timer (mudança chave da 5.10.2).** A assinatura externa de `RunService.Hydrate(runStateObj)` não mudou — mas internamente agora repassa `runStateObj.activeStepCarryMs` + `runStateObj.stepCarryMs` pro `TimerService.Hydrate`. Justificativas:

- **RunService já era o coordenador do TimerService no boot.** Adicionar carry ao mesmo lugar mantém a coordenação num lugar só.
- **Backwards-compat preservada.** TimerService.Hydrate já tinha params opcionais com defaults seguros desde 5.9.1, então passar 5 args não quebra ninguém.
- **Alternativa rejeitada:** `app.ahk` chamar `runService.Hydrate(rs)` E DEPOIS `timer.Hydrate(...)` separadamente. Ruim porque timer receberia Hydrate 2x e a ordem importa muito (segundo Hydrate sobrescreve o primeiro). Acumular acoplamento no app.ahk.

**`app._PersistFinalState` como agregador de captura final.** O padrão que já existia desde a 5.1.b: cada service eh dono do seu estado em runtime, mas no momento de persistir, `app.ahk` captura tudo num `RunState` antes de chamar `runService.Persist()`. A 5.10.2 estendeu o mesmo padrão:

```ahk
rs := this.runService.GetRunState()
rs.objectiveFlags    := this.campaign.GetObjectiveFlags()      ; 5.1.b
rs.activeStepCarryMs := this.timer.GetActiveStepCarryMs()       ; 5.10.2
rs.stepCarryMs       := this.timer.GetStepCarryMap()            ; 5.10.2
rs.townTotals        := this.townTracker.GetTownTotals()        ; 5.10.2
rs.currentZoneName   := this.syncEngine.GetCurrentZoneName()    ; 5.10.2
this.runService.Persist()
```

Isso é elegante porque mantém a regra: **services são donos do seu state em memória, RunStateRepository é dono da serialização, e o Composition Root é dono da costura final**. Nenhum service precisa conhecer o RunState como um todo — cada um expõe seus getters, e o app.ahk junta no momento certo.

**Ordem de instanciação importa (e é explícita).** No `__New`:

1. Core (log, clock, bus)
2. IO primitives (IniFile, CsvFile)
3. Repositorios (incluindo TownZonesRepository)
4. Services Fase 4 (timer, runService, campaign, xp, analytics, logMonitor)
5. **Services Fase 5.10:** TriggerMatcher → BossFightTracker (recebe matcher) → TownVisitTracker → SyncEngine
6. AppTickEmitter
7. WireEventHandlers

A ordem foi escolhida pra: (a) TriggerMatcher antes de BossFightTracker porque o segundo recebe o primeiro injetado; (b) Trackers que SUBSCREVEM (BossFightTracker, TownVisitTracker) antes do SyncEngine que pode triggar publicações indiretas via `campaign.GoToStep`; (c) WireEventHandlers por último pra garantir que todos services já existem quando handlers do app subscrevem.

Adicionei comentário explicito na implementação: "Ordem importa: TriggerMatcher antes do BossFightTracker (que o recebe injetado), services que subscrevem antes do SyncEngine."

**INI/CSV separados no entrypoint dev.** O `speedkalandra_dev.ahk` agora aponta:

```
mainIni:    poe2_tracker_v2.ini       (vs poe2_tracker.ini do legado)
splitsFile: data/splits_v2.csv         (vs data/splits.csv do legado)
deathsFile: data/deaths_v2.csv         (vs data/deaths.csv do legado)
routeIni:   data/campaign_route.ini    (compartilhado)
townZones:  data/town_zones.txt        (compartilhado)
```

Decisão pragmática: durante o período até a Fase 8 (demolição), os dois mundos coexistem. Compartilhar INI/CSV de runs viraria caos (legado escreveria, v2 leria estado parcial; v2 escreveria, legado leria estado de outra arquitetura). Separar permite rodar os dois lado-a-lado em paralelo sem cruzar fios. `campaign_route.ini` e `town_zones.txt` são estrutúrais (configuração do jogo, não estado de run) então são compartilhados sem perigo.

Na Fase 8, quando o legado for removido, `_v2` sai dos nomes — a v2 vira o tracker em produção.

**Smoke test manual agora vivo.** Pela primeira vez desde a Fase 1, o `speedkalandra_dev.ahk` boota um app que TEM tudo o que precisa pra realmente funcionar:

- `LogMonitorService` lê Client.txt e publica eventos
- `SyncEngine` reage a `Evt.ZoneChanged` e avança cursor
- `BossFightTracker` reage a `Evt.LogLineRead` e detecta lutas
- `TownVisitTracker` reage a `Evt.ZoneChanged` e acumula tempo de cidade
- `RunService` + `TimerService` + `CampaignService` + `XpService` mantêm state em memória
- `_PersistFinalState` no Stop grava tudo no INI v2

Faltam peças de UI (widgets ainda não renderizam visíveis pq composition root não instancia eles — isso é outra dívida que vai ser fechada na Fase 7) e a costura final de splits CSV (deferida). Mas o backbone está vivo, e é a primeira vez que dá pra **rodar uma run de teste no jogo e ver o app v2 reagindo a eventos reais**.

**Padrão de teste do Composition Root maduro.** A 5.10 reusou o helper `_MakeConfig` da 5.1.a/b que cria tmpDir + paths isolados. Adicionei `townZonesFile` ao default. Cada teste:

1. Cria `cfg` via `_MakeConfig()` (tmpDir + paths isolados)
2. Pre-popula INI via `_SeedMainIni(cfg, settings, progress, runState)` se quiser hydrate state
3. Instancia `SpeedKalandraApp(cfg)`
4. Asserta sobre comportamento (instanciação, hydrate, persist, round-trip via boot1+boot2)
5. `_Cleanup(cfg)` no `finally` deleta tmpDir

Round-trip via 2 boots (boot1 muta state + Stop, boot2 boota e lê estado preservado) virou padrão consagrado pra validação de persistência ponta-a-ponta. Quatro testes na 5.10.2 usam esse padrão: `Test_5_10_App_Stop_persists_carry`, `Test_5_10_App_Stop_persists_townTotals`, `Test_5_10_App_Stop_persists_currentZoneName`, e o crown jewel `Test_5_10_App_carry_softSwitch_round_trip_via_app` (cenário realista de soft-switch atravessando boot).

**Fora do escopo (continua deferido):**

- **CSV split por visita de cidade** (`RecordTownSplit` do legado). Não entrou na 5.10. Estimativa: ~5-10 linhas no `app.ahk` que subscreve `Evt.TownVisitEnded` e chama `runRepo.AppendSplit(...)`. Vai pra Fase 7 ou ad-hoc.

- **Acordar `SummaryWidget`/`PerfWidget` totalmente via `Evt.SplitRecorded`.** SyncEngine ainda não publica esse evento (sub-fase 5.4 originalmente cogitava, deferido). Quando publicar (em alguma fase futura), os dois widgets ganham contadores de mapas/bosses + transitionMs. Hoje os dois widgets estão em walking skeleton parcial (deaths funciona via DeathDetected, resto fica zero).

- **Composition root instanciar widgets.** Widgets são classes órfas — não aparecem no overlay. Vai entrar na Fase 7 (UI consumindo).

**Lição pra anotar: Dívida de wire-up acumula silenciosamente. Reservar uma sub-fase explicita pra fechar antes de mudar fase grande é más prática que tentar fechar incrementalmente.** A alternativa — atualizar `app.ahk` ao final de cada sub-fase 5.2-5.9 — teria adicionado overhead considerável a cada entrega (testes do composition root quebrando, refactor pequeno por vez), provavelmente diluindo o foco de cada sub-fase. **Acumular até ter massa crítica e fechar de uma vez funcionou melhor**: 11 testes novos cobrem TODAS as integrações de uma só vez, com round-trip end-to-end que valida a costura inteira.

Esse padrão requer disciplina: a dívida tem que SER VISTA, não esquecida. Anotei explícito em cada "Próximas peças" de cada sub-fase desde a 5.6 que faltava wire-up. A 5.10 é a parte do plano onde a dívida é paga, não uma surpresa de última hora.

**Próxima fase real:** Fase 7 (Editor + Settings GUI) ou Fase 8 (demolição do legado). Antes da 8, ainda pode fazer sentido um adendo enxuto pra acordar widgets e instanciação de UI no composition root — mas isso é escopo de Fase 7 mesmo. **Decisão pra próxima sessão.**

### 17.19 — Decisões da Fase 7.1 (Wire-up de widgets no Composition Root)

A 7.1 é onde os 8 widgets criados nas fases 6.2-6.6 finalmente **aparecem no overlay**. Até então eram classes órfãs: testadas isoladamente com `FakeBus`/mocks, mas o Composition Root não instanciava ninguém. Resultado: 1223 testes (+10 vs 5.10), `speedkalandra_dev.ahk` boota e o overlay aparece visualmente. Smoke test ficou ainda mais real: agora dá pra ver o timer rodando, a zona mudando, mortes acumulando — v2 vivo na tela.

**Por que widgets são instanciados em `Start()`, não no construtor.** Cada widget recebe `OverlayPosition` como argumento de construtor (não pode ser ""). A `OverlayPosition` vem de `appSettings.overlay.positions[widgetId]`, que só conhecemos depois de `cfg = settingsRepo.Load()`. Como o construtor do app não tem `cfg` (e não deveria ter — boot deve ser preço de Start), instanciamos widgets em Start.

Isso difere dos services Fase 4-5: lá, services são instanciados no construtor com `_state := Empty()` e Hydrate substitui depois. **Widgets não seguem esse padrão porque `OverlayPosition` faz parte da identidade construtiva, não do estado.** Um widget sem position válida não tem como ser construído — a posição influencia tamanho da Gui, fonte, padding, layout dos controles internos. Diferente de um service como CampaignService que pode existir vazio sem rota carregada.

Consequência: testes que verificam estado pré-Start (`Test_7_1_App_widgets_not_instantiated_before_Start`) checam `app.widgets == ""` (não um Map vazio). É explícito: campo "" significa "ainda não construído", Map vazio significaria "construído mas vazio" (que é estado inválido pra widgets).

**Headless mode pra testes** (`cfg["headless"] := true`). Widgets, ao serem `Show()`-ados, criam `Gui` reais do AHK — janelas que aparecem na tela. Em testes, isso polui o ambiente: cada teste deixa janelas órfãs, atrapalha visualização do output, possivelmente causa flicker. A flag `headless` corta a parte visual do `Start()` mas mantém a parte estrutural:

```ahk
if !this._headless
{
    for _, w in this.widgets
        try w.Show()
    this.hoverHide.Start()
}
```

O construtor de cada widget não cria Gui (só `Show()` cria) — então instanciar em headless é seguro. Isso permite testar TUDO menos o pixel: instanciation, registry, subscriptions via bus, hydrate de state, persistencia round-trip.

Default em `_MakeConfig()` dos testes é `headless: true` pra preservar TODOS os 30+ testes da 5.1.a/b/5.10 sem alteracao. Em produção (`speedkalandra_dev.ahk`), `headless: false`. Padrão consagrado: testes podem inspecionar o que fariam diferentemente em produção sem precisar mockar o framework de GUI.

**`_GetPositionOrDefault` injeta default na `cfg.overlay`.** Quando `appSettings.overlay.GetPosition(widgetId)` retorna "", o helper:

1. Pega o default de `WidgetManager.DefaultLayout()`
2. Faz `cfg.overlay.SetPosition(widgetId, default)` — INJETA na overlay
3. Retorna o default

O passo 2 é essencial. Se só retornasse o default sem injetar, widget e cfg ficariam **dessincronizados**: widget mutaria sua position (que é referencia ao default original), `onPersist` salvaria cfg.overlay, mas cfg.overlay não tinha entry pra esse widget. No proximo boot, position do widget seria perdida.

Injetação garante: cfg.overlay tem entry pra cada widget; widget recebe a MESMA referência que está em cfg.overlay; mutações do widget mudam cfg via aliasing; persistência funciona automaticamente. É a mesma técnica de "shared mutable reference" que `RunService` usa pra `runState.objectiveFlags` (campaign service e RunState compartilham o mesmo Map). Convencionado desde a Fase 5.1.b.

**`onPersist` callback compartilhado entre 8 widgets.** Em vez de 8 callbacks distintos (um por widget), criamos UM `onPersist := () => this.settingsRepo.Save(this._appSettings)` e passamos pra todos. Justificativas:

- **Semanânticamente todos fazem a mesma coisa**: salvar AppSettings (que contém a overlay completa).
- **Menos closures = menos referências presas no this** — pequena economia mas legível.
- **Se um dia mudar o que persistir significa, muda num lugar só.**

É a primeira vez no projeto que reaproveitamos um callback assim entre vários construtores. Convencionar: **se vários componentes do mesmo wiring fazem a mesma coisa em resposta ao mesmo trigger, criar um callback compartilhado em vez de N cópias.**

**Initial zone do ZoneWidget vem do SyncEngine, não do RunState diretamente.** Poderia-se passar `runState.currentZoneName`, mas o SyncEngine já tinha sido hidratado com esse mesmo valor antes do `_InitWidgets`. Pegar de `syncEngine.GetCurrentZoneName()` é mais consistente: o widget vê o que o resto do sistema vê, não um snapshot do disco que pode estar defasado.

Caso benéfico: se uma sub-fase futura adicionar transformacao de zona no Hydrate (ex: alias resolution, normalization), o widget pega já transformada.

**AHK v2 não tem nested functions em métodos** (reforço crítico). Tentei escrever:

```ahk
_InitWidgets(cfg)
{
    getPos(widgetId) {    ; <-- nested function: ILEGAL em AHK v2
        ...
    }
    this.widgets["timer"] := TimerWidget(this.bus, getPos("timer"), ...)
}
```

Não compila. AHK v2 só aceita funções top-level ou métodos de classe. Solução: extrair pra método privado:

```ahk
_InitWidgets(cfg)
{
    this.widgets["timer"] := TimerWidget(this.bus, this._GetPositionOrDefault(cfg, "timer", defaults), ...)
}

_GetPositionOrDefault(cfg, widgetId, defaults)
{
    ...
}
```

**Adicionar ao 17.5 (convenções AHK v2):** quando precisar de helper local em método, NUNCA tente nested function — extraia pra método privado da classe (mesmo que use só dentro de um método). Fat-arrow `(x) => expr` funciona pra one-liners; multi-statement helpers requerem método.

**Ordem do `Stop()` foi ajustada.** A sequência ficou:

1. Publica `Evt.AppStopping` (subscribers consultam state vivo)
2. Para `tickEmitter` (subscribers param de receber Tick — widgets congelam visualmente)
3. Para `hoverHide` (Fase 7.1)
4. Hide widgets se !headless (Fase 7.1)
5. Para `logMonitor` (eventos do log param)
6. `_PersistFinalState` (salva tudo no disco)
7. Publica `Evt.AppStopped`

A ordem importa: Tick para ANTES de Hide pra evitar widget receber Tick durante shutdown e tentar atualizar Gui que está sendo destruida. Hide ANTES de logMonitor stop é detalhe — ordem ali é indiferente, mas mantenho "UI shutdown" agrupado.

**Peças deferidas pra sub-fases futuras:**

- **Hotkeys globais (7.2):** atualmente só `Ctrl+Alt+Q` (sair) e `Ctrl+Alt+W` (gerenciar widgets) no entrypoint dev. Pause/Undo/Reset/NewRun ainda não têm hotkey. Vai pra 7.2 com bind ao bus (`Cmd.TimerToggleRequested`, `Cmd.UndoRequested`, etc).
- **CSV split por visita (7.3):** `RecordTownSplit` do legado. Quando jogador sai de cidade, escrever no `splits_v2.csv`. Pequeno (~5-10 linhas no app.ahk subscribe a `Evt.TownVisitEnded`).
- **`Evt.SplitRecorded` no SyncEngine (7.3):** SyncEngine ainda não publica esse evento — quando publicar, SummaryWidget e PerfWidget acordam totalmente (contadores de mapas/bosses + transitionMs).
- **Settings GUI (7.4):** dialog de configuração (campanha selection, hotkeys, log path, profile) — grande mas gerenciável.
- **Campaign Editor GUI (7.5):** o monstro — lista de atos+steps com add/edit/delete, route group config. Legado tem 298KB de código só pra isso.

**Smoke test ficou ainda mais real.** Até a 5.10 dá pra rodar o app e ver eventos publicados (via DebugView). A partir da 7.1 dá pra **abrir o jogo e VER o timer correndo, a zona atualizando, mortes contando** — overlay v2 aparece sobre o jogo. Faltam apenas hotkeys (7.2) pro setup ficar utilizável, e CSV split (7.3) pro SummaryWidget/PerfWidget popularem totalmente.

**Lição pra anotar: Quando uma família de componentes precisa de inicialização consistente, padronizar a família inteira de uma vez.** Se eu tivesse instanciado widgets numa sub-fase ANTES de fechar o wire-up de services (5.10), teria criado coupling: widget construido sem todos os services disponíveis, hack de injeção tardia, etc. Manter widgets como "órfãos" durante a Fase 5 e fechá-los todos juntos na 7.1 manteve a arquitetura limpa: cada widget recebe TODAS suas deps de uma vez no construtor, sem fallbacks de "e se ainda não foi instanciado".

Esse padrão ecoa a 5.10 (wire-up final de services agrupado): **acumular dívida de wire-up de uma família inteira até ela estar completa, depois fechar tudo de uma vez.** Só funciona se a dívida é visível — documentei explícito em "Próximas peças" de cada sub-fase 6.x que o wire-up faltava.

**Próxima sub-fase:** 7.2 (Hotkeys globais) — menor + independente das outras. Permite controlar Pause/Undo/Reset via teclado, deixando o setup utilizável pra play-testing real.

### 17.20 — Decisões da Fase 7.2 (Hotkeys globais + subscribers de Commands)

A 7.2 é onde o setup vira **utilizável pra play-testing real**. Até a 7.1 tínhamos overlay aparecendo, mas ninguém podia apertar Pause/Undo/Reset — eventos do log atualizavam state automaticamente, mas controle do jogador via teclado não existia. Resultado: 1255 testes (+32 vs 7.1 — 19 isolados do HotkeyService + 13 de integração no app), `speedkalandra_dev.ahk` agora traduz `^!Backspace` em Undo coordenado, `^3` em Toggle do timer, etc.

**Por que `HotkeyService` e não hotkeys hardcoded no entrypoint dev.** O entrypoint até a 7.1 tinha `^!q::` e `^!w::` hardcoded — funcionava pro shutdown e pro WidgetManager.Open mas era ad-hoc. Pra production-grade precisamos: (a) bindings customizáveis pelo user (já estavam em `AppSettings.hotkeys` desde Fase 3), (b) hotkeys serem **comandos no bus** (não chamadas diretas a services), (c) testabilidade sem hotkeys globais reais.

O HotkeyService entrega os três: lê bindings de `AppSettings.hotkeys` (Map<actionName, keyBind>), publica `Commands.*` no bus, e tem **headless mode** pra testes (mantém registry interno sem chamar `Hotkey()` real do AHK).

**Mapping action → command é explícito e parcial.** `HotkeyService.ActionToCommand` tem 8 entradas:

```
StartPause     -> Cmd.TimerToggleRequested
NewRun         -> Cmd.NewRunRequested
ResetRun       -> Cmd.ResetRunRequested
CompleteStep   -> Cmd.CompleteStepRequested
Undo           -> Cmd.UndoRequested
Settings       -> Cmd.OpenSettingsRequested
CampaignEditor -> Cmd.OpenCampaignEditorRequested
ToggleOverlay  -> Cmd.ToggleOverlayRequested
```

Mas `AppSettings._DefaultHotkeys()` define ~15 actions (PrevAct, NextAct, ForceSyncZone, Targets, GemPlanner, TestLoadingVisual, ToggleCompact). As 7 extras são **silenciosamente ignoradas** — sem warning, sem erro. Justificação: AppSettings pode conter binds de actions futuras ou legadas que não existem mais. Service não tem como saber quais são válidas no momento; ignorar bindings não-mapeadas é mais robusto que rejeitar.

Quando uma fase futura adicionar `Cmd.SwitchActRequested` com subscriber no app, basta adicionar `"PrevAct"` e `"NextAct"` ao `ActionToCommand` — zero mudança no AppSettings, zero mudança nos defaults, zero mudança no entrypoint. É uma forma de **graceful evolução**: o universo de actions cresce sem quebrar config existente.

**Subscribers de `Cmd.*` ficam no `app.ahk`, não nos services individuais.** Adicionei sete subscribers em `_WireEventHandlers`:

```ahk
this.bus.Subscribe(Commands.TimerToggleRequested, (data) => this._OnTimerToggle())
this.bus.Subscribe(Commands.NewRunRequested,      (data) => this._OnNewRunRequested())
; ... etc
```

Cada handler chama o método apropriado do service que executa a ação (`runService.NewRun()`, `timer.Start/Pause/Resume`, etc). **Por que app.ahk e não services?**

- **Services são agnósticos a quem disparou.** `RunService.NewRun()` não sabe se foi hotkey, botão do widget, ou chamada de teste. Ninguém no service deveria estar fazendo `bus.Subscribe(Cmd.NewRunRequested)` — isso amarra service a uma origem específica.
- **App.ahk é o coordenador**: traduz intenções do usuário em chamadas de método. É a fronteira entre "bus de eventos/comandos" e "chamadas diretas em services".
- **Permite lógica composta**: `_OnTimerToggle` consulta `timer.IsActive()` + `IsPaused()` pra decidir se chama Start/Resume/Pause. Service não tem essa lógica de toggling porque não conhece o conceito.
- **`_OnCompleteStepRequested` faz três coisas**: pega `segmentMs`, push undo snapshot (alinhamento com 5.7.3), chama `campaign.CompleteCurrentStep` + `timer.ResetSegment`. É sequencia coordenada — não cabe em service nenhum.

**Exceção documentada: `Cmd.UndoRequested`.** Esse command NÃO tem subscriber no app.ahk porque TimerService e CampaignService já subscrevem direto desde 5.7.2. É um padrão diferente: como undo é OPERAÇÃO DO PRÓPRIO SERVICE (cada um auto-reverte snapshot), faz sentido o subscriber estar no service. Adicionei teste explícito (`Test_7_2_UndoRequested_reverts_via_existing_subscribers`) pra garantir que o wire-up da 7.2 não quebrou esse padrão.

**Esse contraste é importante**: services subscrevem commands quando o command é sobre **manipulação do próprio state do service**. App.ahk subscreve quando o command requer **coordenação entre services** ou tradução de "intenção do usuario" pra operações concretas.

**Headless mode (mesma técnica da 7.1).** Em testes, `HotkeyService(bus, headless := true)` não chama `Hotkey()` do AHK — só popula `_bound[keyBind] := handler` internamente. Permite testar **TODA** a lógica de mapping (action conhecida vs ignorada, bind vazio, idempotência de Start/Stop) sem polluir hotkeys globais do AHK que afetariam testes seguintes ou o ambiente de desenvolvimento.

O app.ahk passa `this._headless` direto pro HotkeyService construtor:

```ahk
this.hotkeyService := HotkeyService(this.bus, this._headless)
```

Mesma flag controla widgets (Show/Hide) e hotkeys (Hotkey() real). Vale generalizar: **headless mode = "não toca em recursos globais do sistema operacional"**. Inclui GUIs do AHK e bindings de teclado. É uma fronteira clara que tende a englobar a maioria dos efeitos colaterais externos.

**`TriggerAction(actionName)` como API pública.** Adicionei método público que dispara um command associado a uma action sem precisar de hotkey real:

```ahk
app.hotkeyService.TriggerAction("StartPause")
; equivalente a apertar a tecla configurada pra StartPause
```

Usos:
- **Testes em headless mode**: única forma de testar end-to-end (hotkey → command → service) sem registrar Hotkey() real.
- **Código de menus**: "Pause" no tray menu pode chamar `TriggerAction("StartPause")` em vez de duplicar a lógica de toggle.
- **Comandos via outros channels** (futuro): se algum dia houver controle por voz, gestos, IPC — todos podem reusar `TriggerAction`.

É a primeira vez que tenho método público que duplica caminho do teclado. **Convencionar: quando service registra hooks externos (hotkey, mouse, sinais OS), expor método público que dispara mesmo trigger sem o hook.** Facilita testes E generaliza pra outros disparadores.

**Ordem do `Stop()` evoluiu novamente.** Agora:

1. Publica `Evt.AppStopping`
2. Para `tickEmitter`
3. Para `hoverHide`
4. Hide widgets (se !headless)
5. **Para `hotkeyService` (Fase 7.2)**
6. Para `logMonitor`
7. `_PersistFinalState`

Agrupei tudo de "input/UI" antes de logMonitor. Justificação: depois que hotkey desliga, não tem mais como o jogador disparar comando que mexa em state. logMonitor pode ainda processar últimas linhas do log (event-driven, não user-driven). Persist por último — padrão desde 5.1.b.

**Stubs pra `OpenSettingsRequested` e `OpenCampaignEditorRequested`.** Esses dois Commands têm handlers que **só logam** — virão pra valer nas Fases 7.4 e 7.5 quando os dialogs existirem. Adicionei agora porque:

- HotkeyService já mapeia `Settings`/`CampaignEditor` actions — se eu não adicionasse subscriber, publish iria pro bus e ninguém receberia (warning suprimível mas confuso).
- ActionsWidget e o tray menu apertam essas actions — se não houver handler, silêncio é pior que log.
- Quando 7.4 chegar, basta substituir `this.log.Info(...)` por `this.settingsDialog.Open()` — mudança localizada.

**Padrão emergente: stubs explicitos para subscribers que virão.** Melhor ter subscriber que loga do que sem subscriber + warning silencioso do bus. Loga também vira marker pra grep "no-op ate Fase X" quando precisar finalizar.

**`_OnToggleOverlayRequested` decisão de design.** Tinha várias opções pra implementar:

- **A) Toggle individual de cada widget** (cada um inverte). Ruim porque widgets podem estar em estados misturados.
- **B) Esconder todos sempre + show all sempre, alternando**. Ruim porque o estado da última ação pode não refletir realidade.
- **C) Se ALGUM oculto → mostrar todos, senão ocultar todos.** ✅ escolhido. Semântica natural: "toggle" significa "ligar/desligar overlay" — estado intermediário (alguns visiveis, outros não) conta como "meio-ligado", ação resolve pra "ligado completo".

Comportamento: jogador esconde 1 widget pelo gerenciador, depois aperta `F8` (ToggleOverlay) — todos voltam visíveis. Aperta `F8` de novo — todos somem. Próximo `F8` — todos voltam. Liga/desliga real, não oscila estado.

**Peças deferidas pra sub-fases futuras:**

- **Hotkeys de PrevAct/NextAct** (7.x): precisa Cmd novo + handler em CampaignService (pula ato sem completar), depois entra no `ActionToCommand`.
- **Hotkey ForceSyncZone** (7.x): manualmente forcar SyncEngine pra reavaliar zona atual. Útil quando log monitoring perde uma zona. Pequeno.
- **Hotkey customization UI** (7.4): dialog de Settings precisa permitir ao user editar `AppSettings.hotkeys`. HotkeyService.Stop()+Hydrate()+Start() pode re-bindar sem reiniciar app.
- **Conflict detection**: hoje se dois actions usam a mesma key, o segundo bind sobreescreve silenciosamente. Validar + avisar fica pra Settings UI.

**Smoke test agora ainda mais real.** 7.0 → 7.1 trouxe visível; 7.1 → 7.2 traz **interativo**. Jogador pode:
- Apertar `^3` pra Pause/Resume timer
- Apertar `^!Backspace` pra Undo (timer + campaign rolam back juntos)
- Apertar `^!Space` pra avançar step manualmente (com snapshot pra undo)
- Apertar `^!n` pra começar new run
- Apertar `^5` pra reset run
- Apertar `F8` pra esconder/mostrar overlay

É a primeira vez que dá pra rodar uma run completa do jogo só com v2 — sem precisar do legado pra control hooks.

**Lição pra anotar: arquitetura subscribe-based escala melhor quando Commands são agnósticos a origem.** Como o command não sabe se foi hotkey/widget/teste/menu, qualquer canal novo plug-and-play. É a primeira vez que **explicitamente** demonstro essa propriedade no projeto: o teste `Test_7_2_HotkeyService_TriggerAction_via_bus_works_end_to_end` valida que `TriggerAction("StartPause")` produz o mesmo efeito que `bus.Publish(Cmd.TimerToggleRequested)` que produz o mesmo efeito que `app._OnTimerToggle()`. Três caminhos, mesmo resultado.

Reforça a decisão de manter Commands no bus como tipo separado de Events (5.7.2 firmou isso). Events são "fato passado", Commands são "intenção futura" — origens diferentes, semânticas diferentes, mas ambos passam pelo mesmo barramento.

**Próxima sub-fase:** 7.3 (CSV split por visita + acordar widgets dormentes via `Evt.SplitRecorded`). Pequena: ~5-10 linhas pra subscribe `Evt.TownVisitEnded` no app e chamar `runRepo.AppendSplit(...)`. SyncEngine ganhará publicação de `Evt.SplitRecorded` quando cursor avança, acordando completamente SummaryWidget (mapsCount, bossesCount) e PerfWidget (loading times). Estimativa: ~15-20 testes.

### 17.21 — Decisões da Fase 7.3 (Splits CSV + acordar widgets dormentes)

A 7.3 fecha o ciclo de tracking de runs no v2: cada step completado vira linha no `splits_v2.csv`, cada visita de cidade vira town split, e os widgets dormentes desde a 6.3/6.4 finalmente têm dados pra mostrar. Resultado: 1267 testes (+12 vs 7.2), v2 agora produz CSV indistinguível do legado em formato.

**Fluxo final dos splits.** Tinha vários designs possíveis. Optei por:

```
CampaignService.CompleteCurrentStep
   ↓ (publica Evt.StepCompleted com payload mínimo)
App._OnStepCompleted (subscriber)
   ↓ (enriquece via campaign + runService + appSettings)
   ├→ publica Evt.SplitRecorded (subscribers: widgets)
   └→ escreve linha no splits_v2.csv (se HasActiveRun)
```

A virada de chave: o **CampaignService publica payload mínimo (actIndex/stepIndex/stepId/durationMs)**, e o **app.ahk enriquece** consultando os modelos pra adicionar mapName, segmentType, bossName, objective, actName. Justificações:

- **CampaignService não conhece runId/profile/patch** — essa metadata vem do RunService + AppSettings, e CampaignService não tem (nem deve ter) acesso a esses.
- **Widgets não devem consultar campaign** — widget que recebe Evt.StepCompleted e faz `campaign.FindStep(...)` começa a entender estrutura interna do CampaignService. SplitRecorded enriquecido entrega tudo pronto.
- **App.ahk é o coordenador natural** — já tem todas as deps (campaign, runService, appSettings, runRepo), já é o lugar onde peças do sistema se encontram (5.10, 7.1, 7.2 reforcaram).

**Single point of enrichment como princípio.** Generalizável: quando vários consumidores precisam da mesma informação derivada de múltiplas fontes, **uma das partes faz o enrichment uma vez e re-publica enriquecido**. Não cada consumer enriquecendo individualmente. Reduz duplicação, centraliza lógica de lookup, e mantém subscribers triviais (só reagem aos campos já prontos no payload).

**Dois caminhos de split distintos.** Map/boss splits passam por `Evt.StepCompleted`; town splits passam por `Evt.TownVisitEnded`. Por que separados:

- **Semântica diferente**: map/boss é "completou objetivo na rota"; town é "saiu de uma cidade".
- **Sem stepId em town**: town visits não correspondem a step da rota — jogador pode entrar em qualquer cidade de qualquer ato.
- **Source diferente no CSV**: `"auto"` pra cumpridos, `"auto_town"` pra cidades. Permite análise por origem.
- **Disparadores diferentes**: StepCompleted vem do CampaignService (cursor avançou); TownVisitEnded vem do TownVisitTracker (zona mudou).

Unificar num único Evt.SplitRecorded com discriminator (segmentType="town") foi tentado mentalmente mas rejeitado porque o caminho de TownVisitEnded não passa pelo enrichment via campaign (não tem stepId pra resolver) — forcaria branching no enricher. Mais simples: dois subscribers, dois caminhos.

**CSV write só se HasActiveRun, mas SplitRecorded é publicado sempre.** Decisão sutil. Justificações:

- **CSV é histórico de runs**: se não há run ativa (jogador está explorando sem ter dado NewRun), gravar splits polui o arquivo — split órfão de runId vazio causa problemas no LoadRun e no Analytics.
- **SplitRecorded é sinal de UI**: widgets devem mostrar progresso em tempo real mesmo sem run ativa formal. Jogador pode estar testando/configurando — vê o overlay reagir, sem afetar histórico.

Esse split entre "que persistem fato" vs "sinais que UI consome" é importante: **não todo evento merece CSV, não todo evento merece refresh de UI**. Cada subscriber decide independente.

**`transitionMs` fica em zero.** Wire-up está 100% pronto: SummaryWidget faz `loadingMs += transitionMs`, PerfWidget faz `_actLoadingMs[actIdx] += transitionMs`. Só falta a fonte de dados — alguém que detecte tempo de loading entre zonas e popule o campo.

No legado isso vem de um "loading visual scanner" que captura screen pra detectar tela de loading. É trabalho considerável — não cabe na 7.3. **Fica deferido com intenção**: o código recebe o campo e usa corretamente; quando a fonte chegar, plug-and-play.

Padrão: **terminar wire-up antes da fonte de dados**. Se eu deixasse pra implementar tudo junto (loading detector + wire-up), ficaria escopo grande demais. Separando, a 7.3 fica focada no caminho de splits, e a fonte vira sub-fase isolada futura.

**Bug pego em smoke test: GetAct estoura sem rota.** Os primeiros 12 testes da 7.3 rodaram, dois falharam:

```
Test_7_3_StepCompleted_handles_unknown_stepId_gracefully
Test_7_3_TownVisitEnded_writes_town_split
```

Ambos testes chamavam handler com `actIndex=1` mas SEM `_SeedMinimalRoute` (rota vazia). `CampaignService.GetAct(1)` lança `ValueError` se actIdx fora de range. Resultado: handler abortava antes do publish/CSV write.

Fix: `actObj := ""; if (actIdx >= 1 && actIdx <= this.campaign.GetActCount()) actObj := this.campaign.GetAct(actIdx)`. Defensive coding.

**Lição**: handlers de bus podem ser chamados em qualquer estado do sistema. Subscriber publicado durante boot (antes de Hydrate completar), durante shutdown (depois de Stop), com payload mal-formado de fonte externa, etc. **Defender sempre.** Não assumir que campaign tem rota, que runService tem run ativa, que appSettings tem campos preenchidos. Use guards explícitos.

Essa lição ecoa o padrão que já existia em outros services (RunState lookup defensive em CampaignService desde 4.4, payload validation em BossFightTracker desde 5.3) — o que mudou é que agora **app.ahk também é fronteira de subscribers**, não só services. Mesma disciplina.

**Helper `_FindStepInActs` duplica `SyncEngine._FindStepById`.** As duas funções fazem essencialmente o mesmo: itera atos e steps procurando id. Aceitei a duplicação por agora porque:

- **Cada uma tem 5 linhas de lógica trivial**.
- **Fontes diferentes**: SyncEngine usa via campaign privadamente; app.ahk usa via campaign também. Não há reuso óbvio.
- **Refatorar agora seria especulativo**. Quando aparecer terceiro consumer, extrair pra `CampaignService.FindStepById(stepId)` público fica uma linha de mudança por callsite.

Convenção que vou seguir: **dois copies é OK, três é hora de extrair**. Uma linha em ARCHITECTURE.md basta pra não esquecer.

**Boss split NÃO duplica boss count.** Detalhe sutil testado explicitamente. Quando BossFightTracker detecta boss derrotado, publica `Evt.BossDefeated` → SummaryWidget incrementa bossesCount (desde 6.3). Quando esse mesmo step depois é completado (jogador volta ao hub), CampaignService publica `Evt.StepCompleted` com stepId do boss step → app enriquece e publica `Evt.SplitRecorded` com segmentType="boss" → SummaryWidget recebe.

Se SummaryWidget incrementasse bossesCount em ambos os caminhos: contagem dobrada. Implementação correta: SplitRecorded com segmentType="boss" **registra historicamente** (CSV) mas não mexe no contador. `Evt.BossDefeated` é o caminho canônico.

Teste explicitamente cobre isso: `Test_7_3_SplitRecorded_boss_segment_does_not_increment_mapsCount` valida que boss split deixa mapsCount=0 e bossesCount=0 (porque Evt.BossDefeated não foi publicado). Captura a separação de responsabilidades.

**Peças deferidas pra fases futuras:**

- **Loading detection** (sub-fase futura): detector de loading screen via screen capture. Quando funcionar, popula `transitionMs` em SplitRecorded — widgets atualizam automaticamente.
- **Death tracking no app.ahk**: `Evt.DeathDetected` é publicado pelo LogMonitor mas o app não escreve no `deaths_v2.csv`. Atualmente só SummaryWidget conta. Faltaria subscriber que cria `Death.FromMap(...)` + `runRepo.AppendDeath(...)`. **Pequeno** (~15 linhas), entra em sub-fase futura.
- **Split source = "manual"**: quando jogador aperta hotkey CompleteStep manualmente (7.2), o handler ainda usa source="auto" no CSV. Diferenciar manual vs auto fica pra refinamento.
- **Split source = "leave_town_to_X"**: legado discrimina town splits pelo destino. V2 não tem essa info disponivel facilmente. Aceitar `auto_town` genérico por agora.

**Smoke test final do overlay.** Com 7.1+7.2+7.3 rodando, dado uma rota completa carregada e jogador ativo:
- Timer corre (TimerService pulsa via Tick, widget renderiza)
- Zona muda (LogMonitor publica ZoneChanged, SyncEngine avança cursor, ZoneWidget atualiza)
- Step completa (SyncEngine cascata CompleteCurrentStep, app enriquece e escreve splits_v2.csv, SummaryWidget incrementa mapas, SplitsWidget atualiza MED/BEST/LAST)
- Boss morre (BossFightTracker publica BossDefeated, SyncEngine seta flag, SummaryWidget incrementa bosses, ObjectiveWidget atualiza)
- Cidade visitada (TownVisitTracker mede tempo, app escreve town split no CSV)
- Jogador aperta `^!Backspace` (HotkeyService publica Cmd.UndoRequested, TimerService+CampaignService revertem)
- Jogador aperta `F8` (HotkeyService publica Cmd.ToggleOverlayRequested, app esconde/mostra todos widgets)
- Stop persiste tudo (carry, townTotals, currentZoneName, AppSettings, Progress)

**É a v2 funcionalmente completa** — falta apenas Settings GUI (7.4) pra config sem editar INI manual e CampaignEditor GUI (7.5) pra editar rotas no app.

**Lição pra anotar: terminar wire-up antes da fonte de dados é estratégia válida quando a fonte é escopo grande/incerto.** No caso de loading detection, separar wire-up (7.3, focado em código de plumbing) de fonte (sub-fase futura, focada em screen capture / log scanning) deixou a 7.3 enxuta e completa por si. O "campo zerado mas tudo conectado" é estado legítimo de espera — quando a fonte chegar, ativação é imediata. Isso é o oposto de "premature optimization" — chame de **deferred activation**.

**Próxima sub-fase:** 7.4 (SettingsDialog GUI) — grande mas gerenciável. Dialog pra configurar campanha selection, hotkeys, log path, profile, plot metrics. Subscribers de `Cmd.OpenSettingsRequested` (que hoje só logam) ganham implementação real. Estimativa: ~30-50 testes.

### 17.22 — Decisões da Fase 7.4 (SettingsDialog GUI)

A 7.4 transforma o setup de "funcional" pra "configurável pelo usuário". Até a 7.3, mexer em hotkey ou caminho do Client.txt obrigava editar `poe2_tracker_v2.ini` na mão e reiniciar o app. Agora: diálogo de Configurações via `Ctrl+Alt+S` (ou tray menu futuro), edita campos, Save → INI persistido + hotkeys re-bindados sem reload. 1305 testes (+38 vs 7.3 — 35 isolados + 4 integração, contagem total ajustada por um teste removido em refactor de stub).

**GUI como casca, lógica em `ApplyChanges`.** Decisão central da 7.4. Tinha duas opções:

- **A) Acoplar validação + persist + rebind no handler do botão Save**. Cada handler de UI seria responsável pelo fluxo completo. Funciona, mas testar GUI é caro e frágil em AHK (só testes manuais via `Send`/`Click`).
- **B) Separar core funcional em `ApplyChanges(changesMap)`**. GUI vira casca: coleta valores e delega. Core é diretamente testável sem precisar instanciar GUI. ✅ escolhido.

Resultado: 35 testes isolados batendo direto em `ApplyChanges`, sem nenhum precisar abrir uma janela real do AHK. Padrão que vou consolidar: **toda lógica de mutação de state via UI deve ter API programática equivalente, testável sem GUI**. A própria GUI passa a ser thin layer que coleta valores e delega.

Mesma estratégia que aplico em widgets desde 6.x (`SetVisible/SetScale/SetPosition` mutáveis sem precisar de GUI), mas pela primeira vez aplicada num dialog complexo com múltiplos campos e validação cruzada.

**`changesMap` com keys compostas escala bem.** Em vez de métodos especializados (`SetProfileName`, `SetHotkey(action, val)`, `SetPlotMetric(name, val)`), a API é um único método recebendo Map de mudanças. Keys composte com prefixo (`hotkey:StartPause`, `plotMetric:loading`) discriminam o tipo.

Vantagens:
- **Atomicidade**: todas as mudanças validam JUNTAS antes de qualquer persist. Hotkey conflict detectado entre dois actions trocados na mesma chamada (`hotkey:StartPause=F1` + `hotkey:NewRun=F1` num único ApplyChanges).
- **Diff-based**: `_CollectChangesFromControls()` só inclui campos que MUDARAM em relação a `_appSettings` atual. Save sem mudanças = no-op (não reescreve INI desnecessariamente).
- **Forward compatibility**: keys desconhecidas são silenciosamente ignoradas. Se uma versão futura adicionar `"theme"` ou `"language"` ao changesMap, dialogs antigos não quebram.
- **Test-friendly**: passar `Map("profileName", "X")` direto evita ter que mockar GUI controls.

**Validação atomic: tudo ou nada.** O fluxo é:

```
1. _Validate(changesMap) -> ok | error
2. SE !ok, retorna early SEM mutar nada
3. _ApplyToSettings(changesMap)
4. settingsRepo.Save(this._appSettings)
5. SE houve mudança em hotkey, _RebindHotkeys()
6. onAfterSave callback (opcional)
```

Validação ANTES de mutação garante que se algo der errado, o estado em memória fica intocado. Teste `Test_Validation_failure_does_not_persist` valida explicitamente: tenta `Map("profileName", "WouldChange", "logFile", "")` (logFile vazio = inválido), e verifica que `cfg.profileName` continua original APÓS a falha. Sem isso, o usuário teria "meio-mudança aplicada" — perigoso.

**Hotkey conflict detection é case-insensitive.** AHK trata `^F1` e `^f1` como a mesma tecla. Se validação for sensível a case, o usuário pode salvar `^F1` em StartPause e `^f1` em NewRun — setando os dois pra mesma tecla (último registrado vence). `_Validate` normaliza com `StrLower(Trim(keyBind))` antes de comparar.

Teste explicitamente cobre isso: `Test_Validation_hotkey_conflict_is_case_insensitive`. É a categoria de bug que só aparece em produção quando alguém testa com caps lock por engano — cobrir antecipadamente economiza dor de cabeça.

**Re-bind condicional via `_HasHotkeyChanges`.** `HotkeyService.Stop()+Hydrate()+Start()` re-registra todos os 8 binds globais no AHK. Em produção isso afeta o teclado real do usuário — hotkeys "piscam" durante o ciclo. Não quero ciclar quando mudação foi só em `profileName`.

Solução:

```ahk
_HasHotkeyChanges(changesMap)
{
    for k, _ in changesMap
        if (SubStr(k, 1, 7) = "hotkey:")
            return true
    return false
}
```

Baseado no prefixo das keys. Se nenhuma começa com `"hotkey:"`, não re-binda. Teste `Test_ApplyChanges_does_not_rebind_when_only_non_hotkey_changes` valida: hotkey service está parado (setup), ApplyChanges com profileName, e DEPOIS verifica que ainda está parado (Hydrate+Start não rodou). Sem essa otimização, todo Save reiniciaria hotkeys mesmo quando desnecessário.

**Headless mode pela terceira vez (7.1, 7.2, 7.4) — padrão consolidado.** A regra já estava clara desde a 7.2: "headless = não toca em recursos globais do OS". A 7.4 adiciona `Open()/Close()/IsOpen()` ao conjunto.

Mas note a sutileza: SettingsDialog em headless **ainda funciona logicamente** (`Open()` marca `_isOpen=true`, subscribe Cmd ainda roda, `ApplyChanges` ainda persiste). Só a construção do GUI (`_BuildGui()`) é pulada. Isso permite testar:

- **Subscriber cabeça-a-cabeça**: `Cmd.OpenSettingsRequested → Open() → _isOpen=true`. Testável.
- **Lifecycle**: Open/Close idempotentes, IsOpen reflete estado.
- **Stop fecha o dialog**: integração no app valida que `app.Stop()` fecha automaticamente.

O modo não é um "mock" — é a mesma classe rodando, com só a parte de GUI desligada. Próximo padrão emergente: **classes que tocam OS resources devem aceitar flag `headless` no construtor que skipa apenas a parte que toca o recurso**, mantendo todo o resto funcionando.

**Bug 17.5 reincidente — desta vez no SettingsDialog.** O construtor recebia `hotkeyService` como parâmetro:

```ahk
__New(bus, cfg, settingsRepo, hotkeyService, headless, onAfterSave)
{
    if !(hotkeyService is HotkeyService)   ; <-- shadowing
```

Em AHK v2 case-insensitive, `hotkeyService` (parâmetro local) é a mesma identificador que `HotkeyService` (classe). O `is HotkeyService` resolve pra `is hotkeyService` — que é a própria variável local (uma instance, não uma classe). Resultado: AHK estoura `"Expected a Class but got a HotkeyService"`.

107 testes do app falharam de uma vez — todos os que construíam SpeedKalandraApp com `_headless=true` (que era a maioria dos testes da fase 5+). Mensagem do erro foi imediatamente diagnóstica graças à convenção 17.5 já documentada — reconheci o padrão em segundos.

Fix: renomear parâmetro pra `hotkeySvc`. Reforça a regra:

> **Parâmetros de método NUNCA podem ter mesmo nome de classe ignorando case.** Vale pra qualquer classe usada como type check no corpo do método.

A convenção 17.5 listava `step`, `act`, `run`, `progress`, `appSettings`, `events`, `commands`, `clock`, `bus`, `cfg`. Adiciono agora: **qualquer classe de service / repository que apareça em validation type check**. No projeto: `HotkeyService`, `SettingsRepository`, `RunRepository`, `EventBus`, etc. Convencional usar abreviado: `bus`, `repo`, `cfg`, `hotkeySvc`, `runRepo`.

**Subscriber direto SettingsDialog → Cmd.OpenSettingsRequested.** Removi o stub `_OnOpenSettingsRequested` do `app.ahk`. Antes da 7.4, app.ahk tinha:

```ahk
this.bus.Subscribe(Commands.OpenSettingsRequested, (data) => this._OnOpenSettingsRequested(data))
; ...
_OnOpenSettingsRequested(data)
{
    this.log.Info("OpenSettingsRequested (no-op ate Fase 7.4)", "App")
}
```

Agora: SettingsDialog subscreve direto no construtor. App.ahk apenas instancia o dialog em `Start()`. Mais limpo — quem reage à intenção é quem implementa a ação, não um interpretador no meio.

**Stub vira implementação real — padrão de evolução saudável.** Na 7.2 documentei o padrão "stubs explicitos para subscribers que virão". A 7.4 é a primeira aplicação desse padrão vira implementação real. Funcionou perfeitamente: marker `"no-op ate Fase 7.4"` no log facilitou grep, troca foi localizada (uma linha de subscribe + um método deletado).

Proximo stub na fila: `_OnOpenCampaignEditorRequested` (ainda loga `"no-op ate Fase 7.5"`). Quando 7.5 chegar, mesmo padrão de troca.

**`onAfterSave` callback opcional.** Inspirado em `onPersist` dos widgets (7.1). Permite ao app reagir a saves sem o dialog conhecer o app:

```ahk
this.settingsDialog := SettingsDialog(
    this.bus, cfg, this.settingsRepo, this.hotkeyService,
    this._headless,
    () => this.log.Info("Settings saved", "App")
)
```

App só quer logar agora, mas no futuro pode reagir a mudanças de logFile (reconfigurar LogMonitor) ou de profileName (publicar `Evt.ProfileChanged`). Sem callback, dialog teria que conhecer o app ou publicar evento genérico no bus.

Convenção que cristalizo: **dialogs que mutam state global expoem `onAfterSave` callback opcional**. Outros dialogs futuros (CampaignEditor 7.5) devem seguir.

**Peças deferidas pra fases futuras:**

- **Build registry / Build Planner**: legado tem dropdown de builds com classe/patch/descrição + Stats Dashboard. V2 simplificou pra apenas `profileName` text edit. Build registry vira fase futura (provavelmente 7.6+).
- **Targets editor (Tempos-alvo)**: legado tem GUI separada pra editar `targetMs` por step. Depende de UI por act+step. Vira sub-fase ou parte da 7.5 (CampaignEditor).
- **Loading visual settings (poll ms, test, logs, folder)**: depende de loading detection que ainda não existe na v2.
- **Panel overlay keys (micro overlay triggers)**: micro overlay ainda não portado pra v2.
- **Force sync, Resumo, Limpar estatisticas**: ferramentas auxiliares; entram quando relevantes.
- **Browse button para logFile**: implementado (`FileSelect`), só testado manualmente — testes automatizam o `_CollectChanges` direto.

**Smoke test final da 7.4.** Com 7.1-7.4 rodando:

1. Apertar `^!s` (default hotkey de Settings) → dialog abre
2. Trocar StartPause de `^3` pra `F2` → Save
3. Hotkey `^3` para de funcionar
4. Hotkey `F2` começa a controlar timer (toggle pause/resume)
5. INI persiste mudança — reload do app preserva nova hotkey

É a primeira vez que o usuário v2 pode configurar o tracker SEM editar arquivo manualmente. Marco importante — setup vira autônomo.

**Lição pra anotar: separar core de lógica de UI eleva drasticamente a testabilidade.** O dialog tem ~400 linhas (com GUI), mas apenas ~150 são testadas. Testar essas 150 linhas (ApplyChanges + validação) cobre ~95% do comportamento que importa. As 250 de GUI (BuildGui, OnSaveClick, OnBrowseLogFile) são testadas indiretamente via integração (`Cmd → Open`) ou manualmente.

Proporção aceitável: 95% de comportamento coberto via 150 linhas de lógica + 35 testes. Tentar testar GUI direto (mockar controls, simular clicks) seria 10x mais código de teste pra ~5% de cobertura adicional. Ganho marginal não vale a pena.

Generalizável: **quando uma classe junta lógica + GUI, a fronteira da testabilidade é onde a lógica termina e o framework de UI começa.** Mantenha lógica em métodos puros que retornam valores; UI vira coletor + delegator.

**Próxima sub-fase:** 7.5 (CampaignEditor GUI — "o monstro"). Lista de atos + steps com add/edit/delete + route group config. Legado tem 298KB pra esse arquivo. Vai ser maior que tudo na fase 7 combinado. Estimativa: 80-150 testes, possivelmente sub-dividida em 7.5.1 / 7.5.2 / etc.

### 17.23 — Decisões da Fase 7.5 (CampaignEditor GUI — MVP)

A 7.5 é "o monstro" da Fase 7. Legado tem 305KB de `campaign_editor.ahk` com tudo que envolve manipulação de rota: lista de atos + lista de steps + painel com 25 campos + validação + persist + live log feed + NPC dialogue picker + regex tester + guide. MVP da 7.5 cobre o core do editor (CRUD completo + validação + persist) e deixa as features adjacentes (live log, NPC picker, regex tester, guide) como sub-fases 7.5.x. 1359 testes (+54 vs 7.4: 36 core + 14 dialog + 4 integração).

**Decisão central: Core / Dialog em duas classes separadas.** Diferente da 7.4 (SettingsDialog que fundiu tudo numa só classe), a 7.5 separou:

- `CampaignEditorCore(routeRepo)` — toda lógica de mutação (Act lifecycle: New/Rename/Delete/Move; Step lifecycle: New/Duplicate/Delete/Move/Update) + validação + persist. Pure logic, não depende de bus nem de GUI.
- `CampaignEditorDialog(bus, routeRepo, headless, onAfterSave)` — GUI casca. Has-a Core via `_core`. Subscribe `Cmd.OpenCampaignEditorRequested`. Botões delegam tudo pra core.

**Por que separar?** SettingsDialog tem UMA ação central (Save), 35 tests batem em `ApplyChanges` direto. CampaignEditor tem 8+ mutators (cada act/step lifecycle method) + validação complexa + persist. Fundir geraria classe de ~500+ linhas misturando lógica e GUI — testes do core ficariam acoplados à maquinaria do dialog (Subscribe, Open/Close, headless flag), aumentando coupling.

Resultado: 36 tests do core focam puramente em lógica (não constroem bus nem dialog), 14 tests do dialog focam em lifecycle + integração. Cada classe tem responsabilidade única. **Generalização**: dialogs com múltiplos mutators (3+) merecem core separado; dialogs com 1-2 ações centrais podem fundir.

**`UpdateStep` reconstrói Step via `Step.FromMap`.** A propriedade `step.completionRule` foi adicionada na 5.5.2 como **derivada** dos campos planos (`completionMode + regexes`). Mutar campos planos diretamente não re-deriva a rule — ficaria stale.

Solução: `UpdateStep(actIdx, stepIdx, fieldsMap)` faz:
1. Pega step atual
2. Constrói Map com TODOS os 25 campos via `_StepToMap`
3. Sobrescreve com `fieldsMap`
4. `Step.FromMap(merged)` cria novo Step (rederiva rule)
5. Substitui no array

Ehrostso a primeira vez no projeto que um campo derivado força esse padrão de "reconstruct via factory". É a contrapartida natural de tê-lo derivado em vez de armazenado: mutação direta não basta. **Consequência arquitetural**: campos derivados em modelos imutáveis exigem reconstrução em update flows. Vale o preço pela invariante "rule sempre coerente com campos".

**`DeleteAct/MoveAct` re-indexam `act.index` via `_ReindexActs`.** `routeRepo.Save(acts)` itera `for _, actObj in acts` e escreve `[Act<actObj.index>]` no INI. Se delete de meio deixar buracos (índices 1, 3, 4), o INI fica corrompido (secção `[Act2]` ausente; loader procura act 2 pelo `actCount` e não acha).

`_ReindexActs` itera o array pós-mutacaõo e seta `actObj.index := i`. Garante invariante "índices sequenciais 1..N" sem importar a ordem de operações. Tests cobrem: Delete remove + reindexa, Move swap + reindexa, MoveAct nas bordas é no-op (preserva invariante).

**`_StepToMap` clona arrays via `.Clone()`.** `DuplicateStep` precisa que o clone tenha listas (rewards, drops, tips, buffs, aliases, physicalZones) **independentes** do original. Sem clone, ambos compartilham referência — modificar `aliases` do clone afetaria original (bug pego em teste `Test_DuplicateStep_clones_lists_independently`).

Decisão genérica: **sempre que um helper extrai estado de um modelo pra reconstruir/clonar, listas e Maps internos devem ser clonados**. Em AHK v2 `Array.Clone()` faz shallow copy (suficiente aqui porque listas são de strings).

**Errors fatais, warnings informativos.** `ValidateRoute()` retorna `Map("ok", bool, "errors", [], "warnings", [])`. Diferenciação:

- **Errors** (FATAL, bloqueiam Persist): step ids duplicados globalmente, ato sem nome
- **Warnings** (informativos, não bloqueiam): boss step sem regex, routeGroup com 1 único membro, requiredFlag sem flag setadora

`Persist()` usa `validation["ok"]` (depende só dos errors) pra decidir se salva. Warnings võem junto no return pra UI exibir mas não impedem persist. Por quê? Permite o usuário editar incrementalmente:

- Cria boss step antes de configurar regexes → warning, mas pode salvar e voltar depois
- Cria step com `routeGroup` antes do segundo membro → warning temporário até adicionar parceiro

Sem essa distinção, validação estrita travaria o user em estados intermediários válidos. **Licão**: erros que corrompem dados (ids duplicados → INI quebrado) merecem fatal; problemas que apenas afetam comportamento futuro (boss não detectado até regex chegar) são warnings.

**Virtual gate flag detection.** `requiredFlag` terminando em `_gate_open` (ex: `boss_phase1_gate_open`) é setada **automaticamente pelo engine** quando todos steps de um group completam (4.4.3). Validation conhece esse pattern: se `requiredFlag` termina em `_gate_open`, não emite warning de "flag órfã".

Eh um conhecimento que vaza do domínio do CampaignService pro CampaignEditorCore. Aceitável porque é um mecanismo bem estabelecido (existia desde Fase 4) e validation é informativa, não struturalmente acoplada. Se um dia trocarmos o sufixo virtual, ajustamos no helper. **Test cobre**: `Test_ValidateRoute_no_warning_for_virtual_gate_flag`.

**Generated step ids: `a<actIdx>_<NN>_new_<TickCount>`.** `NewStep` sem `stepData` precisa gerar id único. Estrutura:

```
a1_01_new_26546500
^^^^^^^^^^^^^^^^^
|||  ||  |||
|||  ||  ++++--- A_TickCount (milisegundos desde boot, 32-bit)
|||  ++--------- Número do step (2 dígitos zero-padded)
+++------------- act<index>
```

`A_TickCount` evita colisão temporal: chamadas consecutivas geram ids diferentes mesmo em loop tight. Combinado com act+step indices dá unicidade entre atos diferentes.

Pattern é válido pela regex de `StepId.MustBeValid`: `^[a-z][a-z0-9]*_\d{2}_[a-z0-9_]+`. Usuário pode renomear via `UpdateStep` depois (id é mutável via Map).

**Bug pego em testes: StepId regex rejeita slugs curtos.** Os testes iniciais usavam ids como `x`, `dup`, `pre`, `p1`, `boss1`, `alone` — todos rejeitados por `StepId.MustBeValid` que exige formato `<act>_<NN>_<slug>`.

Fix: testes usam formato válido (`a1_01_x`, `a1_01_dup`, `a1_01_pre`, etc). Ao mesmo tempo, `NewStep` default agora gera `objective` não-vazio (`(novo objetivo)`) — pois `Step.FromMap` exige objective não vazio também.

**Lição**: validations de domínio (StepId.MustBeValid, objective obrigatório) são invariantes que o código só enfrenta quando alguém TENTA quebrá-las. Em Fases 1-6 ninguém construiu Step do nada — fixtures sempre vinham via `LegacyAdapter.ActsFromLegacy` (que respeita formato). 7.5 é a primeira vez que código CONSTRUIU Steps em runtime, e os invariantes apareceram. Generalização: **invariantes de domínio são latêntes até o código encontrar o ponto onde são exigidas**.

**Headless mode pela 4ª vez — padrão totalmente consolidado.** 7.1 (widgets), 7.2 (HotkeyService), 7.4 (SettingsDialog), 7.5 (CampaignEditorDialog). A regra é sempre a mesma: "headless skipa apenas a parte que toca recurso global do OS". O resto (subscribe Cmd, lógica de mutação) funciona normal em testes.

A cada repetição, o padrão ficou mais automático. Pra 7.5, eu nem precisei pensar — já escrevi `_BuildGui()` skipped quando `_headless`, com Open/Close/IsOpen funcionando logicamente. Próximas classes que tocarem GUI/OS resources copiam sem refletir.

**Stub → implementação real (segunda aplicação).** Na 7.4 documentei o padrão; na 7.5 funcionou com a mesma fluidez:

1. App.ahk antes da 7.5: `Subscribe(OpenCampaignEditorRequested) → _OnOpenCampaignEditorRequested(data)` que só logava "no-op ate Fase 7.5"
2. App.ahk depois da 7.5: campo `campaignEditor` instanciado em `Start()`, dialog subscribe direto, stub deletado

Marker `"no-op ate Fase 7.5"` foi indicador útil pra grep durante a transição. App.ahk fica mais leve a cada dialog que substitui stub.

**Peças deferidas pra sub-fases 7.5.x:**

- **7.5.1 Live log feed** — `Edit ReadOnly VScroll` que subscreve `Evt.LogLineRead` e appendia linhas em tempo real. Trivial em si, mas poluiu o GUI base se fosse junto. Vai como sub-fase pequena.
- **7.5.2 NPC dialogue picker** — botão que abre lista de NPCs/falas detectadas no log e gera regex pronto. Depende do live log estar funcionando primeiro.
- **7.5.3 Regex tester** — testa regex contra linha de exemplo, mostra match/no-match. Utilíssimo mas autocontido.
- **7.5.4 Guide text** — texto estático explicando rota/grupos/flags. Última prioridade.

Nenhuma das 4 é bloqueante pra usar o editor em produção. Lançar 7.5 MVP sem elas permite testar fluxo principal (CRUD + validação + persist) e iterar.

**Smoke test final da 7.5.** Com 7.1-7.5 rodando:

1. Apertar `Ctrl+Alt+E` (default hotkey de CampaignEditor) → dialog abre
2. Adicionar novo ato via botão `+ Ato`
3. Adicionar steps via botão `+ Step` + editar campos no painel
4. Salvar step → atualizado em memória
5. Salvar rota → INI persistido
6. Reiniciar app → rota carrega com mudanças

Pela primeira vez, usuário v2 pode editar a rota inteira sem editar `campaign_route.ini` na mão. Combinado com 7.4 (Settings GUI), v2 é totalmente configurável pelo usuário. Marco grande — setup vira autônomo.

**Fase 8 se aproxima.** Com 7.1-7.5 fechadas, o app v2 tem feature parity com o core do legado:

- ? Overlay com 8 widgets reativos
- ? Hotkeys globais configuráveis
- ? Splits CSV escritos durante runs
- ? Settings dialog
- ? Campaign editor (CRUD)
- ? SyncEngine + boss tracking + town tracking + carry preservation
- ?? Live log feed, NPC picker, regex tester (deferidos pra 7.5.x)
- ?? Loading detection (sem v2 ainda, transitionMs em zero)

A Fase 8 (demolição do legado) começa com migração final dos consumers — `poe2_campaign_tracker.ahk` legado vira shim que delega tudo pra `speedkalandra_dev.ahk` (renomeado), e `src/` pode ser deletada inteira. Pendentes deferidos viram dependencies da própria fase 8 ou ficam como improvements pós-migração.

**Próxima sub-fase:** 7.5.1-7.5.4 (live log + NPC picker + regex tester + guide) ou direto pra Fase 8 (demolição). Decisão do usuário.

### 17.24 — Decisões da Fase 7.5.x (Editor extras)

Quatro sub-fases pequenas, cada uma autocontida, fechando o feature parity do CampaignEditor com legado. 1404 testes (+45 vs 7.5: 12 LiveLogFeed + 19 NpcDialogueExtractor + 12 RegexTester + 2 dialog integ.).

**Três classes auxiliares (LiveLogFeed, NpcDialogueExtractor, RegexTester) seguem padrões já estabelecidos** — Subscribe-based ou static helpers, headless friendly, testes isolados sem GUI. Nenhuma decisão nova de escala arquitetural; o valor desta sub-fase está nas micro-decisões de extensão do dialog.

**LiveLogFeed: dado primeiro, GUI segundo.** A classe é essencialmente um buffer circular que subscreve `Evt.LogLineRead`. `AttachControl(editCtrl)` adiciona render side-effect (apenda + scroll), `DetachControl()` remove. Em headless, `_attachedControl = ""` e tudo o resto funciona normal. Buffer FIFO com `RemoveAt(1)` quando passa de `_maxLines` (default 500). Permite que o NPC picker (7.5.2) e debugging futuro acessem buffer sem recriar subscribe. **Generalização**: classes que combinam dado + render se beneficiam de attach/detach pattern — mantém dado vivo sempre, GUI opcional.

**NpcDialogueExtractor: pure logic, static, dedup por (npc, line).** Em vez de criar service com state, fiz tudo `static`. Input é `Array<String>` de linhas, output é `Array<Map>` com candidatos estruturados. Trade-off: chamadas re-extraem tudo a cada botão de NPC picker apertado, mas como buffer maxLines=500 e logica é O(n), não vale cache. **3 patterns em ordem de confiança + skip patterns conhecidos** evitam mis-classificação (linha tipo "Generating level X area Y" tem `:` mas não é NPC). Dedup por chave `"<npc>|<line>"` — múltiplas ocorrências da mesma fala (NPCs repetem em zonas) viram 1 candidato. **Licão**: helpers de extração com filtros simbólicos (skip patterns) escalam melhor que regex monstro tentando capturar tudo de uma vez.

**RegexTester: try/catch em vez de propagar.** O caso de uso é user testando regexes WIP — sintaxe inválida é normal e esperada. `Test()` envolve `RegExMatch` em try/catch e retorna `Map("valid", false, "errorMsg", "...")` em vez de throw. UI exibe mensagem amigável sem stack trace. Empty/whitespace regex também é invalido (evita match acidental contra qualquer coisa). `FormatResult` separada em função própria pra UI ter formatação consistente — testes exercitam ambas separadamente.

**4 popups secundários em vez de inflar dialog principal.** Cada botão de "Ferramentas" abre `Gui +AlwaysOnTop +Owner<mainHwnd>` separado. Vantagens: (1) main dialog não cresce sem controle; (2) cada popup tem seu próprio destroy lifecycle; (3) usuário pode abrir múltiplos simultaneamente (ex: live log + regex tester lado a lado); (4) `Owner<hwnd>` garante que popup sempre fica acima do main, mas não bloqueia (não-modal). **Comparação com legado**: legado tem TUDO inline no main editor, ~3000 linhas de GUI numa só classe. Nossa abordagem é mais Mac-style (palette flutuante por feature).

**`A_Clipboard` para handoff entre popups.** NPC picker copia regex selecionado pro clipboard ao invés de tentar resolver "qual campo do main dialog popular". Trade-off: usuário precisa Ctrl+V manualmente. Vantagem: dialog do NPC picker não sabe nada sobre estrutura do form principal — zero coupling. Se um dia adicionarmos "target field" via dropdown no popup, fica trivial; por agora, clipboard é a ponte mais simples.

**`_GuideText()` retorna string crua via continuation "`(...)`".** AHK v2 syntax pra string multi-linha sem escape de aspas. Texto vive INLINE no dialog em vez de em arquivo separado — simplicidade vs. internacionalização. Como projeto é monolingüe (PT-BR), aceitável. Se um dia precisar i18n, extrai pra `data/guide_<lang>.txt` e `FileRead`.

**Headless mode: 4 popups, 4 if-headless-return.** Cada handler `_OnShowXxx` começa com `if this._headless return`. Resultado: testes constroem dialog com `headless := true`, `Open()` funciona, mas chamar `_OnShowLiveLog()` etc é no-op silencioso. Reforça o padrão: a fronteira de "GUI vs não-GUI" é na criação de `Gui()` objects. Tudo antes (lógica, state) testa normal; tudo a partir de `Gui()` skipa em headless.

**Sub-test "Test_dialog_liveLogFeed_subscribes_to_bus".** Confirma round-trip: dialog instancia LiveLogFeed no construtor, feed subscribe `Evt.LogLineRead`, publish acumula no buffer. Testes diretos da LiveLogFeed (em test_live_log_feed.ahk) já cobrem mecânica do feed; este teste extra na suite do dialog confirma a integração sem assumir.

**Feature parity completa com legado para o editor.** Com 7.5 + 7.5.1-7.5.4, o CampaignEditor v2 tem: CRUD de atos/steps, validação, persist, live log feed, NPC dialogue picker, regex tester, guide text. Tudo que o legado oferece. Restam apenas detalhes de UX (auto-completar campos, historíco de selecionados, etc) — polishing que pode entrar ad-hoc.

**Próxima fase:** **Fase 8 — Demolição do legado**. Com v2 feature-completo, podemos começar a desligar `src/`. Plano em alto nível:

1. **8.1**: `poe2_campaign_tracker.ahk` legado vira shim que apenas faz `#Include speedkalandra_dev.ahk` (renomeado pra `speedkalandra.ahk`). Smoke test: tracker continua funcionando do ponto de vista do usuário.
2. **8.2**: Remover `src/*.ahk` de includes do shim. Validar que app v2 standalone roda 100% (todas features operacionais). Renomear `speedkalandra_dev.ahk` → `speedkalandra.ahk` (entrypoint definitivo).
3. **8.3**: Deletar `src/` inteira. Últimas referências devem virar erros de compilação; corrigir cada uma (provavelmente includes residuais).
4. **8.4**: Limpeza ad-hoc: campos do AppSettings que existiam só pra legado (se algum); INI/CSV legado co-existem com v2 (`poe2_tracker.ini` vs `poe2_tracker_v2.ini`) - decidir migração automática ou pedir usuário rerodar do zero.

**Pendentes deferidos** após Fase 8:
- **Loading detection** (transitionMs em zero atualmente). Maior em escopo — precisa scanner visual ou heurística baseada em pause de log. Pode ser "Fase 9" ou ad-hoc.
- Polish ad-hoc de UX no editor.

### 17.25 — Decisões da Fase 8 (Demolição do legado)

Fim da migração Strangler Fig. v2 fica standalone, sem co-existir com src/. 1404 testes mantidos (zero impacto — mudanças foram só em entrypoints e marker).

**Estratégia em duas fases: shim primeiro, deletar depois.** Numa primeira passada, criamos `speedkalandra.ahk` como entrypoint definitivo (cópia adaptada de `speedkalandra_dev.ahk`) e os dois entrypoints antigos viraram shims de uma linha (`#Include "speedkalandra.ahk"`). Isso permitiu testar que o app v2 standalone funcionava sem nenhuma dependência legada antes de qualquer deleção. Numa segunda passada (mesma fase, depois do smoke test ok), o usuário pediu remoção completa: criamos `LIMPAR_LEGADO.bat` que apaga `src/`, shims, configs legadas, dados antigos e ~50 docs do legado. Backup externo já havia sido feito — sem rede de segurança interna necessária.

**O que foi preservado vs. apagado.** Estrutura final mínima:

- **Preservado**: `speedkalandra.ahk`, `src_v2/`, `data/{campaign_route.ini, town_zones.txt, splits_v2.csv, deaths_v2.csv}`, `assets/`, `runs/.keep`, `ARCHITECTURE.md`, `README.md`, `poe2_tracker_v2.ini`.
- **Apagado**: `src/` inteira, `backups/` inteira, `dist/` inteira, `runs/2026*.csv`, shims (`speedkalandra_dev.ahk`, `poe2_campaign_tracker.ahk`), `poe2_tracker.ini`, `data/{builds.ini, build_planner_*.csv, deaths.csv, gem_recommendations.ini, loading*, npc_dialogue.ini, overlay_debug.log, *.log, splits.csv}`, helpers legados (`codex_route_validate_out.txt`, `fix_log_monitor.py`, `overlay_prototype.html`, `PREPARAR_DISTRIBUICAO.bat`), e ~50 docs (`CHANGELOG_*`, `VALIDACAO_*`, `FIX_APLICADO_*`, `GUIA_*`, `HANDOVER_5_4.md`, `FEATURE_QUEUE.md`).

**Sem migração de dados (decisão do usuário).** INI/CSV legado (`poe2_tracker.ini`, `splits.csv`, `deaths.csv`) permanecem intactos mas não são mais lidos. v2 escreve em `poe2_tracker_v2.ini`, `splits_v2.csv`, `deaths_v2.csv` desde 5.10 — namespace separado por design preventivo. Histórico de runs antigas é perdido pra fins de stats; usuário começa fresh. Aceitável pra eles, simplifica enormemente Fase 8 (sem código de migração, sem testes de bridge).

**Fim da Strangler Fig formaliza-se aqui.** O padrão foi: src/ + src_v2/ co-existem, v2 publica/subscribe no mesmo bus, legado migra pedaço por pedaço. Na Fase 8, src/ é desligada de produção. v2 é a única fonte de verdade. Os 1404 testes cobrem 100% do que o app faz — não existe mais código "em uso" sem cobertura.

**Mapeamento documentado em `src/DEPRECATED.md`.** 14 arquivos legados com seus equivalentes v2. Pendentes intencionalmente não-migrados:
- `loading_visual.ahk` → deferido. Loading detection precisa de scanner visual / heurística de log que não existe ainda no v2. transitionMs fica em zero por enquanto. Vira Fase 9 ou ad-hoc
- `gems.ahk` → feature lateral (gem planning), não é core do tracker. Pode entrar como módulo separado
- `debug_injector.ahk` → dev tool, não precisava migrar

**Licão transversal: "deletar" em projetos vivos é raro — mas quando é possível, vale fazer.** Em projeto de bibliotecas públicas, mesmo cenário teria mais cerimônia (deprecation warnings, major version bump, etc) e shims poderiam permanecer indefinidamente. Aqui, com o usuário sendo o único consumidor (não há produtos terceiros consumindo) e backup externo confirmado, deleção agressiva foi a opção certa: pasta de projeto fica enxuta, não existe ambiguidade sobre "o que está vivo vs morto", reduz risco de futuro Claude/dev olhar arquivo legado e tentar usar como referência. **Padrão de duas fases (shim depois delete) escala bem**: fase 1 valida feature parity sem risco; fase 2 limpa quando confiante.

**O que sobra:** 
- Loading detection (Fase 9 opcional)
- Polish ad-hoc do editor (UX, auto-completar, etc)

**O Strangler Fig terminou.** 🌳 Árvore antiga (src/) foi finalmente removida do solo. v2 é a única árvore.

### 17.26 — Reincidência da convenção 17.5 em refactors recentes (2026-05)

Depois da Fase 8 fechada, alguns refactors enxutos extraíram classes de `app/app.ahk` pra módulos próprios: `RouteAutomationService`, `RunRecordingWorkflow`, `MigrationsRunner`, `BootDialogModule` (`PendingRunPrompt`). Cada extração trouxe **uma rodada nova de bug 17.5** — apesar da convenção estar documentada desde a Fase 3 e ter sido reforçada em 17.9 (Fase 6.2/6.6) e 17.22 (Fase 7.4).

**Cinco shadows encontrados em uma única sessão de testes (2488 → 2488 passing após 4 iterações):**

| Arquivo | Param/var ofensor | Renomeado pra |
| ------- | ------------------ | ------------- |
| `app/services/route_automation_service.ahk` | `triggerMatcher` | `tmatcher` |
| `app/workflows/run_recording_workflow.ahk` | `runService`, `syncEngine` | `runSvc`, `syncEng` |
| `app/boot/pending_run_prompt.ahk` | `runState` | `rs` |
| `tests/app/services/test_route_automation_service.ahk` | `triggerMatcher` (local) | `triggerMatcherObj` |
| `tests/app/workflows/test_run_recording_workflow.ahk` | `runService`, `syncEngine`, `appSettings` (locais) | `runSvc`, `syncEng`, `appSet` |

Sintomas observados (todos previstos pela seção 17.5):
- `"Expected a Class but got a <X>"` quando a expressão `valor is X` virava `valor is valor` (param shadow).
- `"This local variable has not been assigned a value..."` quando `local := X.Method(...)` tinha `local` case-insensitive igual a `X` — AHK marca o nome como local não-inicializada e o lado direito (a classe) também é lido como ela mesma, ainda sem valor. Foi exatamente isso com `appSettings := AppSettings.Defaults()` no helper de teste do RunRecordingWorkflow.

**Adições ao test harness na mesma sessão:**
- `Assert.Contains(actualStr, expectedSubstr, message)` — verifica substring case-insensitive em mensagens de erro.
- `Assert.Fail(message)` — falha incondicional, útil em branch que não deveria executar.

Ambos eram referenciados nos tests novos mas não existiam em `tests/_harness/assert.ahk`. Adicionados pra cumprir contrato.

**Lição pra anotar (terceira repetição da mesma lição em ângulo diferente):** **toda classe nova extraída de `app.ahk` precisa de auditoria de nomes de parâmetro/local antes de virar PR.** Memória não cura 17.5; só hábito mecânico cura. Roteiro de checagem ao terminar de extrair uma classe `Foo`:

1. `grep -rn "foo := " src_v2/` — variáveis locais com nome da classe.
2. `grep -rn "__New(.*foo[,)]" src_v2/` — parâmetros de construtor.
3. `grep -rn "is Foo" src_v2/` — cada type check é um lugar potencial de shadow.
4. Se a classe é serviço (ex: `BarService`), o sufixo padrão é `barSvc` (consagrado em 17.20: hotkeySvc, runSvc, syncEng, etc).

A tabela na seção 17.5 cresceu pra refletir essas descobertas — agora cobre 26 classes (vs 16 originais). Mas a tabela continua sendo **histórica**, não exaustiva. A regra real é: classe usada em `is X` no escopo → param/local não pode ser `x`.

### 17.27 — Refactors pós-Fase 8: descongestão do Composition Root (2026-05)

Depois de Fase 8 fechada, análise externa apontou (com razão) que `app.ahk` virou orquestrador de features ao invés de Composition Root puro. 103KB, 2221 linhas, com handler de ~50 linhas tomando decisões de negócio (`_OnLogLineReadObjectives`), 5 handlers replicando o mesmo pattern "evento → enrich via campaign → write CSV", 6 migrations one-shot inline, e bootDialog de 120 linhas adicionado por inércia. Sintoma clássico: toda feature nova caia em app.ahk porque era o caminho menos resistente.

**Refactors aplicados, em ordem de bang-for-buck:**

| # | Extração | Origem | Destino | Linhas movidas |
|---|---------|--------|---------|----------------|
| 1 | RouteAutomationService | `app._OnLogLineReadObjectives` | `app/services/route_automation_service.ahk` | ~50 (regra de negócio embutida) |
| 2 | RunRecordingWorkflow | `_OnStepCompleted`, `_OnTownVisitEnded`, `_OnDeathDetected`, `_OnBossDefeatedSplit`, `_OnLoadingMeasured` + helpers | `app/workflows/run_recording_workflow.ahk` | ~300 |
| 3 | MigrationsRunner | `app._RunMigrations` + 6 migrations inline | `app/migrations/migrations.ahk` | ~150 |
| 4 | PendingRunPrompt | `app._PromptPendingRunIfNeeded` + helpers de format | `app/boot/pending_run_prompt.ahk` | ~120 |
| 5 | ZoneMatcher + RouteGroupPolicy | `SyncEngine._NormalizeName`, `_StepMatchesZone`, `_TrySoftSwitchWithinGroup`, `_TryCompleteOnHubReturn`, `_TryCompletePendingHubReturnInGroup` | `app/policies/zone_matcher.ahk` + `app/policies/route_group_policy.ahk` | ~400 |

**Resultado quantitativo:**
- `app.ahk`: **103KB → 74KB** (28% menor)
- `sync_engine.ahk`: **42KB → 17KB** (60% menor)
- Testes: 2488 → ~2525 (37 novos: 16 ZoneMatcher + 21 RouteGroupPolicy + integrações)

**Estratégia: stubs antes de extrair.** Cada extração seguiu o padrão:

1. Criar classe nova com testes próprios (todos passando isolados)
2. Atualizar `app.ahk` pra instanciar e delegar
3. Manter comentários `; ============================================================\n; <NomeAntigo> -- extraido para <novo path>\n; ============================================================` no lugar onde o código antigo estava
4. Registrar includes em `speedkalandra.ahk` e `run_all_tests.ahk`
5. Validar 2488/2488 antes de seguir pra próxima extração

Os commentários deixados como pista (ex: "`; Refactor: handlers de StepCompleted... foram extraídos para RunRecordingWorkflow`") são críticos pra futuro debug — quando alguém for procurar onde "o código de gravar split" está, encontra a pista no app.ahk e segue pro arquivo certo. Custo: 1-3 linhas. Ganho: economiza 10 minutos de busca.

**Decisão pragmática no SyncEngine: 2 classes em vez de 4.** A análise externa sugeriu split em `ZoneMatcher`, `RouteAdvancePolicy`, `RouteGroupPolicy`, `OptionalStepPolicy`. Implementei apenas as 2 primeiras como classes; `RouteAdvancePolicy` e `OptionalStepPolicy` ficaram como métodos privados do SyncEngine (`_FindForwardStepByMap`, `_AdvanceCursorTo`, `_TryBackwardSwitchToOptional`).

Motivo: forward-only e backward-switch para optional são pequenos (40-80 linhas cada), não tem state próprio, e não são consumidos por outros arquivos. Extrair geraria classes anemicas com 1-2 métodos cada — custo de teste de construção > ganho de coesão. **YAGNI aplicado**: classes nascem quando têm reuso real, múltiplos consumers, ou state independente. Forward-only não tem nenhum desses; soft-switch + hub return tem (RouteGroupPolicy é consumida pelo handler `_OnObjectiveFlagSet` em loop, não só pelo dispatch principal).

**Convenção consolidada para refactors de extração:**

1. **Subpasta nomeia o conceito**, não o tipo: `app/policies/`, `app/workflows/`, `app/migrations/`, `app/boot/` (não `app/classes/` ou `app/extracted/`).
2. **Sufixo clássico para services**: `Service` quando é serviço long-lived com state runtime. Quando é utilitário puro/estático, sem sufixo (ZoneMatcher, não ZoneMatcherService).
3. **Políticas com state stateful** (case do RouteGroupPolicy que coordena timer carry preservation) — instanciável com deps por construtor.
4. **Test files espelham source path**: `app/policies/zone_matcher.ahk` → `tests/app/policies/test_zone_matcher.ahk`.
5. **Includes em ordem de dependência**: `app/policies/` antes de `app/services/sync_engine.ahk` (porque SyncEngine instancia RouteGroupPolicy).

**O que sobra no roadmap:**

- **`SettingsService`** — mover `SettingsDialog.ApplyChanges` para use case em `app/`. ROI baixo enquanto há apenas 1 dialog com esse pattern; **deferir até segundo dialog precisar do mesmo workflow** (princípio aplicado também em 17.13: "prepara o tipo, pára na derivação, deixa o consumer chegar quando precisar").

**Lição pra anotar:** **anti-padrão "tudo cai no Composition Root" é quase invisível quando emerge organicamente** — cada handler novo parece pequeno, cada subscribe parece coerente, e em meses viram 2000+ linhas de lógica de negócio embutida. Análise externa periódica (ou auto-revisão estruturada) eh barato e preventivo. **A métrica simples**: se um método de `app.ahk` tem mais de 30 linhas E não é instanciação ou subscribe wire-up, está pedindo extração.

### 17.28 — Lifecycle correctness em services long-running (2026-05)

Depois das extrações da 17.27, análise externa identificou 3 bugs de **ciclo de vida** que sobreviveram ao refactor estrutural — cada um suficiente pra causar perda de dados ou estado inconsistente em condições reais.

**P1 — Migration marcada como aplicada sem persistir o efeito.** O `MigrationsRunner.RunAll` fazia, por migration: `Apply(cfg, ini)` muta cfg → `ini.Write("1", "Migrations", key)` marca flag. As mutações em `cfg` (AppSettings) só iam pro disco no `Stop()` final via `_PersistFinalState`. Se o usuário fizesse Reload (Ctrl+Alt+Q não) ou crash entre boot e Stop, a flag ficava marcada mas a mudança real perdida — próximo boot pulava a migration sem ter aplicado o efeito.

**P2 — "Descartar run pendente" não zerava progresso da campanha.** O `PendingRunPrompt.MaybeShow`, no caminho "No", salvava `RunState.Empty()` no repo, mas não tocava em `Progress`. Em `app.Start`, `progress` já fora carregado do disco e era passado pra `campaign.Hydrate` mesmo após o discard. Resultado: timer e run zeravam, mas cursor + done steps + objectiveFlags da campanha anterior continuavam ativos. "Comecar do zero" não começava do zero.

**P3 — RunRecordingWorkflow acumulava subscribers em ciclos Stop/Start.** O workflow era instanciado em `app.Start()` (precisava de `_appSettings` carregado do disco), e seu construtor fazia 5 `bus.Subscribe()` pra StepCompleted/TownVisitEnded/DeathDetected/BossDefeated/LoadingMeasured. `Stop()` não desfazia nada. Se a mesma instância de `SpeedKalandraApp` ciclasse Stop → Start (cenário comum em testes integration ou em algum modo de hot-reload futuro), os handlers antigos ficavam vivos no EventBus — cada split/death/loading seria gravado N vezes (N = ciclos de restart).

**Padrão comum dos 3 bugs:** **estado de válido em memória, mas a janela de durabilidade/tempo-de-vida estava errada.** São invisíveis em testes felizes (boot completo → Stop completo → verifica disco) e só emergem com Reload/crash/ciclos. Refactor estrutural anterior não detecta isso porque foca em organização de código, não em ordens temporais entre operations.

**Fixes aplicados:**

| # | Fix | Arquivo | Estratégia |
|---|-----|---------|------------|
| P1 | `RunAll(cfg, ini, persistCallback)` | `app/migrations/migrations.ahk` | Ordem por migration: Apply → persistCallback(cfg) → MarkFlag. Se persist falha, flag não marcada — próximo boot tenta de novo. Callback opcional pra back-compat de testes. |
| P2 | `PendingRunPrompt.DidLastDiscard()` getter | `app/boot/pending_run_prompt.ahk` + `app/app.ahk` | Field `_lastDidDiscard` setado em discard, resetado em cada MaybeShow. App.Start chama `Progress.Empty()` + `progressRepo.Save()` antes de `campaign.Hydrate` se getter true. |
| P3 | `RunRecordingWorkflow.Stop()` unsubscribe | `app/workflows/run_recording_workflow.ahk` + `app/app.ahk` | 5 closures de handler guardadas como fields (`_handlerStepCompleted` etc), `Stop()` faz Unsubscribe em cada uma. App.Stop chama workflow.Stop. Idempotente. |

**Princípios consolidados:**

1. **"Marcar como feito" deve vir DEPOIS de "persistir o efeito".** Vale pra migrations, mas também pra qualquer flag de idempotência. A ordem temporária certa eh: efeito → persist → mark; nunca efeito → mark → persist. Se a máquina morre entre 2 e 3, idempotência do efeito segura no próximo boot.

2. **Decisões de UI que envolvem reset devem ser comunicadas ao caller via API explícita.** O `MaybeShow` retornar `RunState.Empty()` não era suficiente — o caller precisa saber se foi descarte (→ zera mais coisas) ou skip (→ mantém tudo). Adicionar getter `DidLastDiscard()` deixa o caller decidir o que mais resetar além do RunState. Mais limpo que passar callbacks ou refs por parâmetro.

3. **Subscribers em construtor exigem unsubscribe em Stop.** Se a classe assina events no `__New`, *toda* instância precisa de `Stop()` que desfaz. Sem isso, ciclos Start/Stop acumulam handlers e cada evento dispara N vezes. Na prática, AHK v2 closures inline (`(d) => this._Handler(d)`) criam refs novas a cada chamada — portanto o handler precisa ser **guardado em field** pra que o Unsubscribe ache a mesma ref depois.

4. **Testes felizes não cobrem essa categoria.** "Cria objeto, exercita, descarta" é o caso 99%. Mas Reload, crash, e Stop→Start são também parte do contrato e merecem teste explícito. **Heurística**: se uma classe tem `Subscribe`, deve ter `Stop` testado. Se persiste flag, a ordem deve ser testada com fault injection (callback que throw).

**Nota sobre AHK v2 e closures comparadas por referência.** `EventBus.Unsubscribe` compara callbacks com `=` (ref equality). Cada `(data) => this._Method(data)` cria nova closure, então subscribe + unsubscribe com lambdas inline não batem. Solução: criar a closure UMA vez no construtor, salvar em field, usar a mesma ref no Subscribe e no Unsubscribe.

**Resultado quantitativo:**
- Linhas adicionadas: ~50 (incluindo doc) entre os 3 fixes
- Testes novos: 12 (4 por fix), cobrindo persist failure, idempotência de Stop, ciclo Stop→Start sem duplicação de subscribers
- Sem regressão nos 2526 testes existentes — todos os fixes mantêm back-compat (callback opcional, getter novo, método Stop novo)

**Sobre o ponto residual de SettingsDialog.** O analista reapontou que `SettingsDialog` continua validando, mutando AppSettings, salvando repo e rebindando hotkeys dentro de `ui/`. Reconhece que não é regressão nova, e o ponto continua deferido com a mesma justificativa de 17.27 (YAGNI até segundo dialog precisar do mesmo workflow). A dívida arquitetural existe, mas o ROI de extrair eh baixo enquanto for um caso único, e os 3 bugs de lifecycle desta sessão tinham priority maior porque são falhas de comportamento — dvida arquitetural pode esperar; perda silenciosa de dados, não.

### 17.29 — Bug do cemetery group: physicalZones bloqueando soft-switch (2026-05)

Usuário reportou bug recorrente da rota oficial: ao entrar em Tomb of the Consort ou Mausoleum of the Praetor durante a fase do Cemetery of the Eternals, o tempo dentro das sub-zonas era ignorado. As steps `a1_09_tomb_consort_key` e `a1_10_mausoleum_draven_key` completavam com **duração zero** quando o jogador voltava ao Cemetery e a fala do NPC do portão setava as flags em loop.

**Causa-raiz.** A configuração do INI do step `a1_08_cemetery_find_tombs`:

```ini
[Step:a1_08_cemetery_find_tombs]
Map=Cemetery of the Eternals
CompletionMode=next_step
RouteGroup=a1_cemetery_keys
PhysicalZones=Cemetery of the Eternals||Tomb of the Consort||Mausoleum of the Praetor
```

A intenção do editor da rota foi razoável: "durante o step de explorar o cemitério procurando as tumbas, todas essas zonas são parte da fase". Mas a ordem das policies em `SyncEngine.TryAdvanceToZone` capturava isso como idempotência:

```
1. Hub return       — declina (a1_08 é next_step, não objective_return)
2. Idempotency      — StepMatches(a1_08, "tomb of the consort") via
                       physicalZones → MATCH → return false  ← TRAVAVA AQUI
3. Town zone filter
4. Soft-switch within group  ← nunca alcançado
5. Backward switch
6. Forward-only
```

Resultado: cursor preso em a1_08 enquanto o jogador estava dentro da Tomb. Tempo da sub-zona ia para o segment do hub. Quando voltava ao Cemetery e a fala do NPC casava o `completionRegex`, o `_OnObjectiveFlagSet` em loop completava a1_09 e a1_10 com `GetSegmentMs()=0`. Sintoma exato relatado: "ignora a etapa que se passa dentro da tumba e do mausoleum".

**Distinção semântica que estava implícita.** `mapName`/`aliases` representam o **objetivo** do step ("a zona-alvo é X"). `physicalZones` representa **tolerância** ("esta zona é aceita como volta intermediária pós-objetivo, não me tire daqui"). Soft-switch dentro do route group deve mirar APENAS objetivos, nunca tolerância — porque é decisão de "o jogador atingiu o alvo de outro step", não "o jogador está numa zona tolerada do step atual". Idempotency, por sua vez, pode (e deve) usar a definição mais ampla.

**Complicação adicional.** Os steps `a1_08_cemetery_find_tombs` e `a1_11_cemetery_lachlann` ambos têm `Map=Cemetery of the Eternals`. Soft-switch ingênuo (cursor em a1_08, jogador permanece em Cemetery) pularia para a1_11. O safeguard que já existia — gate trancado quando `IsRouteGroupComplete=false` — é o que protege esse caso: a1_11 é o gate (completionMode=objective, único do group que não é next_step nem objective_return) e o group só completa quando ambos `a1_consort_defeated` e `a1_draven_defeated` estão setadas.

**Fix combinado em duas mudanças cirúrgicas:**

| # | Arquivo | Mudança |
|---|---------|---------|
| 1 | `app/policies/route_group_policy.ahk` | `TrySoftSwitch` troca `ZoneMatcher.StepMatches` (inclui physicalZones) por `ZoneMatcher.StepMapNameMatches` (só mapName + aliases). Soft-switch agora só mira "objetivo do step". |
| 2 | `app/services/sync_engine.ahk` | `TryAdvanceToZone` reordena: soft-switch within group precede idempotency, **com guarda `currentStep.routeGroup != ""`**. Steps fora de grupo mantêm idempotency primeiro (preserva comportamento). |

Validação dos cenários relevantes pós-fix:

| Cursor | Zona | Pré-fix | Pós-fix |
|--------|------|---------|---------|
| a1_08 (hub) | SubA (Tomb) | Idempotency MATCH via physicalZones → cursor preso | Soft-switch (StepMapNameMatches) → a1_09 |
| a1_08 (hub) | Hub | Idempotency MATCH via mapName → noop | Soft-switch tenta a1_11 (gate) → trancado → declina → idempotency → noop |
| a1_03 (test fixture, group, no physicalZones) | Tomb A (mapName atual) | Soft-switch self-skip → idempotency MATCH → noop | Mesmo comportamento (preservado) |
| a1_01 (sem group) | Clearfell (próximo) | Soft-switch guard skip → idempotency mismatch → forward-only avança | Mesmo (guard `routeGroup != ""` preserva path) |

**Princípios consolidados:**

1. **`mapName`/`aliases` são objetivo; `physicalZones` é tolerância.** Onde a engine de matching precisa decidir "este step é o alvo da zona X", use só objetivo. Onde precisa decidir "esta zona é aceita pelo step", use objetivo + tolerância. Não misture as duas semânticas no mesmo predicado — `StepMatches` continua existindo para idempotency e force sync; `StepMapNameMatches` para soft-switch.

2. **Soft-switch dentro de group precede idempotency.** Quando o cursor está em step de route group e a zona muda, há 3 possibilidades dignas de checagem antes de "já estou no objetivo": (a) hub return, (b) outro step do group casa, (c) idempotency. A ordem (a) → (b) → (c) é mais informativa do que (a) → (c) → (b) — porque idempotency em route groups é *too eager* quando physicalZones lista zonas de outros sub-steps.

3. **Guard `routeGroup != ""` preserva o path comum.** Para steps sem group (~80% dos steps da rota oficial), idempotency primeiro é o comportamento correto e mais barato. A reordenação só ativa quando faz sentido — quando estamos no "escopo" de um group que pode ter sub-steps elegíveis.

4. **Smell arquitetural detectado mas tolerado.** Dois steps no mesmo group com mesmo `mapName` (a1_08 e a1_11 ambos `Cemetery of the Eternals`) é cheiro arquitetural — força gymnastics de gate detection. Aceito pragmaticamente porque (i) o gate filter já protege, (ii) refatorar o INI quebra outras decisões de UX ("qual zona mostro como alvo do step?"), (iii) é específico da estrutura do PoE2 que o jogo expõe assim. Documentado aqui para que próximo refactor não esqueça por que o gate filter existe.

**Resultado quantitativo:**
- Linhas modificadas: ~30 (2 substituições + comentários explicativos extensos)
- Testes novos: 6 (2 em RouteGroupPolicy validando mapName-only matching; 4 em SyncEngine reproduzindo o cenário cemetery completo, incluindo full flow consort→draven→lachlann e medição correta de duração da sub-zona)
- Sem regressão nos 2538 testes existentes — testes existentes do RouteGroupPolicy/SyncEngine não exercitavam physicalZones em route groups, então a troca `StepMatches → StepMapNameMatches` não afeta cenários cobertos

### 17.30 — Bug do cemetery group, parte II: chamada órfã a método removido (2026-05)

Depois do fix de 17.29, BDK (amigo do usuário) rodou uma run real e reportou que **a1_09 (Tomb), a1_10 (Mausoleum), a1_11 (Lachlann) e a1_12 (Hunting Grounds Freythorn) não foram registrados** no `splits_v2.csv` — o cursor pulou de a1_08 direto pra a1_13. O bug do cemetery group continuava, mas com sintoma diferente.

**Diagnóstico via debug zip do BDK.** O `speedkalandra.log` mostrou 5 ocorrências deste erro durante a fase do cemetery:

```
[2026-05-05 16:06:09] ERROR [EventBus] Handler de 'Evt.LogLineRead' falhou:
  This value of type "Class" has no method named "_DiagLog". | Line: 6961
```

Timestamps: 16:06:09, 16:10:06, 16:15:25, 16:16:48, 16:17:22 — exatamente quando o NPC do portão falava "You have the keys?".

**Causa-raiz.** Em `route_automation_service.ahk._ApplyCompletionRegex`:

```ahk
if (stepObj.routeGroup = "a1_cemetery_keys")
    SyncEngine._DiagLog("CompletionRegex match: step='" stepObj.id "'...")  ; <- ORFÃ

this._triggerMatcher.ResetAndProgress(keyComp)
flag := stepObj.requiredFlag != "" ? stepObj.requiredFlag : stepObj.completionFlag
if (flag != "" && !this._campaign.IsFlagSet(flag))
{
    this._campaign.SetFlag(flag, true)        ; <- NUNCA EXECUTA
    ...
}
```

`SyncEngine._DiagLog` foi um método estático de diagnóstico que escrevia em `data/sync_diag.log` (visível nos logs antigos do projeto). Em algum refactor o método foi removido junto com chamadas internas em SyncEngine e RouteGroupPolicy, mas a chamada em RouteAutomationService **sobreviveu como referência órfã**.

Quando `completionRegex` de a1_09 batia na fala do NPC, a chamada órfã lançava exception. EventBus capturava, registrava ERROR, e o handler do RouteAutomationService **abortava no meio do for loop**. Steps subsequentes (a1_10, a1_11, ...) não eram processados naquela linha, e o `SetFlag` que viria DEPOIS da chamada órfã nunca executava — nem para a1_09.

**Cascata de falhas observada:**

1. NPC fala → exception → nem `a1_consort_defeated` nem `a1_draven_defeated` são setadas
2. Hub return não dispara em ZoneChanged subsequente (flag ausente)
3. Cursor permanece em a1_10 (último soft-switch do user)
4. Forward-only não cascateia a1_10 (completionMode=objective_return tem regra própria, não pulado pelo cascade)
5. a1_11 (gate, mapName=Cemetery) e a1_12 (Hunting Grounds) também não completam por razões relacionadas
6. Em algum momento o user vai pra Ogham Village/Manor; cursor finalmente avança "saltando" de a1_10 pra a1_13 sem registrar splits intermediários

**O fix de 17.29 funcionou.** Soft-switch a1_08→a1_09→a1_10 ocorreu corretamente (visível nas mudanças de zona Tomb/Mausoleum no log). O problema era posterior ao soft-switch — no fluxo de finalização via NPC dialogue.

**Fix em duas mudanças cirúrgicas:**

| # | Arquivo | Mudança |
|---|---------|---------|
| 1 | `app/services/route_automation_service.ahk` | Substituir chamada órfã `SyncEngine._DiagLog(...)` por `this._LogInfo(...)` (método já existente na classe que usa LogService injetado com fallback no-op). Mantém diagnostic mas via canal robusto. |
| 2 | `app/services/route_automation_service.ahk` | Envolver `_ApplyEngageRegex` + `_ApplyCompletionRegex` em try/catch dentro do for loop em `_OnLogLineRead`. Defesa em profundidade: se um step lança, os subsequentes ainda são processados. |

**Princípios consolidados:**

1. **Refactor que remove método precisa varrer chamadas em todo o projeto.** O `_DiagLog` foi removido sem buscar chamadores. AHK é dinâmica — o compilador não pega chamadas de métodos inexistentes. Próximo refactor de remoção de API: `grep` por nome do método antes de deletar, e considerar deprecation warning antes de remoção se houver chance de chamadas externas.

2. **Loops de dispatch sobre coleções precisam de isolamento por item.** Quando RouteAutomationService itera N steps, um bug em UM step não pode quebrar todos. Try/catch ao redor do processamento de cada step custa pouco (uma exception por linha de log no pior caso) e protege contra bugs imprevisíveis. Mesma lógica aplicável a outros despachadores (LoadingDetectionService, OverlayInteractionService, etc.) — oportunidade de hardening futuro.

3. **EventBus capturando exceptions não é substituto pra defesa interna.** O EventBus já captura exception por subscriber (é por isso que vimos ERROR no log e não crash do app), mas isso protege apenas que outros subscribers continuem rodando. **Dentro** de um subscriber, se uma exception interrompe meio-caminho, o próprio handler fica em estado inconsistente. Try/catch interno é necessário quando o handler itera sobre múltiplos itens independentes.

4. **Logs de ERROR silenciosos são o pior dos mundos.** O bug existia em runs reais há quem sabe quanto tempo — cada vez que cemetery rodava, ERROR aparecia no log mas ninguém percebia até ter que investigar splits faltando. Consideração futura: alertar visualmente (overlay widget) quando handler ERROR ocorre, ou pelo menos contar e expor métrica.

**Por que os 2538 testes não pegaram isso:** os testes do RouteAutomationService usam `_MakeStep` direto, sem `routeGroup` cemetery_keys. O ramo `if (stepObj.routeGroup = "a1_cemetery_keys") SyncEngine._DiagLog(...)` nunca era exercitado. **Cobertura de teste baseada em valor de dado** (e não só em fluxo) é importante onde há hardcode de identificadores específicos.

**Resultado quantitativo:**
- Linhas modificadas: ~25 (substituição + try/catch + `_LogWarn` novo + comentários)
- Testes novos: 2 (regression direto do bug do BDK + defesa em profundidade com log stub que lança)
- Total esperado: 2544 + 2 = **2546 testes passing**

### 17.31 — Cascade trava em optional+objective (2026-05)

Durante a investigação de 17.30 o usuário levantou outra suspeita observada no comportamento real da rota: "travou no objetivo opcional de freythorn". Análise do código confirmou um bug separado, não relacionado ao `_DiagLog`.

**O bug.** A rota tem `a1_13_freythorn_rituals_king_mists` configurado como `Optional=1` + `CompletionMode=objective`. Configuração legítima: o King in the Mists é um boss opcional que dá +30 Spirit + Patua, mas não é obrigatório pra progredir o ato. Auto-skip de optional existia em `CampaignService._FindNextPending` desde a Fase 4.4.3, então quando o cursor cascateava de a1_12 (Hunting Grounds) através de a1_13 com destino a1_14 (Ogham Farmlands), o `_FindNextPending` corretamente pulava a1_13.

Mas o cenário que travava era diferente: usuário **entra** em Freythorn primeiro, entáo cursor vai pra a1_13 via post-loop check do `_AdvanceCursorTo`. Se ele depois sai sem matar o boss (vai pra Ogham), o cascade falha:

```ahk
; SyncEngine._AdvanceCursorTo (pre-fix)
if (IsObject(currentStepBefore)
    && (currentStepBefore.completionMode = "objective"
     || currentStepBefore.completionMode = "objective_return"))
{
    break    ; <- nao verifica .optional
}
```

O break não checava `.optional`. Resultado: cursor preso em a1_13 mesmo que o step seja opcional. E todas as zonas seguintes (Ogham Village, Manor Ramparts, etc.) também travavam, porque a cada nova `ZoneChanged` o cursor ainda estava em a1_13 e o cascade dava break antes de cascateir.

**Inconsistência entre dois sistemas de auto-skip:**

| Local | Trata optional? |
|-------|-----------------|
| `CampaignService._FindNextPending` | Sim, pula |
| `SyncEngine._AdvanceCursorTo` | Não, ignorava `.optional` |

Isso só manifestava no caminho `cursor=optional+objective → zona forward`. O caminho `cursor anterior → zona forward além do optional` já funcionava porque passava pelo `_FindNextPending` via `CompleteCurrentStep`.

**Fix em uma mudança círurgica em SyncEngine._AdvanceCursorTo:**

Quando cursor está em step `optional+objective` ou `optional+objective_return`, em vez de break, pular via `GoToStep(currStep+1)` (ou atravessar fronteira de ato se for o último step):

```ahk
if (IsObject(currentStepBefore)
    && (currentStepBefore.completionMode = "objective"
     || currentStepBefore.completionMode = "objective_return"))
{
    if !currentStepBefore.optional
        break

    ; Optional+objective/objective_return: pula sem completar
    nextIdx := currStepIdx + 1
    if (nextIdx > actObj.steps.Length)
    {
        if (currActIdx >= actCount)
            break
        this._timer.PushUndoSnapshot()
        this._campaign.GoToStep(currActIdx + 1, 1)
        this._timer.ResetSegment()
        anyCompleted := true
        continue
    }
    this._timer.PushUndoSnapshot()
    this._campaign.GoToStep(currActIdx, nextIdx)
    this._timer.ResetSegment()
    anyCompleted := true
    continue
}
```

**GoToStep, não CompleteCurrentStep.** Decisão de design importante: `CompleteCurrentStep` marca o step como `done=true` e gera `StepCompleted` event (que vira split no CSV). Optional **não-feito** não deve gerar split nem ser marcado done. O step fica como "abandoned/skipped" — cursor passou sem cumprir, não existe split fantasma indicando que o jogador o cumpriu.

**Princípios consolidados:**

1. **Auto-skip de optional precisa ser consistente em TODOS os caminhos.** Quando uma semântica como "optional pode ser pulado pelo sistema" é introduzida em um lugar (`_FindNextPending`), todos os outros pontos que potencialmente lidam com cursor avançando precisam aplicar a mesma regra. O bug aqui não foi um código errado, foi uma feature aplicada parcialmente. Quando `Optional=1` foi adicionado ao Step domain, faltou olhar todos os pontos de cascade.

2. **"Pular" e "completar" têm semânticas distintas.** A diferença entre `GoToStep` (move cursor sem mutar `done`) e `CompleteCurrentStep` (marca `done` + gera evento) reflete a diferença entre "cursor passou por aqui" e "objetivo cumprido". Pra optional pulado, o cursor passou mas o objetivo não foi cumprido — logo, `GoToStep`. Misturar os dois geraria splits fantasma, inflando estatísticas com 0 esforço real.

3. **Cobertura de teste por estado inicial do cursor.** Os testes existentes cobriam o caso `cursor antes do optional → zona após optional` (cascade pula via FindNextPending). Mas não cobriam `cursor EM optional+objective → zona forward`. Cobertura de teste não é só por flow ou por valor de dado — é também por **estado inicial do sistema** quando a ação inicia. Bugs em casos onde o sistema chega em um estado por um caminho que os testes não exercitaram são comuns.

4. **A confusão entre 17.30 e 17.31 mostra valor de instrumentar runs reais.** O log do BDK + splits.csv juntos contavam uma história com múltiplos bugs sobrepostos: 17.30 (ERROR `_DiagLog`) explicava por que cemetery group quebrava; 17.31 explicava por que mesmo depois disso, optionals ainda travariam o cascade. Sem o log + splits + INI, separar os dois bugs seria muito mais lento.

**Resultado quantitativo:**
- Linhas modificadas: ~30 em `SyncEngine._AdvanceCursorTo` (excecao + GoToStep + travessia de ato + comentários)
- Testes novos: 6 (regression direto + skip não emite StepCompleted + mandatory ainda trava + fluxo realista visit→leave + edge case na fronteira de ato + objective_return também pulável)
- Total esperado: 2546 + 6 = **2552 testes passing**

### 17.32 — Exceções conscientes ao princípio "sem globais" (2026-05)

A seção 3 lista oito princípios não-negociáveis. Em geral todos foram mantidos, mas ao longo da execução algumas exceções foram introduzidas com justificativa. Esta seção registra cada uma para que apareçam na primeira leitura do doc — não enterradas em comentário inline.

**Singleton estático em `OverlayInteractionService`.**

O serviço é instanciado pelo Composition Root como qualquer outro, mas tambem expõe `OverlayInteractionService.Instance` (referência estática auto-setada no `__New`). `WidgetBase.Show()` e `LayoutWidgetBase.Show()` consultam essa referência ao construir cada `Gui()` para registrar o `Hwnd` no service de drag/click-through.

**Por que não passar por construtor.** Cada widget é construído com posições/tema/bus/services específicos. Adicionar `OverlayInteractionService` ao construtor de TODOS os 8 widgets + LayoutContainers + qualquer dialog futuro que crie Gui registrável é fricção sem retorno: o service é universal (toda janela do app fala com ele) e não tem alternativa por widget. DI fica simbólico.

**Por que é seguro.** A referência `Instance` é setada uma vez no `__New` e nunca trocada em runtime. O Composition Root garante criação única. Em testes, basta NÃO instanciar o service (o `WidgetBase.Show` checa `OverlayInteractionService.Instance != ""` antes de registrar) — `headless` mode já cobre esse caminho. Não há global mutável de estado de domínio; é fundamentalmente um registry de Hwnds gerenciado pelo próprio service.

**Limite do escape.** Esta é a ÚNICA classe do projeto autorizada a ter singleton estático. Se aparecer um segundo caso (`SomethingService.Instance`), provavelmente há erro de design — verificar se a injeção real era viável antes de copiar o padrão.

**Subscriptions sem unsubscribe em services do app.ahk.**

Services instanciados pelo Composition Root assinam events via `bus.Subscribe(...)` no construtor mas em geral não tinham `Stop()`/`Dispose()` que faz `Unsubscribe`. O argumento aceito até a 17.28 era "o bus morre junto com o app, não vaza".

17.28 mostrou que isso quebra em **ciclos `Stop()`/`Start()` na mesma instância de `SpeedKalandraApp`** (cenário de testes integrados ou hot-reload futuro). RunRecordingWorkflow recebeu Stop() proper lá.

**Convenção consolidada (refactor R8, 2026-05):** TODA classe que faz `Subscribe` no construtor deve guardar o callback como field e expor `Dispose()` (ou `Stop()` para classes pré-R8 cujo nome não caiba) que faz Unsubscribe idempotente. App.Stop() tem dispose chain que itera sobre todos os services e chama `Dispose()` defensivamente via `HasMethod("Dispose")`.

**Status dos services do projeto (atualizado em 2026-05):**

| Service | Subs | Status | Adicionado em |
|---|---|---|---|
| RunRecordingWorkflow | 5 | `Stop()` | 17.28 |
| LoadingDetectionService | 3 | `Dispose()` | R4 |
| RunLifecycleService | 7 | `Dispose()` | R6 |
| SyncEngine | 3 | `Dispose()` | R8 |
| BossFightTracker | 6 | `Dispose()` | R8 |
| BossTimerService | 7 | `Dispose()` | R8 |
| TownVisitTracker | 8 | `Dispose()` | R8 |
| LoadingTotalsService | 5 | `Dispose()` | R8 |
| RouteAutomationService | 1 | `Dispose()` | R8 |
| GemPlannerService | 2 | `Dispose()` | R8 |
| OverlayModeService | 5 | `Dispose()` | R8 |
| OverlayModeApplier | 1 | `Dispose()` | R8 |
| HotkeyService | — | `Stop()` (lifecycle de Hotkey) | desde Fase 7.2 |
| FocusAutoPauseService | — | `Stop()` (lifecycle de SetTimer) | desde Fase 9.1 |
| PanelKeyService | — | `Stop()` (lifecycle de Hotkey + watchdog) | desde Fase 9.8 |
| OverlayInteractionService | — | `Stop()` (lifecycle de Hotkey/OnMessage) | singleton (vide acima) |

Services read-only sem Subscribe (Analytics, TargetService, RunStatsPlotBuilder, SummariesExportService, RunExportService, XpService, TriggerMatcher, HudPixelScanner) não precisam.

**Pattern consolidado (replicar quando criar service novo):**

```ahk
class FooService
{
    _bus := ""
    _handlerXxx := ""    ; ref estável pra Unsubscribe

    __New(bus)
    {
        this._bus := bus
        this._handlerXxx := (data) => this._OnXxx(data)
        this._bus.Subscribe(Events.Xxx, this._handlerXxx)
    }

    Dispose()
    {
        if (this._handlerXxx != "")
        {
            this._bus.Unsubscribe(Events.Xxx, this._handlerXxx)
            this._handlerXxx := ""
        }
    }
}
```

Closures fat-arrow inline criam refs novas a cada chamada — impossível Unsubscribe (vide 18.5). Por isso o handler vai como field, nunca inline no Subscribe.

**`SettingsDialog` mistura coleta de UI com mutação de AppSettings + Save + Rebind.**

Reconhecido como dívida arquitetural em 17.27 e 17.28. O dialog deveria publicar `Cmd.SettingsChanged(changesMap)` no bus e um `SettingsService` em `app/services/` aplicaria a mudança. Hoje o dialog faz tudo (validação, mutação, save, hotkey rebind).

**Por que não foi extraído.** YAGNI: enquanto for o único dialog com esse pattern, o ROI de extrair é baixo. Quando aparecer um segundo caso (CampaignEditor faz coisa parecida com a rota, mas via `routeRepo` injetado já no construtor — não tem o mesmo problema), aí extrai.

**Riscos aceitos.** (a) Refactor parcial obrigaria revisitar dialog inteiro. (b) Lógica de validação fica em `ui/`, não testável sem instanciar dialog (mitigado com `ApplyChanges` separado da GUI dentro da própria classe — vide 17.22). (c) Se aparecer um terceiro dialog antes do segundo, vira massa crítica de débito.

### 17.33 — Persistência atômica via .tmp + FileMove (refactor R10, 2026-05)

Até R10, operações de "reescrever arquivo inteiro" eram vulneráveis a corrupção em crash durante a escrita. Dois pontos críticos:

**1. `JsonFile.Write` (export de runs)**

```ahk
; Antes:
try FileDelete(this._path)
FileAppend(json, this._path, "UTF-8")
```

Gap entre `FileDelete` e `FileAppend`. Crash nesse intervalo (raro mas possível: power loss, BSOD, kill -9 do processo) deixa o arquivo permanentemente perdido. O proximo boot lê `FileExist=false` e reseta state que o user achou que tinha salvo.

**2. `SummariesRepository.Write{Step,RunStep,Boss}Summaries` (rewrite periódico ao finalizar runs)**

```ahk
; Antes:
try FileDelete(this._stepCsv.GetPath())
this._stepCsv.EnsureHeader(STEP_HEADER)
for _, summary in stepSummariesList
    this._stepCsv.AppendRow(row)    ; FileAppend por linha
```

Pior: gap entre `FileDelete` e `EnsureHeader` (header perdido), depois N gaps entre cada `AppendRow`. Crash deixa CSV truncado com header + parte das linhas — lido como "válido" por ReadAllRows mas com dados incompletos. Estatísticas (best/avg/last) ficam erradas silenciosamente.

**Pattern atomic write.** Clássico do Unix/Windows:

1. Escreve conteúdo completo em `<path>.tmp`
2. `FileMove <path>.tmp -> <path>` (operacão atômica no NTFS via `MoveFileEx`)

NTFS garante atomicidade no nível da entrada do diretório: ou o destino aponta para o inode antigo, ou aponta para o novo. **Não existe estado intermediário observável**. Crash antes do `FileMove` deixa `<path>` intacto com conteúdo antigo + `.tmp` órfão (que é deletado defensivamente na próxima escrita). Crash durante o `FileMove` é atomicamente "foi ou não foi" — nunca parcial.

**Implementação:**

| Componente | Mudança |
|---|---|
| `infra/io/atomic_write.ahk` | Novo. Helper estático `AtomicWriter.WriteAll(path, content, encoding)` que faz cleanup de `.tmp` órfão + `FileAppend` em `.tmp` + `FileMove` para path. Cria diretório intermediário se necessário. |
| `infra/io/json_file.ahk` | `Write` substitui `FileDelete + FileAppend` por chamada única a `AtomicWriter.WriteAll`. |
| `infra/io/csv_file.ahk` | Novo método `WriteAllRows(headerArray, rowsList)` constrói buffer (header + rows formatadas) em memória e chama `AtomicWriter.WriteAll`. **Validação de colunas acontece antes de tocar disco** — row inválida lança sem deixar estado parcial. |
| `infra/summaries_repository.ahk` | `WriteStepSummaries`, `WriteRunStepSummaries`, `WriteBossSummaries` constróem lista e delegam para `CsvFile.WriteAllRows`. |

**Princípios consolidados:**

1. **Toda operação que reescreve arquivo deve ser atômica.** O custo é ~50 linhas de código + 1 buffer em memória. O ganho é que arquivo nunca é visto em estado parcial — reader concorrente (raro no nosso caso, mas existe entre o app e o legacy reader externo) sempre vê OLD ou NEW, nunca half-written. Ainda mais importante: imune a crash durante save.

2. **Buffer-then-write é mais rápido que loop-FileAppend.** N `FileAppend(line, path)` faz N abre+seek+write+close no OS. Um `FileAppend(buffer, path)` faz uma unica abertura. Pra CSVs com 100s de linhas (caso típico de step_summary depois de muitas runs), é ~10x mais rápido. (Não foi a motivação do refactor, mas ganho de bonus.)

3. **Validar antes de escrever, sempre.** `WriteAllRows` valida `expected columns` em todas as rows antes de gerar buffer. Sem isso, uma row inválida no meio da lista geraria buffer parcial — mesmo com atomic write, o resultado seria CSV truncado (apenas atomico no momento do FileMove). Validar primeiro garante que ou todo o buffer eh consistente, ou nada eh escrito.

4. **`.tmp` órfão é inevitável — cleanup defensivo no início.** Se app crashou antes do `FileMove`, o `.tmp` fica no disco. Próxima execução de `WriteAll` deve deletar antes de começar a escrever — senão `FileAppend` faria append em cima do residuo do crash anterior, contaminando o novo conteúdo.

**Limites do escopo R10:**

Atomic write **não foi aplicado a `IniFile`**. Cada `IniWrite()` individual da AHK API é atomicamente seguro no nível de chave (a chamada do Windows preserva o arquivo enquanto edita), mas múltiplos `IniWrite` em sequência (como `RunStateRepository.Save` que chama N writes) deixam estado intermediário visível no disco. Aplicar atomic ali requer reestruturação maior: ler INI inteiro pra Map, mutar Map em memória, serializar Map de volta pra texto INI, e escrever via AtomicWriter. **Deferido como R10.5 se houver evidência de bug real de corrupção de INI**. Hoje, o RunState é reescrito a cada split (alta frequência) e nunca tivemos relato de corrupção — IniWrite individual + ordem das writes é "good enough" pro caso atual.

CSVs append-only (splits.csv, deaths.csv, loading.csv, run_summary.csv) também **não usam atomic write**. `FileAppend` de uma linha é fundamentalmente atômico no Windows (writes pequenos são single-syscall). Aplicar atomic em append seria over-engineering.

**Resultado quantitativo:**
- Linhas adicionadas: ~120 (atomic_write.ahk + WriteAllRows + 9 testes novos AtomicWriter + 5 testes novos CsvFile.WriteAllRows)
- Linhas removidas: ~45 (loops AppendRow nos 3 métodos do SummariesRepository)
- Testes novos: 14 (9 AtomicWriter + 5 CsvFile.WriteAllRows). Os testes existentes do SummariesRepository continuam validando o comportamento end-to-end (mesmo conteúdo no arquivo final).
- Cobertura de crash real: impossível testar diretamente em unit tests sem fault injection no FS. Confiamos na garantia do NTFS.

### 17.34 — INIs em UTF-8 com auto-migração de UTF-16 LE (refactor R11, 2026-05)

> **⚠️ STATUS: auto-migration REVERTIDA.** A infra `TextEncoding` foi entregue e tem 15 testes verdes, mas a auto-chamada em `IniFile.__New` causava corrupção silenciosa em testes que faziam o ciclo "IniFile cria > IniWrite > IniFile reabre" (IniRead retornava `""` após a conversão, mesmo com BOM UTF-8 corretamente gravado). Causa raiz não diagnosticada — hipóteses: `FileRead(path, "UTF-16")` com BOM presente perde dados em re-encode; `FileAppend` em `.tmp` recém-deletado não gera BOM em todos os casos; ou racing entre `IniWrite` flush e `FileRead`. INIs do projeto continuam **UTF-16 LE BOM** (estado pré-R11). O helper `TextEncoding.MigrateIniToUtf8` continua disponível para uso manual ou futuro refactor quando o bug for diagnosticado.
>
> A descrição abaixo é o **design original** — mantida pra referência histórica e pra eventual retomada do trabalho.

AHK v2 cria arquivos INI em **UTF-16 LE com BOM** por default quando `IniWrite` chama o arquivo pela primeira vez. Isso eh herdado de "comportamento Windows ANSI legacy onde UTF-16 LE eh o encoding seguro pra tudo". Em 2026, isso eh anacronismo: arquivos sao 2x maiores que necessario, e ferramentas modernas (diff tools, editors, git) lidam melhor com UTF-8.

Mantemos compatibilidade total: arquivos antigos UTF-16 sao convertidos transparentemente; arquivos novos nascem em UTF-8 quando AHK rescreve via IniWrite após a migração (porque AHK detecta o BOM UTF-8 existente).

**Implementação:**

| Componente | Mudança |
|---|---|
| `infra/io/text_encoding.ahk` | Novo. `TextEncoding.DetectBom(path)` retorna `"UTF-16-LE"` / `"UTF-16-BE"` / `"UTF-8-BOM"` / `"NONE"`. `ConvertUtf16ToUtf8(path)` usa AtomicWriter (R10) pra reescrever atomicamente em UTF-8 com BOM. `MigrateIniToUtf8(path)` orquestra detect+convert e eh idempotente. |
| `infra/io/ini_file.ahk` | `__New` chama `TextEncoding.MigrateIniToUtf8(this.path)` em `try`. Auto-migra na primeira instânciação de IniFile apontando para o path. Idempotente para arquivos já UTF-8, inexistentes, ou sem BOM. |

**Por que UTF-8 *com* BOM e nao UTF-8-RAW (sem BOM)?**

AHK v2 detecta encoding em IniRead/IniWrite através do BOM:
- UTF-16 LE BOM (`FF FE`): le como UTF-16 LE
- UTF-8 BOM (`EF BB BF`): le como UTF-8 → caracteres acentuados (cao, cafe, posicao) funcionam
- Sem BOM: trata como **ANSI (CP1252 em Windows pt-BR)** — corrompe acentos

Se gravassemos sem BOM, o próximo IniRead leria "posicao" como `posição` (CP1252 default) ou similar lixo. UTF-8 com BOM eh o único estado seguro que mantém AHK feliz e arquivo legivel em editors modernos.

**Por que auto-migration em `__New` e nao migration explicita uma vez?**

O app instancia 8+ IniFiles diferentes (settings, progress, run state, gem plans, targets, campaign route, build planner, etc). Cada um aponta pra path diferente. Auto-migration em `__New` significa:

1. Zero código de migration central: cada IniFile cuida do seu próprio path.
2. Idempotente: chamadas redundantes sao no-ops (no caso comum onde main ini eh compartilhado entre vários repos, ate' a primeira migra; demais detectam UTF-8-BOM e retornam early).
3. Cobre INIs futuros sem mudança de código: novo repo + novo IniFile = já nasce com migration coberta.
4. Testes isolados: cada teste que cria IniFile temporario nao precisa pensar em migration.

**Performance:**

- `MigrateIniToUtf8` em arquivo já UTF-8: faz 1 `FileRead` de ~3 bytes (BOM detect), retorna. Custo desprezível (<1ms).
- `MigrateIniToUtf8` em arquivo UTF-16: faz `FileRead(UTF-16)` + `AtomicWriter.WriteAll(UTF-8)`. Custo ~10-50ms num arquivo de 50KB. Acontece **uma vez** por path por boot do app que tinha INI antigo.
- `MigrateIniToUtf8` em arquivo inexistente: 1 `FileExist`, retorna. Custo zero.

**Limites e não-fazeres:**

- **UTF-16 BE não eh convertido automaticamente** (retorna `"skipped-be"`). Raro em Windows mas existiria se alguém importasse INI de Mac/Unix. AHK v2 `FileRead` não tem flag explicita para UTF-16 BE; tratamos como caso edge não-coberto.
- **Arquivos sem BOM não sao tocados** (retorna `"no-bom"`). Sem BOM = sem informação sobre encoding. Pode ser ANSI legacy ou UTF-8-RAW; assumir errado destruiria o conteúdo. INIs do nosso projeto sempre tem BOM (AHK gera).
- **CSVs nao usam essa migration.** CsvFile já escreve UTF-8 com BOM explicitamente desde a Fase 3.
- **INIs novos criados pelo IniWrite sem arquivo pré-existente nascem UTF-16 LE.** Na próxima instânciação de IniFile no boot seguinte, sao migrados. Eager migration na criação foi rejeitada porque criar arquivo vazio em `__New` quebraria a semântica de `IniFile.Exists()` (retornaria true sem o IniWrite ter rodado, confundindo repos que usam Exists pra decidir entre load e defaults).

**Estado dos INIs do projeto após R11:**

| Arquivo | Pre-R11 | Pos-primeiro-boot-R11 |
|---|---|---|
| `poe2_tracker_v2.ini` | UTF-16 LE | UTF-8 BOM (auto-migra) |
| `data/campaign_route.ini` | UTF-16 LE | UTF-8 BOM (auto-migra) |
| `gem_recommendations.ini` | UTF-16 LE | UTF-8 BOM (auto-migra) |
| `targets.ini` (se houver) | UTF-16 LE | UTF-8 BOM (auto-migra) |
| Catalogs (RePoE) | varia | inalterado (read-only, nao tocado) |

**Resultado quantitativo:**
- Linhas adicionadas: ~170 (text_encoding.ahk + 16 testes novos + auto-call em IniFile.__New)
- Linhas removidas: 0
- Testes novos: 16 (DetectBom × 7, ConvertUtf16ToUtf8 × 3, MigrateIniToUtf8 × 5, IniFile integration × 1)
- Tamanho dos INIs no disco: ~50% menor depois da primeira migração (UTF-16 usa 2 bytes por char ASCII; UTF-8 usa 1).

### 17.35 — LogService com buffer + flush em crash (refactor R7, 2026-05)

Pre-R7, `LogService._Log` chamava `FileAppend(line, path, "UTF-8")` por linha. Cada chamada eh um syscall (abre+seek+write+close). Num app que loga ~5-20 linhas por minuto (heart rate normal), o overhead eh desprezivel. Mas o `HudPixelScanner` pode disparar logs de DEBUG a 25Hz quando ativo, e ai ja eh I/O sincrono em hot-path: ~1500 FileAppends por minuto. R7 adiciona um buffer in-memory.

Mas o R7 nao eh so performance. Tem um problema mais grave: **quando o app crasha, as ultimas N linhas de log sao as mais importantes** (descrevem o que aconteceu antes do crash). Sem buffer, todas estao no disco; com buffer, perdemos as N linhas pendentes. Solucao: **WARN e ERROR sempre flush imediato + flush hooks em Stop/OnExit pra cobrir crashes "graciosos"**.

**Implementação:**

| Componente | Mudança |
|---|---|
| `core/log_service.ahk` | `LogService.__New` aceita `bufferSize` (default 1 — sem buffer, preserva compat com testes que checam conteudo do arquivo imediatamente). Internamente: INFO/DEBUG vao pro buffer; quando atinge bufferSize, auto-flush. WARN/ERROR fazem flush do buffer pendente + escrita direta. Novo metodo publico `Flush()` (idempotente). |
| `app/app.ahk` | `__New` le `cfg.logBufferSize` (default **32** em producao) e passa pro LogService. `_PersistFinalState` (chamado por `Stop()`) chama `log.Flush()` no fim. |
| `speedkalandra.ahk` | Adiciona `OnExit((reason, exitCode) => app.log.Flush())` apos `app.Start()`. Cobre Ctrl-C, kill via taskmgr, Reload, e qualquer outro caminho que nao passe por `Stop()`. |

**Por que WARN/ERROR flush imediato e nao bufferiza?**

Situacao real: app crasha apos `log.Warn("Falha ao gravar splits: ...")`. Se a WARN estiver em buffer e o crash for hard (ExitApp via exception nao tratada, AHK process kill), o OnExit handler PODE ainda rodar (AHK garante isso na maioria dos casos), mas em cenarios extremos (BSOD, taskmgr End Process) nem isso eh chamado. Mensagens criticas precisam estar no disco no momento que sao geradas, nao depender de cleanup posterior.

INFO/DEBUG sao logs de fluxo normal — perder os ultimos 32 nao impede diagnostico (o crash em si sera WARN/ERROR e ja esta no arquivo).

**Por que `bufferSize=1` (sem buffer) por default?**

Testes existentes do `LogService` chamam `log.Info(...)` e imediatamente fazem `FileRead(path)` pra verificar conteudo. Adicionar buffer por default quebraria todos eles. A escolha de `1` como default preserva 100% da compat — codigo de teste nao precisa mudar.

Producao opta explicitamente por `32` via cfg do entrypoint. Esse numero veio de balancear:
- Pequeno o suficiente pra perder pouco em crash (max 32 linhas INFO/DEBUG)
- Grande o suficiente pra absorver bursts de DEBUG do HudPixelScanner (25Hz = 750 linhas/30s; buffer cheio em ~1.3s, flush a cada 32 syscalls em vez de 750)

**Hooks de flush (caminho completo de cobertura):**

| Cenário | Cobertura |
|---|---|
| User aperta `^!q` (hotkey de exit) | `app.Stop()` -> `_PersistFinalState` -> `log.Flush()` |
| Tray menu "Exit" | mesmo path |
| User fecha janela (X do tray) | OS dispara WM_CLOSE -> `OnExit` callback -> `app.log.Flush()` |
| Ctrl-C no terminal | `OnExit("Close")` -> flush |
| `Reload` programatico | `OnExit("Reload")` -> flush |
| `ExitApp()` direto | `OnExit("Exit")` -> flush |
| Excecao nao-tratada | `OnExit("Error")` -> flush |
| BSOD / kill -9 / power loss | **Nao coberto** — perde buffer pendente (max 32 linhas INFO/DEBUG; WARN/ERROR ja estavam no disco) |

**Idempotencia:**

`Flush()` em buffer vazio eh no-op. Multiplas chamadas (Stop chama Flush antes do OnExit; OnExit chama Flush; ate' o teste idempotencia chama 3x) nao re-escrevem nada.

**InMemoryLogger e NullLogger** ganharam `Flush() => 0` no-op pra preservar duck-typing com `LogService` (codigo que chama `log.Flush()` nao precisa saber qual logger e').

**Resultado quantitativo:**
- Linhas adicionadas: ~140 (buffer + Flush + 9 testes novos + OnExit handler)
- Linhas removidas: ~10 (refactor interno do `_Log` que agora delega pra `_FlushInternal`/`_WriteDirect`)
- Testes novos: 9 (bufferSize=1 imediato; buffer N retem INFO; auto-flush ao encher; Flush escreve pendente; Flush idempotente; WARN flush imediato; ordem cronologica preservada com ERROR; validacoes de bufferSize)
- Hot-path I/O em prod: **~30x reducao** de FileAppend syscalls quando HudPixelScanner ativo (32 logs por syscall em vez de 1).

---

## 18. Naming pitfalls do AHK v2 (referência rápida)

Esta seção concentra as armadilhas de linguagem que custaram tempo durante a migração e ressurgem em código novo. É complementar à seção 17.5 (que cresceu organicamente com cada incidência).

**1. Case-insensitivity em identificadores.**

`appSettings is AppSettings` quebra dentro de método cujo parâmetro chama `appSettings`. Solução padronizada: classes de service/repo viram `bus`, `cfg`, `repo`, `runSvc`, `hotkeySvc`, etc; classes de domain viram `stepObj`, `actObj`, `runObj`, `pr`, `rs`, `ws`. Tabela completa em 17.5.

**Detecção:** mensagem `"Expected a Class but got a <X>"` ou `"This local variable has not been assigned a value"`.

**2. Métodos one-liner com chaves não compilam.**

```ahk
_OnRunStarted() { this._runActive := true }    ; INVÁLIDO em AHK v2
```

AHK v2 só aceita métodos multi-linha (chaves em linhas separadas) ou fat-arrow:

```ahk
_OnRunStarted()                                    ; ok
{
    this._runActive := true
}

_OnRunStarted() => this._runActive := true        ; ok (fat-arrow expression)
```

Ocorrência registrada na 17.x — `invariant_checker_extras.ahk` tinha 5 ocorrências corrigidas.

**3. `Map.Delete(key)` em chave inexistente lança `"Item has no value"`.**

Diferente de `dict.pop(default)` em Python ou `Dictionary.Remove` em C# (silenciosos), AHK v2 é estrito. Sempre guardar com `.Has()`:

```ahk
if this._stepCarryMap.Has(stepId)
    this._stepCarryMap.Delete(stepId)
```

Incidência: TriggerMatcher 5.4 (`_andProgress.Delete` em key não-criada quando AND completou em uma única chamada via vazias auto-matched).

**4. Nested functions são proibidas em métodos.**

```ahk
_DoThing(x)
{
    helper(y) { ... }    ; INVÁLIDO
    return helper(x)
}
```

Solução: extrair pra método privado da classe (`this._Helper(y)`), mesmo que use só dentro de um método. Fat-arrow funciona pra one-liners. Incidência: 7.1 (`_GetPositionOrDefault` extraído).

**5. Closures em fat-arrow são comparadas por referência no `EventBus.Unsubscribe`.**

Cada `(d) => this._Method(d)` cria uma closure NOVA. Subscribe + Unsubscribe com lambdas inline não batem:

```ahk
; ERRADO — Unsubscribe não acha o handler
bus.Subscribe(Events.X, (d) => this._OnX(d))
; ... mais tarde ...
bus.Unsubscribe(Events.X, (d) => this._OnX(d))   ; ref diferente

; CERTO — guardar a ref
this._handlerX := (d) => this._OnX(d)
bus.Subscribe(Events.X, this._handlerX)
; ... mais tarde ...
bus.Unsubscribe(Events.X, this._handlerX)        ; mesma ref
```

Incidência principal: 17.28 (RunRecordingWorkflow.Stop não desfazia subscriptions).

**6. `try` engole ERROR do `LogService` se ele estiver vazio.**

Classico: `try service.Method()` esconde stacktraces. Convenção: `try` apenas em borda de I/O ou quando explicitamente quer ignorar (com motivo no comentário). Para wiring/composição, falhar alto.

**7. Ordem de `#Include` afeta funções top-level mas não classes.**

Classes são resolvidas em runtime quando referenciadas — incluir em qualquer ordem funciona. Funções top-level (`global Foo()` ou módulo de helpers) precisam ser incluídas antes do primeiro uso. Convenção do projeto: includes em `speedkalandra.ahk` seguem hierarquia (core → domain → infra → app/services → app/policies → app/workflows → app → ui), evitando ordem confusa.

**8. `Includes` circulares são tolerados, mas só funcionam se as referências entre arquivos forem APENAS classes (resolvidas em runtime).**

Se `a.ahk` chamar uma função top-level definida em `b.ahk`, e `b.ahk` chamar outra em `a.ahk`, AHK v2 precisa que ambos os arquivos terminem o parsing antes do primeiro uso — circular include com refs runtime de classes resolve, refs de funções não. Em geral, projeto evita funções top-level mesmo.

