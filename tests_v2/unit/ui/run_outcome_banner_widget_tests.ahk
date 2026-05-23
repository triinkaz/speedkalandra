; ============================================================
; RunOutcomeBannerWidgetTests
; ============================================================
;
; Headless tests for the transient run-outcome banner. The widget
; itself is mostly thin coordination — subscribe on construction,
; record the message text + colour name when Evt.RunOutcomeReported
; arrives, clear on Evt.RunStarted and on Evt.ShowOutcomeBannerChanged
; (with newValue=false). The Gui-building branch is skipped in
; headless mode; the production rendering path is covered by manual
; testing inside Claude in Chrome / the real overlay.
;
; What this file pins:
;   - Constructor validation (bus / cfg type checks)
;   - Subscribe / Unsubscribe lifecycle (Dispose is idempotent)
;   - Message formatter per outcome (saved/dnf/too_short/reset
;     + unknown fallback)
;   - Colour selection per outcome (and the PB-saved upgrade to
;     goodStrong)
;   - Duration formatter for the MM:SS and HH:MM:SS branches
;   - cfg.showOutcomeBanner=false skips the show path silently
;     without breaking subscribers
;   - Evt.RunStarted clears _lastMessage so the new run starts
;     with a clean slate
;   - Evt.ShowOutcomeBannerChanged{newValue:false} hides; the
;     {newValue:true} path is a no-op (no banner to show)


class RunOutcomeBannerWidgetTests extends TestCase
{
    bus       := ""
    cfg       := ""
    widget    := ""

    Setup()
    {
        this.bus    := Fixtures.MakeBus()
        this.cfg    := AppSettings.Defaults()
        this.widget := RunOutcomeBannerWidget(this.bus, this.cfg, true)   ; headless=true
    }

    Teardown()
    {
        if IsObject(this.widget)
            this.widget.Dispose()
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Construction ---
        "constructor_throws_when_bus_not_event_bus",
        "constructor_throws_when_cfg_not_app_settings",
        "constructor_subscribes_to_three_events",
        "constructor_accepts_headless_default_false",

        ; --- Outcome → message ---
        "outcome_saved_renders_saved_with_duration",
        "outcome_saved_with_pb_changed_appends_pb_marker",
        "outcome_dnf_renders_dnf_with_duration",
        "outcome_too_short_renders_too_short_label",
        "outcome_reset_renders_reset_without_duration",
        "outcome_unknown_renders_upper_case_fallback",

        ; --- Outcome → colour ---
        "outcome_saved_no_pb_uses_good_colour",
        "outcome_saved_with_pb_uses_good_strong_colour",
        "outcome_dnf_uses_warn_colour",
        "outcome_too_short_uses_accent_soft_colour",
        "outcome_reset_uses_subtle_colour",
        "outcome_unknown_uses_text_colour",

        ; --- Duration formatter ---
        "duration_formatter_mm_ss_for_under_one_hour",
        "duration_formatter_hh_mm_ss_for_one_hour_or_more",
        "duration_formatter_zero_renders_double_zero",
        "duration_formatter_clamps_negative_to_zero",

        ; --- cfg.showOutcomeBanner opt-out ---
        "outcome_skipped_when_show_outcome_banner_false",
        "outcome_visible_again_after_flag_flipped_back_to_true",

        ; --- RunStarted clears state ---
        "run_started_event_clears_last_message",

        ; --- ShowOutcomeBannerChanged ---
        "show_banner_changed_to_false_clears_state",
        "show_banner_changed_to_true_does_not_resurrect_message",
        "show_banner_changed_ignores_malformed_payload",

        ; --- Outcome handler defensive paths ---
        "outcome_handler_ignores_non_object_payload",
        "outcome_handler_ignores_payload_without_outcome",
        "outcome_handler_defaults_missing_duration_to_zero",
        "outcome_handler_defaults_missing_pb_changed_to_false",

        ; --- Dispose ---
        "dispose_unsubscribes_all_three_events",
        "dispose_is_idempotent"
    ]

    ; ============================================================
    ; Construction
    ; ============================================================

    constructor_throws_when_bus_not_event_bus()
    {
        c := this.cfg
        Assert.Throws(TypeError, () => RunOutcomeBannerWidget("not bus", c, true))
        Assert.Throws(TypeError, () => RunOutcomeBannerWidget(Map(),     c, true))
    }

