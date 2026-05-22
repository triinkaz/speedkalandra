# Plus Layouts — Design Specification

Specification for the **Plus** variant of the three overlay layouts
(`CompactLayoutPlusWidget`, `SteveLayoutPlusWidget`,
`MicroLayoutPlusWidget`), enabled via the `cfg.layoutVariant` opt-in
flag.

This document is the source of truth during implementation. When code
and this document disagree, the disagreement is resolved here first.

---

## Scope

- Three new widget classes co-existing with the current Classic widgets
- Feature flag in `AppSettings` + checkbox in `SettingsDialog`
- Palette aliases (`pb`, `map`, `loading`, `town`)

**Out of scope:**
- Removing or modifying Classic widgets
- Changing the run lifecycle, persistence formats, or services
- Per-widget granular toggles (single flag controls all three)
- Resize-by-dragging-borders — see §7 below.

---

## 1. Feature flag

```ahk
; src_v2/domain/app_settings.ahk
cfg.layoutVariant := "classic"   ; "classic" | "plus" — default classic
```

INI mapping:
```
[Layouts]
Variant=classic
```

Settings dialog gains one checkbox: `☐ Use experimental "Plus" layouts (BETA)`.
Checking it sets `Variant=plus`. **A restart is required** to apply
(toast on save: "Restart SpeedKalandra to apply the layout change.").

Composition root in `app.ahk` branches on `cfg.layoutVariant` when
instantiating the three layout widgets — Classic and Plus classes never
co-exist at runtime.

---

## 2. Shared with Classic

The Plus variants share with Classic:

- **`WIDGET_ID`**: `"compactLayout"`, `"microLayout"`, `"steveLayout"` (same keys
  in `[Overlay]` INI section). Position and scale persist across variant changes.
- **Base sizes** (FIXED_W × FIXED_H):
  - Compact Plus: **380×96**
  - Steve Plus:   **380×64**
  - Micro Plus:   **200×32**
- **Bus subscriptions**: same events (`Tick`, `ZoneEntered`, `DeathDetected`, etc.)
- **`LayoutWidgetBase`** as parent class

The Plus widgets are drop-in replacements for the Classic ones at the
composition-root level — no contract changes downstream.

---

## 3. Palette aliases

New entries in `Theme._COLORS`:

| Alias | Hex | Used for |
|---|---|---|
| `pb` | `2DD4BF` | PB labels and values (teal — distinct from `good`/`goodStrong` which mark timer state) |
| `map` | `38BDF8` | Map portion of distribution bar |
| `loading` | `FACC15` | Loading portion of distribution bar |
| `town` | `A78BFA` | Town portion of distribution bar (= legacy `purple`) |

The existing `accent` (`D8492F`), `text` (`E8E2D6`), `muted` (`A49C91`),
`subtle` (`6E6962`), `surface` / `surface2` / `surface3`, `goodStrong`
(`4ADE80`), `warn` (`F59E0B`), `danger` (`F87171`), `line` (`3A3330`)
are reused unchanged.

---

## 4. Fields shown — final inventory

After all the decisions in this spec, the Plus widgets show:

### 4.1 Compact Plus

```
+---------------------------------------------------------------+
| ACT 1  Clearfell                                          [1] |  <- line 1
|                                                           [2] |
|        ┌──────────┐  ┌──────────┐                         [3] |  <- center blocks
|        │ ZONE     │  │ RUN      │                             |
|        │ 00:28    │  │ 03:33    │                             |
|        │ PB 00:28 │  │ PB 03:33 │                             |
|        └──────────┘  └──────────┘                             |
| × 0  XP                                                       |  <- chips
| ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓     |  <- distribution
+---------------------------------------------------------------+
```

