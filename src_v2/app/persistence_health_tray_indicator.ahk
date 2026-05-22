; PersistenceHealthTrayIndicator — surfaces RunService's
; persistence-degraded state via a tray-menu item.
;
; Subscribes to Events.PersistenceHealthChanged and toggles a tray
; menu indicator:
;
;   degraded=true  -> add  "⚠ Crash recovery may be stale — see log"
;                          (disabled / informational only)
;   degraded=false -> remove the item
;
; The actual A_TrayMenu mutation is delegated to two callables
; (addItemFn / removeItemFn). Production wires the global helpers
; SpeedKalandraTrayAddPersistenceWarning / RemovePersistenceWarning
; (defined in speedkalandra.ahk) so the menu-position logic lives
; alongside the other tray helpers. Tests inject lambdas that
; record into arrays for assertions, so the indicator stays unit-
; testable without a real tray.
;
; State is tracked internally (_itemAdded) so consecutive
; degraded=true publishes don't double-add and consecutive
; degraded=false publishes don't false-remove. The transition-only
; publish contract in RunService._Persist already guarantees this,
; but keeping the indicator idempotent is cheap insurance against
; a future subscriber-order quirk.
;
; Dispose() unsubscribes and clears any lingering item so a Reload
; cycle on the same tray instance doesn't carry visual cruft.

class PersistenceHealthTrayIndicator
{
    static ITEM_LABEL := "⚠ Crash recovery may be stale — see log"

    _bus          := ""
    _handler      := ""
    _addItemFn    := ""
    _removeItemFn := ""
    _itemAdded    := false

    __New(bus, addItemFn := "", removeItemFn := "")
    {
        if !(bus is EventBus)
            throw TypeError("PersistenceHealthTrayIndicator: 'bus' must be EventBus")
        if (addItemFn != "" && !(addItemFn is Func) && !HasMethod(addItemFn, "Call"))
            throw TypeError("PersistenceHealthTrayIndicator: 'addItemFn' must be callable")
        if (removeItemFn != "" && !(removeItemFn is Func) && !HasMethod(removeItemFn, "Call"))
            throw TypeError("PersistenceHealthTrayIndicator: 'removeItemFn' must be callable")

        this._bus := bus
        ; Default to the global tray helpers defined in
        ; speedkalandra.ahk. Tests pass lambdas that capture into
        ; an array so we can assert add/remove ordering without a
        ; real tray.
        this._addItemFn    := (addItemFn = "")
            ? (label) => SpeedKalandraTrayAddPersistenceWarning()
            : addItemFn
        this._removeItemFn := (removeItemFn = "")
            ? (label) => SpeedKalandraTrayRemovePersistenceWarning()
            : removeItemFn

        this._handler := (data) => this._OnHealthChanged(data)
        bus.Subscribe(Events.PersistenceHealthChanged, this._handler)
    }

    Dispose()
    {
        if (this._handler != "")
        {
            try this._bus.Unsubscribe(Events.PersistenceHealthChanged, this._handler)
            this._handler := ""
        }
        ; Best-effort: clear lingering menu item so a Reload on the
        ; same tray instance doesn't carry a stale warning. The
        ; underlying removeFn is wrapped in try because production
        ; default calls A_TrayMenu.Delete which throws if the item
        ; isn't there.
        if this._itemAdded
        {
            try (this._removeItemFn)(PersistenceHealthTrayIndicator.ITEM_LABEL)
            this._itemAdded := false
        }
    }

    ; Test-facing accessor: true while the tray indicator is
    ; expected to be visible. Production callers shouldn't need it
    ; (they'd just look at A_TrayMenu directly).
    IsIndicatorShown() => this._itemAdded

    _OnHealthChanged(data)
    {
        if !IsObject(data)
            return
        degraded := data.Has("degraded") ? !!data["degraded"] : false

        if degraded
        {
            ; Idempotent add: skip if already shown.
            if this._itemAdded
                return
            try (this._addItemFn)(PersistenceHealthTrayIndicator.ITEM_LABEL)
            this._itemAdded := true
        }
        else
        {
            ; Idempotent remove: skip if already hidden.
            if !this._itemAdded
                return
            try (this._removeItemFn)(PersistenceHealthTrayIndicator.ITEM_LABEL)
            this._itemAdded := false
        }
    }
}
