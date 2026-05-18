; ============================================================
; BootPromptsTests
; ============================================================
;
; BootPrompts is a thin coordinator over three boot-time modal
; dialogs. The dialogs themselves require an interactive desktop and
; are not exercised here. Coverage is focused on:
;   - Constructor input validation
;   - Each method's early-return guards
;   - That the injected persistFn callback is NOT invoked when a
;     guard short-circuits the flow
;
; Headless-only suite by design: the dialogs would block any
; environment without a user able to click them.


; Minimal stub of RunService whose IsActive() is configurable. Used
; to exercise the second guard of PromptHydratedRun without spinning
; up the whole composition root.
class _BootPromptsStubRunService
{
    _active := false

    SetActive(active)
    {
        this._active := !!active
    }

    IsActive()
    {
        return this._active
    }
}


class BootPromptsTests extends TestCase
{
    cfg          := ""
    persistCount := 0
    persistFn    := ""
    log          := ""

    Setup()
    {
        this.cfg          := AppSettings.Defaults()
        this.persistCount := 0
        ; Arrow function that increments the counter — used to detect
        ; whether a guard let the method reach the persist step.
        this.persistFn    := () => this.persistCount += 1
        this.log          := NullLogger()
    }

    Teardown()
    {
        Fixtures.CleanupAll()
    }

    static Tests := [
        ; --- Constructor ---
        "constructor_throws_when_cfg_not_app_settings",
        "constructor_throws_when_persist_fn_not_callable",
        "constructor_accepts_empty_service_references",

        ; --- ShowDisclaimerIfNeeded guards ---
        "disclaimer_no_op_when_headless",
        "disclaimer_no_op_when_already_acknowledged",

        ; --- PromptLogFileSetupIfNeeded guards ---
        "log_file_setup_no_op_when_headless",
        "log_file_setup_no_op_when_existing_path_is_valid",

        ; --- PromptHydratedRun guards ---
        "hydrated_run_no_op_when_headless",
        "hydrated_run_no_op_when_run_service_missing",
        "hydrated_run_no_op_when_no_active_run"
    ]

    ; ============================================================
    ; Constructor
    ; ============================================================

    constructor_throws_when_cfg_not_app_settings()
    {
        Assert.Throws(TypeError, () => BootPrompts(
            "not an AppSettings", this.persistFn, "", "", "", this.log, true
        ))
    }

    constructor_throws_when_persist_fn_not_callable()
    {
        Assert.Throws(TypeError, () => BootPrompts(
            this.cfg, "not a function", "", "", "", this.log, true
        ))
    }

    constructor_accepts_empty_service_references()
    {
        ; Empty strings for logMonitor / runService / timer are valid;
        ; the methods that need them guard with IsObject checks.
        prompts := BootPrompts(this.cfg, this.persistFn, "", "", "", this.log, true)
        Assert.IsType(BootPrompts, prompts)
    }

    ; ============================================================
    ; ShowDisclaimerIfNeeded
    ; ============================================================

    disclaimer_no_op_when_headless()
    {
        prompts := BootPrompts(this.cfg, this.persistFn, "", "", "", this.log, true)
        prompts.ShowDisclaimerIfNeeded()
        Assert.False(this.cfg.disclaimerAcknowledged, "cfg flag should stay false in headless")
        Assert.Equal(0, this.persistCount, "persistFn should not run when headless")
    }

    disclaimer_no_op_when_already_acknowledged()
    {
        this.cfg.disclaimerAcknowledged := true
        ; headless=false: passes the first guard, hits the second one
        ; (already acknowledged) and returns before touching the Gui.
        prompts := BootPrompts(this.cfg, this.persistFn, "", "", "", this.log, false)
        prompts.ShowDisclaimerIfNeeded()
        Assert.True(this.cfg.disclaimerAcknowledged, "ack flag must remain true")
        Assert.Equal(0, this.persistCount, "persistFn should not run when already acked")
    }

    ; ============================================================
    ; PromptLogFileSetupIfNeeded
    ; ============================================================

    log_file_setup_no_op_when_headless()
    {
        ; Even with an empty logFile (which would otherwise trigger the
        ; setup dialog), headless mode short-circuits before any Gui.
        this.cfg.logFile := ""
        prompts := BootPrompts(this.cfg, this.persistFn, "", "", "", this.log, true)
        prompts.PromptLogFileSetupIfNeeded()
        Assert.Equal("", this.cfg.logFile, "logFile should stay empty in headless")
        Assert.Equal(0, this.persistCount)
    }

    log_file_setup_no_op_when_existing_path_is_valid()
    {
        ; Real existing file: the second guard returns before the dialog.
        existingFile := Fixtures.TempFile("dummy content", "txt")
        this.cfg.logFile := existingFile
        prompts := BootPrompts(this.cfg, this.persistFn, "", "", "", this.log, false)
        prompts.PromptLogFileSetupIfNeeded()
        Assert.Equal(existingFile, this.cfg.logFile, "logFile should be unchanged")
        Assert.Equal(0, this.persistCount, "no save needed when path was already valid")
    }

    ; ============================================================
    ; PromptHydratedRun
    ; ============================================================

    hydrated_run_no_op_when_headless()
    {
        ; runService is missing — would skip the prompt regardless — but
        ; the headless guard fires first; we still want to confirm
        ; nothing else happens.
        prompts := BootPrompts(this.cfg, this.persistFn, "", "", "", this.log, true)
        prompts.PromptHydratedRun()
        ; No observable side effect to assert beyond "no throw / no
        ; persist call" since the method only mutates services.
        Assert.Equal(0, this.persistCount)
    }

    hydrated_run_no_op_when_run_service_missing()
    {
        ; headless=false, but runService is "" → second guard returns.
        prompts := BootPrompts(this.cfg, this.persistFn, "", "", "", this.log, false)
        prompts.PromptHydratedRun()
        Assert.Equal(0, this.persistCount)
    }

    hydrated_run_no_op_when_no_active_run()
    {
        ; Stub RunService that reports IsActive() = false.
        stubRun := _BootPromptsStubRunService()
        stubRun.SetActive(false)
        prompts := BootPrompts(this.cfg, this.persistFn, "", stubRun, "", this.log, false)
        prompts.PromptHydratedRun()
        Assert.Equal(0, this.persistCount)
    }
}

TestRegistry.Register(BootPromptsTests)
