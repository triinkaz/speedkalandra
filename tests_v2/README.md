# SpeedKalandra Test Suite

Unit test suite for SpeedKalandra. Started in Wave 0 with:

- Micro test runner in pure AHK v2 (~600 LOC of framework).
- EventBus smoke (10 tests) that doubles as proof-of-life for the runner and
  as the start of core coverage.

## How to run

Double-click `run_tests.ahk` (if the extension is associated with AHK v2), or:

```
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" tests_v2\run_tests.ahk
```

Success = `ExitApp(0)` and a "Tests OK" MsgBox. Failure = `ExitApp(1)` and a MsgBox listing the result. Details in `tests_output.log` next to `run_tests.ahk`.

### Filter tests during development

```
AutoHotkey64.exe tests_v2\run_tests.ahk EventBus
AutoHotkey64.exe tests_v2\run_tests.ahk publish_calls
```

The argument is a case-insensitive substring of `ClassName::method`. Useful when you're iterating on a specific test.

## Structure

```
tests_v2/
├── run_tests.ahk            Entry point. #Include order matters.
├── framework/
│   ├── assert.ahk           Assert.True/False/Equal/Near/Throws/...
│   ├── test_case.ahk        Base TestCase with Setup/Teardown.
│   ├── test_registry.ahk    Static suite registry.
│   ├── test_runner.ahk      Iterates suites, classifies the result.
│   ├── test_reporter.ahk    Log file + MsgBox + ExitApp(N).
│   └── fixtures.ahk         TempDir/TempFile, factories.
├── unit/
│   └── core/
│       └── event_bus_smoke_tests.ahk
└── tests_output.log         (generated on every run)
```

## Writing a new suite

1. Create a file at `unit/<layer>/<module>_tests.ahk`.
2. Define a class that extends `TestCase`.
3. Declare `static Tests := ["method_name_1", ...]` explicitly listing the test methods.
4. (Optional) `Setup()` and `Teardown()` for fixtures.
5. At the end of the file, call `TestRegistry.Register(MyClass)`.
6. Add `#Include unit/.../my_file.ahk` to `run_tests.ahk`.

Minimal example:

```ahk
class FoobarTests extends TestCase
{
    static Tests := ["adds_two_numbers"]

    Setup()
    {
        this.svc := Foobar()
    }

    adds_two_numbers()
    {
        Assert.Equal(5, this.svc.Add(2, 3))
    }
}

TestRegistry.Register(FoobarTests)
```

## Assert API

```ahk
Assert.True(actual, message := "")
Assert.False(actual, message := "")
Assert.Equal(expected, actual, message := "")          ; deep compare Array/Map
Assert.NotEqual(expected, actual, message := "")
Assert.Near(expected, actual, tolerance, message := "")
Assert.Contains(needle, haystack, message := "")       ; string or Array
Assert.IsType(expectedClass, actual, message := "")    ; uses `is`
Assert.Throws(expectedClass, fn, message := "")
Assert.Fail(message)
```

Convention: first argument is the expected value, second is the observed one. Failures throw `AssertionFailed` (extends Error); the runner distinguishes that from non-assertion errors (which become `[ERR ]`).

## Available fixtures

```ahk
Fixtures.TempDir()                          ; creates, returns path, registers cleanup
Fixtures.TempFile(content := "", ext := "txt")
Fixtures.CleanupAll()                       ; call in Teardown if you used Temp*
Fixtures.MakeBus()                          ; EventBus(NullLogger)
Fixtures.MakeBusWithLog(&logOut)            ; EventBus(InMemoryLogger), exposes log
Fixtures.MakeFakeClock(initialMs := 0)
Fixtures.MakeNullLogger()
Fixtures.MakeInMemoryLogger()
```

## Conventions

- Test methods in `snake_case_descriptive`. The name is the documentation of what is being tested.
- Setup constructs new state for each test (the runner instantiates the suite once per test).
- No magic helpers: each test is readable without opening the entire suite.
- Assert errors produce `AssertionFailed`. TypeError/ValueError errors in test code become `[ERR ]` (distinguishes a bug in the test from a failure in the SUT).

## AHK v2 pitfalls already discovered

