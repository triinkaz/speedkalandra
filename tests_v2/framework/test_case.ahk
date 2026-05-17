; ============================================================
; TestCase - base class for test suites
; ============================================================
;
; Each suite is a class that extends TestCase and defines:
;   - static Tests := ["method_name_1", ...]  - explicit list
;   - Setup()    (optional) - runs before each test
;   - Teardown() (optional) - runs after each test
;   - Test methods whose names are listed in static Tests
;
; The TestRunner creates ONE new instance of the suite per test,
; guaranteeing state isolation between tests. Setup runs in a clean state.
;
; Discovery is explicit (static Tests array) instead of reflection
; because enumerating methods of a class in AHK v2 is flaky, and
; because we want adding a test to be a visible action in the diff.
;
; Example:
;
;   class FooTests extends TestCase
;   {
;       static Tests := [
;           "publishes_event_on_start",
;           "throws_when_already_started",
;       ]
;
;       Setup()
;       {
;           this.bus := Fixtures.MakeBus()
;           this.svc := FooService(this.bus)
;       }
;
;       publishes_event_on_start()
;       {
;           this.svc.Start()
;           Assert.Equal(1, this.bus.Subscribers("FooStarted"))
;       }
;   }
;
;   TestRegistry.Register(FooTests)

class TestCase
{
    ; Optional hook - overridden by subclasses
    Setup()
    {
    }

    ; Optional hook - overridden by subclasses
    Teardown()
    {
    }
}
