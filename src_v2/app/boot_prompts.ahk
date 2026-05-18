; BootPrompts — three modal dialogs shown during SpeedKalandraApp.Start():
;
;   1. ShowDisclaimerIfNeeded         — first-boot disclaimer (sticky once acked)
;   2. PromptLogFileSetupIfNeeded     — required PoE2 Client.txt path
;   3. PromptHydratedRun              — optional choice for a run resumed from disk
;
; Each method is a no-op in headless mode. The first two are sticky
; (skipped once the cfg flag / path is in good state); the third only
; runs when RunService.IsActive() returns true after hydration.
;
; This class owns no state of its own — it is a thin coordinator that
; reaches into AppSettings + LogService + a few services, drives the
; modal lifecycle, and writes the user's choice back through the
; injected persistFn callback or the service references.
;
; Construction (from the composition root):
;
;   prompts := BootPrompts(
;       this._cfg,
;       () => this._PersistSettings(),
;       this.logMonitor,
;       this.runService,
;       this.timer,
;       this.log,
;       this._headless
;   )


class BootPrompts
{
    _cfg          := ""      ; AppSettings, shared reference (mutated on user choice)
    _persistFn    := ""      ; callable () => app._PersistSettings()
    _logMonitor   := ""      ; LogMonitorService, for live re-Configure after setup
    _runService   := ""      ; RunService, for the hydrated-run prompt
    _timer        := ""      ; TimerService, paused during the hydrated-run prompt
    _log          := ""      ; LogService
    _headless     := false

    __New(cfg, persistFn, logMonitor, runService, timer, log, headless)
    {
        if !(cfg is AppSettings)
            throw TypeError("BootPrompts: 'cfg' must be AppSettings")
        if !IsObject(persistFn) || !persistFn.HasMethod("Call")
            throw TypeError("BootPrompts: 'persistFn' must be callable")
        ; logMonitor / runService / timer may be empty in early-stage
        ; tests; the methods that consume them guard against missing
        ; objects with IsObject checks.
        this._cfg        := cfg
        this._persistFn  := persistFn
        this._logMonitor := logMonitor
        this._runService := runService
        this._timer      := timer
        this._log        := log
        this._headless   := !!headless
    }

    ; First-boot disclaimer modal. Skipped when headless or when the
    ; user has already ticked "Don't show again" (persisted via
    ; cfg.disclaimerAcknowledged). The body text is in English to
    ; reach the widest player audience.
    ShowDisclaimerIfNeeded()
    {
        if this._headless
            return
        if this._cfg.disclaimerAcknowledged
            return

        ; Disclaimer text (multi-line continuation section).
        ; Leading whitespace on each line is stripped by AHK up to the
        ; closing `)`. Mirrors README.md § Disclaimer.
        bodyText := "
        (
SpeedKalandra is an independent personal project. It reads Path of Exile 2's Client.txt log file and samples pixel colors on screen for loading detection. It does not inject into the game process, modify game files, or send inputs to the game. To the best of my knowledge this falls within typical overlay/tracker territory, but I make no guarantees — use it understanding that you are responsible for what runs on your machine while playing.

The codebase was developed with significant AI assistance, was reviewed and tested in real runs, and is covered by an automated test suite that runs on CI for every commit. I keep this notice because AI-assisted development should be transparent.

Use at your own risk. Forks are welcome under the project's GPL license.
        )"

        choice := { dontShow: false, done: false }

        g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox +ToolWindow",
                 "SpeedKalandra - Disclaimer")
        g.MarginX := 16
        g.MarginY := 14

        g.SetFont("s11 bold", "Segoe UI")
        g.Add("Text", "x16 y14 w560", "Before using SpeedKalandra...")

        ; Multi-line Edit read-only with VScroll. Automatic wrap.
        g.SetFont("s9", "Segoe UI")
        edt := g.Add("Edit",
            "x16 y42 w560 h360 +Multi +ReadOnly +VScroll Background0xFFFFFF",
            bodyText)

        ; Checkbox
        g.SetFont("s9", "Segoe UI")
        chkDontShow := g.Add("Checkbox", "x16 y414 w300",
            "Don't show this disclaimer again")

        ; Button
        btnOk := g.Add("Button", "x456 y410 w120 h30 Default", "I understand")

        ; Handlers — closure shares the choice object by reference
        dismissFn := (*) => (
            choice.dontShow := chkDontShow.Value = 1,
            choice.done := true,
            g.Destroy()
        )
        btnOk.OnEvent("Click", dismissFn)
        g.OnEvent("Close",  dismissFn)
        g.OnEvent("Escape", dismissFn)

        ; Center on the screen
        g.Show("w592 h460")

        ; Block until user dismisses (same pattern as PromptHydratedRun)
        hwnd := g.Hwnd
        while (!choice.done && WinExist("ahk_id " hwnd))
            Sleep 50

