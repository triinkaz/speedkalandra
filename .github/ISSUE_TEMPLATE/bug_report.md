---
name: Bug report
about: Report something that doesn't work as documented
title: "[bug] "
labels: bug
assignees: ''
---

<!--
Before you open this issue, please check:
  - KNOWN_ISSUES.md (a few categories of issue are documented limitations)
  - SECURITY.md (security issues should be reported privately, not here)
-->

## Summary

<!-- One or two sentences describing what went wrong. -->

## Environment

- **SpeedKalandra version**: <!-- hover the tray icon → "SpeedKalandra vX.Y.Z" -->
- **AutoHotkey version**: <!-- output of: AutoHotkey64.exe /? top line, or "compiled .exe" -->
- **Windows version**: <!-- `winver` → e.g. Windows 11 24H2 -->
- **Path of Exile 2 client language**: <!-- English / Português / etc -->
- **Run state at the time**: <!-- first run after install / hydrated from previous session / mid-run / between runs -->
- **EventTracingEnabled**: <!-- 0 (default) or 1 — see [Diagnostics] in speedkalandra.ini -->

## Steps to reproduce

1. <!-- Be specific. "I clicked X then Y" beats "it broke". -->
2. ...
3. ...

## What you expected

<!-- What the app should have done. -->

## What actually happened

<!-- What it did instead. Include the visible behaviour: overlay state, tray notifications, error dialogs, etc. -->

## Log snippet

<!--
Open `data/speedkalandra.log` and find the timestamp range around the bug.
Paste 20–50 lines around the issue between the triple-backticks below.

⚠ Privacy review before posting:
  - The log includes your character name, the zones you visited, and (if
    EventTracingEnabled=1) raw lines from Client.txt.
  - These are not credentials but they ARE personal. Review and redact
    anything you don't want public.
  - If the log is essential and large, attach it as a file rather than
    pasting inline.
-->

```
<paste log lines here>
```

## Screenshot / video (optional)

<!--
Drag and drop here. Useful for: overlay rendering, weird states, dialogs
in unexpected positions, button responses you can't describe in text.
-->

## Reproducibility

- [ ] Happens every time
- [ ] Happens sometimes — I have a hunch about when (please describe)
- [ ] Happened once and I can't trigger it again

## Anything else

<!-- Workarounds you found, related issues you've seen, hypotheses. Optional. -->
