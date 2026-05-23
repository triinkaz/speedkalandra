; ============================================================
; RunOutcomeBannerWidget — transient on-overlay run-outcome banner
; ============================================================
;
; Subscribes to Events.RunOutcomeReported and surfaces a short
; banner (4 s) over the overlay describing what happened to the
; run: "SAVED · PB", "SAVED", "DNF", "TOO SHORT", "RESET".
;
; Why a dedicated widget (not extending WidgetBase):
;   - Not user-positionable (yet). Sits centered horizontally near
;     the top of the screen, fixed.
;   - Not subject to layout modes (NORMAL / COMPACT / MICRO) and
;     doesn't appear in the SHOW/HIDE widget list. It's a transient
;     notification, not a permanent overlay element.
;   - Doesn't need scale, Ctrl-drag, or the highlight border.
;   WidgetBase exists for the four concerns above; pulling it in
;   here would mean carrying complexity that this widget never uses
;   and forcing an OverlayPosition into AppSettings for something
;   the user can't move.
;
; What it does need (still preserved):
;   - Click-through (WS_EX_TRANSPARENT). Without it the banner would
;     steal clicks meant for the game when it overlaps the screen.
;   - AlwaysOnTop. Otherwise it disappears under PoE2 fullscreen.
;   - Auto-dismiss after AUTO_HIDE_MS via SetTimer.
;   - Dismiss-on-next-RunStarted. If the user kicks off another run
;     before the timer fires, the banner closes immediately so it
;     doesn't sit on top of the new run's HUD.
;
; Opt-out:
;   cfg.showOutcomeBanner=false makes the widget a no-op (still
;   subscribes for lifecycle symmetry but never builds a Gui).
;   Live-reconfigurable: SettingsDialog publishes the new value via
;   Evt.ShowOutcomeBannerChanged so the widget can drop the next
;   banner without a restart.
;
; Headless mode:
;   When headless = true the widget skips every Gui call. Subscribers
;   still register, so tests can drive _OnOutcome / _OnRunStarted
;   directly and inspect the resulting state (_lastMessage etc.)
;   without an X server.


class RunOutcomeBannerWidget
{
    ; Visual lifetime of the banner. Picked to be long enough to
    ; read at a glance during a speedrun (≈ four words) but short
    ; enough that it has cleared before the next run is well under
    ; way. Tunable here if user feedback warrants it; everything
    ; downstream (tests, SetTimer arming) reads this constant.
    static AUTO_HIDE_MS := 4000

    ; Fixed geometry. The widget sits centered horizontally at
    ; TOP_PCT of the screen height. Width is wide enough to fit
    ; "TOO SHORT · 02:59 · NOT SAVED" without wrapping.
    static WIDTH   := 420
    static HEIGHT  := 78
    static TOP_PCT := 8

    _bus      := ""
    _cfg      := ""
    _headless := false

    ; Gui state. _gui is "" while hidden; a Gui object while visible.
    ; _hideTimerFn holds the bound closure passed to SetTimer so we
    ; can clear it on early dismissal (next RunStarted, Dispose).
    _gui            := ""
    _hideTimerFn    := ""

    ; Last message rendered, exposed for tests. Cleared in Hide().
    _lastMessage  := ""
    _lastOutcome  := ""

    _handlerOutcome             := ""
    _handlerRunStarted          := ""
    _handlerShowBannerChanged   := ""

    __New(bus, cfg, headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("RunOutcomeBannerWidget: 'bus' must be EventBus")
        if !(cfg is AppSettings)
            throw TypeError("RunOutcomeBannerWidget: 'cfg' must be AppSettings")
        this._bus      := bus
        this._cfg      := cfg
        this._headless := !!headless

        this._handlerOutcome           := (data) => this._OnOutcome(data)
        this._handlerRunStarted        := (data) => this._OnRunStarted(data)
        this._handlerShowBannerChanged := (data) => this._OnShowBannerChanged(data)

        bus.Subscribe(Events.RunOutcomeReported, this._handlerOutcome)
        bus.Subscribe(Events.RunStarted,         this._handlerRunStarted)
        bus.Subscribe(Events.ShowOutcomeBannerChanged, this._handlerShowBannerChanged)
    }

