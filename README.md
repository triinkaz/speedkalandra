# SpeedKalandra

A minimalist Path of Exile 2 speedrun tracker for Windows.

> **Status**: Personal project, slow response times. See [disclaimer](#disclaimer) below.

---

## What it does

- Times your campaign runs with per-zone breakdowns
- Reads `Client.txt` for zone transitions and deaths
- Three configurable overlays: **Compact** (full info), **Micro** (minimal), **Steve** (timer-focused)
- Tracks personal bests per zone, per act, and per full run
- Detects loading screens via pixel scanning to isolate that time from gameplay
- Auto-finalize on configurable regex trigger (e.g. last-boss kill line)
- Crash recovery — re-hydrates run state on relaunch

## Game language

The auto-start and auto-finalize features rely on regex matches against lines in `Client.txt`. The default auto-start regex matches a Wounded Man line from the **English** PoE2 client. If your game is in another language, either:

- Edit the regex strings in **Settings** to match the equivalent lines in your locale, **or**
- Leave them empty and use the manual hotkeys instead (`Ctrl+Alt+N` to start, `Ctrl+Alt+F` to finalize).

Everything else (zone detection, deaths, loading screens, level changes, personal bests) works regardless of client language — it relies on stable text fragments and pixel patterns that don't change with locale.

## Disclaimer

SpeedKalandra is a personal project by a player, not a developer.

I built this because some functionality was missing from the overlays available during my runs, and I wanted something for my own use that other players might also find useful.

Yes, I know other speedrun trackers exist, some maintained by teams. I don't care if there are 10 other people working on this — I'm not trying to compete with them. I'm doing this because it's fun, and because I want a tracker that works the way I want it to.

The code was written with substantial help from AI. I directed what I wanted, reviewed the output, tested in actual runs, and iterated when things broke. I keep this disclaimer because AI-assisted development should be transparent — but the project is real, maintained, and tested.

**Use at your own risk.** Bugs are likely. Don't expect fast support.

**Anti-cheat / TOS**: The tool only reads the PoE2 `Client.txt` log file and captures pixel colors from the screen for loading detection. It does not inject into the game process, modify game files, or send inputs to the game. To my knowledge this is within typical overlay/tracker territory, but I make no guarantees — use it understanding that ultimately you're responsible for what runs on your machine while playing.

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

~1569 tests covering core primitives, domain, persistence, services, UI bases, and end-to-end app wiring. Output goes to `tests_v2/tests_output.log` plus a final MsgBox with the pass/fail count. Filter by substring: `AutoHotkey64.exe tests_v2\run_tests.ahk EventBus`. Conventions and assertion API are in [`tests_v2/README.md`](tests_v2/README.md).

## Architecture

[`ARCHITECTURE.md`](ARCHITECTURE.md) is the design tour: layered structure (`core` / `domain` / `infra` / `app` / `ui`), the EventBus, run persistence, run history format, AHK v2 pitfalls encoded in the code. [`src_v2/README.md`](src_v2/README.md) is a shorter map of the source tree.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). TL;DR: PRs welcome, response times are slow, set expectations accordingly.

## Changelog

See [`CHANGELOG.md`](CHANGELOG.md) for release notes.

## License

GPL v3. See [`LICENSE`](LICENSE). Forks are welcome but must remain open-source under the same license.
