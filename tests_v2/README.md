# SpeedKalandra Test Suite

Suite de testes unitarios pro SpeedKalandra. Comecou na Wave 0 com:

- Micro test runner em AHK v2 puro (~600 LOC de framework).
- Smoke do EventBus (10 testes) que serve como prova-de-vida do runner e
  como inicio da cobertura do core.

## Como rodar

Duplo-clique em `run_tests.ahk` (se a extensao estiver associada ao AHK v2), ou:

```
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" tests_v2\run_tests.ahk
```

Sucesso = `ExitApp(0)` e MsgBox "Tests OK". Falha = `ExitApp(1)` e MsgBox listando o resultado. Detalhes em `tests_output.log` ao lado do `run_tests.ahk`.

### Filtrar testes durante desenvolvimento

```
AutoHotkey64.exe tests_v2\run_tests.ahk EventBus
AutoHotkey64.exe tests_v2\run_tests.ahk publish_calls
```

O argumento e' substring case-insensitive de `ClassName::method`. Util quando voce esta iterando num teste especifico.

## Estrutura

```
tests_v2/
├── run_tests.ahk            Entry point. #Include order matters.
├── framework/
│   ├── assert.ahk           Assert.True/False/Equal/Near/Throws/...
│   ├── test_case.ahk        Base TestCase com Setup/Teardown.
│   ├── test_registry.ahk    Registro estatico das suites.
│   ├── test_runner.ahk      Itera suites, classifica resultado.
│   ├── test_reporter.ahk    Log file + MsgBox + ExitApp(N).
│   └── fixtures.ahk         TempDir/TempFile, factories.
├── unit/
│   └── core/
│       └── event_bus_smoke_tests.ahk
└── tests_output.log         (gerado em cada run)
```

## Escrever uma nova suite

1. Cria um arquivo em `unit/<camada>/<modulo>_tests.ahk`.
2. Define uma classe que extende `TestCase`.
3. Declara `static Tests := ["nome_metodo_1", ...]` listando explicitamente os metodos de teste.
4. (Opcional) `Setup()` e `Teardown()` para fixtures.
5. No fim do arquivo, chama `TestRegistry.Register(MinhaClasse)`.
6. Adiciona `#Include unit/.../meu_arquivo.ahk` no `run_tests.ahk`.

Exemplo minimo:

```ahk
class FoobarTests extends TestCase
{
    static Tests := ["soma_dois_numeros"]

    Setup()
    {
        this.svc := Foobar()
    }

    soma_dois_numeros()
    {
        Assert.Equal(5, this.svc.Add(2, 3))
    }
}

TestRegistry.Register(FoobarTests)
```

## API do Assert

```ahk
Assert.True(actual, message := "")
Assert.False(actual, message := "")
Assert.Equal(expected, actual, message := "")          ; deep compare Array/Map
Assert.NotEqual(expected, actual, message := "")
Assert.Near(expected, actual, tolerance, message := "")
Assert.Contains(needle, haystack, message := "")       ; string ou Array
Assert.IsType(expectedClass, actual, message := "")    ; usa `is`
Assert.Throws(expectedClass, fn, message := "")
Assert.Fail(message)
```

Convencao: primeiro argumento e' o esperado, segundo o observado. Falhas estouram `AssertionFailed` (extends Error); o runner diferencia isso de erros nao-assercao (que viram `[ERR ]`).

## Fixtures disponiveis

```ahk
Fixtures.TempDir()                          ; cria, retorna path, registra cleanup
Fixtures.TempFile(content := "", ext := "txt")
Fixtures.CleanupAll()                       ; chama no Teardown se usou Temp*
Fixtures.MakeBus()                          ; EventBus(NullLogger)
Fixtures.MakeBusWithLog(&logOut)            ; EventBus(InMemoryLogger), expoe log
Fixtures.MakeFakeClock(initialMs := 0)
Fixtures.MakeNullLogger()
Fixtures.MakeInMemoryLogger()
```

## Convencoes

- Metodos de teste em `snake_case_descritivo`. O nome e' a documentacao do que esta sendo testado.
- Setup constroi estado novo a cada teste (o runner instancia a suite uma vez por teste).
- Sem helpers magicos: cada teste e' lido sem precisar abrir a suite inteira.
- Erros de Assert produzem `AssertionFailed`. Erros de TypeError/ValueError em codigo de teste viram `[ERR ]` (diferencia bug no teste de falha no SUT).

## Pitfalls AHK v2 ja descobertos

