; ============================================================
; HudPixelScanner — detects the PoE2 HUD via pixel sampling (Phase 9.2)
; ============================================================
;
; Port of legacy GetVisualHudStats / IsHud*Pixel (loading_visual.ahk).
; Takes PoE2 window coordinates and samples pixels in 3 regions:
;
;   - Mana   (bottom-right corner):  rx 0.825-0.985, ry 0.760-0.985
;   - Life   (bottom-left corner):   rx 0.025-0.170, ry 0.760-0.985
;   - Hotbar (bottom center):        rx 0.365-0.750, ry 0.835-0.990
;
; Threshold: HUD visible if manaHits >= 2 OR lifeHits >= 2 OR
;            (lifeHits + manaHits) >= 3 OR hotbarHits >= 8.
;
; Philosophy: pure logic, injectable deps for testing:
;   - pixelReader: closure (x, y) -> color RGB integer
;
; In prod, pixelReader will be (x, y) => PixelGetColor(x, y, "RGB").
; In tests, can be a Map of coords -> color to simulate HUD
; present/absent.

class HudPixelScanner
{
    _pixelReader := ""

    ; Region constants (relative to the game window)
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
            throw TypeError("HudPixelScanner: 'pixelReader' must be callable")

        if (pixelReader = "")
            pixelReader := (x, y) => HudPixelScanner._DefaultPixelReader(x, y)

        this._pixelReader := pixelReader
    }

    ; Scan(wx, wy, ww, wh) -> Map(visible, lifeHits, manaHits, hotbarHits)
    ;
    ; Same logic as legacy: mana first (most stable signal), early
    ; exit if >=2; otherwise tries life; otherwise hotbar as auxiliary.
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

    ; Life: dominant red. r >= 55, r > g + 18, r > b + 12.
    static IsLifePixel(color)
    {
        r := (color >> 16) & 0xFF
        g := (color >> 8) & 0xFF
        b := color & 0xFF
        return (r >= 55 && r > g + 18 && r > b + 12)
    }

    ; Mana: dominant blue/cyan. b >= 55, b > r + 12, b >= g + 4.
    static IsManaPixel(color)
    {
        r := (color >> 16) & 0xFF
        g := (color >> 8) & 0xFF
        b := color & 0xFF
        return (b >= 55 && b > r + 12 && b >= g + 4)
    }

    ; Hotbar: saturated colorful skill icons. max >= 80, range >= 55.
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

    ; Reads a pixel via the injected reader. Returns -1 on error so
    ; the caller can skip.
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
