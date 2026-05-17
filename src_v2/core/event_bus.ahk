; ============================================================
; EventBus — in-process pub/sub, synchronous
; ============================================================
;
; Heart of the architecture. UI publishes Commands, Services consume
; them and publish Events, other subscribers react.
;
; Usage:
;   bus := EventBus(logger)
;   bus.Subscribe(Events.RunPaused, MyHandler)
;   bus.Publish(Commands.PauseRequested)
;
; Characteristics:
;   - Synchronous: handlers run immediately in subscribe order
;   - Fault-tolerant: a handler that throws does not prevent others
;   - Errors are logged via logger (never silenced)
;   - Safe Unsubscribe during Publish (clones array before iterating)
;
; Does NOT do:
;   - Threading (AHK has none). For "async" use SetTimer + Publish
;   - Persistent queues. Lost events are lost (no replay)

class EventBus
{
    _subs   := Map()      ; eventName -> Array of callbacks
    _logger := ""

    __New(logger := "")
    {
        this._logger := IsObject(logger) ? logger : NullLogger()
    }

    ; ------------------------------------------------------------
    ; Subscribe(eventName, callback)
    ;   callback receives (data) where data is what was passed to Publish
    ;   (empty string if Publish does not pass data)
    ; Returns a token that can be used in Unsubscribe (the callback itself)
    ; ------------------------------------------------------------
    Subscribe(eventName, callback)
    {
        if (eventName = "")
            throw ValueError("EventBus.Subscribe: empty eventName")
        if (!IsObject(callback))
            throw TypeError("EventBus.Subscribe: callback must be callable")

        if !this._subs.Has(eventName)
            this._subs[eventName] := []
        this._subs[eventName].Push(callback)

        this._logger.Debug("Subscribed to '" eventName "' (" this._subs[eventName].Length " total)", "EventBus")
        return callback
    }

    ; ------------------------------------------------------------
    ; Unsubscribe(eventName, callback)
    ;   Removes the callback from the event. No effect if it wasn't subscribed.
    ; ------------------------------------------------------------
    Unsubscribe(eventName, callback)
    {
        if !this._subs.Has(eventName)
            return false

        for i, cb in this._subs[eventName]
        {
            if (cb = callback)
            {
                this._subs[eventName].RemoveAt(i)
                this._logger.Debug("Unsubscribed from '" eventName "'", "EventBus")
                ; v17.15 (Bug #22): if there are no subscribers left, delete
                ; the Map key. Prevents _subs from growing indefinitely in
                ; long sessions with Stop/Start cycles (and keeps the
                ; Publish() fast-path when nobody listens to the event).
                if (this._subs[eventName].Length = 0)
                    this._subs.Delete(eventName)
                return true
            }
        }
        return false
    }

    ; ------------------------------------------------------------
    ; Publish(eventName, data := "")
    ;   Calls all subscribed callbacks in subscribe order.
    ;   Errors are isolated — a callback that throws does not prevent
    ;   the others. Errors are logged as ERROR.
    ; ------------------------------------------------------------
    Publish(eventName, data := "")
    {
        if !this._subs.Has(eventName)
            return 0

        ; Clone to allow Unsubscribe or new Subscribe during Publish
        callbacks := this._subs[eventName].Clone()
        delivered := 0

        for _, cb in callbacks
        {
            try
            {
                cb(data)
                delivered++
            }
            catch as e
            {
                this._logger.Error(
                    "Handler for '" eventName "' failed: " e.Message
                    . " | What: " (e.HasOwnProp("What") ? e.What : "?")
                    . " | Line: " (e.HasOwnProp("Line") ? e.Line : "?"),
                    "EventBus"
                )
            }
        }

        return delivered
    }

    ; ------------------------------------------------------------
    ; Subscribers(eventName) -> int
    ;   How many handlers are subscribed. Useful for debug/test.
    ; ------------------------------------------------------------
    Subscribers(eventName)
    {
        return this._subs.Has(eventName) ? this._subs[eventName].Length : 0
    }

    ; ------------------------------------------------------------
    ; Clear()
    ;   Removes ALL subscribers. Useful in tests/teardown.
    ;   Do NOT use in production.
    ; ------------------------------------------------------------
    Clear()
    {
        this._subs := Map()
    }
}