- **`throw` does not fit inside an arrow function** (`(x) => throw Error(...)`). It's a statement, not an expression. Use a nested function inside the test method when you need a handler that throws.
- **Generic loop variable name** (`ln`, `idx`) may collide with a global and trigger `#Warn LocalSameAsGlobal`. Prefer specific names (`stackLine`, `lineIdx`).
- **Name `log` as a local variable in a test** collides with a global in some project file. Use `memLog` (InMemoryLogger), `srvLog` (LogService), `nullLog` (NullLogger).
- **Case-insensitive collision with class name**: AHK v2 resolves identifiers case-insensitively, so a local variable `fakeClock` collides with the class `FakeClock` (they are the same identifier). When this happens, AHK v2 treats the name as local across the WHOLE body of the function - including the RHS of `:=`. Result: `fakeClock := FakeClock(...)` breaks with `UnsetError` because the `FakeClock` on the RHS resolves to the local uninitialized `fakeClock`. Same pitfall already documented in the project's `ARCHITECTURE.md` ("parameter `timerService` collides with class `TimerService`"). For tests that need a local instance of a class, use prefixes like `stub`, `mock`, `produced`, `genX`: `stubClock`, `mockBus`, `producedId`.
- **AHK v2 builtin functions/classes also collide** case-insensitively with locals and trigger `#Warn LocalSameAsGlobal`. Cases already encountered: `run` collides with `Run` (function), `buffer` collides with `Buffer` (class), `isFloat` collides with `IsFloat` (function), `ln` collides with `Ln` (function). Others to avoid as a local name: `type`, `map`, `array`, `func`, `error`, `send`, `format`, `chr`, `ord`, `string`, `integer`, `float`. Convention: use descriptive prefixes (`serializedRun`, `outBuffer`, `numIsFloat`) or suffixes (`runItem`).
- **Domain classes collide with semantically equivalent names**. `class RunId` (in domain/values/ids.ahk) collides case-insensitively with local `runId`. Same for `StepId`, `ProfileId`. When the test or production code needs a local variable for an ID, use `currentRunId`, `currentStepId`, `currentProfileId` in loops and assignment contexts. Formal method parameters named `runId` (etc.) do NOT trigger the warning - only locals.
- **The `Events` class (in `core/event_names.ahk`) collides case-insensitively with lowercase locals** like `events`. Case found in RunStatsRecorder tests that collected bus events into `events := []`. Solution: `evtLog`, `capturedEvents`, `subscribedNames`. Same pattern as the other classes.
- **IniRead key-lookup only works on UTF-16 LE BOM files** (Wave 4 - PersonalBest tests). `IniRead(path, section, key, default)` in AHK v2 always returns the default for UTF-8 BOM files, regardless of line endings (CRLF or LF). `IniRead(path, section)` (whole section, no key) tolerates both encodings - that's why `ReadSectionAsMap` works. When generating INIs manually in tests, use `FileAppend(content, path, "UTF-16")`. In production, `AtomicWriter.WriteAll(path, content, "UTF-16")`.
- **Closure-in-loop captures variables by reference, not by value** (Wave 5a - subscriber tracking tests). Loop `for _, nm in names { bus.Subscribe(nm, (data) => out.Push(localName := nm)) }` causes ALL handlers to see the LAST value of `nm` when finally invoked. In AHK v2 there's no per-iteration `let`. Practical solution in tests: manually unroll the loop (4 explicit handlers instead of 1 loop). In production, consider creating the closure inside another function that receives the value as a parameter.
- **`Assert.IsType` is for classes, not for primitives via string**. `Assert.IsType("Integer", 42)` fails because the first argument must be a class reference (e.g.: `Integer` without quotes). But in AHK v2 not every primitive is an accessible class — `Integer` is a keyword. To check primitive type use `Assert.Equal("Integer", Type(42))`. Reserve `Assert.IsType` for checking instances of defined classes (e.g.: `Assert.IsType(EventBus, this.bus)`).
- **`m[k]` in a Map with integer keys rejects lookup via string-coerced key** (Wave 5a - real bug in `PersonalBestService._MapToDebugStr`). AHK v2 treats `m[1]` (int) and `m["1"]` (string) as DISTINCT keys in Maps. Pattern to avoid: converting keys to string in an intermediate loop (sort/dedup) and then doing `m[strKey]` on the original map that has int keys. Solution: store the value ALONGSIDE the string-key during the first loop, avoiding the re-lookup. Already fixed in `PersonalBestService._MapToDebugStr`.

