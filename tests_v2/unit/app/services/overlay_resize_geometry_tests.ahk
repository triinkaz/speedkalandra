; ============================================================
; OverlayResizeGeometryTests
; ============================================================
;
; Pure-geometry helpers used by the resize-by-border interaction
; (PLUS_LAYOUTS_SPEC.md §7-§8). Static-only class — no state,
; no construction, no headless flag.
;
; Three independent functions exercised here:
;   HitTestBorder  — coordinate-vs-rectangle classification
;   ComputeNewSize — delta application with floor clamping
;   ComputeFloor   — scale-aware minimum size


class OverlayResizeGeometryTests extends TestCase
{
    static Tests := [
        ; --- HitTestBorder ---
        "hit_test_returns_none_when_cursor_outside_widget",
        "hit_test_returns_none_when_cursor_in_center",
        "hit_test_returns_right_when_cursor_within_threshold_of_right_edge",
        "hit_test_returns_bottom_when_cursor_within_threshold_of_bottom_edge",
        "hit_test_returns_right_when_cursor_exactly_on_right_edge",
        "hit_test_returns_bottom_when_cursor_exactly_on_bottom_edge",
        "hit_test_corner_prefers_right_on_tie",
        "hit_test_corner_picks_closer_edge",
        "hit_test_uses_default_border_px_when_zero_passed",
        "hit_test_uses_custom_border_px_when_specified",

        ; --- ComputeNewSize ---
        "compute_new_size_right_drag_changes_width_only",
        "compute_new_size_bottom_drag_changes_height_only",
        "compute_new_size_clamps_at_min_width",
        "compute_new_size_clamps_at_min_height",
        "compute_new_size_no_upper_bound",
        "compute_new_size_unknown_edge_no_op",
        "compute_new_size_negative_delta_shrinks_until_floor",

        ; --- ComputeFloor ---
        "compute_floor_at_scale_1_returns_fixed_size",
        "compute_floor_at_scale_2_doubles",
        "compute_floor_at_scale_half_halves",
        "compute_floor_below_min_scale_clamps_up",

        ; --- Static constants ---
        "static_default_border_px_is_six",
        "static_edge_constants_are_distinct"
    ]

    ; ============================================================
    ; HitTestBorder
    ; ============================================================

    hit_test_returns_none_when_cursor_outside_widget()
    {
        ; Widget at (100, 100), 380x96. Cursor far to the left.
        edge := OverlayResizeGeometry.HitTestBorder(50, 120, 100, 100, 380, 96)
        Assert.Equal("", edge, "Cursor left of widget — no edge")
    }

    hit_test_returns_none_when_cursor_in_center()
    {
        ; Center of the same widget.
        edge := OverlayResizeGeometry.HitTestBorder(290, 148, 100, 100, 380, 96)
        Assert.Equal("", edge, "Cursor in center — no edge")
    }

    hit_test_returns_right_when_cursor_within_threshold_of_right_edge()
    {
        ; Widget right edge at 100+380 = 480. Cursor at 477 (3px inside),
        ; vertically centered, well away from bottom.
        edge := OverlayResizeGeometry.HitTestBorder(477, 130, 100, 100, 380, 96)
        Assert.Equal("right", edge)
    }

    hit_test_returns_bottom_when_cursor_within_threshold_of_bottom_edge()
    {
        ; Widget bottom edge at 100+96 = 196. Cursor at 193, horizontally
        ; centered, well away from right.
        edge := OverlayResizeGeometry.HitTestBorder(290, 193, 100, 100, 380, 96)
        Assert.Equal("bottom", edge)
    }

    hit_test_returns_right_when_cursor_exactly_on_right_edge()
    {
        ; Right edge is at winX+winW = 480, but the rectangle is
        ; half-open: [winX, winX+winW). So x=480 is OUTSIDE.
        ; x=479 is the last pixel inside, and distRight=1.
        edge := OverlayResizeGeometry.HitTestBorder(479, 130, 100, 100, 380, 96)
        Assert.Equal("right", edge)
    }

    hit_test_returns_bottom_when_cursor_exactly_on_bottom_edge()
    {
        edge := OverlayResizeGeometry.HitTestBorder(290, 195, 100, 100, 380, 96)
        Assert.Equal("bottom", edge)
    }

    hit_test_corner_prefers_right_on_tie()
    {
        ; Bottom-right corner: distRight == distBottom == 3.
        ; Tie-break is documented: right wins. Anti-regression: if
        ; this flips, every diagonal drag changes axis silently.
        edge := OverlayResizeGeometry.HitTestBorder(477, 193, 100, 100, 380, 96)
        Assert.Equal("right", edge,
            "On tie, HitTestBorder prefers right (documented)")
    }

    hit_test_corner_picks_closer_edge()
    {
        ; distRight=5 (x=475), distBottom=2 (y=194). Bottom is closer
        ; — should win even though both are within threshold.
        edge := OverlayResizeGeometry.HitTestBorder(475, 194, 100, 100, 380, 96)
        Assert.Equal("bottom", edge,
            "Closer of two simultaneously-on borders wins")
    }

    hit_test_uses_default_border_px_when_zero_passed()
    {
        ; borderPx=0 must fall back to DEFAULT_BORDER_PX (=6).
        ; Cursor 5px from right edge: should register with default
        ; (6) but not with a narrower threshold.
        edge := OverlayResizeGeometry.HitTestBorder(475, 130, 100, 100, 380, 96, 0)
        Assert.Equal("right", edge,
            "borderPx=0 sentinel triggers default threshold")
    }