**Fields:**
- `ACT N` (label `accent`)
- `zoneName` (canonical from catalog; raw string passthrough if unknown)
- **ZONE block**: timer (mono, condicional color) + sub-label `PB MM:SS` (color `pb`, or `--:--` muted if no PB)
- **RUN block**: timer (mono, condicional color) + sub-label `PB MM:SS` (color `pb`, or `--:--` muted if no PB)
- **Chips** (only two): `× N` (mortes, muted when 0, warn when ≥1) and `XP` (color-only via `XpRules`, no text)
- **V1/V2/V3 buttons**: kept vertically on the right (muted/subtle styling — they exist, don't compete)
- **Distribution bar**: full-width footer, colors `map` / `loading` / `town`. Empty/blank before first transition.

**Removed vs Classic**: `Lv N`, `LOAD %`, `TOWN %` text chips, `Area N` field.

**Block sizing**: ZONE and RUN blocks are larger than the Classic equivalents
because the chip row is much sparser. The freed vertical/horizontal space is
absorbed by the two blocks (larger timer font + more padding).

### 4.2 Steve Plus

```
+---------------------------------------------------------------+
| ACT 1 · Clearfell                                             |
|                                            03:33.42           |  <- timer mono giant
| × 0   XP                                            03:33     |
| ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  |  <- 4px footer
+---------------------------------------------------------------+
```

**Fields:**
- `ACT N · zoneName` (single line, left-aligned)
- **Run timer** (mono, ~32pt at scale 1.0, conditional color)
- **Chips**: `× N` (deaths), `XP`
- **Bare PB value** (right-aligned, teal): the per-act PB of the
  current act, no `PB` or `RUN` label. Shows `—` (em-dash) if no PB
  exists for the act yet.
- **Distribution bar**: 4px high footer (no labels, just colors)

**Note on the PB value:** the right-aligned teal `MM:SS` reads from
`pbService.GetRunPbForAct(currentAct)` — the same per-act PB the LINE1
timer compares against for its goodStrong/danger color. The teal
colour against the muted chips on the left is what signals "this is
a PB-related value" — no `PB` label is needed and would just compete
with the digits for attention. The bare value rolls forward as the
runner advances through acts (PB at end of Act 1, then end of Act 2,
and so on). If a future iteration wants the literal overall-run PB
instead, `pbService.GetRunPbMs()` already exists and is populated by
`UpdateFromRun`; the swap is a one-line change in `_GetRunPbMs`.

**Label-iteration history (post-implementation).** This single slot
went through three labels before landing on "no label":
1. `PB MM:SS` chip on the left, next to the XP chip. Plus an
   identical `RUN · PB MM:SS` sublabel on the right — same per-act
   source on both, so they rendered the same number twice.
2. `PB MM:SS` chip only (left chip alone). Removed the sublabel
   because of the duplication.
3. `RUN · PB MM:SS` sublabel only (right alone). Removed the chip
   to keep the surface where the "RUN" framing was, but the framing
   was misleading on a per-act value.
4. Bare `MM:SS` value, right-aligned, teal-coloured (current). The
   teal colour already says "this is a PB"; the label was either
   redundant or actively misleading.

### 4.3 Micro Plus

```
+--------------------------------+
| 00:28  │  03:33  │  XP         |
+--------------------------------+
```

**Fields:**
- Zone timer (mono, conditional color)
- Run timer (mono, conditional color)
- `XP` (color-only, no text)
- Separators: 1px vertical line `line` (`3A3330`) between fields. No `/` `;` `·`.

**Removed vs Classic**: `Lv N`. Micro Classic showed `runTime + "Lv N"`. Plus
shows `zoneTime + runTime`, both with the conditional color treatment.

---

## 5. Dynamic behavior

| Behavior | Rule |
|---|---|
| **Conditional timer color** | Both zone and run timers get the goodStrong/danger/text colors per the current PB comparison. Applies to all three Plus widgets where the timer is present. |
| **PB without value** | Sub-label shows `PB --:--` in `muted`. The label stays visible (predictable structure). |
| **Death count = 0** | Chip shows `× 0` in `muted` (visible but de-emphasized). |
| **Unknown zone (catalog miss)** | Raw zone string accepted; truncated with `...` if it overflows the field width (see §6.b). |
| **Distribution bar before first transition** | Empty/blank surface (no fill). Fills in as `LoadingTotalsService` and `ZoneTrackingService` accumulate data. |

---

## 6. Layout responsiveness

**a) Block positioning** — Originally specified as percentages of the
current widget width/height for proportional reflow under resize. The
resize-by-border interaction that motivated this was removed (see §7
below), and the actual implementation uses static pixel offsets scaled
by `_position.scale`. The Ctrl+wheel scale change reaches every offset
uniformly, so there is no broken case left to fix — percentages are
not needed.

**b) Text overflow** — Long zone names truncate with trailing `...` (e.g.
`The Twilight Strand and...`). No font shrinking. The truncation point is
computed using `_EstimateTextW` (the same `chars × fontSize × 0.6`
estimator already used by Compact Classic).

