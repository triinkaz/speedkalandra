; ============================================================
; OverlayResizeGeometry — pure geometry for resize-by-border
; ============================================================
;
; Static-only helper used by the resize-by-border interaction
; (PLUS_LAYOUTS_SPEC.md §7-§8). Three independent pure functions:
;
;   HitTestBorder  — which border, if any, is the cursor over?
;   ComputeNewSize — given a drag delta, what are the new w/h?
;   ComputeFloor   — what's the smallest valid w/h for a given scale?
;
; The interactive plumbing (OnMessage hooks, SetCapture, cursor
; changes) lives in OverlayInteractionService and consumes these
; helpers. The split exists so the geometry is testable headless
; — Win32 hit-tests are not.


class OverlayResizeGeometry
{
    static EDGE_NONE   := ""
    static EDGE_RIGHT  := "right"
    static EDGE_BOTTOM := "bottom"

    ; Threshold (in pixels at scale=1.0) for the cursor to count as
    ; "on a border". 6px is the smallest that doesn't fight the
    ; default window-chrome click area on a typical 1080p display;
    ; OverlayInteractionService can override per-call if a higher-DPI
    ; tweak ever proves necessary.
    static DEFAULT_BORDER_PX := 6

    ; ============================================================
    ; HitTestBorder
    ;
    ; Returns EDGE_RIGHT, EDGE_BOTTOM, or "" depending on whether
    ; the cursor is within `borderPx` of the right or bottom edge
    ; of the widget rectangle. Coordinates are screen-space; the
    ; widget rectangle is `[winX, winX+winW) × [winY, winY+winH)`.
    ;
    ; Cursor outside the widget altogether returns "". Cursor in
    ; the bottom-right corner (within `borderPx` of both edges)
    ; returns whichever edge is closer; ties favor EDGE_RIGHT — an
    ; arbitrary but deterministic choice, kept stable by tests so
    ; muscle-memory diagonal drags always grab the same axis.
    ;
    ; Why no EDGE_LEFT / EDGE_TOP: see PLUS_LAYOUTS_SPEC.md §7. The
    ; widget's top-left is anchored by the persisted left/top%; any
    ; left/top resize would have to re-anchor that point, doubling
    ; the moving parts for a use case nobody asked for.
    ; ============================================================
    static HitTestBorder(mouseX, mouseY, winX, winY, winW, winH, borderPx := 0)
    {
        if (borderPx <= 0)
            borderPx := OverlayResizeGeometry.DEFAULT_BORDER_PX

        ; Outside the widget rectangle — no edge hit.
        if (mouseX < winX || mouseX >= winX + winW)
            return OverlayResizeGeometry.EDGE_NONE
        if (mouseY < winY || mouseY >= winY + winH)
            return OverlayResizeGeometry.EDGE_NONE

        distRight  := (winX + winW) - mouseX
        distBottom := (winY + winH) - mouseY
        onRight  := distRight  <= borderPx
        onBottom := distBottom <= borderPx

        if (onRight && onBottom)
            return distRight <= distBottom
                ? OverlayResizeGeometry.EDGE_RIGHT
                : OverlayResizeGeometry.EDGE_BOTTOM
        if onRight
            return OverlayResizeGeometry.EDGE_RIGHT
        if onBottom
            return OverlayResizeGeometry.EDGE_BOTTOM
        return OverlayResizeGeometry.EDGE_NONE
    }

    ; ============================================================
    ; ComputeNewSize
    ;
    ; Returns the resulting {w, h} after applying the drag delta to
    ; the dimension matching `edge`. The other dimension passes
    ; through unchanged — drag-right never changes height,
    ; drag-bottom never changes width. Aspect ratio is free.
    ;
    ; Clamped at `minW` / `minH` (the floor for the current scale —
    ; ComputeFloor builds it). No upper bound: a user can drag the
    ; widget arbitrarily large, which is what the spec intends.
    ;
    ; Unknown `edge` returns {startW, startH} unchanged — safer
    ; than throwing because the caller is typically inside a
    ; WM_MOUSEMOVE handler where a throw would surface as a
    ; cryptic stop in the middle of a drag.
    ; ============================================================
    static ComputeNewSize(startW, startH, deltaX, deltaY, edge, minW, minH)
    {
        newW := startW
        newH := startH

        if (edge = OverlayResizeGeometry.EDGE_RIGHT)
        {
            candidate := startW + deltaX
            newW := candidate < minW ? minW : candidate
        }
        else if (edge = OverlayResizeGeometry.EDGE_BOTTOM)
        {
            candidate := startH + deltaY
            newH := candidate < minH ? minH : candidate
        }

        return Map("w", newW, "h", newH)
    }

    ; ============================================================
    ; ComputeFloor
    ;
    ; The smallest valid {w, h} for a widget at the given scale.
    ; Below this, content can't fit even with reflow (the typography
    ; would need more pixels than the container has). Scale below
    ; MIN_SCALE is clamped up to MIN_SCALE — Ctrl+wheel never makes
    ; the floor smaller than the smallest typography size.
    ;
    ; The contract: ComputeNewSize's `minW`/`minH` arguments are
    ; expected to come from this function. Inlining the clamp into
    ; ComputeNewSize would couple it to OverlayPosition; this split
    ; keeps ComputeNewSize a pure delta-application function.
    ; ============================================================
    static ComputeFloor(fixedW, fixedH, scale)
    {
        effectiveScale := scale < OverlayPosition.MIN_SCALE
            ? OverlayPosition.MIN_SCALE
            : scale
        return Map(
            "w", Round(fixedW * effectiveScale),
            "h", Round(fixedH * effectiveScale)
        )
    }
}
