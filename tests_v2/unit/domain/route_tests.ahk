; ============================================================
; Route tests
; ============================================================
;
; Covers the Route domain model:
;   - Constructor (empty / with array / invalid types)
;   - Queries (Count, IsEmpty, HasRoute, GetCurrentIdx, GetZoneAt,
;     GetZones returns a copy)
;   - Editing mutators (Add, Remove, MoveUp, MoveDown) and their
;     side effects on _currentIdx
;   - Progress mutators (Reset, AdvanceTo) with forward/backward
;     match semantics and the off-route no-op behavior
;   - GetVisibleSlice in steady state and at boundaries

class RouteTests extends TestCase
{
    static Tests := [
        ; --- Constructor ---
        "constructor_empty_yields_empty_route",
        "constructor_with_array_populates_zones",
        "constructor_filters_empty_strings",
        "constructor_throws_type_error_on_non_array",
        "constructor_with_empty_string_argument_is_empty_route",

        ; --- Queries ---
        "count_returns_number_of_zones",
        "is_empty_true_for_zero_zones",
        "has_route_true_when_at_least_one_zone",
        "get_current_idx_starts_at_minus_one",
        "get_zone_at_returns_zone_for_valid_idx",
        "get_zone_at_returns_empty_for_out_of_range",
        "get_zone_at_returns_empty_for_negative",
        "get_zones_returns_copy_not_internal",

        ; --- Add ---
        "add_appends_zone",
        "add_ignores_empty_string",
        "add_ignores_whitespace_only",
        "add_allows_duplicates",
        "add_returns_true_on_success",
        "add_returns_false_on_empty",

        ; --- Remove ---
        "remove_deletes_zone_at_idx",
        "remove_returns_false_for_out_of_range",
        "remove_shifts_current_idx_down_when_removed_before_current",
        "remove_decrements_current_idx_when_removed_at_current",
        "remove_does_not_change_current_idx_when_removed_after",
        "remove_at_idx_zero_when_current_is_zero_yields_minus_one",

        ; --- MoveUp / MoveDown ---
        "move_up_swaps_with_previous",
        "move_up_no_op_at_idx_zero",
        "move_up_no_op_out_of_range",
        "move_up_carries_current_idx_along_when_moved",
        "move_up_carries_current_idx_along_when_above_moved",
        "move_down_swaps_with_next",
        "move_down_no_op_at_last",
        "move_down_carries_current_idx_along",

        ; --- Reset ---
        "reset_snaps_current_idx_to_minus_one",

        ; --- AdvanceTo: forward ---
        "advance_to_finds_next_zone_forward",
        "advance_to_jumps_multiple_steps_forward",
        "advance_to_from_minus_one_finds_first_match",
        "advance_to_is_case_insensitive",

        ; --- AdvanceTo: backward (retreat) ---
        "advance_to_retreats_when_no_forward_match",
        "advance_to_prefers_forward_over_backward_for_duplicates",

        ; --- AdvanceTo: off-route / edge cases ---
        "advance_to_off_route_zone_returns_false",
        "advance_to_off_route_does_not_change_current_idx",
        "advance_to_empty_string_returns_false",
        "advance_to_on_empty_route_returns_false",

        ; --- GetVisibleSlice ---
        "visible_slice_empty_route_returns_empty",
        "visible_slice_zero_n_returns_empty",
        "visible_slice_current_minus_one_starts_at_zero",
        "visible_slice_current_at_zero_marks_first_as_current",
        "visible_slice_marks_current_and_upcoming_correctly",
        "visible_slice_shrinks_at_end_of_route",
        "visible_slice_returns_n_rows_when_room",
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_empty_yields_empty_route()
    {
        r := Route()
        Assert.Equal(0, r.Count())
        Assert.Equal(-1, r.GetCurrentIdx())
    }

    constructor_with_array_populates_zones()
    {
        r := Route(["A", "B", "C"])
        Assert.Equal(3, r.Count())
        Assert.Equal("A", r.GetZoneAt(0))
        Assert.Equal("B", r.GetZoneAt(1))
        Assert.Equal("C", r.GetZoneAt(2))
    }

    constructor_filters_empty_strings()
    {
        ; The constructor silently drops empty entries — the Settings
        ; UI is where the user-facing validation lives.
        r := Route(["A", "", "B"])
        Assert.Equal(2, r.Count(), "empty entries are dropped")
        Assert.Equal("A", r.GetZoneAt(0))
        Assert.Equal("B", r.GetZoneAt(1))
    }

    constructor_throws_type_error_on_non_array()
    {
        Assert.Throws(TypeError, () => Route("not an array"))
        Assert.Throws(TypeError, () => Route(Map("a", 1)))
    }

    constructor_with_empty_string_argument_is_empty_route()
    {
        ; "" is the sentinel for "no argument" — matches the project
        ; pattern of treating empty-string default as absent. Allows
        ; RouteRepository.Load to return Route() when the file is
        ; missing without a separate factory method.
        r := Route("")
        Assert.Equal(0, r.Count())
    }

    ; ============================================================
    ; Queries
    ; ============================================================

    count_returns_number_of_zones()
    {
        Assert.Equal(0, Route().Count())
        Assert.Equal(3, Route(["A", "B", "C"]).Count())
    }

    is_empty_true_for_zero_zones()
    {
        Assert.True(Route().IsEmpty())
        Assert.False(Route(["A"]).IsEmpty())
    }

    has_route_true_when_at_least_one_zone()
    {
        Assert.False(Route().HasRoute())
        Assert.True(Route(["A"]).HasRoute())
    }

    get_current_idx_starts_at_minus_one()
    {
        Assert.Equal(-1, Route(["A", "B"]).GetCurrentIdx())
    }

    get_zone_at_returns_zone_for_valid_idx()
    {
        r := Route(["A", "B", "C"])
        Assert.Equal("A", r.GetZoneAt(0))
        Assert.Equal("C", r.GetZoneAt(2))
    }

    get_zone_at_returns_empty_for_out_of_range()
    {
        r := Route(["A"])
        Assert.Equal("", r.GetZoneAt(99))
    }

    get_zone_at_returns_empty_for_negative()
    {
        Assert.Equal("", Route(["A"]).GetZoneAt(-1))
    }

    get_zones_returns_copy_not_internal()
    {
        ; The Settings UI iterates the route for the listbox; if it
        ; received the internal array, a Push there would silently
        ; corrupt Route state. Defensive copy keeps the model
        ; encapsulated.
        r := Route(["A", "B"])
        copy := r.GetZones()
        copy.Push("MUTATED")
        Assert.Equal(2, r.Count(),
            "GetZones must return a defensive copy")
    }

    ; ============================================================
    ; Add
    ; ============================================================

    add_appends_zone()
    {
        r := Route()
        r.Add("A")
        r.Add("B")
        Assert.Equal(2, r.Count())
        Assert.Equal("A", r.GetZoneAt(0))
        Assert.Equal("B", r.GetZoneAt(1))
    }

    add_ignores_empty_string()
    {
        r := Route()
        r.Add("")
        Assert.Equal(0, r.Count())
    }

    add_ignores_whitespace_only()
    {
        r := Route()
        r.Add("   ")
        Assert.Equal(0, r.Count(), "whitespace-only is treated as empty")
    }

    add_allows_duplicates()
    {
        ; The runner may legitimately revisit the same zone in a
        ; planned route (boss room, sweep back through a town hub
        ; to vendor mid-route). AdvanceTo resolves duplicates by
        ; nearest-forward.
        r := Route()
        r.Add("A")
        r.Add("A")
        Assert.Equal(2, r.Count())
    }

    add_returns_true_on_success()
    {
        Assert.True(Route().Add("A"))
    }

    add_returns_false_on_empty()
    {
        Assert.False(Route().Add(""))
        Assert.False(Route().Add("   "))
    }

    ; ============================================================
    ; Remove
    ; ============================================================

    remove_deletes_zone_at_idx()
    {
        r := Route(["A", "B", "C"])
        Assert.True(r.Remove(1))
        Assert.Equal(2, r.Count())
        Assert.Equal("A", r.GetZoneAt(0))
        Assert.Equal("C", r.GetZoneAt(1), "C shifted up to idx 1")
    }

    remove_returns_false_for_out_of_range()
    {
        r := Route(["A"])
        Assert.False(r.Remove(99))
        Assert.False(r.Remove(-1))
        Assert.Equal(1, r.Count())
    }

    remove_shifts_current_idx_down_when_removed_before_current()
    {
        ; If the user deletes a zone BEFORE the current one,
        ; _currentIdx must shift down by 1 so it keeps pointing to
        ; the same zone (now at a smaller index).
        r := Route(["A", "B", "C", "D"])
        r.AdvanceTo("C")
        Assert.Equal(2, r.GetCurrentIdx())

        r.Remove(0)    ; remove "A"
        Assert.Equal(1, r.GetCurrentIdx(),
            "current followed C through the shrinkage")
        Assert.Equal("C", r.GetZoneAt(r.GetCurrentIdx()))
    }

    remove_decrements_current_idx_when_removed_at_current()
    {
        ; If the user deletes the CURRENT zone, the current index
        ; drops by 1. The runner gets a "you're back at the
        ; previous zone" effect on the route widget — there's no
        ; perfect answer (the zone they were in is now gone), but
        ; falling back to the prior zone is the least surprising.
        r := Route(["A", "B", "C"])
        r.AdvanceTo("B")
        Assert.Equal(1, r.GetCurrentIdx())

        r.Remove(1)    ; remove "B" (the current one)
        Assert.Equal(0, r.GetCurrentIdx(), "current fell back to A's slot")
    }

    remove_does_not_change_current_idx_when_removed_after()
    {
        r := Route(["A", "B", "C", "D"])
        r.AdvanceTo("A")
        Assert.Equal(0, r.GetCurrentIdx())

        r.Remove(3)    ; remove "D" (after current)
        Assert.Equal(0, r.GetCurrentIdx(), "current untouched")
    }

    remove_at_idx_zero_when_current_is_zero_yields_minus_one()
    {
        r := Route(["A", "B"])
        r.AdvanceTo("A")
        Assert.Equal(0, r.GetCurrentIdx())

        r.Remove(0)
        Assert.Equal(-1, r.GetCurrentIdx(),
            "removing the current zone at idx 0 resets to 'haven't started'")
    }

    ; ============================================================
    ; MoveUp / MoveDown
    ; ============================================================

    move_up_swaps_with_previous()
    {
        r := Route(["A", "B", "C"])
        Assert.True(r.MoveUp(1))
        Assert.Equal("B", r.GetZoneAt(0))
        Assert.Equal("A", r.GetZoneAt(1))
    }

    move_up_no_op_at_idx_zero()
    {
        r := Route(["A", "B"])
        Assert.False(r.MoveUp(0), "idx 0 has no predecessor")
        Assert.Equal("A", r.GetZoneAt(0))
    }

    move_up_no_op_out_of_range()
    {
        Assert.False(Route(["A"]).MoveUp(99))
        Assert.False(Route(["A"]).MoveUp(-1))
    }

    move_up_carries_current_idx_along_when_moved()
    {
        ; current points at "B" (idx 1). After MoveUp(1) the zone
        ; "B" sits at idx 0; current should follow.
        r := Route(["A", "B", "C"])
        r.AdvanceTo("B")
        Assert.Equal(1, r.GetCurrentIdx())

        r.MoveUp(1)
        Assert.Equal(0, r.GetCurrentIdx(),
            "current follows B to its new position")
    }

    move_up_carries_current_idx_along_when_above_moved()
    {
        ; current at "A" (idx 0). MoveUp(1) swaps A and B; A is
        ; now at idx 1, current must update.
        r := Route(["A", "B", "C"])
        r.AdvanceTo("A")
        Assert.Equal(0, r.GetCurrentIdx())

        r.MoveUp(1)    ; swaps A and B
        Assert.Equal(1, r.GetCurrentIdx(),
            "current follows A to its new position")
    }

    move_down_swaps_with_next()
    {
        r := Route(["A", "B", "C"])
        Assert.True(r.MoveDown(0))
        Assert.Equal("B", r.GetZoneAt(0))
        Assert.Equal("A", r.GetZoneAt(1))
    }

    move_down_no_op_at_last()
    {
        r := Route(["A", "B"])
        Assert.False(r.MoveDown(1), "last idx has no successor")
        Assert.Equal("B", r.GetZoneAt(1))
    }

    move_down_carries_current_idx_along()
    {
        r := Route(["A", "B", "C"])
        r.AdvanceTo("A")
        Assert.Equal(0, r.GetCurrentIdx())

        r.MoveDown(0)    ; A and B swap
        Assert.Equal(1, r.GetCurrentIdx(),
            "current follows A to its new position")
    }

    ; ============================================================
    ; Reset
    ; ============================================================

    reset_snaps_current_idx_to_minus_one()
    {
        r := Route(["A", "B"])
        r.AdvanceTo("B")
        Assert.Equal(1, r.GetCurrentIdx())

        r.Reset()
        Assert.Equal(-1, r.GetCurrentIdx())
    }

    ; ============================================================
    ; AdvanceTo: forward
    ; ============================================================

    advance_to_finds_next_zone_forward()
    {
        r := Route(["A", "B", "C"])
        Assert.True(r.AdvanceTo("A"))
        Assert.Equal(0, r.GetCurrentIdx())
        Assert.True(r.AdvanceTo("B"))
        Assert.Equal(1, r.GetCurrentIdx())
    }

    advance_to_jumps_multiple_steps_forward()
    {
        ; Runner skips a zone via a shortcut/teleport. AdvanceTo
        ; scans forward until it finds a match — no "must be the
        ; next" restriction.
        r := Route(["A", "B", "C", "D"])
        Assert.True(r.AdvanceTo("C"), "skipped B; matched C anyway")
        Assert.Equal(2, r.GetCurrentIdx())
    }

    advance_to_from_minus_one_finds_first_match()
    {
        r := Route(["A", "B", "C"])
        Assert.Equal(-1, r.GetCurrentIdx())
        Assert.True(r.AdvanceTo("B"))
        Assert.Equal(1, r.GetCurrentIdx())
    }

    advance_to_is_case_insensitive()
    {
        ; PoE2 zone names in Client.txt can drift in case relative
        ; to the user's editor input. AHK's `=` operator is case-
        ; insensitive by default, which gives us forgiveness for
        ; free.
        r := Route(["The Riverbank"])
        Assert.True(r.AdvanceTo("the riverbank"))
        Assert.Equal(0, r.GetCurrentIdx())
    }

    ; ============================================================
    ; AdvanceTo: backward (retreat)
    ; ============================================================

    advance_to_retreats_when_no_forward_match()
    {
        ; Runner finishes "C", returns to "A" (e.g. portal back to
        ; town then back through the start zone to grab loot). No
        ; forward match for "A" from idx 2; backward scan finds it
        ; at idx 0.
        r := Route(["A", "B", "C", "D"])
        r.AdvanceTo("C")
        Assert.Equal(2, r.GetCurrentIdx())

        Assert.True(r.AdvanceTo("A"), "retreat succeeds")
        Assert.Equal(0, r.GetCurrentIdx())
    }

    advance_to_prefers_forward_over_backward_for_duplicates()
    {
        ; The route has "A" at both idx 0 and idx 3. Current at
        ; idx 1. AdvanceTo("A") should find idx 3 (forward) rather
        ; than idx 0 (backward) — the natural reading of "advance"
        ; is forward-first.
        r := Route(["A", "B", "C", "A", "E"])
        r.AdvanceTo("B")
        Assert.Equal(1, r.GetCurrentIdx())

        Assert.True(r.AdvanceTo("A"))
        Assert.Equal(3, r.GetCurrentIdx(),
            "forward A at idx 3 wins over backward A at idx 0")
    }

    ; ============================================================
    ; AdvanceTo: off-route / edge cases
    ; ============================================================

    advance_to_off_route_zone_returns_false()
    {
        r := Route(["A", "B", "C"])
        Assert.False(r.AdvanceTo("OFF_ROUTE_ZONE"))
    }

    advance_to_off_route_does_not_change_current_idx()
    {
        r := Route(["A", "B", "C"])
        r.AdvanceTo("B")
        Assert.Equal(1, r.GetCurrentIdx())

        r.AdvanceTo("OFF_ROUTE")
        Assert.Equal(1, r.GetCurrentIdx(),
            "off-route entries leave current intact (Q5 behavior)")
    }

    advance_to_empty_string_returns_false()
    {
        Assert.False(Route(["A"]).AdvanceTo(""))
        Assert.False(Route(["A"]).AdvanceTo("   "))
    }

    advance_to_on_empty_route_returns_false()
    {
        Assert.False(Route().AdvanceTo("anywhere"))
    }

    ; ============================================================
    ; GetVisibleSlice
    ; ============================================================

    visible_slice_empty_route_returns_empty()
    {
        Assert.Equal(0, Route().GetVisibleSlice(5).Length)
    }

    visible_slice_zero_n_returns_empty()
    {
        Assert.Equal(0, Route(["A", "B"]).GetVisibleSlice(0).Length)
    }

    visible_slice_current_minus_one_starts_at_zero()
    {
        ; Before the run starts, the widget should preview "what's
        ; coming" — the slice begins at the first zone.
        r := Route(["A", "B", "C", "D"])
        slice := r.GetVisibleSlice(3)
        Assert.Equal(3, slice.Length)
        Assert.Equal("A", slice[1]["name"])
        Assert.Equal(0,   slice[1]["idx"])
        Assert.Equal("upcoming", slice[1]["status"],
            "no current row when currentIdx=-1")
    }

    visible_slice_current_at_zero_marks_first_as_current()
    {
        r := Route(["A", "B", "C"])
        r.AdvanceTo("A")
        slice := r.GetVisibleSlice(3)
        Assert.Equal(3, slice.Length)
        Assert.Equal("A", slice[1]["name"])
        Assert.Equal("current", slice[1]["status"])
        Assert.Equal("upcoming", slice[2]["status"])
        Assert.Equal("upcoming", slice[3]["status"])
    }

    visible_slice_marks_current_and_upcoming_correctly()
    {
        r := Route(["A", "B", "C", "D", "E"])
        r.AdvanceTo("C")
        slice := r.GetVisibleSlice(3)
        Assert.Equal(3, slice.Length)
        Assert.Equal("C", slice[1]["name"])
        Assert.Equal("current", slice[1]["status"])
        Assert.Equal("D", slice[2]["name"])
        Assert.Equal("upcoming", slice[2]["status"])
        Assert.Equal("E", slice[3]["name"])
        Assert.Equal("upcoming", slice[3]["status"])
    }

    visible_slice_shrinks_at_end_of_route()
    {
        ; Current at last; asking for 5 rows returns only 1.
        r := Route(["A", "B", "C"])
        r.AdvanceTo("C")
        slice := r.GetVisibleSlice(5)
        Assert.Equal(1, slice.Length,
            "slice never exceeds available zones")
        Assert.Equal("current", slice[1]["status"])
    }

    visible_slice_returns_n_rows_when_room()
    {
        r := Route(["A", "B", "C", "D", "E", "F", "G"])
        r.AdvanceTo("B")
        slice := r.GetVisibleSlice(5)
        Assert.Equal(5, slice.Length)
        Assert.Equal("B", slice[1]["name"])
        Assert.Equal("F", slice[5]["name"])
    }
}

TestRegistry.Register(RouteTests)
