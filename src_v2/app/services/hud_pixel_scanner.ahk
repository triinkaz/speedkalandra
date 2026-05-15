; ============================================================
; HudPixelScanner — detecta HUD do PoE2 via pixel sampling (Fase 9.2)
; ============================================================
;
; Port do GetVisualHudStats / IsHud*Pixel do legado (loading_visual.ahk).
; Recebe coordenadas da janela do PoE2 e amostra pixels em 3 regioes:
;
;   - Mana   (canto inferior direito):  rx 0.825-0.985, ry 0.760-0.985
;   - Life   (canto inferior esquerdo): rx 0.025-0.170, ry 0.760-0.985
;   - Hotbar (centro inferior):         rx 0.365-0.750, ry 0.835-0.990
;
; Threshold: HUD visivel se manaHits >= 2 OU lifeHits >= 2 OU
;            (lifeHits + manaHits) >= 3 OU hotbarHits >= 8.
;
; Filosofia: pure logic, deps injetaveis pra teste:
;   - pixelReader: closure (x, y) -> color RGB integer
;
; Em prod, pixelReader sera (x, y) => PixelGetColor(x, y, "RGB").
; Em teste, pode ser Map de coords -> cor pra simular HUD presente/ausente.

class HudPixelScanner
{
    _pixelReader := ""

    ; Constantes de regiao (relativas a janela do jogo)
    static MANA_RX1   := 0.825
    static MANA_RY1   := 0.760
    static MANA_RX2   := 0.985
    static MANA_RY2   := 0.985
    static LIFE_RX1   := 0.025
    static LIFE_RY1   := 0.760
    static LIFE_RX2   := 0.170
    static LIFE_RY2   := 0.985
    static HOTBAR_RX1 := 0.365
    static HOTBAR_RY1 := 0.835
    static HOTBAR_RX2 := 0.750
    static HOTBAR_RY2 := 0.990

    static GRID_LIFE_MANA := 6
    static GRID_HOTBAR    := 5
    static MIN_STEP       := 12

    __New(pixelReader := "")
    {
        if (pixelReader != "" && !IsObject(pixelReader))
            throw TypeError("HudPixelScanner: 'pixelReader' deve ser callable")

        if (pixelReader = "")
            pixelReader := (x, y) => HudPixelScanner._DefaultPixelReader(x, y)

        this._pixelReader := pixelReader
    }

    ; Scan(wx, wy, ww, wh) -> Map(visible, lifeHits, manaHits, hotbarHits)
    ;
    ; Mesma logica do legado: mana primeiro (sinal mais estavel), early
    ; exit se >=2; senao tenta life; senao hotbar como auxiliar.
    Scan(wx, wy, ww, wh)
    {
        if (ww <= 0 || wh <= 0)
            return Map("visible", false, "lifeHits", 0, "manaHits", 0, "hotbarHits", 0)

        manaHits := this._CountInRegion(wx, wy, ww, wh,
            HudPixelScanner.MANA_RX1, HudPixelScanner.MANA_RY1,
            HudPixelScanner.MANA_RX2, HudPixelScanner.MANA_RY2,
            "mana", 2, HudPixelScanner.GRID_LIFE_MANA)
        if (manaHits >= 2)
            return Map("visible", true, "lifeHits", 0, "manaHits", manaHits, "hotbarHits", 0)

        lifeHits := this._CountInRegion(wx, wy, ww, wh,
            HudPixelScanner.LIFE_RX1, HudPixelScanner.LIFE_RY1,
            HudPixelScanner.LIFE_RX2, HudPixelScanner.LIFE_RY2,
            "life", 2, HudPixelScanner.GRID_LIFE_MANA)
        if (lifeHits >= 2 || (lifeHits + manaHits) >= 3)
            return Map("visible", true, "lifeHits", lifeHits, "manaHits", manaHits, "hotbarHits", 0)

        hotbarHits := this._CountInRegion(wx, wy, ww, wh,
            HudPixelScanner.HOTBAR_RX1, HudPixelScanner.HOTBAR_RY1,
            HudPixelScanner.HOTBAR_RX2, HudPixelScanner.HOTBAR_RY2,
            "hotbar", 8, HudPixelScanner.GRID_HOTBAR)

        visible := (lifeHits >= 2 || manaHits >= 2 || (lifeHits + manaHits) >= 3 || hotbarHits >= 8)
        return Map("visible", visible, "lifeHits", lifeHits, "manaHits", manaHits, "hotbarHits", hotbarHits)
    }

    ; ============================================================
    ; Pixel classifiers (pure)
    ; ============================================================

    ; Life: vermelho dominante. r >= 55, r > g + 18, r > b + 12.
    static IsLifePixel(color)
    {
        r := (color >> 16) & 0xFF
        g := (color >> 8) & 0xFF
        b := color & 0xFF
        return (r >= 55 && r > g + 18 && r > b + 12)
    }

    ; Mana: azul/ciano dominante. b >= 55, b > r + 12, b >= g + 4.
    static IsManaPixel(color)
    {
        r := (color >> 16) & 0xFF
        g := (color >> 8) & 0xFF
        b := color & 0xFF
        return (b >= 55 && b > r + 12 && b >= g + 4)
    }

    ; Hotbar: skill icons coloridos saturados. max >= 80, range >= 55.
    static IsHotbarPixel(color)
    {
        r := (color >> 16) & 0xFF
        g := (color >> 8) & 0xFF
        b := color & 0xFF
        maxc := Max(r, Max(g, b))
        minc := Min(r, Min(g, b))
        return (maxc >= 80 && (maxc - minc) >= 55)
    }

    ; ============================================================
    ; Internals
    ; ============================================================

    _CountInRegion(wx, wy, ww, wh, rx1, ry1, rx2, ry2, kind, stopAt, gridDivisions)
    {
        x1 := Round(wx + ww * rx1)
        y1 := Round(wy + wh * ry1)
        x2 := Round(wx + ww * rx2)
        y2 := Round(wy + wh * ry2)
        stepX := Max(HudPixelScanner.MIN_STEP, Round((x2 - x1) / gridDivisions))
        stepY := Max(HudPixelScanner.MIN_STEP, Round((y2 - y1) / gridDivisions))

        hits := 0
        y := y1
        while (y <= y2)
        {
            x := x1
            while (x <= x2)
            {
                color := this._ReadPixel(x, y)
                if (color >= 0)
                {
                    if (kind = "life" && HudPixelScanner.IsLifePixel(color))
                        hits += 1
                    else if (kind = "mana" && HudPixelScanner.IsManaPixel(color))
                        hits += 1
                    else if (kind = "hotbar" && HudPixelScanner.IsHotbarPixel(color))
                        hits += 1
                }
                if (hits >= stopAt)
                    return hits
                x += stepX
            }
            y += stepY
        }
        return hits
    }

    ; Le um pixel via reader injetado. Retorna -1 em erro pra caller skipar.
    _ReadPixel(x, y)
    {
        try
            return Integer(this._pixelReader.Call(x, y))
        return -1
    }

    static _DefaultPixelReader(x, y)
    {
        try
        {
            CoordMode("Pixel", "Screen")
            return PixelGetColor(x, y, "RGB") + 0
        }
        return -1
    }
}
