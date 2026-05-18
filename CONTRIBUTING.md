# Contributing

Thanks for considering it.

## Set expectations

I'm not actively maintaining this as a product. I work on it when I feel like it. Response times to issues and PRs will be slow — sometimes very slow. That's not me being rude, it's just the deal. I do read everything eventually.

## Reporting bugs

Open a GitHub issue with:

- **Version** — hover the tray icon, it shows `SpeedKalandra vX.Y.Z`
- **What you did** — sequence of actions to reproduce
- **What you expected** vs **what happened**
- **Log snippet** from `data/speedkalandra.log` around the issue timestamp (the file rotates at 5MB; if you can't find the timestamp, attach the whole file)

For bugs that depend on event order or timing, you can enable detailed event tracing first: set `EventTracingEnabled=1` under `[Diagnostics]` in `speedkalandra.ini`, reproduce the bug, then attach the log. Be aware that the trace includes raw lines from `Client.txt` (character names, zones visited), so review the file before posting publicly.

If you can reproduce it consistently, say so. If it happened once and went away, describe the conditions.

## Suggesting features

Open an issue with `[feature request]` in the title. Make a case for why it fits this tool's philosophy:

- **Minimalist** — focused on speedrun timing and visualization
- **Read-only** in relation to PoE2 — never sends inputs or modifies game state
- **No gameplay assistance** — not a build planner, not a loot tracker, not a trade tool

I might still say no, but I'll consider it.

## Code contributions

For non-trivial changes, open an issue first to check it's a direction I'd merge. Typos, obvious bugs, and doc improvements — just send the PR directly.

### Dev setup

1. Install [AutoHotkey v2](https://www.autohotkey.com/) (it must be v2, not v1)
2. Clone the repo
3. Open `speedkalandra.ahk` to test, edit files in `src_v2/`
4. Automated test suite under `tests_v2/` (~1569 tests, pure AHK v2, no external deps). Run with `"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" tests_v2\run_tests.ahk`. Add tests for new behavior under `tests_v2/unit/<layer>/` — see `tests_v2/README.md` for conventions and the assertion API.
5. The same suite runs on GitHub Actions for every push and PR (see `.github/workflows/test.yml`); the badge at the top of the README shows the latest status. To replicate the CI invocation locally, set `$env:SPEEDKALANDRA_TEST_NO_GUI="1"` before the command above — the final MsgBox is suppressed and the process exits with `0` on green, `1` on red.

### Style

- Match surrounding code: indentation, naming, structure, comment style
- New services go in `src_v2/app/services/`. Inject dependencies via constructor
- Validate types in constructors with `is ClassName` checks
- Avoid `try` without `catch` — use `catch as ex { OutputDebug(...) }` at minimum

### Architecture orientation

Start with [`src_v2/README.md`](src_v2/README.md) for a map of the source tree. The full architectural tour is in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Forks

Forks are welcome. GPL v3 requires forks remain open-source under the same license — that's the only constraint.

## What I won't merge

- Code that injects into the PoE2 process or sends inputs to the game
- Gameplay assistance features (build planners, loot filters, trade automation)
- Telemetry that phones home
- Ads or monetization integrations within the tracker itself
