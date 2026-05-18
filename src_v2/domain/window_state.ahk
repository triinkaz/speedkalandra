; ============================================================
; WindowState - minimal window state
; ============================================================
;
; The overlay has 3 widgets with fixed sizes (compactLayout 380x96,
; microLayout 200x32, steveLayout 380x64) and positions persisted in
; OverlayLayout. There is no single "main" tracker window — each
; widget is independent.
;
; The only state here is microLocked / steveLocked, indicating whether
; the user manually locked the corresponding mode (vs auto-MICRO via
; panel keys).
;
; INI MAPPING:
;   [Window]
;   MicroLocked=0|1

class WindowState
{
    microLocked := false
    steveLocked := false    ; lock for the SteveTheHappyWhale layout

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
