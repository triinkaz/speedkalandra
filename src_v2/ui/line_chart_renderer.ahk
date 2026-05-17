; ============================================================
; LineChartRenderer - draws a line chart via GDI (Wave 7, v17.9)
; ============================================================
;
; SCOPE:
;   Static utility that renders a line chart into a GDI bitmap and
;   returns the HBITMAP to be assigned to a GUI Picture control.
;
;   Used by RunStatsPlotDialog to show the evolution of runs:
;     - Horizontal X axis: each run is a position (chronological sequence)
;     - Vertical Y axis: time in ms
;     - Each series (map, boss, category, etc.) is a colored line
;       connecting the points of the runs where that item appears
;
; API:
;   LineChartRenderer.Render(gui, x, y, w, h, options) -> picCtrl
;
;   options := Map(
;       "series",     Array<Map{label, color, points:[{xIdx, yMs, present?}]}>,
;       "xCount",     Integer (how many points on the X axis),
;       "yMaxMs",     Integer (maximum Y scale),
;       "bgColor",    "RRGGBB" hex (chart background),
;       "stripeColors", Array["RRGGBB", "RRGGBB"] (alternating stripes),
;       "gridColor",  "RRGGBB" (horizontal lines)
;   )
;
;   Points may have `present: false` (v17.13) to indicate that the
;   series has no data at that run — the line BREAKS at that point
;   and resumes at the next present point. Without `present`, default
;   is true (compat with previous calls).
;
; GDI VS GDI+:
;   Uses classic GDI (Gdi32.dll, User32.dll) for simplicity. GDI+
;   would offer anti-aliasing but requires Gdiplus.dll, COM init, and
;   a more complex wrapper. For a small line chart (300px tall), GDI
;   is enough — lines look a bit jagged but are readable.
;
; HBITMAP OWNERSHIP:
;   When assigned via "HBITMAP:" to a Picture control, AHK takes
;   ownership — when the control/gui is destroyed, the bitmap is
;   freed automatically. Do NOT call DeleteObject manually.
;
; LIMITS:
;   - xCount min: 1 (with 1 point, only renders points without lines)
;   - series.Length min: 0 (empty chart shows only the grid)
;   - yMaxMs: if <=0, uses 1 to avoid division by zero


class LineChartRenderer
{
    ; ============================================================
    ; Render - creates a Picture control with the drawn line chart
    ;
    ; Returns the created Picture control. The Hbitmap is attached
    ; to it and will be freed when the GUI is destroyed.
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

        ; --- Create DC and bitmap ---
        hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
        hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")
        hbm := DllCall("CreateCompatibleBitmap", "Ptr", hdcScreen, "Int", w, "Int", h, "Ptr")
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
        oldObj := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hbm, "Ptr")

        ; --- Uniform background ---
        LineChartRenderer._FillRect(hdcMem, 0, 0, w, h, bgColor)

        ; --- Alternating vertical stripes (if more than 1 point) ---
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

        ; --- Horizontal gridlines (5 lines: 0%, 25%, 50%, 75%, 100%) ---
        nYTicks := 5
        j := 0
        while (j < nYTicks)
        {
            yPct := j / (nYTicks - 1)
            yPos := Round(h - 1 - (yPct * (h - 1)))
            LineChartRenderer._DrawHLine(hdcMem, 0, w, yPos, gridColor, 1)
            j++
        }

        ; --- Series (colored lines) ---
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

        ; --- DC cleanup ---
        DllCall("SelectObject", "Ptr", hdcMem, "Ptr", oldObj)
        DllCall("DeleteDC", "Ptr", hdcMem)

        ; --- Create Picture control ---
        pic := gui.Add("Picture",
            "x" x " y" y " w" w " h" h " Background" bgColor,
            "HBITMAP:" hbm)
        return pic
    }

    ; ============================================================
    ; _FillRect - fills a rectangle with a solid color
    ;
    ; Uses CreateSolidBrush + FillRect. RECT struct: 4 LONG ints
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
    ; _DrawHLine - 1px horizontal line
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
    ; _DrawSeries - draws a series of points connected by a line
    ;
    ; Also draws small circles at the vertices to highlight individual
    ; points (4px diameter).
    ;
    ; v17.13: Points with `present: false` are SKIPPED — the line
    ; breaks before them and resumes at the next present point. This
    ; lets "Per act" series show a gap in runs that didn't reach the
    ; relevant act, instead of falsely dropping to y=0.
    ; ============================================================
    static _DrawSeries(hdc, w, h, points, xCount, yMaxMs, hexColor)
    {
        if !IsObject(points) || points.Length = 0
            return

        color := LineChartRenderer._HexToBgr(hexColor)

        ; --- Line connecting points (with gap support) ---
        pen := DllCall("CreatePen", "Int", 0, "Int", 2, "UInt", color, "Ptr")
        prevPen := DllCall("SelectObject", "Ptr", hdc, "Ptr", pen, "Ptr")

        ; State: penDown=true when the cursor is positioned on a
        ; present point (next line will connect). penDown=false after
        ; an absent point (next line will be MoveTo, not LineTo).
        penDown := false
        for _, p in points
        {
            if !IsObject(p)
                continue
            present := p.Has("present") ? !!p["present"] : true
            if !present
            {
                ; Gap — breaks the current line. Doesn't draw anything;
                ; the next present point will open a new line with MoveTo.
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

        ; --- Circles on vertices (4px diameter) ---
        ; To draw a filled Ellipse, a brush is needed. Same present
        ; logic: skip absent points.
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
        ; 8px margin on each side so points don't sit on the edge
        usableW := w - 16
        return 8 + Round((xIdx / (xCount - 1)) * usableW)
    }

    static _PointY(yMs, yMaxMs, h)
    {
        if (yMaxMs <= 0)
            return h - 1
        ; 6px margin top and bottom so points don't sit on the edge
        usableH := h - 12
        py := 6 + (usableH - Round((yMs / yMaxMs) * usableH))
        return py
    }

    ; ============================================================
    ; _HexToBgr - converts "RRGGBB" hex into COLORREF (BGR)
    ;
    ; GDI uses the 0x00BBGGRR format (BGR, with implicit alpha=0).
    ; Theme.Color and SegmentDefinitions are standard hex RGB "RRGGBB".
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
