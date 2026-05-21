<#
.SYNOPSIS
    Prepares a clean SpeedKalandra distribution without personal data.

.DESCRIPTION
    Copies the project to a destination directory while excluding:
      - speedkalandra.ini         (personal config)
      - speedkalandra_zones.txt   (in-progress run zone totals)
      - data/                     (everything; only data/zones.csv is shipped)
      - exports/                  (user-generated JSON exports)
      - runs/                     (legacy CSV history at the root)
      - debug/                    (Client.txt and diagnostic dumps)
      - BKP/, _LIXEIRA/           (backups and removed files)
      - .git/, .github/, .vscode/ (dev metadata and CI workflows)
      - tests_v2/                 (AHK test suite + build self-test)
      - *.bak, *.tmp, *.swp, *~   (temp files)
      - this script + build-dist.bat themselves

    The data/ rule mirrors .gitignore's `data/* !data/zones.csv` so
    a hand-edited personal file inside data/ never ships even when
    the explicit exclude list doesn't name it.

    Optionally compiles to .exe via Ahk2Exe and produces a .zip.

.PARAMETER DestDir
    Destination directory. Default: ..\SpeedKalandra-dist (sibling of the project).

.PARAMETER Compile
    Switch. If set, compiles speedkalandra.ahk to .exe via Ahk2Exe.
    Searches for the compiler in the standard AutoHotkey install paths.

.PARAMETER Zip
    Switch. If set, creates <DestDir>.zip at the end.

.PARAMETER Force
    Switch. Overwrites DestDir without prompting.

.PARAMETER SkipTests
    Switch. Bypasses the AHK test-suite gate that normally runs before
    packaging. Use only for local iteration or to break recursion in
    `tests_v2/build/test_build_dist.ps1`; never for actual releases.

.PARAMETER AhkPath
    Optional explicit path to AutoHotkey64.exe (AHK v2). When omitted,
    the script tries the standard install locations and then PATH.
    Useful for CI runners and non-standard installs.

.EXAMPLE
    .\build-dist.ps1
    Clean copy to ..\SpeedKalandra-dist, prompts before overwriting.
    Runs the test suite first; aborts on red.

.EXAMPLE
    .\build-dist.ps1 -Compile -Zip -Force
    Full release: tests, copy, compile .exe, zip, SHA256 sidecar.

.EXAMPLE
    .\build-dist.ps1 -DestDir "C:\temp\sk-release" -Zip
    Custom destination, also produces a zip + SHA256 sidecar.

.EXAMPLE
    .\build-dist.ps1 -AhkPath "D:\Apps\AHK\v2\AutoHotkey64.exe" -Zip
    Uses a non-standard AHK install (portable copy on D:).
#>

[CmdletBinding()]
param(
    [string]$DestDir = "",
    [switch]$Compile,
    [switch]$Zip,
    [switch]$Force,
    # Skip running the AHK test suite before packaging. By default the
    # test suite is run as a release gate; failures abort the build.
    # -SkipTests bypasses the gate -- use only for local iteration or
    # the test of this script itself, never for actual releases.
    [switch]$SkipTests,
    # Explicit path to AutoHotkey64.exe (AHK v2). When unset,
    # Resolve-AhkPath tries the standard install locations and then
    # PATH. The explicit value is respected even when wrong -- fails
    # fast instead of silently falling back to a system install,
    # which would otherwise hide CI misconfiguration.
    [string]$AhkPath = ""
)

# ============================================================
# Helpers
# ============================================================

