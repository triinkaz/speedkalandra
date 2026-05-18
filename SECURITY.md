# Security Policy

SpeedKalandra is a personal, local-first AutoHotkey v2 desktop tool. This document describes what counts as a security issue in this project and how to report one privately.

## Threat model

SpeedKalandra runs on the user's Windows machine while Path of Exile 2 is open. It:

- Reads `Client.txt` from a path the user configures.
- Samples pixel colors from the game window via `PixelGetColor`.
- Writes its own state to files inside the project directory (`speedkalandra.ini`, `data/personal_bests.ini`, `data/runs/{runId}.ini`, `data/speedkalandra.log`).
- Registers global hotkeys.
- Optionally runs a `SetTimer` loop that polls the active window.

It does **not** make network calls of any kind, embed analytics, phone home, accept incoming connections, or modify the game process or its files. There is no telemetry. There is no auto-update.

A "security issue" in this project is a deviation from those properties.

## Supported versions

| Version              | Supported   |
| -------------------- | ----------- |
| Latest on `main`     | Yes         |
| Older tagged releases| Best effort |
| Forks / modified builds | No, see below |

Forks and modified builds are out of scope: GPL allows anyone to redistribute SpeedKalandra under the same license, but I cannot vouch for what someone else has compiled or modified. If you got a build from anywhere other than this repository or its official releases, treat the upstream maintainer of that fork as the contact.

## In scope

The following are security issues and should be reported through the private channel below:

- **Unexpected network activity.** Any HTTP request, DNS lookup, TCP/UDP connection, or named-pipe IPC originating from a stock build.
- **Private data leakage.** Anything that causes character names, run history, file paths, or screen-captured pixels to leave the local machine (logged to a third-party service, copied to a network share, attached to outgoing traffic, etc.).
- **Unsafe file writes outside the project directory.** The app writes to `<install>/data/`, `<install>/speedkalandra.ini`, `<install>/speedkalandra_zones.txt`, and `<install>/exports/`. Writes anywhere else (`%SystemRoot%`, user home, AppData, registry) are a bug.
- **Release package including personal files.** A distributed `.zip` or `.exe` that contains `speedkalandra.ini` from the maintainer's machine, real `data/personal_bests.ini`, `data/runs/*.ini`, `Client.txt`, debug logs, or any other private artifact.
- **Malicious behavior in distributed artifacts.** Any difference between the source on `main` and what an official release does (loaded DLLs, embedded scripts, modified binaries).
- **Privilege escalation or arbitrary code execution from untrusted input.** E.g. crafting a `Client.txt` line that causes SpeedKalandra to execute shell commands. This is unlikely given the parsing surface but counts if anyone finds it.

## Out of scope

The following are bugs (sometimes serious bugs) but are not security issues. Open a regular GitHub issue for them:

- **Incorrect timing, splits, or stats.** Off-by-N timer behaviour, wrong zone attribution, missed loading screens, wrong PB rebuilds — these are correctness bugs, not security bugs.
- **Crashes that don't leak data.** A crash that takes the overlay down without compromising files or sending anything out is a stability bug.
- **Game log format changes.** PoE2 patches that change the `Client.txt` line shape and break parsing.
- **Hotkey conflicts.** Global hotkeys colliding with other apps.
- **Antivirus false positives** for the .exe build, unless you can demonstrate a reproducible unsafe behaviour in the binary.
- **Anything in a fork.** See "Supported versions" above.
- **Anti-cheat / TOS questions.** SpeedKalandra is read-only relative to the game and does not inject or send inputs (see [README.md § Disclaimer](README.md#disclaimer)). Whether GGG's anti-cheat treats overlays in general as acceptable is between you and GGG; I make no claim either way.

## Reporting a vulnerability

If you believe you have found an in-scope issue, please **do not open a public GitHub issue with the details**. Send a private report through either of:

- Discord DM: `trinka45642`

Include:

- Affected version (tray icon shows `SpeedKalandra vX.Y.Z`, or commit SHA if you built from source).
- Operating system and AutoHotkey version.
- A clear description of the behaviour and what about it is unsafe.
- Reproduction steps where possible.
- Any logs or captures relevant to the report (please review for personal data before attaching).

I'll acknowledge receipt within a reasonable window given that this is a personal project. Once a fix lands on `main`, the report can become public.

## Disclosure preferences

- Coordinated disclosure is preferred — a private report, a fix, then a public note crediting the reporter if they want credit.
- Embargoes for issues that affect only this project's users (no third-party impact) are generally short: as long as it takes to land the fix and tag a release.
- If a reported issue turns out to be out of scope, I'll say so explicitly rather than ignore it.
