; ============================================================
; WarningSinkTests
; ============================================================
;
; Three sinks share a duck-typed contract: `Warn(message, ex := "")`.
; Each test class covers one implementation:
;
;   NullWarningSinkTests        no-op shape; the sink must not throw
;                                under any input.
;   LogServiceWarningSinkTests  formatting + tag wiring + Warn-never-
;                                throws guarantee.
;   InMemoryWarningSinkTests    capture, Clear, HasMessage semantics.


class NullWarningSinkTests extends TestCase
{
    static Tests := [
        "warn_with_message_only_does_not_throw",
        "warn_with_message_and_exception_does_not_throw",
        "warn_with_empty_string_does_not_throw",
        "warn_with_object_exception_does_not_throw"
    ]

    Setup()
    {
    }
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    warn_with_message_only_does_not_throw()
    {
        sink := NullWarningSink()
        sink.Warn("something failed")
        Assert.True(true)   ; reaching this line is the assertion
    }

    warn_with_message_and_exception_does_not_throw()
    {
        sink := NullWarningSink()
        try
            throw Error("simulated")
        catch as ex
            sink.Warn("op failed", ex)
        Assert.True(true)
    }

    warn_with_empty_string_does_not_throw()
    {
        sink := NullWarningSink()
        sink.Warn("")
        Assert.True(true)
    }

    warn_with_object_exception_does_not_throw()
    {
        sink := NullWarningSink()
        sink.Warn("op failed", Map("not", "an exception"))
        Assert.True(true)
    }
}


class LogServiceWarningSinkTests extends TestCase
{
    static Tests := [
        ; --- Construction validation ---
        "constructor_throws_when_log_service_missing",
        "constructor_throws_when_log_service_has_no_warn",
        "constructor_throws_when_tag_is_empty",
        "constructor_throws_when_tag_is_whitespace",

        ; --- Forwarding behaviour ---
        "warn_forwards_message_to_log_service",
        "warn_uses_constructor_tag_as_context",
        "warn_with_exception_appends_ex_message",
        "warn_with_object_lacking_message_property_falls_back_to_message_only",
        "warn_with_empty_ex_message_falls_back_to_message_only",
        "warn_never_throws_even_if_log_service_breaks",

        ; --- Accessor ---
        "get_tag_returns_constructor_tag"
    ]

    Setup()
    {
    }
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    ; --- Constructor validation ---

    constructor_throws_when_log_service_missing()
    {
        Assert.Throws(TypeError, () => LogServiceWarningSink("", "PB"))
    }

    constructor_throws_when_log_service_has_no_warn()
    {
        Assert.Throws(TypeError, () => LogServiceWarningSink(Map(), "PB"))
    }

    constructor_throws_when_tag_is_empty()
    {
        Assert.Throws(ValueError, () => LogServiceWarningSink(InMemoryLogger(), ""))
    }

    constructor_throws_when_tag_is_whitespace()
    {
        Assert.Throws(ValueError, () => LogServiceWarningSink(InMemoryLogger(), "   "))
    }

    ; --- Forwarding ---

    warn_forwards_message_to_log_service()
    {
        log := InMemoryLogger()
        sink := LogServiceWarningSink(log, "PB")

        sink.Warn("Save failed")

        Assert.Equal(1, log.GetWarnCount())
        Assert.True(log.HasEntry("WARN", "Save failed"))
    }

    warn_uses_constructor_tag_as_context()
    {
        log := InMemoryLogger()
        sink := LogServiceWarningSink(log, "PB")

        sink.Warn("disk full")

        Assert.Equal(1, log.entries.Length)
        Assert.Equal("PB", log.entries[1]["context"])
    }

    warn_with_exception_appends_ex_message()
    {
        log := InMemoryLogger()
        sink := LogServiceWarningSink(log, "PB")

        try
            throw OSError("Access is denied", -2147024891)
        catch as ex
            sink.Warn("Save failed", ex)

        Assert.True(log.HasEntry("WARN", "Save failed: Access is denied"))
    }

    warn_with_object_lacking_message_property_falls_back_to_message_only()
    {
        log := InMemoryLogger()
        sink := LogServiceWarningSink(log, "PB")

        ; Map() has no `Message` property; the sink must not crash
        ; and must still log the original message.
        sink.Warn("Save failed", Map("not", "an exception"))

        Assert.True(log.HasEntry("WARN", "Save failed"))
    }

