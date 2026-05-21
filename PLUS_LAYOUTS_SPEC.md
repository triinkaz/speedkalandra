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
- New resize-by-border interaction (applies to Plus variants only — see §10)
- Palette aliases (`pb`, `map`, `loading`, `town`)

**Out of scope:**
- Removing or modifying Classic widgets
- Changing the run lifecycle, persistence formats, or services
- Per-widget granular toggles (single flag controls all three)

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

**a) Block positioning** — All inner-block coordinates are computed as
**percentages of the current widget width/height**, not as fixed pixel offsets.
When the widget is resized (via Ctrl+drag or Ctrl+wheel), blocks reflow proportionally.

**b) Text overflow** — Long zone names truncate with trailing `...` (e.g.
`The Twilight Strand and...`). No font shrinking. The truncation point is
computed using `_EstimateTextW` (the same `chars × fontSize × 0.6` estimator
already used by Compact Classic).

**c) Steve Plus dimensions** — `FIXED_W := 380`, `FIXED_H := 64`, same as
Steve Classic. The faixa Map/Load/Town footer is **4 px** at scale 1.0.

---

## 7. Resize by dragging borders (new interaction)

A new interaction available on Plus widgets:

- **Active borders**: right edge and bottom edge only (no left/top, no corners).
- **Trigger**: hold `Ctrl`, click and drag the border. Cursor changes to
  resize cursor when hovering border with Ctrl held.
- **Aspect ratio**: free (right drag affects width only; bottom drag affects
  height only). User can produce non-default aspect ratios deliberately.
- **Minimum size**: drag stops at the smallest valid size for the current
  `scale`. The floor is `(FIXED_W × scale, FIXED_H × scale)` — below that,
  content cannot fit even with reflow. Further drag is ignored.
- **Maximum size**: unbounded (the user can make the widget arbitrarily large).
- **Persistence**: new fields `width` and `height` per widget in `[Overlay]` INI:
  ```
  [Overlay]
  compactLayout.left=10.0
  compactLayout.top=1.5
  compactLayout.scale=1.0
  compactLayout.visible=1
  compactLayout.centered=0
  compactLayout.width=480     ; new — pixels at scale 1.0
  compactLayout.height=120    ; new — pixels at scale 1.0
  ```
  Default values (when key missing): `width=FIXED_W`, `height=FIXED_H`.

---

## 8. Interaction between `scale` and `width/height`

`scale` and `width/height` are **orthogonal**: they control different aspects
of the widget and never overwrite each other.

| Mechanism | Controls |
|---|---|
| `scale` (Ctrl+wheel) | **Typography**: font size, line thickness, internal padding, chip dimensions. Think "zoom of the content". |
| `width` / `height` (Ctrl+drag) | **Container size**: the outer rectangle. Content reflows to fill. |

**Resulting behaviors:**

| User action | Effect on widget |
|---|---|
| Ctrl+wheel up | Font and padding grow. If the new content size exceeds current `width × height`, container auto-expands to accommodate (content never truncates from a wheel-up). |
| Ctrl+wheel down | Font and padding shrink. Container stays at current `width × height` (extra space appears as empty padding around content). |
| Ctrl+drag right/bottom expanding | Container grows. Content reflows: blocks gain margin, distribution bar stretches, but **font size does not change**. |
| Ctrl+drag right/bottom shrinking | Container shrinks. Content compresses (less padding, blocks tighter). Stops at floor = `(FIXED_W × scale, FIXED_H × scale)`. Further drag ignored. |
| Ctrl+wheel down while already at floor for current scale | First reduces scale (which also reduces the floor). If scale is already at its minimum, further wheel-down ignored. |

**Floor formula**:
```
minW = FIXED_W * max(scale, MIN_SCALE)
minH = FIXED_H * max(scale, MIN_SCALE)
```

`MIN_SCALE` is the same minimum already used by Classic for Ctrl+wheel
(typically 0.5; verify in `LayoutWidgetBase` during implementation).

---

## 9. Persistence — INI changes summary

`[Layouts]` is a new section:
```
[Layouts]
Variant=classic
```

`[Overlay]` gains two new keys per widget (back-compat: missing keys
default to `FIXED_W` / `FIXED_H`):
```
[Overlay]
<widgetId>.width=<int>
<widgetId>.height=<int>
```

`SettingsRepository._LoadOverlay` / `_SaveOverlay` extended to read/write
these. `OverlayPosition` value object gains `width` / `height` fields.

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
3. **`OverlayPosition.width/height`** + repository round-trip:
   data fields, INI read/write, tests. No UI changes yet — the new fields
   default to `FIXED_W` / `FIXED_H` so Classic widgets ignore them. The
   resize-by-border interaction itself comes later.
4. **Resize-by-border interaction**: new service or extension of
   `OverlayInteractionService` to handle right/bottom edge drag. Includes
   the floor computation and the orthogonality with `scale`. Tests at the
   service level (pure geometry, no real Gui).
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
- The new `width` / `height` fields default to `FIXED_W` / `FIXED_H`, not
  to zero. A user opening an old INI must see Classic widgets at their
  original size, not collapsed to nothing.

---

## 12. Open questions during implementation

None at spec finalization. If new questions surface during steps 1–7,
they should be appended here as `### Q-N: <question>` blocks and answered
explicitly before the affected step lands.
