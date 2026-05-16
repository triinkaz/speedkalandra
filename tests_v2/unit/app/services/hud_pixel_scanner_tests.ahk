; ============================================================
; HudPixelScannerTests
; ============================================================
;
; HudPixelScanner detecta o HUD do PoE2 amostrando pixels em 3
; regioes (mana / life / hotbar). E' puro com dep injetavel:
;   pixelReader: closure (x, y) -> color RGB integer
;
; Em prod, default pixelReader usa PixelGetColor (OS hook).
; Em testes, injetamos closure que retorna cor fixa pra simular
; HUD presente/ausente.
;
; Cobertura:
;   - Classifiers static (IsLifePixel/IsManaPixel/IsHotbarPixel)
;   - Construtor (default, callable, rejeicao de invalidos)
;   - Scan: regioes individuais, combined threshold, edge cases
;
; NOTA SOBRE CORES TESTAVEIS:
;   0xFF0000 (puro vermelho) -> SO life
;   0x0000FF (puro azul)     -> SO mana
;   0xFFFF00 (puro amarelo)  -> SO hotbar
;   0x000000 (preto)         -> nada
;   0xFFFFFF (branco)        -> nada (max=255 mas range=0)


class HudPixelScannerTests extends TestCase
{
    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Classifiers: IsLifePixel ---
        "is_life_pixel_pure_red_passes",
        "is_life_pixel_threshold_at_55_passes",
        "is_life_pixel_just_below_threshold_fails",
        "is_life_pixel_red_too_close_to_green_fails",
        "is_life_pixel_red_too_close_to_blue_fails",
        "is_life_pixel_pure_blue_fails",
        "is_life_pixel_pure_white_fails",
        "is_life_pixel_pure_black_fails",

        ; --- Classifiers: IsManaPixel ---
        "is_mana_pixel_pure_blue_passes",
        "is_mana_pixel_threshold_at_55_passes",
        "is_mana_pixel_just_below_threshold_fails",
        "is_mana_pixel_blue_too_close_to_red_fails",
        "is_mana_pixel_blue_too_close_to_green_fails",
        "is_mana_pixel_pure_red_fails",
        "is_mana_pixel_pure_white_fails",
        "is_mana_pixel_pure_black_fails",

        ; --- Classifiers: IsHotbarPixel ---
        "is_hotbar_pixel_pure_yellow_passes",
        "is_hotbar_pixel_threshold_at_80_passes",
        "is_hotbar_pixel_below_max_threshold_fails",
        "is_hotbar_pixel_below_range_threshold_fails",
        "is_hotbar_pixel_pure_white_fails",
        "is_hotbar_pixel_pure_black_fails",

        ; --- Construtor ---
        "constructor_with_no_args_accepts_default_reader",
        "constructor_accepts_arrow_lambda",
        "constructor_throws_on_string_reader",
        "constructor_throws_on_number_reader",

        ; --- Scan: edge cases ---
        "scan_returns_invisible_for_zero_width",
        "scan_returns_invisible_for_zero_height",
        "scan_returns_invisible_for_negative_dimensions",
        "scan_returns_map_with_required_keys",
        "scan_returns_all_zero_hits_on_black",

        ; --- Scan: regioes ---
        "scan_detects_mana_hits_for_all_blue_pixels",
        "scan_detects_life_hits_when_no_mana",
        "scan_detects_hotbar_hits_when_no_life_no_mana",
        "scan_visible_true_when_mana_hits_geq_2",
        "scan_visible_true_when_life_hits_geq_2",
        "scan_visible_true_when_hotbar_hits_geq_8",
        "scan_invisible_when_all_white",

