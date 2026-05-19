# Release process

SpeedKalandra releases are produced by a tag-triggered GitHub Actions
workflow at `.github/workflows/release.yml`. The build runs the full
AHK test suite as a release gate, filters personal data out of the
distribution, compiles `speedkalandra.ahk` to `.exe`, and uploads a
zip + SHA256 sidecar as a **draft** release for the maintainer to
review and publish manually.

## Creating a new release

1. Make sure `main` is green (the `tests` workflow passes).
2. Update `CHANGELOG.md` under a new `## [vX.Y.Z]` heading describing
   what changed since the previous tag.
3. Update `src_v2/version.ahk` if the displayed version constant needs
   to match the new tag.
4. Commit and push the changes to `main`.
5. Tag the head of `main` and push the tag:

       git tag v0.2.0
       git push origin v0.2.0

6. The `release` workflow starts automatically. It will:
   - Install AutoHotkey v2 on a Windows runner.
   - Run `tests_v2/build/test_build_dist.ps1` (validates the build
     script itself, including `-AhkPath` resolution).
   - Run `build-dist.ps1 -Compile -Zip -Force`, which runs the full
     AHK test suite as a gate; a red suite aborts the release.
   - Rename the artifacts to `SpeedKalandra-vX.Y.Z.zip` and
     `SpeedKalandra-vX.Y.Z.zip.sha256.txt`.
   - Create a **draft** release on GitHub with both files attached.
7. Open *Releases* on GitHub, find the draft, verify the artifacts
   are present and the SHA256 line in the sidecar matches the zip.
   Edit the release notes if needed, then click **Publish release**.

## Manually triggering the workflow

The workflow also accepts `workflow_dispatch` for re-running against
an existing tag (useful if the first run failed mid-way and you
deleted the draft to retry):

1. Go to **Actions** → **release** workflow → **Run workflow**.
2. Enter the tag name (e.g. `v0.2.0`). The tag must already exist on
   the repository.
3. Click **Run workflow**.

## Building locally

`build-dist.ps1` produces the same artifacts a release would, minus
the GitHub draft step. Useful for testing changes to the build
itself before tagging:

    .\build-dist.ps1 -Compile -Zip -Force

Output (in the project's parent directory by default):

- `..\SpeedKalandra-dist\`           — staged tree
- `..\SpeedKalandra-dist.zip`        — packaged zip
- `..\SpeedKalandra-dist.zip.sha256.txt` — SHA256 sidecar

If AutoHotkey v2 is installed in a non-standard location, pass
`-AhkPath`:

    .\build-dist.ps1 -AhkPath "D:\Apps\AHK\v2\AutoHotkey64.exe" -Compile -Zip -Force

The script tries, in order:

1. The explicit `-AhkPath` value (if provided; must exist or the
   script aborts — it does NOT silently fall back to PATH, so a
   misconfigured CI runner is loud rather than quiet).
2. The standard install locations
   (`%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe`,
   `%LOCALAPPDATA%\Programs\AutoHotkey\...`, etc.).
3. `AutoHotkey64.exe` on PATH.

For local iteration that doesn't need to validate against the test
suite, pass `-SkipTests` (not for releases):

    .\build-dist.ps1 -Zip -Force -SkipTests

## Validating the build script itself

`tests_v2/build/test_build_dist.ps1` exercises `build-dist.ps1` against
an isolated fixture in `$env:TEMP` and asserts that the personal-data
filter, the SHA256 sidecar, and the `-AhkPath` resolution behave as
documented. It does NOT need AutoHotkey installed (scenario A runs
with `-SkipTests`, scenario B aborts before any AHK invocation).

Run on Windows (default PowerShell 5.1):

    powershell -ExecutionPolicy Bypass -File tests_v2\build\test_build_dist.ps1

With PowerShell 7+ (if installed):

    pwsh tests_v2\build\test_build_dist.ps1

Exit code is 0 on success, non-zero on any leak or build failure. The
`tests` workflow runs this on every push and PR; the `release`
workflow runs it again at the start of every tagged release.

## Release gates

A release cannot be produced if any of the following are true:

- **AHK test suite is red.** `build-dist.ps1` runs the suite before
  packaging and aborts on non-zero exit. The release workflow does
  not pass `-SkipTests`.
- **`test_build_dist.ps1` is red.** Runs in the `tests` workflow on
  every push and again at the start of the release workflow. Catches
  regressions in the filter (a personal-data sentinel would leak
  into the zip), the SHA256 sidecar format, or the `-AhkPath`
  resolution.
- **AutoHotkey v2 is not installed.** `build-dist.ps1` fails fast
  unless `-SkipTests` is passed; the release workflow installs AHK
  v2 via Chocolatey before invoking the script.

## Verifying a downloaded release

Linux / macOS:

    sha256sum -c SpeedKalandra-vX.Y.Z.zip.sha256.txt

Windows (PowerShell):

    Get-FileHash SpeedKalandra-vX.Y.Z.zip -Algorithm SHA256

The hex digest from `Get-FileHash` (lowercased) must match the
first field in the sidecar file.

## Troubleshooting

**The release workflow fails with "AHK v2 not found".**
The Chocolatey install step succeeded but the AHK binary landed in
an unexpected location. Check the workflow log of the **Install
AutoHotkey v2** step. The `Resolve-AhkPath` function inside
`build-dist.ps1` covers the common install locations; if Chocolatey
changes its layout, that function needs updating.

**The release draft is created but the assets are missing.**
The `gh release create` step uploads the zip and sidecar in the
same call that creates the draft. If the upload failed, the draft
still exists but is empty. Re-run the workflow via
`workflow_dispatch` with the same tag, or delete the draft and let
the next workflow run recreate it.

**`sha256sum -c` reports mismatch.**
The sidecar was not regenerated after the artifact rename. The
release workflow regenerates the sidecar against the renamed zip;
if a downloader sees mismatch, the upload was corrupted in transit
and the zip should be re-downloaded.

**The build runs but the `.exe` is missing.**
`Ahk2Exe.exe` was not found in the standard install locations. The
workflow log of the `build-dist.ps1` step will show a warning. The
`.exe` is optional — the zip ships the `.ahk` entry point as a
fallback, and end users with AHK v2 installed can run that
directly. If you need the `.exe`, install the AutoHotkey Compiler
addon and re-run.
