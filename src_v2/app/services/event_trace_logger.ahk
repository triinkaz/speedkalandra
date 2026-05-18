; EventTraceLogger — logs every event published on the EventBus.
; Registers itself as a bus interceptor and writes one line per
; Publish to LogService (level INFO, context "Event") with the
; payload serialized as readable text. Useful for diagnosing
; ordering bugs, building a session audit trail, or reproducing
; user-reported scenarios from a log attachment.
;
; Output format (LogService prefix included):
;   [yyyy-MM-dd HH:mm:ss] INFO [Event] EventName | key1=val1, key2=val2
;
; Payload serialization:
;   String / number / bool — direct, truncated past 200 chars
;   Map                    — "{k=v, k=v}", recursive up to depth 2
;   Array                  — "[item, ...]", up to 10 items
;   Object                 — "<ClassName>" (no property iteration
;                            so circular refs and slow getters
;                            can't bite us)
;   Empty / unset          — "(none)"
;
; Event volume is high in normal play (a Tick every 300 ms, plus
; gameplay events). LogService size-based + daily rotation handles
; the file growth; opt-out is simply not calling Start() — the
; interceptor isn't registered and Publish pays zero overhead.

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
        ; Bind once — RemoveInterceptor matches by reference.
        this._interceptorFn := (eventName, data) => this._OnPublish(eventName, data)
    }

    ; ---- Lifecycle ----

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

    ; Exposes the formatting through a static method so tests can
    ; assert on the output without an injected logger.
    static FormatPayload(data) => EventTraceLogger._SerializeValue(data, 0)

    ; ---- Interceptor body ----

    _OnPublish(eventName, data)
    {
        payload := EventTraceLogger._SerializeValue(data, 0)
        ; Context "Event" becomes "[Event]" in the log file, easy to grep.
        try this._log.Info(eventName . " | " . payload, "Event")
    }

    ; ---- Payload serialization ----
    ; Goal: one readable line per event, enough info to reproduce
    ; a scenario. Not aiming for round-trip JSON.

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

        ; Generic object — stamp the class name only. Iterating
        ; arbitrary properties would risk circular refs and slow
        ; getters surfacing inside Publish.
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
        ; Use `maxItems`, not `max` — the latter shadows the global
        ; Max() function and trips an AHK v2 warning.
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
        ; Escape newlines/tabs and truncate so the output stays on a
        ; single line, grep-friendly.
        out := StrReplace(s, "`r", "\r")
        out := StrReplace(out, "`n", "\n")
        out := StrReplace(out, "`t", "\t")
        return EventTraceLogger._TruncateScalar(out)
    }

    static _TruncateScalar(s)
    {
        ; Same shadowing reason as _SerializeArray — don't name this `max`.
        maxLen := EventTraceLogger.MAX_VALUE_LEN
        if (StrLen(s) <= maxLen)
            return s
        return SubStr(s, 1, maxLen) "...(+" (StrLen(s) - maxLen) ")"
    }

    ; AHK v2 has no Array.Join.
    static _JoinArray(arr, sep)
    {
        out := ""
        for i, item in arr
            out .= (i = 1 ? "" : sep) item
        return out
    }
}
