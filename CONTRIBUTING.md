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
4. There is no automated test suite (the legacy one is archived in `_LIXEIRA/`, gitignored). Test manually against your own PoE2 logs.

### Style

- Match surrounding code: indentation, naming, structure, comment style
- New services go in `src_v2/app/services/`. Inject dependencies via constructor
- Validate types in constructors with `is ClassName` checks
- Avoid `try` without `catch` — use `catch as ex { OutputDebug(...) }` at minimum
- Tag changes with `; v17.X.Y` in comments where relevant for traceability

### Architecture orientation

Start with [`src_v2/README.md`](src_v2/README.md). For deeper history (waves of demolition from older paradigms) see `ARCHITECTURE.md`.

## Forks

Forks are welcome. GPL v3 requires forks remain open-source under the same license — that's the only constraint.

## What I won't merge

- Code that injects into the PoE2 process or sends inputs to the game
- Gameplay assistance features (build planners, loot filters, trade automation)
- Telemetry that phones home
- Ads or monetization integrations within the tracker itself