        ; --- Scan: reader robusto ---
        "scan_with_throwing_pixel_reader_returns_invisible"
    ]

    ; ============================================================
    ; Classifiers: IsLifePixel
    ; r >= 55 && r > g+18 && r > b+12
    ; ============================================================

    is_life_pixel_pure_red_passes()
    {
        Assert.True(HudPixelScanner.IsLifePixel(0xFF0000))
    }

    is_life_pixel_threshold_at_55_passes()
    {
        ; r=55, g=0, b=0 -> passa por pouco
        Assert.True(HudPixelScanner.IsLifePixel(0x370000))
    }

    is_life_pixel_just_below_threshold_fails()
    {
        ; r=54, g=0, b=0 -> r < 55
        Assert.False(HudPixelScanner.IsLifePixel(0x360000))
    }

    is_life_pixel_red_too_close_to_green_fails()
    {
        ; r=100, g=85, b=0 -> r-g=15 < 18 (precisa > 18)
        Assert.False(HudPixelScanner.IsLifePixel(0x645500))
    }

    is_life_pixel_red_too_close_to_blue_fails()
    {
        ; r=100, g=0, b=92 -> r-b=8 < 12 (precisa > 12)
        Assert.False(HudPixelScanner.IsLifePixel(0x64005C))
    }

    is_life_pixel_pure_blue_fails()
    {
        Assert.False(HudPixelScanner.IsLifePixel(0x0000FF))
    }

    is_life_pixel_pure_white_fails()
    {
        ; r-g=0, r-b=0 -> falha em ambos
        Assert.False(HudPixelScanner.IsLifePixel(0xFFFFFF))
    }

    is_life_pixel_pure_black_fails()
    {
        Assert.False(HudPixelScanner.IsLifePixel(0x000000))
    }

    ; ============================================================
    ; Classifiers: IsManaPixel
    ; b >= 55 && b > r+12 && b >= g+4
    ; ============================================================

    is_mana_pixel_pure_blue_passes()
    {
        Assert.True(HudPixelScanner.IsManaPixel(0x0000FF))
    }

    is_mana_pixel_threshold_at_55_passes()
    {
        ; b=55, r=0, g=0
        Assert.True(HudPixelScanner.IsManaPixel(0x000037))
    }

    is_mana_pixel_just_below_threshold_fails()
    {
        Assert.False(HudPixelScanner.IsManaPixel(0x000036))
    }

    is_mana_pixel_blue_too_close_to_red_fails()
    {
        ; b=100, r=92 -> b-r=8 < 12
        Assert.False(HudPixelScanner.IsManaPixel(0x5C0064))
    }

    is_mana_pixel_blue_too_close_to_green_fails()
    {
        ; b=100, g=97 -> b-g=3 < 4
        Assert.False(HudPixelScanner.IsManaPixel(0x006164))
    }

    is_mana_pixel_pure_red_fails()
    {
        Assert.False(HudPixelScanner.IsManaPixel(0xFF0000))
    }

    is_mana_pixel_pure_white_fails()
    {
        ; b-r=0 -> falha em b > r+12
        Assert.False(HudPixelScanner.IsManaPixel(0xFFFFFF))
    }

    is_mana_pixel_pure_black_fails()
    {
        Assert.False(HudPixelScanner.IsManaPixel(0x000000))
    }

    ; ============================================================
    ; Classifiers: IsHotbarPixel
    ; max(r,g,b) >= 80 && (max-min) >= 55
    ; ============================================================

    is_hotbar_pixel_pure_yellow_passes()
    {
        ; r=255, g=255, b=0 -> max=255, range=255
        Assert.True(HudPixelScanner.IsHotbarPixel(0xFFFF00))
    }

    is_hotbar_pixel_threshold_at_80_passes()
    {
        ; r=80, g=25, b=80 -> max=80, range=55
        Assert.True(HudPixelScanner.IsHotbarPixel(0x501950))
    }

    is_hotbar_pixel_below_max_threshold_fails()
    {
        ; r=79, g=0, b=0 -> max=79 < 80
        Assert.False(HudPixelScanner.IsHotbarPixel(0x4F0000))
    }

    is_hotbar_pixel_below_range_threshold_fails()
    {
        ; r=100, g=50, b=100 -> max=100, range=50 < 55
        Assert.False(HudPixelScanner.IsHotbarPixel(0x643264))
    }

    is_hotbar_pixel_pure_white_fails()
    {
        ; max=255 mas range=0
        Assert.False(HudPixelScanner.IsHotbarPixel(0xFFFFFF))
    }

    is_hotbar_pixel_pure_black_fails()
    {
        Assert.False(HudPixelScanner.IsHotbarPixel(0x000000))
    }

    ; ============================================================
    ; Construtor
    ; ============================================================

    constructor_with_no_args_accepts_default_reader()
    {
        scanner := HudPixelScanner()
        ; Apenas verifica que nao explode. Default usa PixelGetColor real,
        ; nao testavel aqui.
        Assert.True(IsObject(scanner))
    }

    constructor_accepts_arrow_lambda()
    {
        scanner := HudPixelScanner((x, y) => 0xFF0000)
        Assert.True(IsObject(scanner))
    }

    constructor_throws_on_string_reader()
    {
        Assert.Throws(TypeError, () => HudPixelScanner("not callable"))
    }

    constructor_throws_on_number_reader()
    {
        Assert.Throws(TypeError, () => HudPixelScanner(42))
    }

    ; ============================================================
    ; Scan: edge cases
    ; ============================================================

    scan_returns_invisible_for_zero_width()
    {
        scanner := HudPixelScanner((x, y) => 0xFF0000)
        result := scanner.Scan(0, 0, 0, 1000)
        Assert.False(result["visible"])
        Assert.Equal(0, result["lifeHits"])
        Assert.Equal(0, result["manaHits"])
        Assert.Equal(0, result["hotbarHits"])
    }

    scan_returns_invisible_for_zero_height()
    {
        scanner := HudPixelScanner((x, y) => 0xFF0000)
        result := scanner.Scan(0, 0, 1000, 0)
        Assert.False(result["visible"])
    }

    scan_returns_invisible_for_negative_dimensions()
    {
        scanner := HudPixelScanner((x, y) => 0xFF0000)
        result := scanner.Scan(0, 0, -100, -100)
        Assert.False(result["visible"])
    }

    scan_returns_map_with_required_keys()
    {
        scanner := HudPixelScanner((x, y) => 0x000000)
        result := scanner.Scan(0, 0, 1920, 1080)
        Assert.True(result.Has("visible"))
        Assert.True(result.Has("lifeHits"))
        Assert.True(result.Has("manaHits"))
        Assert.True(result.Has("hotbarHits"))
    }

    scan_returns_all_zero_hits_on_black()
    {
        scanner := HudPixelScanner((x, y) => 0x000000)
        result := scanner.Scan(0, 0, 1920, 1080)
        Assert.False(result["visible"])
        Assert.Equal(0, result["lifeHits"])
        Assert.Equal(0, result["manaHits"])
        Assert.Equal(0, result["hotbarHits"])
    }

    ; ============================================================
    ; Scan: regioes individuais
    ; ============================================================

    scan_detects_mana_hits_for_all_blue_pixels()
    {
        ; All pixels = puro azul -> mana classifier hit em qualquer pixel
        ; Mana eh procurada primeiro, early-exit em >=2 hits.
        scanner := HudPixelScanner((x, y) => 0x0000FF)
        result := scanner.Scan(0, 0, 1920, 1080)
        Assert.True(result["visible"])
        Assert.True(result["manaHits"] >= 2, "manaHits deve atingir threshold")
    }

    scan_detects_life_hits_when_no_mana()
    {
        ; Puro vermelho -> nao bate mana, bate life. Mana procurada primeiro
        ; e retorna 0; entao algoritmo procura life.
        scanner := HudPixelScanner((x, y) => 0xFF0000)
        result := scanner.Scan(0, 0, 1920, 1080)
        Assert.True(result["visible"])
        Assert.Equal(0, result["manaHits"])
        Assert.True(result["lifeHits"] >= 2)
    }

    scan_detects_hotbar_hits_when_no_life_no_mana()
    {
        ; Puro amarelo -> nao bate life nem mana, bate hotbar
        scanner := HudPixelScanner((x, y) => 0xFFFF00)
        result := scanner.Scan(0, 0, 1920, 1080)
        Assert.True(result["visible"])
        Assert.Equal(0, result["manaHits"])
        Assert.Equal(0, result["lifeHits"])
        Assert.True(result["hotbarHits"] >= 8)
    }

    ; ============================================================
    ; Scan: thresholds de visibilidade
    ; ============================================================

    scan_visible_true_when_mana_hits_geq_2()
    {
        scanner := HudPixelScanner((x, y) => 0x0000FF)
        result := scanner.Scan(0, 0, 1920, 1080)
        Assert.True(result["visible"])
        Assert.True(result["manaHits"] >= 2)
    }

    scan_visible_true_when_life_hits_geq_2()
    {
        scanner := HudPixelScanner((x, y) => 0xFF0000)
        result := scanner.Scan(0, 0, 1920, 1080)
        Assert.True(result["visible"])
        Assert.True(result["lifeHits"] >= 2)
    }

    scan_visible_true_when_hotbar_hits_geq_8()
    {
        scanner := HudPixelScanner((x, y) => 0xFFFF00)
        result := scanner.Scan(0, 0, 1920, 1080)
        Assert.True(result["visible"])
        Assert.True(result["hotbarHits"] >= 8)
    }

    scan_invisible_when_all_white()
    {
        ; Branco: nem mana (b-r=0), nem life (r-g=0), nem hotbar (range=0)
        scanner := HudPixelScanner((x, y) => 0xFFFFFF)
        result := scanner.Scan(0, 0, 1920, 1080)
        Assert.False(result["visible"])
        Assert.Equal(0, result["manaHits"])
        Assert.Equal(0, result["lifeHits"])
        Assert.Equal(0, result["hotbarHits"])
    }

    ; ============================================================
    ; Scan: reader robusto (throws -> retorna -1, skipa)
    ; ============================================================

    scan_with_throwing_pixel_reader_returns_invisible()
    {
        ; _ReadPixel pega exceptions e retorna -1, _CountInRegion skipa.
        ThrowingReader(x, y)
        {
            throw Error("simulated read failure")
        }

        scanner := HudPixelScanner(ThrowingReader)
        result := scanner.Scan(0, 0, 1920, 1080)
        Assert.False(result["visible"])
        Assert.Equal(0, result["manaHits"])
        Assert.Equal(0, result["lifeHits"])
        Assert.Equal(0, result["hotbarHits"])
    }
}

TestRegistry.Register(HudPixelScannerTests)
