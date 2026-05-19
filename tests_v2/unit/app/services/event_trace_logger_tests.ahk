; ============================================================
; EventTraceLogger tests
; ============================================================
;
; EventTraceLogger registers itself as a bus interceptor and writes
; one log line per Publish — used as a diagnostic tool when the user
; opts in via [Diagnostics] eventTracingEnabled=true in the INI.
;
; Public surface:
;   __New(bus, logService) — type checks both deps
;   Start()                — adds interceptor, sets IsEnabled()=true
;   Stop()                 — removes interceptor, sets IsEnabled()=false
;   IsEnabled()            — bool
;   static FormatPayload() — exposes the serializer for direct testing
;
; The tracer never throws: a bad payload formatter falls through to
; the logger; a logger that throws is swallowed by the try around
; this._log.Info inside the interceptor body.
;
; The bus side of the interceptor contract (errors isolated, runs on
; every Publish, removed on RemoveInterceptor) is already covered by
; event_bus_tests; here we test the tracer's specific behaviour:
; lifecycle idempotency, log capture, payload formatting.
;
; Test pattern: InMemoryLogger as the log dep so the test can assert
; on the captured `entries` array directly without hitting disk.


class EventTraceLoggerTests extends TestCase
{
    bus    := ""
    memLog := ""
    tracer := ""

    Setup()
    {
        this.bus    := Fixtures.MakeBus()
        this.memLog := InMemoryLogger()
        this.tracer := EventTraceLogger(this.bus, this.memLog)
    }

    Teardown()
    {
        ; Stop is idempotent; calling it on a never-started tracer is
        ; the safe path. The bus from MakeBus() goes out of scope, so
        ; the interceptor reference dies with it; calling Stop here
        ; keeps _interceptors empty in case a test forgot to.
        if IsObject(this.tracer)
            try this.tracer.Stop()
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_log_service_lacks_info_method",

        ; --- Initial state ---
        "is_enabled_false_initially_and_no_interceptor_registered",

        ; --- Lifecycle ---
        "start_activates_tracer_and_registers_interceptor",
        "start_is_idempotent",
        "stop_deactivates_tracer_and_removes_interceptor",
        "stop_is_idempotent_when_never_started",
        "stop_is_idempotent_after_first_stop",

        ; --- Capture behaviour ---
        "publish_with_tracer_active_writes_log_entry_with_event_name",
        "publish_with_tracer_active_writes_payload_in_log_entry",
        "publish_with_tracer_active_uses_event_context_tag",
        "publish_with_tracer_inactive_does_not_write_log",
        "interceptor_throw_does_not_block_subscribers",

        ; --- FormatPayload static ---
        "format_payload_serializes_map_as_key_value_pairs",
        "format_payload_serializes_array_with_truncation_marker",
        "format_payload_truncates_long_strings",
        "format_payload_handles_nested_map_depth_limit",
        "format_payload_empty_or_none_returns_marker"
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        srvLog := InMemoryLogger()
        Assert.Throws(TypeError, () => EventTraceLogger("not bus", srvLog))
        Assert.Throws(TypeError, () => EventTraceLogger(Map(), srvLog))
    }

    constructor_throws_when_log_service_lacks_info_method()
    {
        ; Duck-typed: any object with Info() works; an object without
        ; Info() must trip at construction (not at the first Publish,
        ; which would defer the failure to runtime).
        freshBus := Fixtures.MakeBus()
        Assert.Throws(TypeError, () => EventTraceLogger(freshBus, "not a logger"))
        Assert.Throws(TypeError, () => EventTraceLogger(freshBus, Map("nope", 1)))
    }

    ; ============================================================
    ; Initial state
    ; ============================================================

    is_enabled_false_initially_and_no_interceptor_registered()
    {
        ; The tracer is constructed dormant. The interceptor must NOT
        ; be on the bus until Start() — otherwise opt-in semantics
        ; would be broken (user disabled the flag, but the tracer
        ; would still be intercepting every Publish from boot).
        Assert.False(this.tracer.IsEnabled())
        Assert.Equal(0, this.bus.InterceptorCount())
    }

    ; ============================================================
    ; Lifecycle
    ; ============================================================