- **`throw` nao cabe em arrow function** (`(x) => throw Error(...)`). E' statement, nao expressao. Use nested function dentro do metodo de teste quando precisar de handler que estoura.
- **Nome de variavel de loop generico** (`ln`, `idx`) pode colidir com global e disparar `#Warn LocalSameAsGlobal`. Prefira nomes especificos (`stackLine`, `lineIdx`).
- **Nome `log` como variavel local em teste** colide com global em algum arquivo do projeto. Use `memLog` (InMemoryLogger), `srvLog` (LogService), `nullLog` (NullLogger).
- **Case-insensitive collision com nome de classe**: AHK v2 resolve identificadores case-insensitively, entao uma variavel local `fakeClock` colide com a classe `FakeClock` (sao o mesmo identificador). Quando isso acontece, AHK v2 trata o nome como local em TODO o corpo da funcao - inclusive no RHS de `:=`. Resultado: `fakeClock := FakeClock(...)` quebra com `UnsetError` porque o `FakeClock` no RHS resolve pra `fakeClock` local nao-inicializada. Mesmo pitfall ja documentado no `ARCHITECTURE.md` do projeto ("parameter `timerService` colide com class `TimerService`"). Pra testes que precisam de instancia local de uma classe, use prefixos como `stub`, `mock`, `produced`, `genX`: `stubClock`, `mockBus`, `producedId`.
- **Builtin functions/classes do AHK v2 tambem colidem** case-insensitively com locals e disparam `#Warn LocalSameAsGlobal`. Casos ja encontrados: `run` colide com `Run` (function), `buffer` colide com `Buffer` (class), `isFloat` colide com `IsFloat` (function), `ln` colide com `Ln` (function). Outros a evitar como nome local: `type`, `map`, `array`, `func`, `error`, `send`, `format`, `chr`, `ord`, `string`, `integer`, `float`. Convencao: use prefixos descritivos (`serializedRun`, `outBuffer`, `numIsFloat`) ou sufixos (`runItem`).
- **Classes de domain colidem com nomes semanticamente equivalentes**. `class RunId` (em domain/values/ids.ahk) colide case-insensitively com `runId` local. Mesmo para `StepId`, `ProfileId`. Quando o teste ou o codigo de producao precisa de uma variavel local pra um ID, use `currentRunId`, `currentStepId`, `currentProfileId` em loops e contextos de assignment. Parametros formais de metodos com nome `runId` (etc) NAO disparam o warning - so locals.
- **Classe `Events` (em `core/event_names.ahk`) colide case-insensitively com locals minusculos** como `events`. Caso encontrado em testes de RunStatsRecorder que coletavam eventos do bus em `events := []`. Solucao: `evtLog`, `capturedEvents`, `subscribedNames`. Mesmo padrao das outras classes.
- **IniRead key-lookup so funciona em arquivos UTF-16 LE BOM** (Wave 4 - PersonalBest tests). `IniRead(path, section, key, default)` em AHK v2 retorna sempre o default em arquivos UTF-8 BOM, independente de line endings (CRLF ou LF). `IniRead(path, section)` (section inteira, sem key) tolera ambos os encodings - por isso `ReadSectionAsMap` funciona. Ao gerar INIs manualmente em testes, usar `FileAppend(content, path, "UTF-16")`. Em producao, `AtomicWriter.WriteAll(path, content, "UTF-16")`.
- **Closure-in-loop captura variaveis por referencia, nao por valor** (Wave 5a - testes de subscriber tracking). Loop `for _, nm in names { bus.Subscribe(nm, (data) => out.Push(localName := nm)) }` faz com que TODOS os handlers vejam o ULTIMO valor de `nm` quando finalmente sao invocados. Em AHK v2 nao ha `let` por iteracao. Solucao pratica em testes: expandir o loop manualmente (4 handlers explicitos em vez de 1 loop). Em producao, considerar fabricar a closure dentro de outra funcao que recebe o valor como parametro.
- **`Assert.IsType` eh pra classes, nao pra primitivos via string**. `Assert.IsType("Integer", 42)` falha porque o primeiro argumento deve ser uma referencia de classe (ex: `Integer` sem aspas). Mas em AHK v2 nem todo primitivo eh classe acessivel — `Integer` eh palavra-chave. Pra verificar tipo de primitivos use `Assert.Equal("Integer", Type(42))`. Reservar `Assert.IsType` para checar instancias de classes definidas (ex: `Assert.IsType(EventBus, this.bus)`).
- **`m[k]` em Map com keys integer rejeita lookup via string-coerced key** (Wave 5a - bug real em `PersonalBestService._MapToDebugStr`). AHK v2 trata `m[1]` (int) e `m["1"]` (string) como keys DISTINTOS em Maps. Padrao a evitar: converter keys pra string num loop intermediario (sort/dedup) e depois fazer `m[strKey]` no map original que tem int keys. Solucao: guardar o valor JUNTO da string-key durante o primeiro loop, evitando o re-lookup. Ja corrigido em `PersonalBestService._MapToDebugStr`.

