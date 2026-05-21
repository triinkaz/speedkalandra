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
| × 0   XP   PB 03:33                  RUN · PB 03:33           |
| ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  |  <- 4px footer
+---------------------------------------------------------------+
```

**Fields:**
- `ACT N · zoneName` (single line, left-aligned)
- **Run timer** (mono, ~32pt at scale 1.0, conditional color)
- Sub-label below timer: `RUN · PB MM:SS` (PB = full run PB)
- **Chips**: `× N`, `XP`, `PB MM:SS` (PB of the current act)
- **Distribution bar**: 4px high footer (no labels, just colors)

**Note on the third chip:** `PB MM:SS` here is the **PB time to complete the current act**,
queried via `PersonalBestService` (verified: the service already exposes per-act PBs because
Steve Classic uses them for conditional timer color). Shows `--:--` if no PB exists for the act yet.

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