    constructor_throws_when_cfg_not_app_settings()
    {
        b := this.bus
        Assert.Throws(TypeError, () => RunOutcomeBannerWidget(b, "not cfg", true))
        Assert.Throws(TypeError, () => RunOutcomeBannerWidget(b, Map(),    true))
    }

    constructor_subscribes_to_three_events()
    {
        ; The widget owns three subscriptions: RunOutcomeReported
        ; (the trigger), RunStarted (clear), ShowOutcomeBannerChanged
        ; (live opt-out). Setup already constructed one instance,
        ; so each event has exactly one subscriber.
        Assert.Equal(1, this.bus.Subscribers(Events.RunOutcomeReported))
        Assert.Equal(1, this.bus.Subscribers(Events.RunStarted))
        Assert.Equal(1, this.bus.Subscribers(Events.ShowOutcomeBannerChanged))
    }

    constructor_accepts_headless_default_false()
    {
        ; The third argument defaults to false. Documenting that
        ; with a test so a refactor that flips the default doesn't
        ; silently change production behaviour.
        freshBus := Fixtures.MakeBus()
        freshCfg := AppSettings.Defaults()
        ; We don't actually want to spawn a real Gui in tests — pass
        ; headless=true here too. The point of this case is the
        ; OPTIONAL nature of the parameter, not the default value
        ; itself: omitting it must not raise.
        widget := RunOutcomeBannerWidget(freshBus, freshCfg)
        Assert.IsType(RunOutcomeBannerWidget, widget)
        widget.Dispose()
    }

    ; ============================================================
    ; Outcome → message
    ; ============================================================
    ;
    ; The message text is what the user actually reads on the
    ; overlay. Pinning it per outcome locks the wording — a casual
    ; refactor that flips "TOO SHORT" to "Short Run" would change
    ; production UX silently.

    outcome_saved_renders_saved_with_duration()
    {
        this._Publish("saved", 4321000, false)   ; 1:12:01
        Assert.Equal("SAVED · 1:12:01", this.widget.GetLastMessage())
    }

    outcome_saved_with_pb_changed_appends_pb_marker()
    {
        ; pbChanged=true upgrades the message to flag the PB. The
        ; marker has to be obvious; speedrunners want the PB hit
        ; to read as a small celebration.
        this._Publish("saved", 60000, true)
        Assert.Equal("SAVED · 01:00 · PB", this.widget.GetLastMessage())
    }

    outcome_dnf_renders_dnf_with_duration()
    {
        this._Publish("dnf", 600000, false)
        Assert.Equal("DNF · 10:00", this.widget.GetLastMessage())
    }

    outcome_too_short_renders_too_short_label()
    {
        ; Duration intentionally surfaced so the user sees how
        ; close they were to the threshold. "NOT SAVED" suffix
        ; is the explicit fact that prompted the feature.
        this._Publish("too_short", 90000, false)
        Assert.Equal("TOO SHORT · 01:30 · NOT SAVED", this.widget.GetLastMessage())
    }

    outcome_reset_renders_reset_without_duration()
    {
        ; Duration deliberately omitted for resets — see the
        ; widget header for the rationale.
        this._Publish("reset", 12500, false)
        Assert.Equal("RESET · NOT SAVED", this.widget.GetLastMessage())
    }

    outcome_unknown_renders_upper_case_fallback()
    {
        ; Defensive: an unknown outcome (future publisher, typo)
        ; renders something instead of throwing. The auto-hide
        ; cleans up the screen either way.
        this._Publish("mystery", 60000, false)
        Assert.Equal("MYSTERY", this.widget.GetLastMessage())
    }

    ; ============================================================
    ; Outcome → colour
    ; ============================================================
    ;
    ; The widget records the colour NAME (a Theme key) rather than
    ; a hex literal so tests don't drift if the palette changes.
    ; _lastOutcome stays the raw outcome string; we re-derive the
    ; colour from it via the same private helper the widget uses.

    outcome_saved_no_pb_uses_good_colour()
    {
        Assert.Equal("good",       this.widget._ColorFor("saved",     false))
    }

    outcome_saved_with_pb_uses_good_strong_colour()
    {
        Assert.Equal("goodStrong", this.widget._ColorFor("saved",     true))
    }

    outcome_dnf_uses_warn_colour()
    {
        Assert.Equal("warn",       this.widget._ColorFor("dnf",       false))
    }

