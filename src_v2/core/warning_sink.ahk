; ============================================================
; WarningSink — minimal observability channel for infra/services
; ============================================================
;
; Lets non-app layers (repositories, services without a LogService
; dependency) surface actionable failures without coupling to the
; concrete LogService. Keeps the layered architecture honest —
; `infra/` and isolated services do not know about LogService — and
; still makes failures visible in `data/speedkalandra.log` for the
; user.
;
; Three implementations live here:
;
;   NullWarningSink         no-op, zero overhead. Default for tests
;                            and for code paths that haven't opted
;                            in yet.
;   LogServiceWarningSink   adapter that forwards to a LogService
;                            (or any duck-typed logger with a
;                            `Warn(msg, context := "")` method),
;                            tagging every entry with a fixed context
;                            so the log is greppable.
;   InMemoryWarningSink     captures entries into an array, used by
;                            tests to assert that a code path warned.
;
; Duck-typed contract: anything with `Warn(message, ex := "")` works.
; No `extends` chain — keeps construction order in the composition
; root unconstrained and mirrors the NullLogger / InMemoryLogger
; pattern in this same folder.
;
; The `WarningSink.Resolve(...)` static helper is the canonical way
; for a constructor to accept an optional sink parameter: it returns
; a `NullWarningSink` for empty / non-object input, and throws on an
; object that doesn't implement the contract. Fails fast at wiring
; time instead of crashing on the first Warn call somewhere deeper.


; ------------------------------------------------------------
; WarningSink — static utilities only. Acts as the namespace for
; the `Resolve` helper. The three concrete sinks below do NOT
; extend this class (the duck-typed contract is enforced by
; HasMethod checks inside Resolve, not by inheritance).
; ------------------------------------------------------------
class WarningSink
{
    ; Resolve an optional `warningSink` constructor parameter into
    ; a usable sink, or fail with a clear error.
    ;
    ;   sinkOrEmpty = ""          → NullWarningSink()
    ;   sinkOrEmpty = non-object  → NullWarningSink()  (defensive)
    ;   sinkOrEmpty = object with no `Warn` method → TypeError
    ;   sinkOrEmpty = object with `Warn` method    → returned as-is
    ;
    ; The throw on "object without Warn" is the point of this helper:
    ; without it, a wiring bug (e.g. passing a Map() by mistake) would
    ; only surface the first time a save/load failure actually
    ; happened in production. Now it surfaces at app boot.
    static Resolve(sinkOrEmpty)
    {
        if !IsObject(sinkOrEmpty)
            return NullWarningSink()
        if !sinkOrEmpty.HasMethod("Warn")
            throw TypeError("WarningSink.Resolve: object must implement Warn(message, ex := '')")
        return sinkOrEmpty
    }
}


; ------------------------------------------------------------
; NullWarningSink — silently swallows every Warn call.
; Use as the default when a repo is constructed without an explicit
; sink, so callers that don't pass one degrade safely.
; ------------------------------------------------------------
class NullWarningSink
{
    Warn(message, ex := "")
    {
        ; no-op
    }
}


; ------------------------------------------------------------
; LogServiceWarningSink — forwards Warns to a LogService.
;
; Construction:
;   sink := LogServiceWarningSink(logService, "PB")
;
; The tag passed at construction is the LogService context — it
; appears in every log line written through this sink, so a grep
; for `[PB]` shows every warning from this layer.
;
; Warn(message, ex) formats the entry as `"<message>: <ex.Message>"`
; when an exception object is passed, or `"<message>"` otherwise.
; The forward to the underlying logger is wrapped in `try` so a
; broken LogService never breaks the caller — that's a hard rule of
; warning sinks: surfacing a problem must not create a new one.
; ------------------------------------------------------------
class LogServiceWarningSink
{
    _log := ""
    _tag := ""

    __New(logService, tag)
    {
        if !IsObject(logService)
            throw TypeError("LogServiceWarningSink: 'logService' must be an object with a Warn method")
        if !logService.HasMethod("Warn")
            throw TypeError("LogServiceWarningSink: 'logService' must implement Warn(msg, context := '')")
        if (Trim(String(tag)) = "")
            throw ValueError("LogServiceWarningSink: 'tag' is required so log entries are greppable by source")
        this._log := logService
        this._tag := String(tag)
    }

    Warn(message, ex := "")
    {
        fullMsg := String(message)
        if IsObject(ex)
        {
            ; Exception objects from `catch as ex` always carry a
            ; Message property; defensive HasOwnProp guards a caller
            ; that hands us a non-Error object.
            try
            {
                if ex.HasOwnProp("Message") && ex.Message != ""
                    fullMsg .= ": " . ex.Message
            }
        }
        try this._log.Warn(fullMsg, this._tag)
    }

    GetTag() => this._tag
}


; ------------------------------------------------------------
; InMemoryWarningSink — captures Warns into an array, ideal for
; tests that need to assert "the failure path logged" or "the happy
; path did not log".
; ------------------------------------------------------------
class InMemoryWarningSink
{
    entries := []   ; Array<Map("message", str, "ex", obj|"", "ts", str)>

    Warn(message, ex := "")
    {
        this.entries.Push(Map(
            "message", String(message),
            "ex",      ex,
            "ts",      A_Now
        ))
    }

    Count() => this.entries.Length

    Clear()
    {
        this.entries := []
    }

    ; Substring match against any captured message. Returns true on
    ; first hit. Useful for the common assertion "the warn for X
    ; happened" without pinning the exact wording. An empty needle
    ; returns false (rejected as nonsensical — "match anything"
    ; semantics make tests harder to reason about than easier).
    HasMessage(substring)
    {
        needle := String(substring)
        if (needle = "")
            return false
        for _, entry in this.entries
        {
            if InStr(entry["message"], needle)
                return true
        }
        return false
    }
}