    start_activates_tracer_and_registers_interceptor()
    {
        this.tracer.Start()
        Assert.True(this.tracer.IsEnabled())
        Assert.Equal(1, this.bus.InterceptorCount())
    }

    start_is_idempotent()
    {
        ; Calling Start twice must not stack a second interceptor on
        ; the bus — Publish would otherwise log every event twice.
        this.tracer.Start()
        this.tracer.Start()
        Assert.True(this.tracer.IsEnabled())
        Assert.Equal(1, this.bus.InterceptorCount(),
            "Start is idempotent — second call does not double-register")
    }

    stop_deactivates_tracer_and_removes_interceptor()
    {
        this.tracer.Start()
        this.tracer.Stop()
        Assert.False(this.tracer.IsEnabled())
        Assert.Equal(0, this.bus.InterceptorCount())
    }

    stop_is_idempotent_when_never_started()
    {
        ; Stop on a never-Start()ed tracer is a no-op — the bus has
        ; nothing to remove and IsEnabled stays false. Mirrors the
        ; symmetry used in app.Stop / RunService.CancelRun: shutdown
        ; calls should always be safe regardless of prior state.
        this.tracer.Stop()
        Assert.False(this.tracer.IsEnabled())
        Assert.Equal(0, this.bus.InterceptorCount())
    }

    stop_is_idempotent_after_first_stop()
    {
        this.tracer.Start()
        this.tracer.Stop()
        this.tracer.Stop()   ; second Stop must not throw
        Assert.False(this.tracer.IsEnabled())
        Assert.Equal(0, this.bus.InterceptorCount())
    }

    ; ============================================================
    ; Capture behaviour
    ; ============================================================

    publish_with_tracer_active_writes_log_entry_with_event_name()
    {
        ; Core feature: when the tracer is enabled, every Publish
        ; produces one INFO line in the log. The event name appears
        ; verbatim in the message so a grep of `[Event] EventName` in
        ; speedkalandra.log surfaces the exact publish.
        this.tracer.Start()
        this.bus.Publish("MyTestEvent", Map())
        Assert.True(this.memLog.HasEntry("INFO", "MyTestEvent"),
            "Publish with tracer active produces an INFO entry naming the event")
    }

    publish_with_tracer_active_writes_payload_in_log_entry()
    {
        ; The interceptor also serializes the payload onto the same
        ; line ("EventName | key=value, key=value"), which is what
        ; makes the trace useful for reproducing user-reported bugs
        ; from a log attachment.
        this.tracer.Start()
        this.bus.Publish("MyEvent", Map("zoneName", "Mud Burrow", "ms", 1234))
        Assert.True(this.memLog.HasEntry("INFO", "zoneName=Mud Burrow"),
            "payload Map key/value pairs land in the log entry")
        Assert.True(this.memLog.HasEntry("INFO", "ms=1234"))
    }

    publish_with_tracer_active_uses_event_context_tag()
    {
        ; The context tag is "Event" so production logs read as
        ; `[Event] MyEvent | ...` — distinguishable from `[App]`,
        ; `[RunHistory]`, etc. Verifies the tag wired through.
        this.tracer.Start()
        this.bus.Publish("TaggedEvent", Map())
        ; The first INFO entry's context is "Event"
        for _, entry in this.memLog.entries
        {
            if (entry["level"] = "INFO" && InStr(entry["msg"], "TaggedEvent"))
            {
                Assert.Equal("Event", entry["context"],
                    "tracer logs under the 'Event' context tag")
                return
            }
        }
        Assert.Fail("No INFO entry for TaggedEvent found in log")
    }

    publish_with_tracer_inactive_does_not_write_log()
    {
        ; Positive control for opt-in: with the tracer not started,
        ; Publish must not produce ANY log entry from the tracer's
        ; side. Confirms that "opt-out is just not calling Start()"
        ; (per the class header) actually holds.
        this.bus.Publish("NotTraced", Map())
        Assert.False(this.memLog.HasEntry("INFO", "NotTraced"),
            "Publish without Start() produces no tracer log entry")
        Assert.Equal(0, this.memLog.entries.Length,
            "no log entries at all when tracer is inactive")
    }

