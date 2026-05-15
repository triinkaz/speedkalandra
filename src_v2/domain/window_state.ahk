; ============================================================
; WindowState - state minimo da janela (Onda 6)
; ============================================================
;
; VERSAO POS-DEMOLICAO: o overlay agora tem 2 widgets com tamanhos
; FIXOS (compactLayout 720x80, microLayout 200x32) e posicoes
; persistidas em OverlayLayout. Janela "principal" do tracker nao
; existe mais — sao 2 widgets independentes.
;
; O unico state remanescente eh microLocked, que indica se o usuario
; travou manualmente o modo MICRO (vs auto-MICRO por panel keys).
;
; INI MAPPING:
;   [Window]
;   MicroLocked=0|1

class WindowState
{
    microLocked := false
    steveLocked := false    ; v17.14 — lock pro modo SteveTheHappyWhale

    static Defaults() => WindowState()

    static FromMap(data)
    {
        if !IsObject(data)
            throw TypeError("WindowState.FromMap: 'data' deve ser Map")
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
