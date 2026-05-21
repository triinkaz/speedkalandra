<#
.SYNOPSIS
    Tests that build-dist.ps1 filters personal data out of the release.

.DESCRIPTION
    The AHK test suite (`tests_v2\run_tests.ahk`) covers application
    behaviour. This script tests the *release process*: it builds a
    fake project tree containing sentinel files that represent every
    category of personal data we never want shipped, runs
    `build-dist.ps1` against it, then asserts that every sentinel is
    absent from both the staged directory and the produced .zip.

    The AHK runner is the wrong tool for this — the test exercises
    PowerShell, file copy, Compress-Archive, and Expand-Archive.
    Keeping it in PowerShell removes the AHK <-> PowerShell plumbing
    that an AHK-side test would require.

    Run manually:
        powershell -ExecutionPolicy Bypass -File tests_v2\build\test_build_dist.ps1

    Or with PowerShell 7+ (if installed):
        pwsh tests_v2\build\test_build_dist.ps1

    Exit code 0 on success, non-zero on any leak or build failure.

.NOTES
    The fixture invokes build-dist with -SkipTests because
    build-dist's own test gate would otherwise recurse (run the AHK
    suite, which has nothing to do with the leak-filter logic under
    test here).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Resolve project root (this script lives at <root>/tests_v2/build/)
$projectRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
$buildScript = Join-Path $projectRoot "build-dist.ps1"

if (-not (Test-Path $buildScript)) {
    Write-Error "build-dist.ps1 not found at '$buildScript'."
    exit 1
}

Write-Host ""
Write-Host "=== test_build_dist :: SpeedKalandra release filter ===" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# Fixture layout
# ============================================================
#
# We build a minimal fake project under $env:TEMP containing:
#   - Files we EXPECT to pass through (entry .ahk, public catalog)
#   - Sentinels we EXPECT to be filtered out (one per blacklist
#     pattern in build-dist.ps1's $ExcludeFiles / $ExcludeDirs /
#     $ExcludePatterns).
#
# After running build-dist on this fixture, every sentinel must be
# absent from both the staged dir and the .zip.

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$tempBase = Join-Path $env:TEMP "sk-build-test-$timestamp-$([System.IO.Path]::GetRandomFileName().Substring(0,8))"
$fixtureDir = "$tempBase\source"
$destDir = "$tempBase\dist"
$expandDir = "$tempBase\zip-expanded"

Write-Host "Fixture root: $tempBase" -ForegroundColor Gray
Write-Host ""

# Files we WANT in the release (must survive)
$mustKeep = @{
    "speedkalandra.ahk"         = "; minimal fixture entry point"
    "data\zones.csv"            = "Name,InternalId,Act,IsTown`nMud Burrow,G1_town,1,0"
    "src_v2\version.ahk"        = "global VERSION := `"test`""
}

# Sentinels we MUST NOT see in the release
$mustFilter = @{
    "speedkalandra.ini"                = "[General]`nlogFile=C:\private\Client.txt`ncharacterName=PersonalUser"
    "speedkalandra_zones.txt"          = "Mud Burrow=215000"
    "data\personal_bests.ini"          = "[Run]`nBestMs=999999"
    "data\personal_bests.ini.bak"      = "[Run]`nBestMs=999999"
    "data\speedkalandra.log"           = "2026-05-18 12:00:00 INFO sensitive log line"
    "data\run_state.ini"               = "[RunState]`nRunId=in-progress"
    "data\runs\fake_run.ini"           = "[meta]`nrunId=fake_run"
    "data\deaths.csv"                  = "ts;zoneName;patch;profile`n`"2026-05-20 14:32:11`";`"Mud Burrow`";`"0.4`";`"PersonalBuild`""
    "Client.txt"                       = "[INFO Client 1234] sensitive game log copy"
    "Client - alt.txt"                 = "another copy"
    "debug\diag.log"                   = "internal debug"
    "debug\inner\nested.txt"           = "nested under debug"
    "BKP\backup.txt"                   = "old backup"
    "_LIXEIRA\garbage.txt"             = "trashcan"
    "runs\legacy.csv"                  = "legacy CSV history"
    ".gitignore"                       = "*.tmp"
    "ARCHITECTURE.md"                  = "# Architecture (dev-only)"
    "AUDITORIA-PRODUCAO.md"            = "# Internal audit notes"
    "README.md"                        = "# Source README (dev)"
    "src_v2\README.md"                 = "# Source tree map (dev)"
    "build-dist.ps1"                   = "# self - must not be in dist"
    "build-dist.bat"                   = "@echo off"
    "some.bak"                         = "backup"
    "scratch.tmp"                      = "temp"
    ".vscode\settings.json"            = "{}"
    ".git\config"                      = "[core]"
    ".github\workflows\test.yml"       = "name: tests`non: push"
    ".github\ISSUE_TEMPLATE\bug.md"    = "# Bug report template"
    "tests_v2\run_tests.ahk"           = "; AHK test runner"
    "tests_v2\unit\domain\dummy.ahk"   = "; nested test file"
    "tests_v2\build\test_build_dist.ps1" = "# self-test of this very script"
    # Catch-all for data/ — anything under data/ that's not
    # data/zones.csv must be filtered out, mirroring .gitignore's
    # `data/* !data/zones.csv` rule. Two sentinels: a name not on
    # any explicit exclude list (proves the catch-all works for
    # future personal files we haven't anticipated), and a name
    # matching the .gitignore `data/zone_totals*.txt` pattern.
    "data\notes_for_myself.md"         = "# personal notes the user dropped here"
    "data\zone_totals_2024.txt"        = "Mud Burrow=215000"
    # exports/ is now wholesale excluded (was leaking before)
    "exports\my_run_2026-05-20.json"   = '{"runs":[]}'
    "exports\nested\sub_export.json"   = '{"runs":[]}'
}