        ; If the user ticked the checkbox, persist the ack so it does
        ; not show again
        if (choice.dontShow)
        {
            this._cfg.disclaimerAcknowledged := true
            try
            {
                (this._persistFn)()
            }
            catch as ex
            {
                if IsObject(this._log)
                    try this._log.Warn("Failed to persist disclaimer ack: " . ex.Message, "BootPrompts")
            }
            if IsObject(this._log)
                try this._log.Info("Disclaimer acknowledged by user", "BootPrompts")
        }
    }

    ; First-boot setup for the PoE2 Client.txt path. Blocks the boot
    ; until a valid path is configured or the user cancels (cancel
    ; calls ExitApp — the app refuses to run without Client.txt). The
    ; suggested default is the Steam install location; standalone /
    ; GGG-launcher installs need Browse.
    PromptLogFileSetupIfNeeded()
    {
        if this._headless
            return

        ; Do we already have a valid path? Then no setup is needed.
        if (this._cfg.logFile != "" && FileExist(this._cfg.logFile))
            return

        defaultPath := "C:\Program Files (x86)\Steam\steamapps\common\Path of Exile 2\logs\Client.txt"

        ; Pre-fill: if there was already a configured path but the file
        ; is gone, preserve the old path for the user to correct;
        ; otherwise, use the Steam default.
        initialPath := this._cfg.logFile != "" ? this._cfg.logFile : defaultPath

        choice := { value: "", path: "" }

        g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox +ToolWindow",
            "SpeedKalandra — Setup")
        g.MarginX := 16
        g.MarginY := 14

        g.SetFont("s11 bold", "Segoe UI")
        g.Add("Text", "x16 y14 w560", "Configure PoE2's Client.txt path")

        g.SetFont("s9", "Segoe UI")
        bodyText := ""
            . "SpeedKalandra reads Path of Exile 2's Client.txt log file to detect zone"
            . " changes, level ups, and deaths in real time. The path below is the"
            . " default location when PoE2 is installed via Steam.\n\nIf your installation"
            . " is somewhere else, use Browse to point to your own Client.txt. The app"
            . " will not start without a valid path."
        ; AHK v2 doesn't recognize \n; convert to `n
        bodyText := StrReplace(bodyText, "\n", "`n")
        g.Add("Text", "x16 y44 w560 h60", bodyText)

        g.SetFont("s9 bold", "Segoe UI")
        g.Add("Text", "x16 y110 w120", "Client.txt path:")

        g.SetFont("s9", "Consolas")
        editPath := g.Add("Edit", "x16 y130 w470 h24", initialPath)

        g.SetFont("s9", "Segoe UI")
        btnBrowse := g.Add("Button", "x494 y129 w82 h26", "Browse...")
        browseHandler := (*) => (
            picked := this._SetupBrowseLog(editPath.Value),
            (picked != "" ? (editPath.Value := picked) : 0)
        )
        btnBrowse.OnEvent("Click", browseHandler)

        ; Status line (empty initially, gets red text on error)
        g.SetFont("s9", "Segoe UI")
        statusLbl := g.Add("Text",
            "x16 y162 w560 h20 c" Theme.Color("danger"), "")

        ; Buttons
        btnOk := g.Add("Button", "x376 y196 w100 h30 Default", "OK")
        btnCancel := g.Add("Button", "x484 y196 w92 h30", "Cancel")

        okHandler := (*) => (
            (this._SetupValidatePath(editPath.Value, statusLbl)
                ? (choice.value := "ok",
                   choice.path := Trim(editPath.Value),
                   g.Destroy())
                : 0)
        )
        cancelHandler := (*) => (
            choice.value := "cancel",
            g.Destroy()
        )

        btnOk.OnEvent("Click", okHandler)
        btnCancel.OnEvent("Click", cancelHandler)
        g.OnEvent("Close", cancelHandler)
        g.OnEvent("Escape", cancelHandler)

        g.Show("w592 h240")

        ; Block until user dismisses
        hwnd := g.Hwnd
        while (choice.value = "" && WinExist("ahk_id " hwnd))
            Sleep 50

        if (choice.value = "cancel")
        {
            if IsObject(this._log)
                try this._log.Info("Setup cancelled by user: exiting app", "BootPrompts")
            try TrayTip("SpeedKalandra",
                "Setup cancelled. The app cannot run without Client.txt.",
                "Iconx")
            ExitApp()
        }

        ; OK: persist the chosen path
        this._cfg.logFile := choice.path
        try
        {
            (this._persistFn)()
        }
        catch as ex
        {
            if IsObject(this._log)
                try this._log.Warn("Failed to persist log file path from setup: " . ex.Message, "BootPrompts")
        }
        ; Also reconfigure LogMonitor with the chosen path. Without
        ; this, the LogMonitor.Configure("") from __New stays in
        ; effect, and the subsequent logMonitor.Start() in app.Start()
        ; early-returns because the path looks unconfigured — the
        ; user would have to reload the app for the new path to take
        ; effect, defeating the live-setup flow.
        if IsObject(this._logMonitor)
        {
            try
            {
                this._logMonitor.Configure(choice.path)
            }
            catch as ex
            {
                if IsObject(this._log)
                    try this._log.Warn("LogMonitor.Configure failed after setup: " . ex.Message, "BootPrompts")
            }
        }
        if IsObject(this._log)
            try this._log.Info("Client.txt path configured: " . choice.path, "BootPrompts")
    }

    ; Boot prompt for a hydrated active run: Resume / Finalize & save
    ; / Discard. The decision is explicit — no timeout — because each
    ; outcome has different state consequences. Skipped when headless
    ; or when there is no active run. The timer is paused for the
    ; duration of the prompt so the displayed run time doesn't keep
    ; ticking while the user decides.
    PromptHydratedRun()
    {
        if this._headless
            return
        if !IsObject(this._runService) || !this._runService.IsActive()
            return

        wasRunningBeforePrompt := IsObject(this._timer) && this._timer.IsRunning()
        if wasRunningBeforePrompt
            try this._timer.Pause()

        state := this._runService.GetState()
        runMs := IsObject(this._timer) ? this._timer.GetRunMs() : 0
        durStr := Duration.FormatMs(runMs)
        startedAt := state.startedAt != "" ? state.startedAt : "unknown"

        ; Choice via shared closure
        choice := { value: "" }

        g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox +ToolWindow",
            "SpeedKalandra — Active run found")
        g.SetFont("s10")
        g.Add("Text", "x20 y20 w360",
            "An active run was found from a previous session:")
        g.SetFont("s10 bold")
        g.Add("Text", "x20 y50 w360",
            "Started:  " startedAt "`n"
            . "Duration: " durStr)
        g.SetFont("s10")
        g.Add("Text", "x20 y100 w360", "What do you want to do?")

        ; Buttons
        btnResume := g.Add("Button", "x20 y140 w110 h32 Default", "Resume")
        btnResume.OnEvent("Click", (*) => (choice.value := "resume", g.Destroy()))

        btnFinalize := g.Add("Button", "x140 y140 w120 h32", "Finalize && save")
        btnFinalize.OnEvent("Click", (*) => (choice.value := "finalize", g.Destroy()))

        btnDiscard := g.Add("Button", "x270 y140 w110 h32", "Discard")
        btnDiscard.OnEvent("Click", (*) => (choice.value := "discard", g.Destroy()))

        ; Close X = Resume (safe default — does not lose data)
        g.OnEvent("Close", (*) => (choice.value := "resume", g.Destroy()))
        g.OnEvent("Escape", (*) => (choice.value := "resume", g.Destroy()))

        g.Show("w400 h190")

        ; Wait for choice (blocks the thread). g.Destroy() above
        ; triggers the loop exit.
        hwnd := g.Hwnd
        while (choice.value = "" && WinExist("ahk_id " hwnd))
            Sleep 50

        ; Apply the choice
        if (choice.value = "discard")
        {
            try
            {
                this._runService.ResetRun()
            }
            catch as ex
            {
                if IsObject(this._log)
                    try this._log.Warn("Discard hydrated run failed: " . ex.Message, "BootPrompts")
            }
            if IsObject(this._log)
                try this._log.Info("Hydrated run discarded by user (" . durStr . ", started at " . startedAt . ")", "BootPrompts")
            try TrayTip("SpeedKalandra", "Previous run discarded.", "Mute")
        }
        else if (choice.value = "finalize")
        {
            ; FinalizeRun publishes RunCompleted -> _SaveRunSnapshot("completed")
            ; in the composition root, which applies the threshold and
            ; saves or discards.
            try
            {
                this._runService.FinalizeRun()
            }
            catch as ex
            {
                if IsObject(this._log)
                    try this._log.Warn("Finalize hydrated run failed: " . ex.Message, "BootPrompts")
            }
            if IsObject(this._log)
                try this._log.Info("Hydrated run finalized by user (" . durStr . ", started at " . startedAt . ")", "BootPrompts")
        }
        else
        {
            ; "resume" (button or close-X): resume the timer if it was
            ; running before the prompt. If it was paused, keep paused.
            if wasRunningBeforePrompt
                try this._timer.Resume()
        }
    }

    ; ---- Private helpers ----

    ; FileSelect helper for the setup dialog. Kept out of the inline
    ; closure so the path-edit field is captured correctly.
    _SetupBrowseLog(currentValue)
    {
        try
        {
            ; `file` collides with the builtin `File` class; rename locally.
            selectedFile := FileSelect(1, currentValue,
                "Select PoE2 Client.txt", "Log files (*.txt)")
            return selectedFile
        }
        return ""
    }

    ; Validates the chosen path exists. On error, updates the status
    ; label with a red message. Returns a bool.
    _SetupValidatePath(path, statusLbl)
    {
        path := Trim(path)
        if (path = "")
        {
            try statusLbl.Value := "Path cannot be empty."
            return false
        }
        if !FileExist(path)
        {
            try statusLbl.Value := "File not found: " . path
            return false
        }
        return true
    }
}