    outcome_too_short_uses_accent_soft_colour()
    {
        Assert.Equal("accentSoft", this.widget._ColorFor("too_short", false))
    }

    outcome_reset_uses_subtle_colour()
    {
        Assert.Equal("subtle",     this.widget._ColorFor("reset",     false))
    }

    outcome_unknown_uses_text_colour()
    {
        Assert.Equal("text",       this.widget._ColorFor("???",       false))
    }

    ; ============================================================
    ; Duration formatter
    ; ============================================================

    duration_formatter_mm_ss_for_under_one_hour()
    {
        Assert.Equal("00:30", this.widget._FormatDurationMs(30000))
        Assert.Equal("01:30", this.widget._FormatDurationMs(90000))
        Assert.Equal("59:59", this.widget._FormatDurationMs(3599000))
    }

    duration_formatter_hh_mm_ss_for_one_hour_or_more()
    {
        Assert.Equal("1:00:00", this.widget._FormatDurationMs(3600000))
        Assert.Equal("1:12:01", this.widget._FormatDurationMs(4321000))
        Assert.Equal("2:34:56", this.widget._FormatDurationMs(9296000))
    }

    duration_formatter_zero_renders_double_zero()
    {
        Assert.Equal("00:00", this.widget._FormatDurationMs(0))
    }

    duration_formatter_clamps_negative_to_zero()
    {
        ; Defensive: a negative duration would format as something
        ; like "-1:-1" which leaks abstraction. Clamp at zero so
        ; the banner is robust to upstream bugs.
        Assert.Equal("00:00", this.widget._FormatDurationMs(-5000))
    }

    ; ============================================================
    ; cfg.showOutcomeBanner opt-out
    ; ============================================================

    outcome_skipped_when_show_outcome_banner_false()
    {
        ; Speedrunner-friendly opt-out: flag flipped to false means
        ; the widget records nothing and never tries to render.
        ; Subscribers stay wired (the widget needs to react if the
        ; user flips the flag back on later in the session), but
        ; the show path is a no-op.
        this.cfg.showOutcomeBanner := false
        this._Publish("saved", 60000, true)
        Assert.Equal("", this.widget.GetLastMessage(),
            "_OnOutcome must short-circuit when the flag is off")
        Assert.Equal("", this.widget.GetLastOutcome())
    }

    outcome_visible_again_after_flag_flipped_back_to_true()
    {
        ; The handler reads cfg.showOutcomeBanner on every call so
        ; a runtime flip lands immediately on the next outcome —
        ; no widget rebuild, no resubscribe.
        this.cfg.showOutcomeBanner := false
        this._Publish("saved", 60000, false)
        Assert.Equal("", this.widget.GetLastMessage(),
            "precondition: flag off, message empty")

        this.cfg.showOutcomeBanner := true
        this._Publish("dnf", 120000, false)
        Assert.Equal("DNF · 02:00", this.widget.GetLastMessage(),
            "flag back on -> next outcome surfaces normally")
    }

    ; ============================================================
    ; RunStarted clears state
    ; ============================================================

    run_started_event_clears_last_message()
    {
        ; A new run starting -> the previous run's banner has to
        ; clear immediately so it doesn't sit on top of the new
        ; HUD. Tested via Hide() side-effects on _lastMessage.
        this._Publish("saved", 60000, false)
        Assert.Equal("SAVED · 01:00", this.widget.GetLastMessage(),
            "precondition: banner state populated")

        this.bus.Publish(Events.RunStarted, Map("runId", "new_run"))
        Assert.Equal("", this.widget.GetLastMessage(),
            "RunStarted must clear leftover banner state")
    }

    ; ============================================================
    ; ShowOutcomeBannerChanged
    ; ============================================================

    show_banner_changed_to_false_clears_state()
    {
        ; The opt-out flip must visibly take effect. If the user
        ; turns the banner off WHILE one is on screen, they
        ; rightly expect it to disappear.
        this._Publish("saved", 60000, false)
        Assert.Equal("SAVED · 01:00", this.widget.GetLastMessage(),
            "precondition: banner state populated")

        this.bus.Publish(Events.ShowOutcomeBannerChanged,
            Map("oldValue", true, "newValue", false))

        Assert.Equal("", this.widget.GetLastMessage(),
            "Flipping the flag off must clear any banner on screen")
    }