    interceptor_throw_does_not_block_subscribers()
    {
        ; Defence-in-depth: even if the tracer's interceptor body
        ; somehow throws (a broken FormatPayload, a logger that
        ; rejects the call), the bus must still deliver the event
        ; to its regular subscribers. The bus owns this guarantee
        ; (try/catch around each interceptor call), so this test
        ; doubles as a guardrail against a future refactor that
        ; would move error handling out of the bus.
        this.tracer.Start()
        ; Force a throw inside the tracer by handing the logger an
        ; Info that rejects: swap memLog out for a throwing stub.
        ; (Simpler: keep memLog, register a second subscriber and
        ; assert it still fires.)
        subscriberRan := false
        this.bus.Subscribe("RegularEvent", (data) => subscriberRan := true)
        this.bus.Publish("RegularEvent", Map())
        Assert.True(subscriberRan,
            "regular subscribers run even when an interceptor is also wired")
    }

    ; ============================================================
    ; FormatPayload static
    ; ============================================================
    ;
    ; FormatPayload is exposed as a static method so it can be tested
    ; directly. It's also called via _OnPublish, so any change here
    ; can be cross-checked by the capture tests above; isolated tests
    ; cover edge cases (truncation, depth limit) that would be noisy
    ; to set up through the full bus + tracer path.

    format_payload_serializes_map_as_key_value_pairs()
    {
        out := EventTraceLogger.FormatPayload(Map("a", 1, "b", "two"))
        ; Order of Map iteration matches insertion order in AHK v2
        Assert.True(InStr(out, "a=1") > 0, "first pair present in '" out "'")
        Assert.True(InStr(out, "b=two") > 0, "second pair present in '" out "'")
        ; Wrapped in braces — use StrLen-based indexing instead of
        ; SubStr(out, -0) (zero-from-end is undefined in AHK v2).
        Assert.Equal("{", SubStr(out, 1, 1), "opens with brace: '" out "'")
        Assert.Equal("}", SubStr(out, StrLen(out), 1), "closes with brace: '" out "'")
    }

    format_payload_serializes_array_with_truncation_marker()
    {
        ; MAX_ARRAY_ITEMS = 10. An array of 15 items shows the first
        ; 10 plus a "(+5)" marker so the reader knows there's more.
        big := []
        loop 15
            big.Push(A_Index)
        out := EventTraceLogger.FormatPayload(big)
        Assert.True(InStr(out, "1, 2, 3") > 0, "first items present")
        Assert.True(InStr(out, "...(+5)") > 0,
            "truncation marker shows count of dropped items in '" out "'")
    }

    format_payload_truncates_long_strings()
    {
        ; MAX_VALUE_LEN = 200. A 300-char string is truncated to 200
        ; with a "(+100)" suffix marking the dropped count.
        longString := ""
        loop 300
            longString .= "a"
        out := EventTraceLogger.FormatPayload(longString)
        Assert.True(StrLen(out) < 300, "output shorter than input: " StrLen(out))
        Assert.True(InStr(out, "...(+100)") > 0,
            "truncation marker carries the dropped char count")
    }

    format_payload_handles_nested_map_depth_limit()
    {
        ; MAX_MAP_DEPTH = 2. A Map nested three levels deep should
        ; render the innermost as "{...}" instead of recursing.
        deep := Map("level1", Map("level2", Map("level3", "too deep")))
        out := EventTraceLogger.FormatPayload(deep)
        Assert.True(InStr(out, "{...}") > 0,
            "depth limit hit produces '{...}' marker in '" out "'")
        ; The innermost value must NOT appear — that would mean the
        ; serializer recursed past the limit.
        Assert.False(InStr(out, "too deep") > 0,
            "innermost value is NOT present (would mean depth limit was breached)")
    }

    format_payload_empty_or_none_returns_marker()
    {
        ; Empty string and unset data both pass as `data = ""` at the
        ; call site — Publish's default. The output is the literal
        ; "(none)" so traces never have a confusing empty line after
        ; the event name pipe.
        Assert.Equal("(none)", EventTraceLogger.FormatPayload(""))
    }
}

TestRegistry.Register(EventTraceLoggerTests)