# Resolves the AutoHotkey64.exe to use for the release-gate test
# suite. Resolution order:
#   1. -AhkPath explicit (must exist; failure here does NOT fall
#      through -- the user's explicit choice is respected even when
#      wrong, otherwise a CI runner with a misconfigured -AhkPath
#      would silently fall back to any AHK on PATH and bless the
#      release with the wrong version)
#   2. Standard AHK v2 install locations (Program Files / x86 /
#      LOCALAPPDATA, with and without the v2 subdir for installs
#      that didn't follow the multi-version layout)
#   3. PATH fallback via Get-Command
# Returns the resolved path or $null if nothing matched. The caller
# is expected to write the failure message and decide exit policy.
function Resolve-AhkPath {
    param([string]$Explicit)

    if ($Explicit -ne "") {
        if (Test-Path -LiteralPath $Explicit -PathType Leaf) {
            return $Explicit
        }
        # Explicit miss: do NOT fall back. Return $null and let the
        # caller produce the failure message -- that way the user
        # sees "AhkPath '...' does not exist" instead of "AHK not
        # found", which would be confusing when they just passed
        # the flag.
        return $null
    }

    $candidates = @(
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:ProgramFiles\AutoHotkey\AutoHotkey64.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey64.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\AutoHotkey64.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\AutoHotkey64.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) {
            return $c
        }
    }

    $cmd = Get-Command "AutoHotkey64.exe" -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Path
    }

    return $null
}

$ErrorActionPreference = "Stop"

