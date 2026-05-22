# SpeedKalandra Test Suite

Self-contained AHK v2 test suite for SpeedKalandra. Pure AHK v2 — no external runner, no `pip install`, no `npm`. 2000+ tests across `core/`, `domain/`, `infra/`, `app/`, `ui/`, and integration.

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

### Headless mode (CI, scripted runs)

The final MsgBox can be suppressed by setting either environment variable:

- `SPEEDKALANDRA_TEST_NO_GUI=1` — explicit opt-in for local scripted runs.
- `CI=<anything truthy>` — universal convention; GitHub Actions, GitLab CI, CircleCI, Travis, Drone and AppVeyor all set this by default.

When headless, the runner writes `(headless mode — MsgBox skipped)` at the end of `tests_output.log` and exits with the same code it would otherwise use (`0` on all-green, `1` on any failure or error). Useful when you want to chain the suite into another script.

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
- **IniRead key-lookup only works on UTF-16 LE BOM files**. `IniRead(path, section, key, default)` in AHK v2 always returns the default for UTF-8 BOM files, regardless of line endings (CRLF or LF). `IniRead(path, section)` (whole section, no key) tolerates both encodings - that's why `ReadSectionAsMap` works. When generating INIs manually in tests, use `FileAppend(content, path, "UTF-16")`. In production, `AtomicWriter.WriteAll(path, content, "UTF-16")`.
- **Closure-in-loop captures variables by reference, not by value**. Loop `for _, nm in names { bus.Subscribe(nm, (data) => out.Push(localName := nm)) }` causes ALL handlers to see the LAST value of `nm` when finally invoked. In AHK v2 there's no per-iteration `let`. Practical solution in tests: manually unroll the loop (4 explicit handlers instead of 1 loop). In production, consider creating the closure inside another function that receives the value as a parameter.
- **`Assert.IsType` is for classes, not for primitives via string**. `Assert.IsType("Integer", 42)` fails because the first argument must be a class reference (e.g.: `Integer` without quotes). But in AHK v2 not every primitive is an accessible class — `Integer` is a keyword. To check primitive type use `Assert.Equal("Integer", Type(42))`. Reserve `Assert.IsType` for checking instances of defined classes (e.g.: `Assert.IsType(EventBus, this.bus)`).
- **`m[k]` in a Map with integer keys rejects lookup via string-coerced key**. AHK v2 treats `m[1]` (int) and `m["1"]` (string) as DISTINCT keys in Maps. Pattern to avoid: converting keys to string in an intermediate loop (sort/dedup) and then doing `m[strKey]` on the original map that has int keys. Solution: store the value ALONGSIDE the string-key during the first loop, avoiding the re-lookup.

## Current state

Full suite runs in roughly 25 seconds on a typical desktop. Coverage by layer:

| Layer | Notable coverage |
|---|---|
| `core/` | EventBus, LogService, NullLogger, InMemoryLogger, RealClock, FakeClock |
| `domain/` | Duration, Ids, WindowState, RunState, XpRules, OverlayPosition, OverlayLayout, AppSettings |
| `infra/io/` | AtomicWriter, TextEncoding, IniFile, CsvFile, JsonFile, RunExportFormat |
| `infra/` repos | ZonesCatalog, PersonalBestRepository, RunStateRepository, RunHistoryRepository, SettingsRepository |
| `app/services/` pure | XpService, AppTickEmitter, HudPixelScanner, LoadingTotalsService, TimerService, ActCheckpointTracker, RunStatsRecorder, PersonalBestService, RunStatsPlotBuilder |
| `app/services/` stateful | ZoneTrackingService, LogMonitorService, LoadingDetectionService, RunService, AutoStartService, AutoFinalizeService, RunImportService (size gate) |
| `app/services/` OS hooks | OverlayModeService, OverlayModeApplier, HotkeyService, FocusAutoPauseService, OverlayInteractionService |
| `app/` composition | BootPrompts, RunSnapshotSaver |
| `ui/` | Theme, HotkeyFormatter, WidgetBase, LayoutWidgetBase |
| `integration/` | SpeedKalandraApp full wire-up; hydration ordering; death-penalty handler; EventTraceLogger opt-in; UndoLastSave PB rebuild; regression for `#9`. |

## Testing strategy

