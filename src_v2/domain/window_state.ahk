; ============================================================
; WindowState - minimal window state (Wave 6)
; ============================================================
;
; POST-DEMOLITION VERSION: the overlay now has 2 widgets with FIXED
; sizes (compactLayout 720x80, microLayout 200x32) and positions
; persisted in OverlayLayout. The tracker's "main" window no longer
; exists — there are 2 independent widgets.
;
; The only remaining state is microLocked, which indicates whether
; the user manually locked MICRO mode (vs auto-MICRO via panel keys).
;
; INI MAPPING:
;   [Window]
;   MicroLocked=0|1

class WindowState
{
    microLocked := false
    steveLocked := false    ; v17.14 — lock for SteveTheHappyWhale mode

    static Defaults() => WindowState()

    static FromMap(data)
    {
        if !IsObject(data)
            throw TypeError("WindowState.FromMap: 'data' must be a Map")
        w := WindowState()
        w.microLocked := WindowState._GetBool(data, "microLocked", w.microLocked)
        w.steveLocked := WindowState._GetBool(data, "steveLocked", w.steveLocked)
        return w
    }

    ToMap()
    {
        return Map(
            "microLocked", this.microLocked,
            "steveLocked", this.steveLocked
        )
    }

    static _GetBool(data, key, default)
    {
        if !data.Has(key)
            return default
        v := data[key]
        if (v = "" || v = 0 || v = "0" || v = false)
            return false
        if (v = 1 || v = "1" || v = true)
            return true
        return !!v
    }
}