## Roadmap

Current progress:

- [x] **Wave 0**: runner + smoke (10 tests)
- [x] **Wave 1**: `core/` complete (80 tests: EventBus, LogService, NullLogger, InMemoryLogger, RealClock, FakeClock)
- [x] **Wave 2**: `domain/` complete (191 tests: Duration, Ids, WindowState, RunState, XpRules, OverlayPosition, OverlayLayout, AppSettings)
- [x] **Wave 3**: `infra/io/` complete (160 tests: AtomicWriter, TextEncoding, IniFile, CsvFile, JsonFile, RunExportFormat)
- [x] **Wave 4**: `infra/` repositories complete (143 tests: ZonesCatalog, PersonalBestRepository, RunStateRepository, RunHistoryRepository, SettingsRepository)
- [x] **Wave 5a**: pure services (346 tests: XpService, AppTickEmitter, HudPixelScanner, LoadingTotalsService, TimerService, ActCheckpointTracker, RunStatsRecorder, PersonalBestService, RunStatsPlotBuilder)
- [x] **Wave 5b**: services with more state (288 tests: ZoneTrackingService, LogMonitorService, LoadingDetectionService, RunService, AutoStartService, AutoFinalizeService)
- [x] **Wave 6**: services with OS hooks (165 tests: OverlayModeService, OverlayModeApplier, HotkeyService, FocusAutoPauseService, OverlayInteractionService)
- [x] **Wave 7**: pure UI + bases (113 tests: Theme, HotkeyFormatter, WidgetBase, LayoutWidgetBase)
- [ ] **Wave 8**: SpeedKalandraApp end-to-end integration (includes R11 fix)
- [ ] **Wave 9**: regression of catalogued bugs

Current total: **1510 green tests in ~21 seconds**.

## Strategies per wave

- **Wave 5a/5b**: pure services + simple state. Direct Setup/Teardown, no OS mocks.
- **Wave 6 (OS hooks)**: 3 different strategies to decouple from the OS without touching production code:
  - `HotkeyService` and `OverlayInteractionService`: both already had a native `headless` flag (Start() skips `Hotkey()`/`SetTimer`/`OnMessage`). Tests use `headless=true` and exercise the state machine + event publishing.
  - `FocusAutoPauseService`: stub subclass `_FocusAutoPauseStubService` overrides only `_IsGameActive()` with an in-memory flag. Rest of the service runs unchanged (synthesizing events via `bus.Publish(Events.Tick)` exercises the polling backup without real WinActive).
  - `OverlayModeService` + `OverlayModeApplier`: pure state machine (no Win32 calls). `OverlayModeApplier` accepts widgets via Map, so tests inject `_OverlayApplierStubWidget` that tracks the last value of `SetModeVisible`.
