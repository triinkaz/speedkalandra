; ============================================================
; LineChartRenderer - desenha line chart via GDI (Onda 7, v17.9)
; ============================================================
;
; ESCOPO:
;   Utility estatica que renderiza um line chart num bitmap GDI e
;   retorna o HBITMAP pra ser atribuido a um Picture control do GUI.
;
;   Usado pelo RunStatsPlotDialog pra mostrar evolucao das runs:
;     - Eixo X horizontal: cada run uma posicao (sequencia cronologica)
;     - Eixo Y vertical: tempo em ms
;     - Cada serie (mapa, boss, categoria, etc) eh uma linha colorida
;       conectando os pontos das runs onde aquele item aparece
;
; API:
;   LineChartRenderer.Render(gui, x, y, w, h, options) -> picCtrl
;
;   options := Map(
;       "series",     Array<Map{label, color, points:[{xIdx, yMs, present?}]}>,
;       "xCount",     Integer (quantos pontos no eixo X),
;       "yMaxMs",     Integer (escala maxima Y),
;       "bgColor",    "RRGGBB" hex (background do chart),
;       "stripeColors", Array["RRGGBB", "RRGGBB"] (faixas alternadas),
;       "gridColor",  "RRGGBB" (linhas horizontais)
;   )
;
;   Pontos podem ter `present: false` (v17.13) pra indicar que aquela
;   serie nao tem dados naquela run — a linha QUEBRA nesse ponto e
;   recomeca no proximo ponto presente. Sem o `present`, default eh
;   true (compat com chamadas anteriores).
;
; GDI VS GDI+:
;   Usa GDI classico (Gdi32.dll, User32.dll) por simplicidade. GDI+
;   teria anti-aliasing mas requer Gdiplus.dll, COM init, e wrapper
;   mais complexo. Pra line chart pequeno (300px alto), GDI eh
;   suficiente — linhas ficam um pouco serrilhadas mas legivel.
;
; OWNERSHIP DO HBITMAP:
;   Quando atribuido via "HBITMAP:" para um Picture control, o AHK
;   toma posse — quando o controle/gui eh destruido, o bitmap eh
;   liberado automaticamente. NAO chamar DeleteObject manualmente.
;
; LIMITES:
;   - xCount min: 1 (com 1 ponto, so renderiza pontos sem linha)
;   - series.Length min: 0 (gráfico vazio mostra so o grid)
;   - yMaxMs: se <=0, usa 1 pra evitar divisao por zero


class LineChartRenderer
{
    ; ============================================================
    ; Render - cria Picture control com line chart desenhado
    ;
    ; Retorna o Picture control criado. Hbitmap eh anexado a ele e
    ; sera liberado quando o GUI for destruido.
    ; ============================================================
    static Render(gui, x, y, w, h, options)
    {
        if (w < 10 || h < 10)
            return ""

        series       := options.Has("series")       ? options["series"]       : []
        xCount       := options.Has("xCount")       ? options["xCount"]       : 0
        yMaxMs       := options.Has("yMaxMs")       ? options["yMaxMs"]       : 1
        bgColor      := options.Has("bgColor")      ? options["bgColor"]      : "0D0F11"
        stripeCols   := options.Has("stripeColors") ? options["stripeColors"] : ["1A1D21", "131517"]
        gridColor    := options.Has("gridColor")    ? options["gridColor"]    : "303338"

        if (yMaxMs <= 0)
            yMaxMs := 1

        ; --- Cria DC e bitmap ---
        hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
        hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")
        hbm := DllCall("CreateCompatibleBitmap", "Ptr", hdcScreen, "Int", w, "Int", h, "Ptr")
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
        oldObj := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hbm, "Ptr")

        ; --- Background uniforme ---
        LineChartRenderer._FillRect(hdcMem, 0, 0, w, h, bgColor)

        ; --- Faixas verticais alternadas (se mais de 1 ponto) ---
        if (xCount > 1)
        {
            dx := w / (xCount - 1)
            i := 0
            while (i < xCount - 1)
            {
                stripCol := stripeCols[(Mod(i, 2)) + 1]
                x1 := Round(i * dx)
                x2 := Round((i + 1) * dx)
                LineChartRenderer._FillRect(hdcMem, x1, 0, x2, h, stripCol)
                i++
            }
        }