## Roadmap

Progresso atual:

- [x] **Wave 0**: runner + smoke (10 testes)
- [x] **Wave 1**: `core/` completo (80 testes: EventBus, LogService, NullLogger, InMemoryLogger, RealClock, FakeClock)
- [x] **Wave 2**: `domain/` completo (191 testes: Duration, Ids, WindowState, RunState, XpRules, OverlayPosition, OverlayLayout, AppSettings)
- [x] **Wave 3**: `infra/io/` completo (160 testes: AtomicWriter, TextEncoding, IniFile, CsvFile, JsonFile, RunExportFormat)
- [x] **Wave 4**: `infra/` repositorios completo (143 testes: ZonesCatalog, PersonalBestRepository, RunStateRepository, RunHistoryRepository, SettingsRepository)
- [x] **Wave 5a**: services puros (346 testes: XpService, AppTickEmitter, HudPixelScanner, LoadingTotalsService, TimerService, ActCheckpointTracker, RunStatsRecorder, PersonalBestService, RunStatsPlotBuilder)
- [x] **Wave 5b**: services com mais state (288 testes: ZoneTrackingService, LogMonitorService, LoadingDetectionService, RunService, AutoStartService, AutoFinalizeService)
- [x] **Wave 6**: services com OS hooks (165 testes: OverlayModeService, OverlayModeApplier, HotkeyService, FocusAutoPauseService, OverlayInteractionService)
- [x] **Wave 7**: UI puro + bases (113 testes: Theme, HotkeyFormatter, WidgetBase, LayoutWidgetBase)
- [ ] **Wave 8**: integration SpeedKalandraApp end-to-end (inclui fix do R11)
- [ ] **Wave 9**: regressao dos bugs catalogados

Total atual: **1510 testes verdes em ~21 segundos**.

## Estrategias por wave

- **Wave 5a/5b**: services puros + state simples. Setup/Teardown direto, sem mocks de OS.
- **Wave 6 (OS hooks)**: 3 estrategias diferentes pra desacoplar do OS sem mexer em codigo de producao:
  - `HotkeyService` e `OverlayInteractionService`: ambos ja tinham `headless` flag nativa (Start() pula `Hotkey()`/`SetTimer`/`OnMessage`). Tests usam `headless=true` e exercitam state machine + event publishing.
  - `FocusAutoPauseService`: subclasse stub `_FocusAutoPauseStubService` override apenas `_IsGameActive()` com flag in-memory. Resto do service roda inalterado (sintetizar eventos via `bus.Publish(Events.Tick)` exercita o polling backup sem WinActive real).
  - `OverlayModeService` + `OverlayModeApplier`: state machine pura (sem chamadas Win32). `OverlayModeApplier` aceita widgets via Map, entao tests injetam `_OverlayApplierStubWidget` que rastreia ultimo valor de `SetModeVisible`.
- **Cobertura nao exaustiva** em `OverlayInteractionService`: `_OnLButtonDown`, `_OnMouseWheel`, `_DragTick`, `_UpdateHoverState` requerem OnMessage/Win32 reais. Cobertos: lifecycle, register/unregister, `SetCtrlState` + event publish, constantes Win32.
- **Wave 7 (UI)**: cobertura focada em logica pura e bases reutilizadas, evitando renderizacao real de Gui:
  - `Theme` (paleta + Size scaler) e `HotkeyFormatter` (AHK<->human roundtrip): static-only, totalmente puros.
  - `WidgetBase` e `LayoutWidgetBase`: testes mantem `_position.visible=false` pra que `ReRender()` seja no-op (e Show real nao seja chamado). Cobertura: queries, mutators (`SetVisible`/`SetModeVisible`/`SetActivePosition`/`SetScale`/`SetPosition`) com clamps e callback `_Persist`, handler `_OnCtrlStateChanged`, e `_OnWheelResize` do layout.
  - **Fora de escopo Wave 7**: dialogs concretos (`SettingsDialog`, `RunHistoryDialog`, etc) e widgets concretos (`CompactLayoutWidget`, `MicroLayoutWidget`, `SteveLayoutWidget`) sao predominantemente `_BuildGui` (boilerplate de `Gui.Add(...)`). A logica nao-GUI deles ja eh coberta pelas bases. Os dialogs tem flag `headless` mas em headless o ciclo de vida eh trivial (so flag `_isOpen`). Esses serao exercitados em Wave 8 via integration test.
  - **GDI raw**: `LineChartRenderer` faz DllCall direto em Gdi32/User32 — nao testavel sem display real. Deixado pra Wave 9 (visual regression manual) se necessario.