- **Pure services + simple state**: direct Setup/Teardown, no OS mocks.
- **Services with OS hooks** (`HotkeyService`, `OverlayInteractionService`): both have a `headless` flag in production code; `Start()` skips `Hotkey()`/`SetTimer`/`OnMessage`. Tests run `headless=true` and exercise the state machine + bus events.
- **Services with WinActive polling** (`FocusAutoPauseService`): stub subclass `_FocusAutoPauseStubService` overrides only `_IsGameActive()` with an in-memory flag; the rest runs unchanged. Synthetic `Evt.Tick` exercises the polling backup without real `WinActive`.
- **Pure state machines** (`OverlayModeService` + `OverlayModeApplier`): no Win32 calls. `OverlayModeApplier` accepts widgets via Map, so tests inject `_OverlayApplierStubWidget` that records the last `SetModeVisible` call.
- **Widget bases**: `WidgetBase` and `LayoutWidgetBase` tested with `_position.visible=false` so `ReRender()` is a no-op. Coverage: queries, mutators (`SetVisible`/`SetModeVisible`/`SetActivePosition`/`SetScale`/`SetPosition`) with clamps and the `_Persist` callback, `_OnCtrlStateChanged` handler, `_OnWheelResize`.
- **Concrete widgets and dialogs** (`CompactLayoutWidget`, `MicroLayoutWidget`, `SteveLayoutWidget`, `SettingsDialog`, `RunHistoryDialog`, etc.): mostly `_BuildGui` boilerplate; their non-GUI logic is covered by the bases, and `integration/` covers the wiring.
- **Out of reach**: `LineChartRenderer` uses `DllCall` into Gdi32/User32 — not testable without a real display. `_OnLButtonDown`, `_OnMouseWheel`, `_DragTick`, `_UpdateHoverState` in `OverlayInteractionService` need real `OnMessage`/Win32; covered partially via lifecycle, register/unregister, `SetCtrlState`, and Win32 constants.

## Real production bugs surfaced by the suite

The suite finds real bugs that `#Warn` doesn't catch. Each one below changed observable app behavior before a test exposed it. Full details and links to the regression tests live in `REGRESSION-COVERAGE.md`.

- **#1 (FIXED)**: `PersonalBestRepository.Save` was writing UTF-8 BOM, but `IniRead` key-lookup only works on UTF-16 LE BOM. In production, `runPbMs` and `runPbRunId` always returned `0`/`""` after boot even when the PB had been saved. Fix: encoding changed to `"UTF-16"` in `personal_best_repository.ahk`.
- **#2 (FIXED)**: `TextEncoding.MigrateIniToUtf8` (called in `app.Start()`) corrupted `IniRead` key-lookup for the same encoding reason. The migration API was removed entirely; INIs stay UTF-16 LE BOM. Regression catalogued as `W9.1` in `REGRESSION-COVERAGE.md`.
- **#3 (FIXED)**: `PersonalBestService._MapToDebugStr` broke on Maps with integer keys (`UnsetItemError`). It converted keys to string via `String(k)` and then did `m[strKey]` — but AHK v2 Maps with int keys reject lookup by string key. Affected `SetAsRunPb` and `RebuildFromHistory` in production (the outer `try/catch` silenced the throw but the output was wrong). Fix: store `(strKey, value)` pairs in an intermediate array instead of re-looking-up.
- **#4 (FIXED)**: `RunHistoryRepository._SafeCategoryLabel` had scope-dependent behavior. In isolated tests (without `RunStatsPlotBuilder` in scope), the fallback passed through unknown categories. With the builder in scope, it delegated to `CategoryLabel(cat)` which returned `"All"` for unknowns. Result in production: old runs with `category=boss` (a removed category) rendered as `"All"` in the UI. Fix: explicit lookup in `SegmentDefinitions` (only valid categories use the builder's label), passthrough on unknown.
- **#5 (FIXED)**: `LoadingDetectionService` timeout silently discarded `LoadingMeasured`. The `Tick` code detected timeout when `(now - startTick) > maxMs` and called `_End("timeout_no_hud_return")`, but `_End` had a `durationMs > maxMs` filter — exactly the timeout condition — so the event never reached the bus. Loadings exceeding 90 s (default `maxMs`) were invisible in the run plot. Fix: removed the `> maxMs` filter in `_End`; `Tick` is now the sole decider of timeout. Regression catalogued as `W9.2` in `REGRESSION-COVERAGE.md`.