# ============================================================
# Resolve paths
# ============================================================

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$SourceDir = $ScriptDir.TrimEnd('\','/')

if (-not $DestDir) {
    $parent = Split-Path -Parent $SourceDir
    $DestDir = Join-Path $parent "SpeedKalandra-dist"
}
$DestDir = $DestDir.TrimEnd('\','/')

# Sanity check: source must contain speedkalandra.ahk
$entryPoint = Join-Path $SourceDir "speedkalandra.ahk"
if (-not (Test-Path $entryPoint)) {
    Write-Error "speedkalandra.ahk not found in '$SourceDir'.`nRun this script from INSIDE the SpeedKalandra project folder."
    exit 1
}

# Defensive guard: dest cannot equal or be an ancestor of the source
$sourceFull = (Resolve-Path $SourceDir).Path.TrimEnd('\','/')
$destResolvedAttempt = $DestDir
if (-not (Test-Path $DestDir)) {
    # Resolve to absolute manually if it doesn't exist yet
    if (-not [System.IO.Path]::IsPathRooted($DestDir)) {
        $destResolvedAttempt = Join-Path (Get-Location).Path $DestDir
    }
}
else {
    $destResolvedAttempt = (Resolve-Path $DestDir).Path
}
$destFull = $destResolvedAttempt.TrimEnd('\','/')

if ($destFull -ieq $sourceFull) {
    Write-Error "DestDir cannot equal SourceDir."
    exit 1
}
if ($sourceFull.StartsWith($destFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "DestDir cannot be an ancestor of SourceDir (would erase the project)."
    exit 1
}
if ($destFull.StartsWith($sourceFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "DestDir cannot be a descendant of SourceDir (would create a recursive copy). Use a directory outside the project, e.g. '..\SpeedKalandra-dist'."
    exit 1
}

Write-Host ""
Write-Host "=== SpeedKalandra :: Build Dist ===" -ForegroundColor Cyan
Write-Host "Source : $SourceDir" -ForegroundColor Gray
Write-Host "Dest   : $DestDir" -ForegroundColor Gray
Write-Host ""

# ============================================================
# Test gate (release safety)
# ============================================================
#
# Run the AHK test suite headlessly before packaging. A red CI
# build still happens regardless, but the release script itself
# refuses to produce a distribution from a broken tree.
#
# Skip with -SkipTests (intended for local iteration and for the
# test of this script in tests_v2/build/test_build_dist.ps1, which
# would otherwise recurse).

if (-not $SkipTests) {
    Write-Host "Running AHK test suite (release gate)..." -ForegroundColor Cyan
    # Capture this BEFORE invoking AHK so the staleness check below
    # has a reliable lower bound on when the run started, independent
    # of how the suite reports its own duration.
    $gateStartTime = Get-Date
    $ahkExe = Resolve-AhkPath -Explicit $AhkPath
    if (-not $ahkExe) {
        if ($AhkPath -ne "") {
            # Explicit miss: name the bad value so the user can fix it
            # without re-reading the help. Same exit policy whether the
            # path is a typo or a real-but-deleted install -- both
            # surface as "file does not exist".
            Write-Error "AhkPath '$AhkPath' does not exist. Fix the path or omit -AhkPath to let the script discover AHK v2 automatically."
        }
        else {
            Write-Error "AutoHotkey v2 not found in standard install paths or on PATH. Install AHK v2, pass -AhkPath <path-to-AutoHotkey64.exe>, or use -SkipTests (not recommended for releases)."
        }
        exit 1
    }
    Write-Host "  Using AHK: $ahkExe" -ForegroundColor Gray

    # SPEEDKALANDRA_TEST_NO_GUI=1 suppresses the final MsgBox and
    # makes the runner exit with 0/1 instead of waiting for OK.
    #
    # WHY Start-Process and not `& $ahkExe ...`:
    # AutoHotkey64.exe is a Windows-subsystem (GUI) executable, not
    # console-subsystem. PowerShell's call operator (`&`) only waits
    # implicitly on console-subsystem EXEs whose stdout/stderr are
    # wired to the shell; for GUI-subsystem EXEs it returns immediately
    # as fire-and-forget. (PowerShell 7 papers over this for some
    # GUI EXEs but PowerShell 5.1 -- the default `powershell.exe` the
    # build-dist.bat wrapper invokes -- does not.) The previous form
    # `& $ahkExe "tests_v2\run_tests.ahk"` therefore produced a
    # silently broken release gate: build-dist returned and went on
    # to create the zip while the AHK process was still running the
    # suite. Add the null-defensive `$exitCode = $null ? 0 : raw` on
    # top and a real failure mid-suite would never reach this branch.
    #
    # WHY NOT `Start-Process -Wait -NoNewWindow`:
    # That form hung the GitHub Actions Windows runner for 19 minutes
    # with no output -- a known interaction where the child process
    # exits but inherits the shell's stdio handles, leaving the
    # parent's `WaitForExit` blocked on a pipe that never closes.
    # Plain `Start-Process -Wait -PassThru` (no -NoNewWindow) gives
    # AHK its own detached process; -WindowStyle Hidden defends
    # against any incidental console window flicker.
    #
    # The CI workflow (.github/workflows/test.yml) keeps using the
    # `&` form because it runs under `shell: pwsh` (PowerShell 7),
    # which DOES wait on GUI-subsystem EXEs invoked via `&` -- the
    # bug above is local-only. Both paths produce the same observable
    # behavior: a non-zero AHK exit aborts the build.
    $oldNoGui = $env:SPEEDKALANDRA_TEST_NO_GUI
    $env:SPEEDKALANDRA_TEST_NO_GUI = "1"
    try {
        $testProc = Start-Process -FilePath $ahkExe `
                                  -ArgumentList "tests_v2\run_tests.ahk" `
                                  -WorkingDirectory $SourceDir `
                                  -Wait -PassThru `
                                  -WindowStyle Hidden
        # $testProc.ExitCode is the AHK ExitApp(N) value. Unlike
        # $LASTEXITCODE after a `&` call, this is guaranteed populated
        # by .NET's Process.ExitCode property after WaitForExit -- no
        # null-defensive fallback needed.
        $exitCode = $testProc.ExitCode
        if ($exitCode -ne 0) {
            Write-Error "Test suite failed (exit $exitCode). Release aborted. See tests_v2\tests_output.log for details."
            exit $exitCode
        }

        # Defense in depth: an AHK exit 0 alone is not proof the suite
        # actually ran during THIS build. If a future regression causes
        # Start-Process -Wait to behave like the old fire-and-forget `&`
        # (or some sibling Windows subsystem quirk emerges), we'd ship
        # again on a stale gate. The test runner writes tests_output.log
        # via TestReporter.Init at startup, so its LastWriteTime is a
        # reliable lower bound for "the suite did start during this run".
        # Compare against $gateStartTime captured before AHK was invoked:
        # a stale log means AHK was never the process that wrote it (or
        # it wrote nothing at all), and we must abort.
        $outputLog = Join-Path $SourceDir "tests_v2\tests_output.log"
        if (-not (Test-Path -LiteralPath $outputLog)) {
            Write-Error "Release gate: AHK reported exit 0 but tests_v2\tests_output.log was not produced. The test runner either crashed before TestReporter.Init or the gate did not actually wait for AHK to run. Release aborted."
            exit 1
        }
        $logMtime = (Get-Item -LiteralPath $outputLog).LastWriteTime
        if ($logMtime -lt $gateStartTime) {
            Write-Error ("Release gate: AHK reported exit 0 but tests_v2\tests_output.log is stale " +
                         "(last write: $logMtime, gate started: $gateStartTime). " +
                         "The AHK process did not produce a fresh log during this build -- either Start-Process -Wait " +
                         "returned prematurely, or the runner skipped TestReporter.Init. Release aborted.")
            exit 1
        }

        Write-Host "Tests passed." -ForegroundColor Green
        Write-Host ""
    }
    finally {
        $env:SPEEDKALANDRA_TEST_NO_GUI = $oldNoGui
    }
}
else {
    Write-Host "-SkipTests was passed; release gate bypassed." -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================
# Clean dest if it exists
# ============================================================

if (Test-Path $DestDir) {
    if (-not $Force) {
        $resp = Read-Host "Dest '$DestDir' already exists. Overwrite? [y/N]"
        if ($resp -notmatch '^[sSyY]') {
            Write-Host "Aborted by user." -ForegroundColor Yellow
            exit 0
        }
    }
    Write-Host "Removing existing dest..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force -LiteralPath $DestDir
}

New-Item -ItemType Directory -Path $DestDir -Force | Out-Null

# ============================================================
# Exclusion rules
# ============================================================

# Directories excluded recursively. Matched against RELATIVE path
# (e.g. "_LIXEIRA", "data\runs"). Comparison is case-insensitive.
$ExcludeDirs = @(
    "_LIXEIRA",
    "BKP",
    "debug",
    "runs",                 # legacy CSV history at the root
    "data\runs",            # explicit; also covered by the data/* catch-all below
    "exports",              # user-generated JSON exports; personal play data
    ".git",
    ".github",              # CI workflows, issue templates: dev-only
    ".vscode",
    ".idea",
    "node_modules",
    "tests_v2",             # AHK test suite + build self-test: dev-only
    "SpeedKalandra-dist"    # in case the user runs this from inside it
)

# Files allowed to ship from inside data/. Everything else under
# data/ is excluded by Test-IsInDataDirAndNotAllowed below. This
# mirrors the .gitignore rule `data/* !data/zones.csv` so a
# hand-edited data file (a future data/zone_totals_2024.txt, an
# accidental data/notes.md, etc.) never silently ships in the
# release — belt-and-suspenders on top of the explicit excludes
# below.
$AllowedInDataDir = @(
    "data\zones.csv"
)

# Specific files (paths relative to source)
$ExcludeFiles = @(
    "speedkalandra.ini",
    "data\personal_bests.ini",
    "data\personal_bests.ini.bak",
    "data\speedkalandra.log",
    "data\run_state.ini",
    "data\deaths.csv",   # append-only death log; personal play data, not template
    "speedkalandra_zones.txt",
    "build-dist.ps1",       # this script itself
    "build-dist.bat",       # the wrapper
    ".gitignore",
    ".gitattributes",
    # Dev-only docs kept out of the dist (~263 KB saved).
    # README-DIST.txt is generated below for end users.
    "ARCHITECTURE.md",
    "AUDITORIA-PRODUCAO.md",
    "README.md",
    "src_v2\README.md"
)

# Filename patterns (anywhere). Matched against the file's Name.
$ExcludePatterns = @(
    "*.bak",
    "*.tmp",
    "*.swp",
    "*~",
    "*.log",                # covers debug/*.log and any other
    "Client*.txt"           # PoE2 logs the user may have copied in
)

# ============================================================
# Helpers
# ============================================================

function Test-IsExcludedDir {
    param([string]$relPath)
    foreach ($exDir in $ExcludeDirs) {
        $exDirNorm = $exDir.Replace('/', '\')
        # Exact match OR prefix + separator
        if ($relPath -ieq $exDirNorm) { return $true }
        if ($relPath.StartsWith($exDirNorm + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-IsExcludedFile {
    param([string]$relPath, [string]$fileName)

    # Exact path match
    foreach ($exFile in $ExcludeFiles) {
        if ($relPath -ieq $exFile.Replace('/', '\')) { return $true }
    }

    # Filename pattern match
    foreach ($pattern in $ExcludePatterns) {
        if ($fileName -like $pattern) { return $true }
    }

    return $false
}

# Catch-all defense for data/: returns $true for any file under
# data/ that isn't on the $AllowedInDataDir whitelist. This is the
# `data/* !data/zones.csv` rule from .gitignore, applied at build
# time too — a personal file the user dropped into data/
# (data/zone_totals_old.txt, etc.) doesn't ship even when the
# explicit $ExcludeFiles list doesn't name it.
function Test-IsInDataDirAndNotAllowed {
    param([string]$relPath)
    if (-not ($relPath -imatch '^data\\')) { return $false }
    foreach ($allowed in $AllowedInDataDir) {
        if ($relPath -ieq $allowed.Replace('/', '\')) { return $false }
    }
    return $true
}

# ============================================================
# Copy files
# ============================================================

Write-Host "Copying files (filtering personal data)..." -ForegroundColor Green

$copied = 0
$skipped = 0
$skippedSamples = @()

Get-ChildItem -Path $SourceDir -Recurse -File | ForEach-Object {
    $file = $_
    $relPath = $file.FullName.Substring($SourceDir.Length).TrimStart('\','/')

    # Check whether the file sits inside an excluded directory
    $relDir = Split-Path -Parent $relPath
    if ($relDir -and (Test-IsExcludedDir -relPath $relDir)) {
        $script:skipped++
        if ($script:skippedSamples.Count -lt 5) {
            $script:skippedSamples += $relPath
        }
        return
    }

    # Defensive: anything under data/ that's not on the allow list
    # is excluded (mirrors .gitignore's `data/* !data/zones.csv`).
    if (Test-IsInDataDirAndNotAllowed -relPath $relPath) {
        $script:skipped++
        if ($script:skippedSamples.Count -lt 5) {
            $script:skippedSamples += $relPath
        }
        return
    }

    # Check specific-file or pattern exclusions
    if (Test-IsExcludedFile -relPath $relPath -fileName $file.Name) {
        $script:skipped++
        if ($script:skippedSamples.Count -lt 5) {
            $script:skippedSamples += $relPath
        }
        return
    }

    # Copy while preserving the directory structure
    $destFile = Join-Path $DestDir $relPath
    $destSubDir = Split-Path -Parent $destFile
    if ($destSubDir -and -not (Test-Path $destSubDir)) {
        New-Item -ItemType Directory -Path $destSubDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
    $script:copied++
}

Write-Host "  Copied  : $copied files" -ForegroundColor Gray
Write-Host "  Filtered: $skipped files" -ForegroundColor Gray
if ($skippedSamples.Count -gt 0) {
    Write-Host "  Filtered examples:" -ForegroundColor DarkGray
    foreach ($s in $skippedSamples) {
        Write-Host "    - $s" -ForegroundColor DarkGray
    }
}
Write-Host ""

# ============================================================
# Ensure the minimal data/ structure
# ============================================================

$dataDir = Join-Path $DestDir "data"
if (-not (Test-Path $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}
# data/runs/ -- make sure it exists (RunHistoryRepository creates it
# if missing, but better to guarantee it here).
$runsDir = Join-Path $dataDir "runs"
if (-not (Test-Path $runsDir)) {
    New-Item -ItemType Directory -Path $runsDir -Force | Out-Null
    # .keep preserves the dir inside the zip
    New-Item -ItemType File -Path (Join-Path $runsDir ".keep") -Force | Out-Null
}

# ============================================================
# Distribution README
# ============================================================

$distReadme = Join-Path $DestDir "README-DIST.txt"
$readmeContent = @"
SpeedKalandra - PoE2 Speedrun Tracker
======================================

FIRST RUN:
1. Install AutoHotkey v2: https://www.autohotkey.com/
2. Run speedkalandra.ahk (double-click)
   - If compiled, run SpeedKalandra.exe instead
3. Configure the path to PoE2's Client.txt in Settings (tray icon)
   Typical: C:\Program Files (x86)\Grinding Gear Games\Path of Exile 2\logs\Client.txt

DEFAULT HOTKEYS:
   Ctrl+3        Toggle timer (pause/resume run)
   Ctrl+Alt+N    New run (cancels current)
   Ctrl+Alt+F    Finalize run (saves to history, updates PB)
   Ctrl+5        Reset (cancels current without saving)
   Ctrl+Alt+P    Run plot
   Ctrl+Alt+S    Settings
   F8            Toggle overlay
   Ctrl+F9       Toggle Micro mode
   Ctrl+F8       Toggle Steve mode

COMPACT OVERLAY:
   LINE 1: Act N . Zone Name . zone_time / total_time
            (timers green when under PB, red when over)
   LINE 2: Lv X . Area Y | XP | PB zone_time / run_time  (teal)
   LINE 3: stacked bar Map/Loading/Town
   Right side: 3 vendor regex buttons (V1/V2/V3, click with Ctrl)

OVERLAY INTERACTION:
   Hold Ctrl to interact with the overlay (drag, resize, click
   buttons). Without Ctrl, clicks pass through to the game.

PERSISTED DATA (created on first run):
   speedkalandra.ini             configuration + in-progress run state
   speedkalandra_zones.txt       zone totals of the in-progress run
   data/personal_bests.ini       PBs per zone + full run
   data/runs/{runId}.ini         history of finalized runs
   data/deaths.csv               append-only log of every death detected
   data/speedkalandra.log        execution log (rotated at 5 MB)

UPGRADING:
   Extract the new release over the existing folder. The release
   ZIP does NOT contain any of the files above — they survive the
   upgrade. If you extract into a new folder instead, copy the
   files above from the old install to preserve your data.

Enjoy!
"@
$readmeContent | Out-File -FilePath $distReadme -Encoding UTF8
Write-Host "README-DIST.txt created." -ForegroundColor Gray

# ============================================================
# Optional compilation via Ahk2Exe
# ============================================================

if ($Compile) {
    Write-Host ""
    Write-Host "Compiling .ahk -> .exe via Ahk2Exe..." -ForegroundColor Green

    # --- Locate Ahk2Exe.exe ---
    $ahk2exePaths = @(
        "$env:ProgramFiles\AutoHotkey\Compiler\Ahk2Exe.exe",
        "$env:ProgramFiles\AutoHotkey\v2\Compiler\Ahk2Exe.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\Compiler\Ahk2Exe.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\Compiler\Ahk2Exe.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\Compiler\Ahk2Exe.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\Compiler\Ahk2Exe.exe"
    )

    $ahk2exe = $null
    foreach ($p in $ahk2exePaths) {
        if (Test-Path $p) {
            $ahk2exe = $p
            break
        }
    }

    # --- Locate the base file (AutoHotkey64.exe from AHK v2) ---
    # Ahk2Exe needs a "base file" to embed the .exe. For AHK v2 that
    # is AutoHotkey64.exe (64-bit) or AutoHotkey32.exe (32-bit) from
    # the AutoHotkey install. Without it Ahk2Exe pops a GUI asking
    # for the default base; we pass /base explicitly to avoid that.
    $baseFilePaths = @(
        # AHK v2 64-bit (preferred)
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:ProgramFiles\AutoHotkey\AutoHotkey64.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey64.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\AutoHotkey64.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\AutoHotkey64.exe",
        # AHK v2 32-bit fallback
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey32.exe",
        "$env:ProgramFiles\AutoHotkey\AutoHotkey32.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey32.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\AutoHotkey32.exe"
    )

    $baseFile = $null
    foreach ($p in $baseFilePaths) {
        if (Test-Path $p) {
            $baseFile = $p
            break
        }
    }

    if (-not $ahk2exe) {
        Write-Warning "Ahk2Exe.exe not found in the standard AutoHotkey install paths."
        Write-Warning "Compile manually: right-click speedkalandra.ahk -> Compile Script"
    }
    elseif (-not $baseFile) {
        Write-Warning "AutoHotkey64.exe (base file) not found in the standard paths."
        Write-Warning "Verify that AutoHotkey v2 is installed in standard locations."
        Write-Warning "Alternatively, open the Ahk2Exe GUI and configure the default base."
    }
    else {
        $ahkInput  = Join-Path $DestDir "speedkalandra.ahk"
        $exeOutput = Join-Path $DestDir "SpeedKalandra.exe"

        Write-Host "  Compiler : $ahk2exe" -ForegroundColor Gray
        Write-Host "  Base file: $baseFile" -ForegroundColor Gray
        Write-Host "  Input    : $ahkInput" -ForegroundColor Gray
        Write-Host "  Output   : $exeOutput" -ForegroundColor Gray

        # Ahk2Exe args: /in <input> /out <output> /base <ahk_exe>
        & $ahk2exe /in $ahkInput /out $exeOutput /base $baseFile
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Ahk2Exe returned exit code $LASTEXITCODE. Check whether it compiled correctly."
        }
        elseif (Test-Path $exeOutput) {
            $exeSize = [Math]::Round((Get-Item $exeOutput).Length / 1MB, 2)
            Write-Host "Compiled OK: $exeOutput ($exeSize MB)" -ForegroundColor Green
        }
        else {
            Write-Warning "Compilation finished with no exit code but the .exe was not produced."
        }
    }
}

# ============================================================
# Optional zip
# ============================================================

if ($Zip) {
    Write-Host ""
    Write-Host "Creating zip..." -ForegroundColor Green

    $zipPath = "$DestDir.zip"
    if (Test-Path $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    # Compress-Archive accepts a wildcard to include the dir's content (not the dir itself)
    Compress-Archive -Path "$DestDir\*" -DestinationPath $zipPath -CompressionLevel Optimal

    if (Test-Path $zipPath) {
        $zipSize = [Math]::Round((Get-Item $zipPath).Length / 1MB, 2)
        Write-Host "Zip created: $zipPath ($zipSize MB)" -ForegroundColor Green

        # SHA256 sidecar so downloaders can verify integrity.
        # Format mirrors GNU coreutils `sha256sum`: "<HEX>  <filename>".
        # Verify on Linux/macOS:  sha256sum -c SpeedKalandra-dist.zip.sha256.txt
        # Verify on Windows:      Get-FileHash file.zip -Algorithm SHA256
        $hash = Get-FileHash $zipPath -Algorithm SHA256
        $zipName = Split-Path $zipPath -Leaf
        $sidecarPath = "$zipPath.sha256.txt"
        "$($hash.Hash.ToLower())  $zipName" | Out-File -FilePath $sidecarPath -Encoding ASCII -NoNewline
        # Append a trailing newline (coreutils convention)
        Add-Content -Path $sidecarPath -Value "" -Encoding ASCII
        Write-Host "SHA256: $($hash.Hash.ToLower())" -ForegroundColor Gray
        Write-Host "Sidecar: $sidecarPath" -ForegroundColor Gray
    }
}

# ============================================================
# Summary
# ============================================================

Write-Host ""
Write-Host "=== Build finished ===" -ForegroundColor Cyan
Write-Host "Dest: $DestDir" -ForegroundColor White

$totalFiles = (Get-ChildItem -Path $DestDir -Recurse -File).Count
$totalSize  = [Math]::Round(((Get-ChildItem -Path $DestDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 2)
Write-Host "Files: $totalFiles | Size: $totalSize MB" -ForegroundColor Gray
Write-Host ""