    Dispose()
    {
        if (this._handlerOutcome != "")
        {
            this._bus.Unsubscribe(Events.RunOutcomeReported, this._handlerOutcome)
            this._handlerOutcome := ""
        }
        if (this._handlerRunStarted != "")
        {
            this._bus.Unsubscribe(Events.RunStarted, this._handlerRunStarted)
            this._handlerRunStarted := ""
        }
        if (this._handlerShowBannerChanged != "")
        {
            this._bus.Unsubscribe(Events.ShowOutcomeBannerChanged, this._handlerShowBannerChanged)
            this._handlerShowBannerChanged := ""
        }
        this.Hide()
    }

    ; ---- Test-facing accessors ----
    IsVisible()      => this._gui != ""
    GetLastMessage() => this._lastMessage
    GetLastOutcome() => this._lastOutcome

    ; ---- Event handlers ----

    _OnOutcome(data)
    {
        if !IsObject(data) || !data.Has("outcome")
            return
        ; Live opt-out: re-read cfg every call so a flip via the
        ; settings dialog takes effect on the next outcome, no
        ; widget restart needed.
        if !this._cfg.showOutcomeBanner
            return

        outcome    := String(data["outcome"])
        durationMs := data.Has("durationMs") ? Integer(data["durationMs"] + 0) : 0
        pbChanged  := data.Has("pbChanged")  ? !!data["pbChanged"]             : false

        message := this._FormatMessage(outcome, durationMs, pbChanged)
        colorName := this._ColorFor(outcome, pbChanged)
        this._Show(message, colorName, outcome)
    }

    _OnRunStarted(data)
    {
        ; A new run started — clear any leftover banner from the
        ; previous run before the user has to look at it on top of
        ; their new HUD.
        this.Hide()
    }

    _OnShowBannerChanged(data)
    {
        if !IsObject(data) || !data.Has("newValue")
            return
        ; Flipping the setting OFF should immediately remove any
        ; banner that happens to be on screen. Flipping ON has no
        ; immediate effect (nothing to show until the next outcome).
        if !data["newValue"]
            this.Hide()
    }

    ; ---- Rendering ----

    ; Builds and shows the banner. Idempotent for the case where a
    ; new outcome arrives while a previous banner is still visible
    ; (rare in practice — would require two finalizes within 4 s):
    ; the existing Gui is destroyed and rebuilt so the message and
    ; the auto-hide timer both reflect the latest event.
    _Show(message, colorName, outcome)
    {
        this._lastMessage := message
        this._lastOutcome := outcome
        if this._headless
        {
            ; In headless mode we record the message but skip both
            ; Gui creation AND the SetTimer auto-hide. The timer is
            ; the right behaviour in production (so the banner
            ; clears itself) but a test process that arms many
            ; SetTimers during a suite run and then exits before
            ; they fire leaves the AHK runtime with pending
            ; callbacks — noisy at best, source-of-flake at worst.
            ; Tests that want to observe the post-timeout state
            ; can call Hide() directly.
            return
        }

        ; Destroy the previous Gui (if any) so positioning, color
        ; and message all reflect the new outcome.
        if this._gui
        {
            try this._gui.Destroy()
            this._gui := ""
        }

        wg := Gui("+ToolWindow +AlwaysOnTop -Caption +E0x08000000")
        wg.BackColor := Theme.Color("surface")
        wg.MarginX := 0
        wg.MarginY := 0

        ; Single label, centered both ways. Bold so it's legible at
        ; the screen distance of a typical PoE2 session.
        wg.SetFont("s14 c" Theme.Color(colorName) " bold", Theme.FONT_UI)
        wg.Add(
            "Text",
            "x0 y0 w" RunOutcomeBannerWidget.WIDTH
                . " h" RunOutcomeBannerWidget.HEIGHT
                . " Background" Theme.Color("surface")
                . " Center 0x200",
            message
        )

        monW := A_ScreenWidth
        monH := A_ScreenHeight
        posX := Round((monW - RunOutcomeBannerWidget.WIDTH) / 2)
        posY := Round((RunOutcomeBannerWidget.TOP_PCT / 100) * monH)
        wg.Show("NoActivate X" posX " Y" posY
            . " W" RunOutcomeBannerWidget.WIDTH
            . " H" RunOutcomeBannerWidget.HEIGHT)

        ; Same click-through pattern as WidgetBase.Show — see the
        ; long comment block in src_v2/ui/widget_base.ahk for the
        ; AHK v2 quirk that requires this two-step (LAYERED via
        ; WinSetTransparent, TRANSPARENT via WinSetExStyle).
        try WinSetTransparent(255, "ahk_id " wg.Hwnd)
        try WinSetExStyle("+0x20", "ahk_id " wg.Hwnd)

        this._gui := wg
        this._ArmAutoHide()
    }