- **Non-exhaustive coverage** in `OverlayInteractionService`: `_OnLButtonDown`, `_OnMouseWheel`, `_DragTick`, `_UpdateHoverState` require real OnMessage/Win32. Covered: lifecycle, register/unregister, `SetCtrlState` + event publish, Win32 constants.
- **Wave 7 (UI)**: coverage focused on pure logic and reused bases, avoiding real Gui rendering:
  - `Theme` (palette + Size scaler) and `HotkeyFormatter` (AHK<->human roundtrip): static-only, fully pure.
  - `WidgetBase` and `LayoutWidgetBase`: tests keep `_position.visible=false` so that `ReRender()` is a no-op (and real Show isn't called). Coverage: queries, mutators (`SetVisible`/`SetModeVisible`/`SetActivePosition`/`SetScale`/`SetPosition`) with clamps and the `_Persist` callback, `_OnCtrlStateChanged` handler, and `_OnWheelResize` of the layout.
  - **Out of scope for Wave 7**: concrete dialogs (`SettingsDialog`, `RunHistoryDialog`, etc.) and concrete widgets (`CompactLayoutWidget`, `MicroLayoutWidget`, `SteveLayoutWidget`) are predominantly `_BuildGui` (boilerplate of `Gui.Add(...)`). Their non-GUI logic is already covered by the bases. The dialogs have a `headless` flag but in headless the lifecycle is trivial (just the `_isOpen` flag). These will be exercised in Wave 8 via integration tests.
  - **Raw GDI**: `LineChartRenderer` does DllCall directly into Gdi32/User32 — not testable without a real display. Left for Wave 9 (manual visual regression) if necessary.

## Real production bugs discovered by tests

The suite finds real bugs beyond the `#Warn` warnings. Each bug below is a problem that affected the app's behavior before the test exposed it.

- **#1 (Wave 4 - FIXED)**: `PersonalBestRepository.Save` was writing UTF-8 BOM, but `IniRead` key-lookup only works in UTF-16 LE BOM. Result in production: `runPbMs` and `runPbRunId` ALWAYS returned 0/"" after boot, even with the PB saved. Fix: changed encoding to `"UTF-16"` in `personal_best_repository.ahk`.
- **#2 (Wave 4 - PENDING Wave 8)**: `TextEncoding.MigrateIniToUtf8` (called in `app.Start()`) corrupts `IniRead` key-lookup. See Known Bugs below.
- **#3 (Wave 5a - FIXED)**: `PersonalBestService._MapToDebugStr` was breaking on Maps with integer keys (`UnsetItemError`). It converted keys to string via `String(k)` and then did `m[strKey]` — but a Map with int keys rejects lookup with a string key in AHK v2. Affected `SetAsRunPb` and `RebuildFromHistory` in production (the outer try/catch silenced it but behavior was incorrect). Fix: store a triple (strKey, value) in an intermediate array.
- **#4 (Wave 5a - FIXED)**: `RunHistoryRepository._SafeCategoryLabel` had scope-dependent behavior. In isolated tests (without RunStatsPlotBuilder in scope), the fallback did passthrough of the unknown category. With the builder in scope, it delegated to `CategoryLabel(cat)` which returns "All" for unknowns. Result in production: old runs with `category=boss` (removed category) displayed "All" in the UI instead of keeping "boss". Fix: explicit lookup in `SegmentDefinitions` (only valid categories return the builder's label), passthrough on unknown — behavior now identical regardless of scope.
- **#5 (Wave 5b - LATENT / PENDING)**: `LoadingDetectionService` timeout silently discards the LoadingMeasured. The Tick code detects timeout when `(now - startTick) > maxMs`, calls `_End("timeout_no_hud_return")`. But `_End` has a filter `if (durationMs < minMs || durationMs > maxMs) return false` — and the duration NOW IS > maxMs (that was exactly the timeout condition!), so the event is discarded. Even though the source `"timeout_no_hud_return"` exists and is listed in the service doc, it NEVER reaches the bus. Consequence: loadings that exceed 90s (default maxMs) become totally invisible — they don't go to the run plot or to loading.csv. Rare but possible case (long alt-tab during portal animation, frozen machine). Resolve: either (a) timeout publishes with durationMs clamped at maxMs, or (b) remove the `durationMs > maxMs` filter in `_End` (let Tick be the sole decider of timeout). **Decide in Wave 8 or earlier if observed in production.**


## Known Bugs (to resolve in a future wave)

- **R11 `TextEncoding.MigrateIniToUtf8` corrupts IniRead key-lookup** (discovered Wave 4). The migration converts the main INIs (`mainIni`, `routeIni`, `gemPlanIni`) from UTF-16 LE BOM to UTF-8 BOM in `app.Start()`. But `IniRead(path, section, key, default)` in AHK v2 does not work on UTF-8 BOM files (always returns the default). Consequence: settings, run state and other key-based values are silently lost on app boot post-migration. **Resolve in Wave 8 (SpeedKalandraApp end-to-end integration)** or earlier if it causes a visible problem. Possible paths: (a) revert R11, INIs stay UTF-16 LE BOM; (b) reimplement `IniFile.Read` by parsing the file manually instead of delegating to `IniRead`. Cover with regression tests at the time of the fix.