**c) Steve Plus dimensions** — `FIXED_W := 380`, `FIXED_H := 64`, same as
Steve Classic. The faixa Map/Load/Town footer is **4 px** at scale 1.0.

---

## 7. Resize by dragging borders — **ABANDONED**

This section described a Ctrl+drag-border interaction that let the user
resize Plus widgets along the right and bottom edges, with the resulting
width/height persisted to `[Overlay].<widgetId>.width` / `.height`.

The feature was implemented, used in production for a single debug
session, and removed in full. See `CHANGELOG.md` under `### Removed`
for the three concrete problems that motivated the removal (border
hit-test conflicting with the V1/V2/V3 button column, missing
proportional reflow, redundancy with Ctrl+wheel scaling). Listed under
GSG §17 anti-regression so it can't drift back in.

Scroll wheel (`_OnWheelResize` in `LayoutWidgetBase`) is the only
resize mechanism for both Classic and Plus widgets.

---

## 8. Interaction between `scale` and `width/height` — **ABANDONED**

This section described how the resize-by-border interaction (§7) was
supposed to compose with Ctrl+wheel scaling. Both fields are gone—
`scale` is the only knob.

---

## 9. Persistence — INI changes summary

`[Layouts]` is a new section:
```
[Layouts]
Variant=classic
```

The `[Overlay]` section is unchanged from Classic (`<widgetId>.{left,top,scale,visible,centered}` + `hoverHide`). Earlier drafts of this spec added `width` / `height` keys per widget for the resize-by-border interaction; both keys were removed along with the feature itself (see §7).

---

## 10. Implementation order

Each step is one session. Don't combine.

1. **Palette aliases** in `theme.ahk`: `pb`, `map`, `loading`, `town`. No
   widget changes yet. Tests pin the 4 aliases.
2. **Feature flag** infrastructure: `AppSettings.layoutVariant`,
   `SettingsRepository._{Load,Save}Layouts`, checkbox in `SettingsDialog`,
   branch in `app.ahk` composition root. Both branches still instantiate
   the Classic widgets (no Plus class exists yet — visual no-op, tests
   prove the wiring).
3. ~~**`OverlayPosition.width/height`** + repository round-trip~~ — reverted with the resize-by-border feature (see §7).
4. ~~**Resize-by-border interaction**~~ — reverted (see §7).
5. **Steve Plus**: smallest of the three. Re-injects `loadingTotals`,
   gains chips + PB-per-act chip + 4px distribution footer + mono timer.
   Live in production behind the flag.
6. **Compact Plus**: largest. ZONE/RUN blocks, two-chip row, V1/V2/V3
   muted right side, distribution footer. Most code, most tests.
7. **Micro Plus**: smallest scope. Two timers + XP chip in three blocks
   with `line` dividers.

---

## 11. Anti-regression notes (carry forward to GSG §17 if anything sticks)

- The Plus widgets **must** share `WIDGET_ID` with Classic. A typo here
  (e.g. `"compactLayoutPlus"`) would create a parallel position entry in
  `[Overlay]` and the user's drag history would be lost on first Plus boot.
- The Plus widgets **must** preserve the existing `_BuildKalandraBand` /
  `_BuildAccentStripe` / `_SetFont` helpers from `LayoutWidgetBase`. They
  encode AHK Gui quirks (Background prefix, font color via SetFont) that
  apply equally to Plus.
- `cfg.layoutVariant` is read **once at boot**. The composition root reads
  it during `__New` and instantiates one variant or the other. Mid-run
  changes do not take effect — the toast tells the user to restart.
- **Resize-by-border (§7) was abandoned** and is now in GSG §17 as an
  anti-regression item. Scroll wheel is the only resize mechanism.

---

## 12. Open questions during implementation

None at spec finalization. If new questions surface during steps 1–7,
they should be appended here as `### Q-N: <question>` blocks and answered
explicitly before the affected step lands.

---

## 13. PB display mode

Feature added after the initial Plus rollout. Toggles every PB-related
surface (display + timer-color comparison target) between the all-time
PB and the average of the latest five completed runs.

### 13.1 Feature flag

```ahk
; src_v2/domain/app_settings.ahk
cfg.pbDisplayMode := "pb"   ; "pb" | "avg5" — default "pb"
```

INI mapping:
```
[Display]
PbMode=pb
```