        ; --- Gridlines horizontais (5 linhas: 0%, 25%, 50%, 75%, 100%) ---
        nYTicks := 5
        j := 0
        while (j < nYTicks)
        {
            yPct := j / (nYTicks - 1)
            yPos := Round(h - 1 - (yPct * (h - 1)))
            LineChartRenderer._DrawHLine(hdcMem, 0, w, yPos, gridColor, 1)
            j++
        }

        ; --- Series (linhas coloridas) ---
        if (xCount > 0)
        {
            for _, s in series
            {
                if !IsObject(s)
                    continue
                color  := s.Has("color")  ? s["color"]  : "FFFFFF"
                points := s.Has("points") ? s["points"] : []
                if !IsObject(points) || points.Length = 0
                    continue

                LineChartRenderer._DrawSeries(hdcMem, w, h, points, xCount, yMaxMs, color)
            }
        }

        ; --- Cleanup DC ---
        DllCall("SelectObject", "Ptr", hdcMem, "Ptr", oldObj)
        DllCall("DeleteDC", "Ptr", hdcMem)

        ; --- Cria Picture control ---
        pic := gui.Add("Picture",
            "x" x " y" y " w" w " h" h " Background" bgColor,
            "HBITMAP:" hbm)
        return pic
    }

    ; ============================================================
    ; _FillRect - preenche retangulo com cor solida
    ;
    ; Usa CreateSolidBrush + FillRect. RECT struct: 4 LONG ints
    ; (left, top, right, bottom).
    ; ============================================================
    static _FillRect(hdc, x1, y1, x2, y2, hexColor)
    {
        rect := Buffer(16, 0)
        NumPut("Int", x1, "Int", y1, "Int", x2, "Int", y2, rect)
        br := DllCall("CreateSolidBrush", "UInt", LineChartRenderer._HexToBgr(hexColor), "Ptr")
        DllCall("User32\FillRect", "Ptr", hdc, "Ptr", rect, "Ptr", br)
        DllCall("DeleteObject", "Ptr", br)
    }

    ; ============================================================
    ; _DrawHLine - linha horizontal 1px
    ; ============================================================
    static _DrawHLine(hdc, x1, x2, y, hexColor, width)
    {
        pen := DllCall("CreatePen", "Int", 0, "Int", width, "UInt", LineChartRenderer._HexToBgr(hexColor), "Ptr")
        prevPen := DllCall("SelectObject", "Ptr", hdc, "Ptr", pen, "Ptr")
        DllCall("MoveToEx", "Ptr", hdc, "Int", x1, "Int", y, "Ptr", 0)
        DllCall("LineTo", "Ptr", hdc, "Int", x2, "Int", y)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", prevPen)
        DllCall("DeleteObject", "Ptr", pen)
    }

    ; ============================================================
    ; _DrawSeries - desenha uma serie de pontos conectados por linha
    ;
    ; Tambem desenha pequenos circulos nos vertices pra destacar
    ; os pontos individuais (4px diametro).
    ;
    ; v17.13: Pontos com `present: false` sao SKIPADOS — a linha
    ; quebra antes deles e recomeca no proximo ponto presente. Isso
    ; permite series "Por ato" mostrar gap em runs que nao chegaram
    ; ao ato em questao, em vez de cair pra y=0 enganosamente.
    ; ============================================================
    static _DrawSeries(hdc, w, h, points, xCount, yMaxMs, hexColor)
    {
        if !IsObject(points) || points.Length = 0
            return

        color := LineChartRenderer._HexToBgr(hexColor)

        ; --- Linha conectando pontos (com suporte a gaps) ---
        pen := DllCall("CreatePen", "Int", 0, "Int", 2, "UInt", color, "Ptr")
        prevPen := DllCall("SelectObject", "Ptr", hdc, "Ptr", pen, "Ptr")

        ; State: penDown=true quando o cursor esta posicionado num
        ; ponto presente (proxima linha conecta). penDown=false apos
        ; um ponto ausente (proxima linha sera MoveTo, nao LineTo).
        penDown := false
        for _, p in points
        {
            if !IsObject(p)
                continue
            present := p.Has("present") ? !!p["present"] : true
            if !present
            {
                ; Gap — quebra a linha atual. Nao desenha nada;
                ; proximo ponto presente vai abrir nova linha com MoveTo.
                penDown := false
                continue
            }

            xIdx := p.Has("xIdx") ? p["xIdx"] : 0
            yMs  := p.Has("yMs")  ? p["yMs"]  : 0

            px := LineChartRenderer._PointX(xIdx, xCount, w)
            py := LineChartRenderer._PointY(yMs, yMaxMs, h)

            if !penDown
            {
                DllCall("MoveToEx", "Ptr", hdc, "Int", px, "Int", py, "Ptr", 0)
                penDown := true
            }
            else
            {
                DllCall("LineTo", "Ptr", hdc, "Int", px, "Int", py)
            }
        }

        DllCall("SelectObject", "Ptr", hdc, "Ptr", prevPen)
        DllCall("DeleteObject", "Ptr", pen)

        ; --- Circulos nos vertices (4px diametro) ---
        ; Pra desenhar Ellipse preenchido, precisa de brush.
        ; Mesma logica de present: skipa pontos ausentes.
        br := DllCall("CreateSolidBrush", "UInt", color, "Ptr")
        penDot := DllCall("CreatePen", "Int", 0, "Int", 1, "UInt", color, "Ptr")
        prevBr := DllCall("SelectObject", "Ptr", hdc, "Ptr", br, "Ptr")
        prevPen2 := DllCall("SelectObject", "Ptr", hdc, "Ptr", penDot, "Ptr")

        dotR := 3
        for _, p in points
        {
            if !IsObject(p)
                continue
            present := p.Has("present") ? !!p["present"] : true
            if !present
                continue

            xIdx := p.Has("xIdx") ? p["xIdx"] : 0
            yMs  := p.Has("yMs")  ? p["yMs"]  : 0
            px := LineChartRenderer._PointX(xIdx, xCount, w)
            py := LineChartRenderer._PointY(yMs, yMaxMs, h)
            DllCall("Ellipse", "Ptr", hdc,
                "Int", px - dotR, "Int", py - dotR,
                "Int", px + dotR, "Int", py + dotR)
        }

        DllCall("SelectObject", "Ptr", hdc, "Ptr", prevBr)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", prevPen2)
        DllCall("DeleteObject", "Ptr", br)
        DllCall("DeleteObject", "Ptr", penDot)
    }

    static _PointX(xIdx, xCount, w)
    {
        if (xCount <= 1)
            return w // 2
        ; Margem de 8px pra cada lado pra pontos nao ficarem na borda
        usableW := w - 16
        return 8 + Round((xIdx / (xCount - 1)) * usableW)
    }

    static _PointY(yMs, yMaxMs, h)
    {
        if (yMaxMs <= 0)
            return h - 1
        ; Margem de 6px topo e fundo pra pontos nao ficarem na borda
        usableH := h - 12
        py := 6 + (usableH - Round((yMs / yMaxMs) * usableH))
        return py
    }

    ; ============================================================
    ; _HexToBgr - converte "RRGGBB" hex para COLORREF (BGR)
    ;
    ; GDI usa formato 0x00BBGGRR (BGR, com alpha=0 implicito).
    ; Theme.Color e SegmentDefinitions sao hex RGB padrao "RRGGBB".
    ; ============================================================
    static _HexToBgr(hex)
    {
        hex := Trim(String(hex))
        if (hex = "")
            return 0
        if (StrLen(hex) < 6)
            return 0
        r := Integer("0x" SubStr(hex, 1, 2))
        g := Integer("0x" SubStr(hex, 3, 2))
        b := Integer("0x" SubStr(hex, 5, 2))
        return (b << 16) | (g << 8) | r
    }
}