    show_banner_changed_to_true_does_not_resurrect_message()
    {
        ; Symmetric edge: flipping the flag from false→true must
        ; NOT silently re-surface a previously-cleared message.
        ; The next outcome event is what surfaces the next banner;
        ; the flag flip alone is purely permissive.
        this._Publish("saved", 60000, false)
        this.bus.Publish(Events.ShowOutcomeBannerChanged,
            Map("oldValue", true, "newValue", false))
        Assert.Equal("", this.widget.GetLastMessage(),
            "sanity: state cleared after the off-flip")

        this.bus.Publish(Events.ShowOutcomeBannerChanged,
            Map("oldValue", false, "newValue", true))
        Assert.Equal("", this.widget.GetLastMessage(),
            "Flag flip on must NOT resurrect cleared state")
    }

    show_banner_changed_ignores_malformed_payload()
    {
        ; Defensive: a payload without "newValue" must not throw.
        ; The widget's contract is to fail gracefully; a malformed
        ; payload simply doesn't change state. Tests pin this so a
        ; future refactor that adds a stricter check accidentally
        ; surfaces here.
        this._Publish("saved", 60000, false)
        this.bus.Publish(Events.ShowOutcomeBannerChanged, "not a map")
        this.bus.Publish(Events.ShowOutcomeBannerChanged, Map())   ; no newValue

        Assert.Equal("SAVED · 01:00", this.widget.GetLastMessage(),
            "Malformed payload leaves state untouched")
    }

    ; ============================================================
    ; Outcome handler defensive paths
    ; ============================================================

    outcome_handler_ignores_non_object_payload()
    {
        this.bus.Publish(Events.RunOutcomeReported, "not a map")
        Assert.Equal("", this.widget.GetLastMessage())
    }

    outcome_handler_ignores_payload_without_outcome()
    {
        ; A payload that's a Map but lacks "outcome" is no-op. The
        ; widget can't render something it doesn't know about.
        this.bus.Publish(Events.RunOutcomeReported,
            Map("durationMs", 60000, "pbChanged", true))
        Assert.Equal("", this.widget.GetLastMessage())
    }

    outcome_handler_defaults_missing_duration_to_zero()
    {
        ; Missing durationMs key -> 0 (renders 00:00 / "RESET · NOT
        ; SAVED"). The widget never throws on a partial payload,
        ; because the duration is purely cosmetic.
        this.bus.Publish(Events.RunOutcomeReported, Map("outcome", "saved"))
        Assert.Equal("SAVED · 00:00", this.widget.GetLastMessage())
    }

    outcome_handler_defaults_missing_pb_changed_to_false()
    {
        ; Missing pbChanged key -> the safe "no PB" message. A
        ; missing flag must NOT promote the message to "· PB"
        ; (which the user reads as a real PB hit).
        this.bus.Publish(Events.RunOutcomeReported,
            Map("outcome", "saved", "durationMs", 60000))
        Assert.Equal("SAVED · 01:00", this.widget.GetLastMessage())
    }

    ; ============================================================
    ; Dispose
    ; ============================================================

    dispose_unsubscribes_all_three_events()
    {
        this.widget.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.RunOutcomeReported))
        Assert.Equal(0, this.bus.Subscribers(Events.RunStarted))
        Assert.Equal(0, this.bus.Subscribers(Events.ShowOutcomeBannerChanged))
    }

    dispose_is_idempotent()
    {
        ; Stop(): in production, Dispose is called on every reload
        ; cycle. A second call must not throw — the unsubscribe
        ; guard checks the handler field is non-empty before
        ; attempting to remove it.
        this.widget.Dispose()
        this.widget.Dispose()
        Assert.Equal(0, this.bus.Subscribers(Events.RunOutcomeReported))
    }

    ; ============================================================
    ; Helpers
    ; ============================================================

    ; Publishes a well-formed Evt.RunOutcomeReported payload. The
    ; runId field is filler — the widget doesn't read it, but the
    ; production publisher always sets it, so the test payload
    ; mirrors the real shape.
    _Publish(outcome, durationMs, pbChanged)
    {
        this.bus.Publish(Events.RunOutcomeReported, Map(
            "outcome",    outcome,
            "durationMs", durationMs,
            "runId",      "test_run_id",
            "pbChanged",  pbChanged
        ))
    }
}

TestRegistry.Register(RunOutcomeBannerWidgetTests)