## Bugs reais de producao descobertos pelos testes

A suite encontra bugs reais alem dos warnings do `#Warn`. Cada bug abaixo eh um problema que afetava o comportamento da app antes do teste expor.

- **#1 (Wave 4 - CONSERTADO)**: `PersonalBestRepository.Save` gravava em UTF-8 BOM, mas `IniRead` key-lookup so funciona em UTF-16 LE BOM. Resultado em producao: `runPbMs` e `runPbRunId` SEMPRE retornavam 0/"" apos boot, mesmo com PB salvo. Fix: mudou encoding pra `"UTF-16"` em `personal_best_repository.ahk`.
- **#2 (Wave 4 - PENDENTE Wave 8)**: `TextEncoding.MigrateIniToUtf8` (chamado em `app.Start()`) corrompe `IniRead` key-lookup. Ver Known Bugs abaixo.
- **#3 (Wave 5a - CONSERTADO)**: `PersonalBestService._MapToDebugStr` quebrava em Maps com keys integer (`UnsetItemError`). Convertia keys pra string via `String(k)` e depois fazia `m[strKey]` — mas Map com keys int rejeita lookup com string key em AHK v2. Afetava `SetAsRunPb` e `RebuildFromHistory` em producao (try/catch externo silenciava mas comportamento era incorreto). Fix: guardar tripla (strKey, value) num array intermediario.
- **#4 (Wave 5a - CONSERTADO)**: `RunHistoryRepository._SafeCategoryLabel` tinha comportamento dependente do escopo. Em testes isolados (sem RunStatsPlotBuilder no escopo), o fallback fazia passthrough da categoria desconhecida. Com o builder no escopo, delegava pra `CategoryLabel(cat)` que retorna "All" pra unknowns. Resultado em producao: runs antigas com `category=boss` (categoria removida) mostravam "All" na UI em vez de manter "boss". Fix: lookup explicito em `SegmentDefinitions` (so categorias validas retornam label do builder), passthrough no unknown — comportamento agora identico independente de escopo.
- **#5 (Wave 5b - LATENTE / PENDENTE)**: `LoadingDetectionService` timeout descarta o LoadingMeasured silenciosamente. O codigo de Tick detecta timeout quando `(now - startTick) > maxMs`, chama `_End("timeout_no_hud_return")`. Mas `_End` tem filtro `if (durationMs < minMs || durationMs > maxMs) return false` — e a duration AGORA EH > maxMs (foi exatamente essa condicao do timeout!), entao o event eh descartado. Apesar do source `"timeout_no_hud_return"` existir e ser listado no doc do service, NUNCA chega ao bus. Consequencia: loadings que ultrapassam 90s (default maxMs) ficam totalmente invisiveis — nao vao pro plot da run nem pro loading.csv. Caso raro mas possivel (alt-tab longo durante portal animation, machine travada). Resolver: ou (a) timeout publica com durationMs clampado em maxMs, ou (b) remover o filtro `durationMs > maxMs` em `_End` (deixa a Tick ser a unica que decide timeout). **Decidir em Wave 8 ou antes se observado em producao.**


## Known Bugs (a resolver em wave futura)

- **R11 `TextEncoding.MigrateIniToUtf8` corrompe IniRead key-lookup** (descoberto Wave 4). A migration converte INIs principais (`mainIni`, `routeIni`, `gemPlanIni`) de UTF-16 LE BOM pra UTF-8 BOM em `app.Start()`. Mas `IniRead(path, section, key, default)` em AHK v2 nao funciona em arquivos UTF-8 BOM (sempre retorna o default). Consequencia: settings, run state e outros valores key-based sao silenciosamente perdidos no boot do app pos-migration. **Resolver na Wave 8 (integration SpeedKalandraApp end-to-end)** ou antes se causar problema visivel. Possiveis paths: (a) reverter R11, INIs ficam UTF-16 LE BOM; (b) reimplementar `IniFile.Read` parseando arquivo manualmente em vez de delegar pra `IniRead`. Cobrir com testes de regressao no momento do fix.