    hit_test_uses_custom_border_px_when_specified()
    {
        ; Custom threshold = 20. Cursor 15px from right edge.
        edge := OverlayResizeGeometry.HitTestBorder(465, 130, 100, 100, 380, 96, 20)
        Assert.Equal("right", edge)

        ; Same cursor with default threshold (6) is too far.
        edgeDefault := OverlayResizeGeometry.HitTestBorder(465, 130, 100, 100, 380, 96)
        Assert.Equal("", edgeDefault, "Default threshold doesn't reach this far")
    }

    ; ============================================================
    ; ComputeNewSize
    ; ============================================================

    compute_new_size_right_drag_changes_width_only()
    {
        ; Drag right by +50px. Width grows; height untouched.
        result := OverlayResizeGeometry.ComputeNewSize(380, 96, 50, 0, "right", 200, 50)
        Assert.Equal(430, result["w"])
        Assert.Equal(96,  result["h"], "Height unchanged on right-edge drag")
    }

    compute_new_size_bottom_drag_changes_height_only()
    {
        ; Drag down by +30px. Height grows; width untouched.
        result := OverlayResizeGeometry.ComputeNewSize(380, 96, 0, 30, "bottom", 200, 50)
        Assert.Equal(380, result["w"], "Width unchanged on bottom-edge drag")
        Assert.Equal(126, result["h"])
    }

    compute_new_size_clamps_at_min_width()
    {
        ; Drag right by -500px (huge shrink) — should land on minW=200.
        result := OverlayResizeGeometry.ComputeNewSize(380, 96, -500, 0, "right", 200, 50)
        Assert.Equal(200, result["w"], "Width clamps at floor")
        Assert.Equal(96,  result["h"])
    }

    compute_new_size_clamps_at_min_height()
    {
        result := OverlayResizeGeometry.ComputeNewSize(380, 96, 0, -1000, "bottom", 200, 50)
        Assert.Equal(380, result["w"])
        Assert.Equal(50,  result["h"], "Height clamps at floor")
    }

    compute_new_size_no_upper_bound()
    {
        ; A 4K monitor can host a 3000+px overlay. No max clamp.
        result := OverlayResizeGeometry.ComputeNewSize(380, 96, 2620, 0, "right", 200, 50)
        Assert.Equal(3000, result["w"], "No upper bound on width")
    }

    compute_new_size_unknown_edge_no_op()
    {
        ; A mistyped edge value passes startW/startH through. The
        ; comment in OverlayResizeGeometry calls out why we don't
        ; throw — this test pins the behavior.
        result := OverlayResizeGeometry.ComputeNewSize(380, 96, 100, 100, "diagonal", 200, 50)
        Assert.Equal(380, result["w"])
        Assert.Equal(96,  result["h"])
    }

    compute_new_size_negative_delta_shrinks_until_floor()
    {
        ; Start 500x100, drag right by -50. Within floor (200, 50),
        ; should land at 450.
        result := OverlayResizeGeometry.ComputeNewSize(500, 100, -50, 0, "right", 200, 50)
        Assert.Equal(450, result["w"])
    }

    ; ============================================================
    ; ComputeFloor
    ; ============================================================

    compute_floor_at_scale_1_returns_fixed_size()
    {
        result := OverlayResizeGeometry.ComputeFloor(380, 96, 1.0)
        Assert.Equal(380, result["w"])
        Assert.Equal(96,  result["h"])
    }

    compute_floor_at_scale_2_doubles()
    {
        result := OverlayResizeGeometry.ComputeFloor(380, 96, 2.0)
        Assert.Equal(760, result["w"])
        Assert.Equal(192, result["h"])
    }

    compute_floor_at_scale_half_halves()
    {
        ; 0.5 is MIN_SCALE itself — exactly at the boundary, no
        ; clamp triggered.
        result := OverlayResizeGeometry.ComputeFloor(380, 96, 0.5)
        Assert.Equal(190, result["w"])
        Assert.Equal(48,  result["h"])
    }

    compute_floor_below_min_scale_clamps_up()
    {
        ; Scale=0.1 is below MIN_SCALE (0.5). Floor must clamp UP
        ; to MIN_SCALE so the widget never enters an unreadable
        ; sub-50% typography range.
        result := OverlayResizeGeometry.ComputeFloor(380, 96, 0.1)
        Assert.Equal(190, result["w"], "Floor at MIN_SCALE, not at the bad scale")
        Assert.Equal(48,  result["h"])
    }

    ; ============================================================
    ; Static constants
    ; ============================================================

    static_default_border_px_is_six()
    {
        Assert.Equal(6, OverlayResizeGeometry.DEFAULT_BORDER_PX)
    }

    static_edge_constants_are_distinct()
    {
        ; Anti-regression: the consumer relies on string equality
        ; ("right" vs "bottom" vs "") to branch. A constant typo'd
        ; into matching another would corrupt the dispatch silently.
        Assert.NotEqual(OverlayResizeGeometry.EDGE_NONE,   OverlayResizeGeometry.EDGE_RIGHT)
        Assert.NotEqual(OverlayResizeGeometry.EDGE_NONE,   OverlayResizeGeometry.EDGE_BOTTOM)
        Assert.NotEqual(OverlayResizeGeometry.EDGE_RIGHT,  OverlayResizeGeometry.EDGE_BOTTOM)
        Assert.Equal("",       OverlayResizeGeometry.EDGE_NONE)
        Assert.Equal("right",  OverlayResizeGeometry.EDGE_RIGHT)
        Assert.Equal("bottom", OverlayResizeGeometry.EDGE_BOTTOM)
    }
}

TestRegistry.Register(OverlayResizeGeometryTests)