    Hide()
    {
        if (this._hideTimerFn != "")
        {
            try SetTimer(this._hideTimerFn, 0)
            this._hideTimerFn := ""
        }
        if this._gui
        {
            try this._gui.Destroy()
            this._gui := ""
        }
        this._lastMessage := ""
        this._lastOutcome := ""
    }

    _ArmAutoHide()
    {
        if (this._hideTimerFn != "")
        {
            try SetTimer(this._hideTimerFn, 0)
            this._hideTimerFn := ""
        }
        ; Bound closure captured so the very same reference can be
        ; passed to SetTimer(fn, 0) for cancellation. Without the
        ; field we would have no handle to cancel the pending hide.
        this._hideTimerFn := () => this.Hide()
        ; Negative period: one-shot.
        try SetTimer(this._hideTimerFn, -RunOutcomeBannerWidget.AUTO_HIDE_MS)
    }

    ; ---- Message + color formatters ----

    _FormatMessage(outcome, durationMs, pbChanged)
    {
        durStr := this._FormatDurationMs(durationMs)
        switch outcome
        {
            case "saved":
                return pbChanged
                    ? "SAVED · " durStr " · PB"
                    : "SAVED · " durStr
            case "dnf":
                return "DNF · " durStr
            case "too_short":
                return "TOO SHORT · " durStr " · NOT SAVED"
            case "reset":
                ; Duration omitted for reset — speedrunners reset
                ; intentionally and almost never care about the
                ; partial duration. Keeping the message short also
                ; signals "nothing happened" more cleanly.
                return "RESET · NOT SAVED"
            default:
                ; Unknown outcome — render something rather than
                ; throw. The Hide() at AUTO_HIDE_MS still cleans up.
                return StrUpper(outcome)
        }
    }

    _ColorFor(outcome, pbChanged)
    {
        switch outcome
        {
            case "saved":
                return pbChanged ? "goodStrong" : "good"
            case "dnf":
                return "warn"
            case "too_short":
                return "accentSoft"
            case "reset":
                return "subtle"
            default:
                return "text"
        }
    }

    ; Lightweight ms→HH:MM:SS / MM:SS formatter. Mirrors
    ; Duration.FormatMs without taking a dependency on it here so
    ; the widget stays usable in narrow test setups that don't
    ; include the domain layer. (Duration.FormatMs is the right
    ; choice in production code paths; this widget happens to be
    ; UI-only and benefits from being decoupled.)
    _FormatDurationMs(ms)
    {
        if (ms < 0)
            ms := 0
        totalSec := ms // 1000
        hours    := totalSec // 3600
        mins     := (totalSec - hours * 3600) // 60
        secs     := totalSec - hours * 3600 - mins * 60
        if (hours > 0)
            return Format("{:d}:{:02d}:{:02d}", hours, mins, secs)
        return Format("{:02d}:{:02d}", mins, secs)
    }
}
