; ============================================================
; EventTraceLogger - log every event published on the EventBus (v0.1.4)
; ============================================================
;
; Cross-cutting observer that registers as an interceptor on the
; EventBus and writes one log line per Publish, including the full
; payload serialized as text. Useful for:
;
;   - Diagnosing bugs that depend on event ordering or content
;   - Audit trail of what the app did in a session
;   - Reproducing user scenarios from real log files
;
; OUTPUT TARGET:
;   Writes via the application LogService (the same file as Info/Warn/
;   Error messages — speedkalandra.log). Uses level INFO with context
;   "Event" so it can be filtered with `grep "[Event]"`. Rotation
;   (size and daily) is handled by LogService itself.
;
; FORMAT (one event per line, prefixed by LogService):
;   [yyyy-MM-dd HH:mm:ss] INFO [Event] EventName | key1=val1, key2=val2
;
; PAYLOAD SERIALIZATION:
;   - String, number, bool: direct (truncated > 200 chars)
;   - Map: "{key1=val1, key2=val2}" (recursive, depth limit 2)
;   - Array: "[item1, item2, ...]" (max 10 items)
;   - Object: "<ClassName>" (we don't iterate arbitrary properties to
;     avoid surprises with circular references)
;   - Empty string / unset: "(none)"
;
; LIFECYCLE:
;   logger := EventTraceLogger(bus, logService)
;   logger.Start()    ; registers the interceptor (idempotent)
;   logger.Stop()     ; unregisters
;
; CAVEAT:
;   Event volume can be very high (every Tick at ~300ms = 3 events/s
;   minimum, plus zone/timer/etc. events). In a long session this
;   significantly inflates the log file. The LogService size-based
;   rotation (5MB -> rotation) and daily rotation handle that.
;
;   To temporarily disable event trace without recompiling, just don't
;   call Start() — the interceptor isn't registered and there is zero
;   overhead per Publish.
;
; ============================================================

class EventTraceLogger
{
    static MAX_VALUE_LEN := 200            ; chars before truncating each value
    static MAX_ARRAY_ITEMS := 10           ; first N items of an Array
    static MAX_MAP_DEPTH := 2              ; recursion depth for nested Maps

    _bus           := ""
    _log           := ""    ; LogService (duck-typed: Info method)
    _enabled       := false
    _interceptorFn := ""

    __New(bus, logService)
    {
        if !(bus is EventBus)
            throw TypeError("EventTraceLogger: 'bus' must be EventBus")
        if !(IsObject(logService) && logService.HasMethod("Info"))
            throw TypeError("EventTraceLogger: 'logService' must have Info() method")
        this._bus := bus
        this._log := logService
        ; Bind once. Required so RemoveInterceptor finds the same reference.
        this._interceptorFn := (eventName, data) => this._OnPublish(eventName, data)
    }

    ; ============================================================
    ; Lifecycle
    ; ============================================================

    Start()
    {
        if this._enabled
            return
        this._enabled := true
        this._bus.AddInterceptor(this._interceptorFn)
    }

    Stop()
    {
        if !this._enabled
            return
        this._enabled := false
        try this._bus.RemoveInterceptor(this._interceptorFn)
    }

    IsEnabled() => this._enabled

    ; ============================================================
    ; Public test helpers
    ;
    ; Exposes formatting in a static method so tests can assert on
    ; the output format without depending on injected logger.
    ; ============================================================
    static FormatPayload(data) => EventTraceLogger._SerializeValue(data, 0)

    ; ============================================================
    ; Interceptor body
    ; ============================================================

    _OnPublish(eventName, data)
    {
        payload := EventTraceLogger._SerializeValue(data, 0)
        ; LogService context becomes "[Event]" in the file, easy to grep.
        try this._log.Info(eventName . " | " . payload, "Event")
    }

    ; ============================================================
    ; Payload serialization
    ;
    ; Format goal: 1 line, readable in `grep`, with enough info to
    ; reproduce a scenario. We don't aim for round-trip JSON — we
    ; aim for diagnostic readability.
    ; ============================================================

    static _SerializeValue(value, depth)
    {
        ; Primitive: empty/unset
        if (value = "")
            return "(none)"

        ; Primitive: number (integer or float)
        if IsNumber(value)
            return EventTraceLogger._TruncateScalar(String(value))

        ; Primitive: string
        if (Type(value) = "String")
            return EventTraceLogger._FormatString(value)

        ; Objects from here on
        if !IsObject(value)
            return EventTraceLogger._TruncateScalar(String(value))

        ; Array
        if (value is Array)
            return EventTraceLogger._SerializeArray(value, depth)

        ; Map
        if (value is Map)
        {
            if (depth >= EventTraceLogger.MAX_MAP_DEPTH)
                return "{...}"
            return EventTraceLogger._SerializeMap(value, depth)
        }

        ; Generic object: stamp the class name. We avoid iterating
        ; arbitrary properties to dodge circular references and
        ; performance surprises.
        return "<" Type(value) ">"
    }

    static _SerializeMap(m, depth)
    {
        parts := []
        for k, v in m
        {
            keyStr := EventTraceLogger._SerializeKey(k)
            valStr := EventTraceLogger._SerializeValue(v, depth + 1)
            parts.Push(keyStr "=" valStr)
        }
        if (parts.Length = 0)
            return "{}"
        return "{" EventTraceLogger._JoinArray(parts, ", ") "}"
    }

    static _SerializeArray(arr, depth)
    {
        ; Local name `maxItems` (not `max`) to avoid AHK v2 warning about
        ; shadowing the global `Max()` function.
        if (arr.Length = 0)
            return "[]"
        items := []
        maxItems := EventTraceLogger.MAX_ARRAY_ITEMS
        loop Min(arr.Length, maxItems)
        {
            items.Push(EventTraceLogger._SerializeValue(arr[A_Index], depth + 1))
        }
        suffix := arr.Length > maxItems
                  ? ", ...(+" (arr.Length - maxItems) ")"
                  : ""
        return "[" EventTraceLogger._JoinArray(items, ", ") suffix "]"
    }

    static _SerializeKey(k)
    {
        if IsNumber(k)
            return String(k)
        return EventTraceLogger._FormatString(String(k))
    }

    static _FormatString(s)
    {
        ; Escapes newlines/tabs and truncates. The output stays on a
        ; single line, readable in `grep`.
        out := StrReplace(s, "`r", "\r")
        out := StrReplace(out, "`n", "\n")
        out := StrReplace(out, "`t", "\t")
        return EventTraceLogger._TruncateScalar(out)
    }

    static _TruncateScalar(s)
    {
        ; Local name `maxLen` (not `max`) to avoid AHK v2 warning about
        ; shadowing the global `Max()` function.
        maxLen := EventTraceLogger.MAX_VALUE_LEN
        if (StrLen(s) <= maxLen)
            return s
        return SubStr(s, 1, maxLen) "...(+" (StrLen(s) - maxLen) ")"
    }

    ; AHK v2 has no built-in Array.Join. Small helper.
    static _JoinArray(arr, sep)
    {
        out := ""
        for i, item in arr
            out .= (i = 1 ? "" : sep) item
        return out
    }
}
