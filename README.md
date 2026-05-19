# SpeedKalandra

[![tests](https://github.com/triinkaz/speedkalandra/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/triinkaz/speedkalandra/actions/workflows/test.yml)

A minimalist Path of Exile 2 speedrun tracker for Windows.

> **Status**: Independent project; response times depend on availability. See [disclaimer](#disclaimer) below.

---

## What it does

- Times your campaign runs with per-zone breakdowns
- Reads `Client.txt` for zone transitions and deaths
- Three configurable overlays: **Compact** (full info), **Micro** (minimal), **Steve** (timer-focused)
- Tracks personal bests per zone, per act, and per full run
- Detects loading screens via pixel scanning to isolate that time from gameplay
- Auto-finalize on configurable regex trigger (e.g. last-boss kill line)
- Crash recovery — re-hydrates run state on relaunch

## Game language: English client only

PoE2 translates `Client.txt` to the UI language, and SpeedKalandra parses English text fragments throughout: zone transitions (`[SCENE] Set Source`), deaths (`has been slain`), level-ups (`is now level`), area changes (`Generating level N area X with seed`), focus markers (`[WINDOW] Lost focus`), and the auto-start/auto-finalize regex defaults. On a non-English client these patterns never match, which means per-zone tracking, death counting, level tracking, and the auto triggers all stay silent.

The auto-start and auto-finalize regexes can be edited in **Settings** to match the equivalent lines in your locale; the manual hotkeys (`Ctrl+Alt+N` to start, `Ctrl+Alt+F` to finalize) also work. The pixel-based loading detector is language-agnostic — a non-English user can time runs manually with loading isolation, but the core campaign-tracking experience assumes English.

## Disclaimer

SpeedKalandra is an independent personal project. It reads Path of Exile 2's `Client.txt` log file and samples pixel colors on screen for loading detection — it does not inject into the game process, modify game files, or send gameplay inputs. The only key-level action it issues is a defensive `{Ctrl up}{Alt up}{Shift up}{LWin up}{RWin up}` on script exit, which releases modifiers if AHK happens to terminate while you're holding a hotkey (`SpeedKalandraOnExitHandler` in `speedkalandra.ahk`). This is OS-level housekeeping, not addressed at the game. To the best of my knowledge this falls within typical overlay/tracker territory, but I make no guarantees; use it understanding that you are responsible for what runs on your machine while playing.

The codebase was developed with significant AI assistance. Every change was reviewed, tested in real runs, and is covered by an automated test suite that runs on CI for every commit (see the badge above). I keep this disclaimer because AI-assisted development should be transparent — the project itself is real, maintained, and validated.

Use at your own risk. Issues and pull requests are welcome; response times depend on availability.

## Installation

### From source

1. Install [AutoHotkey v2](https://www.autohotkey.com/) (it must be v2, not v1)
2. Clone this repo (or download as ZIP and extract)
3. Double-click `speedkalandra.ahk`
4. Right-click the tray icon → **Settings** → set the path to your PoE2 `Client.txt`
   - Typical location: `C:\Program Files (x86)\Grinding Gear Games\Path of Exile 2\logs\Client.txt`

### Packaged distribution

Run `build-dist.ps1` to generate a self-contained `SpeedKalandra-dist/` folder you can zip and share. Use `-Compile` to also produce a standalone `.exe` (requires AutoHotkey's Ahk2Exe tool).

## Default hotkeys

| Hotkey | Action |
|---|---|
| `Ctrl+3` | Toggle timer (pause/resume current run) |
| `Ctrl+Alt+N` | New run (cancels current) |
| `Ctrl+Alt+F` | Finalize run (saves to history, updates PB) |
| `Ctrl+5` | Reset (cancels current without saving) |
| `Ctrl+Alt+P` | Open run plot |
| `Ctrl+Alt+S` | Open settings |
| `F8` | Toggle overlay visibility |
| `Ctrl+F9` | Toggle Micro mode |
| `Ctrl+F8` | Toggle Steve mode |

All hotkeys are remappable in Settings.

**Overlay interaction**: hold `Ctrl` to drag, resize, or click buttons on the overlay. Without `Ctrl`, clicks pass through to the game.

## Persisted data (created on first run)

| File | Purpose |
|---|---|
| `speedkalandra.ini` | Configuration |
| `data/personal_bests.ini` | PBs per zone, per act, and full run |
| `data/runs/{runId}.ini` | One file per finalized run (history) |
| `data/speedkalandra.log` | Execution log (rotates at 5MB) |

These are gitignored — they stay on your machine.

## Testing

The project ships with a self-contained AHK v2 test suite under `tests_v2/` (no external dependencies). Run it with:

```
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" tests_v2\run_tests.ahk
```

An automated test suite covers core primitives, domain, persistence, services, UI bases, and end-to-end app wiring. Output goes to `tests_v2/tests_output.log` plus a final MsgBox with the pass/fail count. Filter by substring: `AutoHotkey64.exe tests_v2\run_tests.ahk EventBus`. Conventions and assertion API are in [`tests_v2/README.md`](tests_v2/README.md).

## Architecture

[`ARCHITECTURE.md`](ARCHITECTURE.md) is the design tour: layered structure (`core` / `domain` / `infra` / `app` / `ui`), the EventBus, run persistence, run history format, AHK v2 pitfalls encoded in the code. [`src_v2/README.md`](src_v2/README.md) is a shorter map of the source tree.

## Known limitations

[`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) lists design constraints (atomic-write window, loading detection assumes default HUD position, English-client-only parser, no boss detection). Worth a glance before opening an issue.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). TL;DR: issues and PRs welcome; response times depend on availability.

## Changelog

See [`CHANGELOG.md`](CHANGELOG.md) for release notes.

## License

GPL v3. See [`LICENSE`](LICENSE). Forks are welcome but must remain open-source under the same license.