    warn_with_empty_ex_message_falls_back_to_message_only()
    {
        log := InMemoryLogger()
        sink := LogServiceWarningSink(log, "PB")

        ; An exception with empty Message shouldn't produce
        ; "Save failed: " trailing junk.
        try
            throw Error("")
        catch as ex
            sink.Warn("Save failed", ex)

        ; Exact match: nothing trailing.
        Assert.Equal("Save failed", log.entries[1]["msg"])
    }

    warn_never_throws_even_if_log_service_breaks()
    {
        ; Hard guarantee: a broken downstream logger must not break
        ; the caller. Otherwise an error path would generate a new
        ; error path, defeating the point of the sink.
        brokenLogger := _ThrowingLoggerForSinkTests()
        sink := LogServiceWarningSink(brokenLogger, "PB")

        sink.Warn("disk full")   ; must not throw

        Assert.Equal(1, brokenLogger.warnCallCount)
    }

    ; --- Accessor ---

    get_tag_returns_constructor_tag()
    {
        sink := LogServiceWarningSink(InMemoryLogger(), "RunState")
        Assert.Equal("RunState", sink.GetTag())
    }
}


class InMemoryWarningSinkTests extends TestCase
{
    static Tests := [
        "starts_empty",
        "warn_appends_entry_with_message_and_ex",
        "warn_without_ex_stores_empty_ex_field",
        "count_returns_entry_count",
        "clear_resets_entries",
        "has_message_substring_match",
        "has_message_returns_false_when_no_match",
        "has_message_empty_substring_returns_false"
    ]

    Setup()
    {
    }
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    starts_empty()
    {
        sink := InMemoryWarningSink()
        Assert.Equal(0, sink.Count())
    }

    warn_appends_entry_with_message_and_ex()
    {
        sink := InMemoryWarningSink()
        try
            throw Error("simulated")
        catch as ex
            sink.Warn("op failed", ex)

        Assert.Equal(1, sink.Count())
        Assert.Equal("op failed", sink.entries[1]["message"])
        Assert.True(IsObject(sink.entries[1]["ex"]))
    }

    warn_without_ex_stores_empty_ex_field()
    {
        sink := InMemoryWarningSink()
        sink.Warn("no exception passed")

        Assert.Equal("", sink.entries[1]["ex"])
    }

    count_returns_entry_count()
    {
        sink := InMemoryWarningSink()
        sink.Warn("a")
        sink.Warn("b")
        sink.Warn("c")
        Assert.Equal(3, sink.Count())
    }

    clear_resets_entries()
    {
        sink := InMemoryWarningSink()
        sink.Warn("a")
        sink.Warn("b")
        sink.Clear()
        Assert.Equal(0, sink.Count())
    }

    has_message_substring_match()
    {
        sink := InMemoryWarningSink()
        sink.Warn("PersonalBest save failed: disk full")
        Assert.True(sink.HasMessage("disk full"))
        Assert.True(sink.HasMessage("PersonalBest"))
    }

    has_message_returns_false_when_no_match()
    {
        sink := InMemoryWarningSink()
        sink.Warn("totally unrelated")
        Assert.False(sink.HasMessage("disk full"))
    }

    has_message_empty_substring_returns_false()
    {
        ; Empty needle is rejected by the sink as nonsensical.
        ; Without this guard, AHK v2's InStr throws on empty needle.
        sink := InMemoryWarningSink()
        sink.Warn("a")
        Assert.False(sink.HasMessage(""))
    }
}


; ------------------------------------------------------------
; Test helper — a logger whose `Warn` always throws. Used to assert
; that LogServiceWarningSink swallows downstream errors instead of
; propagating them to the caller.
; ------------------------------------------------------------
class _ThrowingLoggerForSinkTests
{
    warnCallCount := 0

    Debug(msg, context := "") => 0
    Info(msg, context := "")  => 0

    Warn(msg, context := "")
    {
        this.warnCallCount += 1
        throw OSError("simulated log failure")
    }

    Error(msg, context := "") => 0
    Flush() => 0
    GetWarnCount()  => this.warnCallCount
    GetErrorCount() => 0
    ResetCounts()   => 0
}


TestRegistry.Register(NullWarningSinkTests)
TestRegistry.Register(LogServiceWarningSinkTests)
TestRegistry.Register(InMemoryWarningSinkTests)