Settings dialog gains one checkbox under a new **DISPLAY** section:
`☐ Show average of last 5 runs instead of PB`. Unlike `layoutVariant`,
the change is **hot-reloadable** — `SettingsDialog._OnSave` publishes
`Evt.PbDisplayModeChanged` and every widget re-renders without a
restart. Section header in the dialog sits between LAYOUTS (BETA) and
HOTKEYS so the user sees both display knobs grouped together.

Any value other than the literal `"avg5"` normalizes to `"pb"` in both
`AppSettings.FromMap` and `SettingsRepository._LoadDisplay` — same
defense-in-depth pattern `layoutVariant` uses (§1).

### 13.2 Scope

Applies to **every widget that consults `_pbService`**, Classic and
Plus alike. Five widgets touched (Micro Classic is the only PB-using
layout excluded — it doesn't read PB at all):

| Widget | PB literal display? | Timer color uses PB? | Visual differentiation in avg5 mode |
|---|---|---|---|
| Steve Plus       | yes (bare value)      | yes | `~ MM:SS` prefix (tilde = average) |
| Compact Plus     | yes (`PB MM:SS` chip) | yes | label swaps to `AVG MM:SS` |
| Compact Classic  | yes (`PB ZZ:ZZ / TT:TT`) | yes | label swaps to `AVG ZZ:ZZ / TT:TT` |
| Steve Classic    | no                    | yes | (none — color-only) |
| Micro Plus       | no                    | yes | (none — color-only) |

The display value AND the color comparison target both follow the
same source. "Current below target" still reads green either way —
the semantic stays consistent across modes.

### 13.3 Data source

New service `RunAverageService` (`src_v2/app/services/run_average_service.ahk`).
Pull-based mirror of `PersonalBestService` over `RunHistoryRepository`:

```ahk
GetAverageRunMs()              ; ← mean of summary.totalMs across latest 5 runs
GetAverageRunMsForAct(actNum)  ; ← mean of actCheckpoints[actNum] across runs that reached that act
GetAverageZoneMs(zoneName)     ; ← mean of (sum of visits) across runs that visited the zone
```

- `N_RECENT := 5` constant. Not exposed in the UI yet — the user
  asked for "average of the last 5", so 5 is hard-wired here with a
  single edit point for future surfacing.
- Per-act denominator counts **only runs that reached the act**.
  An Act-1-only run contributes to Act 1's average, not Act 3's.
- Per-zone denominator counts **only runs that visited the zone**.
  Multiple visits within one run are summed before averaging across
  runs — same shape as `ZoneTrackingService.GetZoneTotalWithActive`,
  which is what the PB service compares against.
- Categories `loading` and `morte` are excluded from zone averages,
  matching the filter `PersonalBestService.RebuildFromHistory` uses.

### 13.4 Caching

Two caches with separate lifetimes:

- **Run + per-act averages**: built from `LoadSummaries(5)` (fast —
  meta + totals + checkpoints, no details). Invalidated on
  `Evt.RunCompleted` / `Evt.RunCancelled`.
- **Per-zone averages**: built lazily on first `GetAverageZoneMs`
  after an invalidation, via `ListRunIds(5)` + `Load(runId)` per
  run. Slow path (5 INI reads) but bound to N_RECENT runs and
  cached until the next dirty flip.

The service subscribes to both events in its constructor and exposes
a manual `Invalidate()` hook for callers that change runs outside
the finalize flow (run-history delete, run import).

### 13.5 Widget integration

Every PB-using widget gained two optional ctor params at the end of
the signature: `cfg` (already present in some) and `avgService`. A
`_IsAvg5Mode()` helper performs a **dual check** — `cfg` set AND
`avgService` injected AND `cfg.pbDisplayMode = "avg5"`. When the
service is missing, the helper returns false and the widget falls
back to PB rather than render stale/empty values.

Widgets subscribe to `Evt.PbDisplayModeChanged` and reset every
derived cache (timer color, PB chip text) before calling `_Refresh`.
The other caches (act/zone state, deaths count) are mode-independent
and stay intact.

### 13.6 ToS compliance (GSG §18)

`RunAverageService` reads ONLY `data\runs\*.ini` — files written by
this tracker. Zero game interaction: no Client.txt read, no input
simulation, no GGG API or website access. **No risk** under PoE2
Terms of Use clauses 7(b–f, i).