function New-Sentinel {
    param([string]$Base, [string]$Rel, [string]$Content)
    $full = Join-Path $Base $Rel
    $dir = Split-Path $full -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -Path $full -Value $Content -Encoding UTF8 -NoNewline
}

try {
    # ============================================================
    # Build the fixture
    # ============================================================

    New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null
    Write-Host "Building fixture..." -ForegroundColor Cyan

    foreach ($rel in $mustKeep.Keys) {
        New-Sentinel -Base $fixtureDir -Rel $rel -Content $mustKeep[$rel]
    }
    foreach ($rel in $mustFilter.Keys) {
        New-Sentinel -Base $fixtureDir -Rel $rel -Content $mustFilter[$rel]
    }

    # Copy the real build-dist.ps1 into the fixture so it runs in the
    # fixture's working directory (its self-exclusion targets the
    # script's own filename, not its absolute path).
    Copy-Item -LiteralPath $buildScript -Destination (Join-Path $fixtureDir "build-dist.ps1")

    $totalIn = (Get-ChildItem -Path $fixtureDir -Recurse -File).Count
    Write-Host "  Fixture: $totalIn files ($($mustKeep.Count) must-keep + $($mustFilter.Count) sentinels + build-dist.ps1)" -ForegroundColor Gray
    Write-Host ""

    # ============================================================
    # Run build-dist against the fixture
    # ============================================================

    # Violations / missing accumulate across BOTH scenarios A and B.
    # Declared here (before scenario A) so a scenario-B finding is
    # not silently zeroed by a redundant initialization between the
    # scenarios and the assertion phase below.
    $violations = @()
    $missing = @()

    Write-Host "Scenario A: build-dist.ps1 -Zip -Force -SkipTests..." -ForegroundColor Cyan
    $fixtureBuildScript = Join-Path $fixtureDir "build-dist.ps1"

    # Invoke in the fixture dir so $PSScriptRoot resolves to the
    # fixture, not the real project.
    Push-Location $fixtureDir
    try {
        # Reset $LASTEXITCODE before the call. With -SkipTests,
        # build-dist.ps1 doesn't invoke any external process, so it
        # never sets $LASTEXITCODE on its own — the variable keeps
        # whatever value the last unrelated external command left
        # behind. Without this reset, a stale non-zero $LASTEXITCODE
        # from some earlier shell command would make the success
        # check below report a false failure even when the build is
        # completely clean.
        $global:LASTEXITCODE = 0
        & $fixtureBuildScript -DestDir $destDir -Zip -Force -SkipTests | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "build-dist.ps1 returned exit code $LASTEXITCODE."
            exit 1
        }
    }
    finally {
        Pop-Location
    }
    Write-Host ""

    # ============================================================
    # Scenario B: -AhkPath pointing at a non-existent file aborts
    # ============================================================
    #
    # Companion check: build-dist must refuse to package when the
    # explicit -AhkPath doesn't exist. Without this guard, a CI
    # environment with a misconfigured path could silently fall
    # through to whatever AutoHotkey64.exe is on PATH (or, worse,
    # to no AHK at all if PATH is empty) and produce a release
    # blessed by the wrong tool version.
    #
    # The check runs WITHOUT -SkipTests so that the Resolve-AhkPath
    # branch in build-dist.ps1 actually executes. The bogus path is
    # rejected by Test-Path BEFORE any AHK invocation, so this test
    # does not need a real AHK install — the failure must come from
    # the resolution step, not from a missing test runner.
    #
    # If the resolution were ever changed to fall back to the
    # standard install paths when the explicit -AhkPath misses (the
    # "convenience" alternative discussed in the function comment),
    # this assertion would catch it: a CI runner with AHK installed
    # would pass the gate and proceed to copying files, and the
    # exit code would no longer be non-zero.

    Write-Host "Scenario B: bogus -AhkPath aborts the build..." -ForegroundColor Cyan
    $destDir2 = "$tempBase\dist-scenario-b"
    $bogusAhk = "C:\definitely\not\exists\fake_ahk_$($timestamp).exe"
    Push-Location $fixtureDir
    try {
        # Two viable "refused" paths from build-dist.ps1, both valid:
        #   1. exit 1 reached: $LASTEXITCODE = 1, no exception thrown.
        #   2. Write-Error fires under $ErrorActionPreference = "Stop"
        #      and becomes a terminating error that propagates through
        #      the `&` call. The exit statement after Write-Error is
        #      never reached; $LASTEXITCODE stays at whatever the
        #      previous external command set.
        # Both end with no dest dir created — that's the assertion
        # we anchor on. The inner try/catch keeps the terminating
        # error from propagating up through this script's own
        # outer try/finally, which would otherwise short-circuit
        # the assertion phase below.
        $global:LASTEXITCODE = 0
        $bogusRefused = $false
        try {
            # 2>&1 | Out-Null suppresses the Write-Error rendering
            # when build-dist exits cleanly via `exit 1`. Under the
            # Stop-preference terminating path the redirect doesn't
            # apply (the error becomes an exception before reaching
            # the pipeline), so the catch below is what actually
            # silences that case.
            & $fixtureBuildScript -DestDir $destDir2 -AhkPath $bogusAhk -Force 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $bogusRefused = $true
            }
        }
        catch {
            # Terminating error from Write-Error under Stop preference.
            # This is one of the two legitimate refusal paths and
            # counts as success for the assertion.
            $bogusRefused = $true
        }

        if (-not $bogusRefused) {
            $violations += "build-dist with -AhkPath '$bogusAhk' should have refused (non-zero exit or terminating error) but completed cleanly"
        }
        else {
            Write-Host "  build-dist correctly refused" -ForegroundColor Gray
        }
        if (Test-Path $destDir2) {
            $violations += "build-dist with bogus -AhkPath should NOT create dest dir '$destDir2'"
        }
    }
    finally {
        Pop-Location
    }
    Write-Host ""

    # ============================================================
    # Assertions (against scenario A outputs; scenario B already
    # appended its own findings to $violations during execution)
    # ============================================================

    # 1. Sentinels must NOT be in the staged dest dir
    foreach ($rel in $mustFilter.Keys) {
        $staged = Join-Path $destDir $rel
        if (Test-Path $staged) {
            $violations += "STAGED dir contains sentinel: $rel"
        }
    }

    # 2. Sentinels must NOT be in the .zip
    $zipPath = "$destDir.zip"
    if (-not (Test-Path $zipPath)) {
        Write-Error "Expected zip not found at '$zipPath'."
        exit 1
    }

    if (Test-Path $expandDir) {
        Remove-Item -LiteralPath $expandDir -Recurse -Force
    }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $expandDir

    foreach ($rel in $mustFilter.Keys) {
        $zipped = Join-Path $expandDir $rel
        if (Test-Path $zipped) {
            $violations += "ZIP contains sentinel: $rel"
        }
    }

    # 3. Must-keep files MUST be in the .zip
    foreach ($rel in $mustKeep.Keys) {
        $zipped = Join-Path $expandDir $rel
        if (-not (Test-Path $zipped)) {
            $missing += "ZIP missing expected file: $rel"
        }
    }

    # 4. SHA256 sidecar must exist and parse
    $sidecarPath = "$zipPath.sha256.txt"
    if (-not (Test-Path $sidecarPath)) {
        $violations += "Missing SHA256 sidecar at '$sidecarPath'"
    }
    else {
        $sidecarContent = (Get-Content -LiteralPath $sidecarPath -Raw).Trim()
        if ($sidecarContent -notmatch '^[0-9a-f]{64}\s+\S+') {
            $violations += "SHA256 sidecar has unexpected format: '$sidecarContent'"
        }
        else {
            # Verify the hash matches the actual zip
            $expectedHash = ($sidecarContent -split '\s+', 2)[0]
            $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()
            if ($expectedHash -ne $actualHash) {
                $violations += "SHA256 mismatch: sidecar=$expectedHash, actual=$actualHash"
            }
        }
    }

    # ============================================================
    # Report
    # ============================================================

    if ($violations.Count -eq 0 -and $missing.Count -eq 0) {
        Write-Host "=== PASS ===" -ForegroundColor Green
        Write-Host "  $($mustFilter.Count) sentinels correctly filtered from staged dir and .zip" -ForegroundColor Gray
        Write-Host "  $($mustKeep.Count) must-keep files correctly preserved" -ForegroundColor Gray
        Write-Host "  SHA256 sidecar produced and matches the .zip" -ForegroundColor Gray
        exit 0
    }

    Write-Host "=== FAIL ===" -ForegroundColor Red
    foreach ($v in $violations) {
        Write-Host "  $v" -ForegroundColor Red
    }
    foreach ($m in $missing) {
        Write-Host "  $m" -ForegroundColor Yellow
    }
    exit 1
}
finally {
    # ============================================================
    # Cleanup (always)
    # ============================================================
    if (Test-Path $tempBase) {
        try {
            Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not fully clean up fixture at '$tempBase': $_"
        }
    }
    # The zip and sidecar live alongside $destDir, not inside it; clean them too.
    if (Test-Path "$tempBase.zip") {
        Remove-Item -LiteralPath "$tempBase.zip" -Force -ErrorAction SilentlyContinue
    }
}
