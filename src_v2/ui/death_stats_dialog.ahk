; DeathStatsDialog — surfaces DeathStatsService aggregations to the
; user. Subscribes to Cmd.OpenDeathStatsRequested; opened by the
; "Death Stats" button in RunStatsPlotDialog (the natural home: the
; aggregate spans every recorded death across all play sessions and
; is independent of which runs are currently in history).
;
; Two modes (mutually exclusive, toggled by a bottom-left button):
;
;   - "live"    (default) — reads data/deaths.csv via DeathStatsService.
;                            Filters by Patch/Build dropdowns. Reflects
;                            the death log accumulated since the app
;                            started recording.
;
;   - "alltime"            — reads the raw Client.txt via DeathLogScanner.
;                            No filtering (the log carries no patch or
;                            build metadata, and the view deliberately
;                            ignores cfg.characterName so deaths from
;                            every character the player ever ran are
;                            included — current PoE2 builds do not emit
;                            "has been slain" for bosses, so dropping
;                            the character filter does not pollute the
;                            result). Counts only deaths in **campaign
;                            zones** — hideouts, atlas maps, endgame
;                            trials and towns are dropped (see the
;                            scanner header for the rationale). Cruel
;                            difficulty is detected via the `C_` prefix
;                            on the area code and surfaces as a
;                            separate row with a " (Cruel)" suffix
;                            (e.g. "Mud Burrow" and "Mud Burrow (Cruel)"
;                            counted independently). Generated
;                            synchronously each time the button is
;                            clicked; nothing persists. Returns to
;                            "live" on next click or when the dialog
;                            is closed and reopened. Adds an
;                            "Export..." button that lets the user save
;                            the current view as CSV to a path of their
;                            choice (default: Downloads), outside the
;                            app's data directory — the view itself
;                            never persists anywhere inside the app.
;
; Layout:
;
;   +-----------------------------------------------+
;   | Death Stats                                   |
;   | Total deaths (filtered): N                    |
;   |                                               |
;   | Patch: [(All) v]   Build: [(All) v]           |
;   |                                               |
;   | ListView 3 cols:                              |
;   |   Zone | Count | Bar                          |
;   |                                               |
;   | [All-time (from log)]              [Close]    |
;   +-----------------------------------------------+
;
; In alltime mode the dropdowns are disabled, the header reads
; "Death Stats - All-time (from Client.txt)", the toggle button
; reads "Back to live", and an "Export..." button appears between
; the toggle and Close.
;
; Bar column is an ASCII proportion ('█' * round(count/max * 30)).
; AHK v2's ListView has no per-cell custom-draw hook short of
; subclassing the control via WM_NOTIFY (fragile and out of scope);
; ASCII bars stay readable in the default font, copy-paste cleanly,
; and survive HiDPI scaling without code.
;
; "(All)" is a UI sentinel for "no filter on this dimension". It is
; NEVER a valid patch or profile string in the log (the upstream
; handler reads cfg.gamePatch and cfg.profileName, which default
; to "Unknown" and "Default" on a fresh install) -- treating "(All)"
; as no-filter rather than as a literal value is safe by inspection.
;
; Available lists in DeathStatsService.Aggregate are extracted from
; the WHOLE dataset, not the filtered subset, so the two dropdowns
; can be populated once per Open() and stay stable while the user
; cycles through filters. No second pass needed.


class DeathStatsDialog
{
    static WINDOW_W := 580
    static WINDOW_H := 520
    static BAR_CHAR := "█"
    static BAR_MAX_CHARS := 30
    static ALL_LABEL := "(All)"

    ; Mode sentinels — string values rather than enums because AHK
    ; v2 has no enum type and string comparisons read clearly in the
    ; if/else branches of _Refresh.
    static MODE_LIVE    := "live"
    static MODE_ALLTIME := "alltime"

    _bus            := ""
    _statsSvc       := ""
    _scanner        := ""   ; DeathLogScanner — for the alltime view
    _cfg            := ""   ; AppSettings — source for logFile + characterName
    _headless       := false
    _gui            := ""
    _ctrls          := ""    ; Map<key, GuiControl>
    _isOpen         := false
    _mode           := "live"
    _alltimeResult  := ""    ; Map result from DeathLogScanner.Scan when in alltime mode; "" otherwise

    __New(bus, statsSvc, scanner, cfg, headless := false)
    {
        if !(bus is EventBus)
            throw TypeError("DeathStatsDialog: 'bus' must be EventBus")
        if !(statsSvc is DeathStatsService)
            throw TypeError("DeathStatsDialog: 'statsSvc' must be DeathStatsService")
        if !(scanner is DeathLogScanner)
            throw TypeError("DeathStatsDialog: 'scanner' must be DeathLogScanner")
        if !(cfg is AppSettings)
            throw TypeError("DeathStatsDialog: 'cfg' must be AppSettings")

        this._bus       := bus
        this._statsSvc  := statsSvc
        this._scanner   := scanner
        this._cfg       := cfg
        this._headless  := !!headless
        this._ctrls     := Map()

        bus.Subscribe(Commands.OpenDeathStatsRequested, (data) => this.Open())
    }

    IsOpen() => this._isOpen

    ; Public accessor for tests + (potential) status widgets that
    ; might want to display the current mode.
    GetMode() => this._mode

    IsInAlltimeMode() => this._mode = DeathStatsDialog.MODE_ALLTIME

    Open()
    {
        ; A fresh Open always starts in live mode. Closing and
        ; reopening discards any cached all-time scan: the user
        ; opted into the all-time view explicitly by clicking the
        ; toggle, so it shouldn't sticky across sessions.
        this._mode := DeathStatsDialog.MODE_LIVE
        this._alltimeResult := ""

        if this._headless
        {
            this._isOpen := true
            return true
        }

        if this._isOpen && this._gui
        {
            this._Refresh()
            try this._gui.Show()
            return true
        }
        this._BuildGui()
        this._isOpen := true
        return true
    }

    Close()
    {
        if this._gui
        {
            try this._gui.Destroy()
            this._gui   := ""
            this._ctrls := Map()
        }
        this._isOpen := false
    }

    ; ============================================================
    ; GUI construction
    ; ============================================================

    _BuildGui()
    {
        g := Gui("+AlwaysOnTop -MaximizeBox", "SpeedKalandra - Death Stats")
        g.BackColor := Theme.Color("bg")
        g.MarginX := 14
        g.MarginY := 12
        g.OnEvent("Close",  (*) => this.Close())
        g.OnEvent("Escape", (*) => this.Close())
        this._gui := g

        ; Header
        g.SetFont("s12 bold c" Theme.Color("text"), Theme.FONT_UI)
        this._ctrls["header"] := g.Add("Text", "x14 y10 w540", "Death Stats")

        ; Total label (populated by _Refresh).
        g.SetFont("s10 c" Theme.Color("muted"), Theme.FONT_UI)
        this._ctrls["total"] := g.Add("Text", "x14 y36 w540", "Total deaths (filtered): 0")

        ; Filter row: 2 DropDownLists, populated by _Refresh.
        ;
        ; gAlign-style alignment is via explicit x coordinates rather
        ; than columns because DropDownList doesn't honor the AHK v2
        ; "Section" group like Edit does in some builds; explicit
        ; coords are robust across runtime quirks.
        g.SetFont("s9 c" Theme.Color("muted"), Theme.FONT_UI)
        g.Add("Text", "x14 y72 w50",         "Patch:")
        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        this._ctrls["patchDdl"] := g.Add("DropDownList",
            "x60 y68 w180 vDeathStatsPatchDdl Choose1",
            [DeathStatsDialog.ALL_LABEL])
        this._ctrls["patchDdl"].OnEvent("Change", (*) => this._OnFilterChanged())

        g.SetFont("s9 c" Theme.Color("muted"), Theme.FONT_UI)
        g.Add("Text", "x260 y72 w50",         "Build:")
        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        this._ctrls["profileDdl"] := g.Add("DropDownList",
            "x310 y68 w180 vDeathStatsProfileDdl Choose1",
            [DeathStatsDialog.ALL_LABEL])
        this._ctrls["profileDdl"].OnEvent("Change", (*) => this._OnFilterChanged())

        ; ListView
        g.SetFont("s9 c" Theme.Color("text"), Theme.FONT_UI)
        lvW := 540
        lvH := 360
        this._ctrls["list"] := g.Add("ListView",
            "x14 y102 w" lvW " h" lvH " Background" Theme.Color("surface2"),
            ["Zone", "Count", "Bar"])
        this._ctrls["list"].ModifyCol(1, 220)
        this._ctrls["list"].ModifyCol(2, 60)
        this._ctrls["list"].ModifyCol(3, 240)

        ; Buttons — toggle on the left, Export in the middle
        ; (visible only in alltime mode), Close on the right. The
        ; toggle's text and behaviour switch by mode (see
        ; _OnToggleAlltimeClicked); the export button is shown by
        ; _RefreshAlltime and hidden by _RefreshLive.
        btnY := 102 + lvH + 8
        btnToggle := g.Add("Button", "x14 y" btnY " w160 h28", "All-time (from log)")
        btnToggle.OnEvent("Click", (*) => this._OnToggleAlltimeClicked())
        this._ctrls["btnToggle"] := btnToggle

        ; Export starts hidden — it only makes sense in alltime
        ; mode (live data is already in data/deaths.csv on disk).
        ; AHK v2 GUI controls expose .Visible as both getter and
        ; setter, so the mode-refresh methods just flip the flag.
        btnExport := g.Add("Button", "x180 y" btnY " w110 h28", "Export...")
        btnExport.OnEvent("Click", (*) => this._OnExportClicked())
        btnExport.Visible := false
        this._ctrls["btnExport"] := btnExport

        btnClose := g.Add("Button", "x440 y" btnY " w110 h28", "Close")
        btnClose.OnEvent("Click", (*) => this.Close())

        this._Refresh()
        g.Show("w" DeathStatsDialog.WINDOW_W " h" DeathStatsDialog.WINDOW_H)
    }

    ; ============================================================
    ; Refresh
    ; ============================================================

    ; Full refresh: dispatches by mode. In live mode rebuilds both
    ; dropdowns from the unfiltered aggregate and redraws the
    ; ListView with the current filter; in alltime mode disables
    ; the dropdowns and renders straight from the cached scan.
    _Refresh()
    {
        if !IsObject(this._ctrls) || !this._ctrls.Has("list")
            return

        if (this._mode = DeathStatsDialog.MODE_ALLTIME)
        {
            this._RefreshAlltime()
            return
        }
        this._RefreshLive()
    }

    ; Live mode refresh: re-Aggregates the whole dataset, rebuilds
    ; both dropdowns with the current "available" lists, and redraws
    ; the ListView with the filter that's currently selected (which
    ; may have just become invalid if a value disappeared from the
    ; data — in that case we silently fall back to "(All)").
    _RefreshLive()
    {
        ; Header + toggle button text snap back to the live labels.
        if this._ctrls.Has("header")
            try this._ctrls["header"].Value := "Death Stats"
        if this._ctrls.Has("btnToggle")
            try this._ctrls["btnToggle"].Text := "All-time (from log)"
        if this._ctrls.Has("btnExport")
            try this._ctrls["btnExport"].Visible := false
        this._SetDropdownsEnabled(true)

        ; Capture the currently-selected filter values (if any) so we
        ; can try to preserve them across the rebuild. If a value is
        ; no longer available we fall back to "(All)".
        prevPatch   := this._GetSelectedText("patchDdl")
        prevProfile := this._GetSelectedText("profileDdl")

        unfilteredResult := this._statsSvc.Aggregate()

        this._PopulateDropdown("patchDdl",   unfilteredResult["availablePatches"],   prevPatch)
        this._PopulateDropdown("profileDdl", unfilteredResult["availableProfiles"],  prevProfile)

        ; Recompute with the (possibly preserved) filter to drive the
        ; ListView. Aggregate is cheap (single pass over an in-memory
        ; CSV read); the second call costs nothing measurable and
        ; keeps the code linear -- no need to share a result with
        ; _RefreshList.
        this._RefreshList(this._GetCurrentFilter())
    }

    ; Alltime mode refresh: render straight from the cached scanner
    ; result. Patch/Build filters don't apply (the raw log has no
    ; such metadata), so dropdowns get disabled and the header gains
    ; a suffix that names the data source. Total label also reports
    ; deaths the scanner dropped because they were outside any
    ; campaign zone (hideout, endgame map, town, or no zone seen
    ; yet) so the user can spot data loss explicitly.
    _RefreshAlltime()
    {
        if this._ctrls.Has("header")
            try this._ctrls["header"].Value := "Death Stats - All-time (from Client.txt)"
        if this._ctrls.Has("btnToggle")
            try this._ctrls["btnToggle"].Text := "Back to live"
        if this._ctrls.Has("btnExport")
            try this._ctrls["btnExport"].Visible := true
        this._SetDropdownsEnabled(false)

        if !IsObject(this._alltimeResult)
            return

        if this._ctrls.Has("total")
        {
            msg := "Total deaths: " . this._alltimeResult["totalDeaths"]
            skipped := this._alltimeResult["skippedNonCampaign"]
            if (skipped > 0)
                msg .= "   (skipped: " . skipped . " outside campaign zones)"
            try this._ctrls["total"].Value := msg
        }

        lv := this._ctrls["list"]
        try lv.Delete()

        perZone := this._alltimeResult["perZone"]
        if !IsObject(perZone) || perZone.Length = 0
            return

        ; Bar reference = top count (perZone is sorted desc, so [1]).
        maxCount := perZone[1]["count"]
        for _, row in perZone
        {
            try lv.Add(,
                row["zoneName"],
                row["count"],
                DeathStatsDialog.FormatBar(row["count"], maxCount, DeathStatsDialog.BAR_MAX_CHARS))
        }
    }

    _SetDropdownsEnabled(enabled)
    {
        if this._ctrls.Has("patchDdl")
            try this._ctrls["patchDdl"].Enabled := enabled
        if this._ctrls.Has("profileDdl")
            try this._ctrls["profileDdl"].Enabled := enabled
    }

    ; Partial refresh: recomputes with the given filter and redraws
    ; the ListView + Total label only. Used by _OnFilterChanged --
    ; the dropdowns themselves don't change when the user picks a
    ; new filter, so we skip the dropdown rebuild work.
    _RefreshList(filter)
    {
        if !IsObject(this._ctrls) || !this._ctrls.Has("list")
            return

        result := this._statsSvc.Aggregate(filter)

        ; Total label
        if this._ctrls.Has("total")
            try this._ctrls["total"].Value :=
                "Total deaths (filtered): " . result["totalDeaths"]

        ; ListView
        lv := this._ctrls["list"]
        try lv.Delete()

        perZone := result["perZone"]
        if !IsObject(perZone) || perZone.Length = 0
            return

        ; Bar reference = top count (perZone is sorted desc, so [1]).
        maxCount := perZone[1]["count"]
        for _, row in perZone
        {
            try lv.Add(,
                row["zoneName"],
                row["count"],
                DeathStatsDialog.FormatBar(row["count"], maxCount, DeathStatsDialog.BAR_MAX_CHARS))
        }
    }

    ; ============================================================
    ; Mode toggle
    ; ============================================================

    ; Public hook for tests — exposes the same behaviour the
    ; button does without needing a real Gui. Production code
    ; reaches this through the OnEvent("Click") wired in _BuildGui.
    ToggleAlltimeMode()
    {
        this._OnToggleAlltimeClicked()
    }

    ; Handler for the toggle button. In "live" mode it scans the
    ; Client.txt and switches to "alltime"; in "alltime" mode it
    ; clears the cached scan and switches back to "live". The scan
    ; runs synchronously (FileOpen + ReadLine over the full log)
    ; and can take a few seconds on multi-hundred-MB logs — the
    ; user clicked an explicit "from log" button so a brief UI
    ; pause is expected. No background thread, no progress UI:
    ; that complexity would buy little and add a lot of moving
    ; parts (SetTimer reentrancy + cancelation + partial-result
    ; rendering) for what's effectively a one-off operation.
    _OnToggleAlltimeClicked()
    {
        if (this._mode = DeathStatsDialog.MODE_ALLTIME)
        {
            this._mode := DeathStatsDialog.MODE_LIVE
            this._alltimeResult := ""
            this._Refresh()
            return
        }

        ; mode = live → attempt scan and switch only if it succeeds.
        ; Failure paths (missing file, read error) leave the mode
        ; unchanged; the user sees an error dialog in production
        ; and the live view continues to be valid.
        if !this._DoAlltimeScan()
            return
        this._mode := DeathStatsDialog.MODE_ALLTIME
        this._Refresh()
    }

    ; Runs the all-time scan. Returns true on success and stores
    ; the result in this._alltimeResult; returns false (and shows
    ; an error to the user, unless headless) on any failure path.
    ; Reads cfg.logFile at call time — the user may have changed
    ; it in Settings since the dialog was opened, and reading live
    ; avoids stale state.
    ;
    ; The all-time view deliberately does NOT pass cfg.characterName
    ; as a filter. Three reasons:
    ;   - The view is meant to surface every death the Client.txt
    ;     records, across every character the player ever ran on
    ;     the install — the cfg.characterName filter would hide
    ;     deaths from past or alt characters, which is the opposite
    ;     of what "all-time" implies.
    ;   - Current PoE2 builds do NOT emit `has been slain` for
    ;     bosses, so removing the filter does not pollute the
    ;     result with monster/boss kills (they simply don't show
    ;     up in the log under this pattern).
    ;   - The live view (deaths.csv via DeathStatsService) still
    ;     attributes each death to a character via the upstream
    ;     LogMonitorService filter at ingest time — that's where
    ;     per-character separation belongs.
    _DoAlltimeScan()
    {
        logPath := String(this._cfg.logFile)

        result := this._scanner.Scan(logPath, "")
        if !result["success"]
        {
            if !this._headless
                try MsgBox("Failed to scan Client.txt:`n`n" . result["errorMessage"],
                    "SpeedKalandra", "IconX")
            return false
        }
        this._alltimeResult := result
        return true
    }

    ; ============================================================
    ; Export (alltime only)
    ; ============================================================

    ; Handler for the Export button. Wraps a FileSelect Save dialog
    ; over _WriteExportToPath. Guards:
    ;   - Only runs in alltime mode (the live view's data is
    ;     already in data/deaths.csv on disk, which the user can
    ;     copy with the file manager — no extra export wired).
    ;   - Skipped in headless (FileSelect would block tests).
    ;
    ; The default folder is the user's Downloads (falls back to
    ; Documents if Downloads is absent — some Windows installs and
    ; corporate profiles remove it). The default filename embeds a
    ; timestamp so consecutive exports don't overwrite each other.
    _OnExportClicked()
    {
        if (this._mode != DeathStatsDialog.MODE_ALLTIME)
            return
        if !IsObject(this._alltimeResult)
            return
        if this._headless
            return

        defaultDir  := DeathStatsDialog._GetDownloadsPath()
        defaultName := "death_stats_alltime_" . FormatTime(A_Now, "yyyyMMdd_HHmmss") . ".csv"
        defaultPath := defaultDir . "\" . defaultName

        selectedPath := ""
        try
            selectedPath := FileSelect("S", defaultPath, "Export Death Stats", "CSV Files (*.csv)")
        catch
            return

        if (selectedPath = "")
            return   ; user cancelled

        if !this._WriteExportToPath(selectedPath)
            return

        try TrayTip("SpeedKalandra",
            "Death stats exported to:`n" . selectedPath, "Mute")
    }

    ; Writes the current alltime result as CSV to the given path,
    ; via AtomicWriter (so a crash mid-write doesn't leave a half
    ; file at the user-chosen destination). Public-ish (underscore
    ; prefix but stable contract) so tests can exercise the write
    ; path without driving a real FileSelect dialog. Returns true on
    ; success, false on failure (the failure path surfaces a MsgBox
    ; in production; silent in headless).
    _WriteExportToPath(path)
    {
        if !IsObject(this._alltimeResult)
            return false
        if (Trim(String(path)) = "")
            return false

        csv := DeathStatsDialog.FormatExportCsv(this._alltimeResult["perZone"])
        try
        {
            AtomicWriter.WriteAll(path, csv, "UTF-8")
            return true
        }
        catch as ex
        {
            if !this._headless
                try MsgBox("Failed to write export file:`n`n" . ex.Message,
                    "SpeedKalandra", "IconX")
            return false
        }
    }

    ; Returns the user's Downloads folder if it exists, otherwise
    ; Documents (A_MyDocuments). USERPROFILE is read via EnvGet
    ; rather than hard-coding C:\Users — works through redirected
    ; profiles, corporate roaming, and the OneDrive-mirrored
    ; profile setups that show up on real-world Windows installs.
    static _GetDownloadsPath()
    {
        profile := EnvGet("USERPROFILE")
        if (profile != "")
        {
            candidate := profile . "\Downloads"
            if DirExist(candidate)
                return candidate
        }
        return A_MyDocuments
    }

    ; FormatExportCsv(perZone) -> string
    ;
    ; Static helper for tests + the live handler. Emits the same
    ; semicolon-quoted UTF-8 CSV the rest of the project uses
    ; (delegates to CsvFile.FormatRow for proper quote-escape +
    ; LF termination). Defensive against non-array input and
    ; non-Map rows: always returns at least the header line, so the
    ; export is never an empty file the user might not notice.
    static FormatExportCsv(perZone)
    {
        ; Header without quotes (matches CsvFile.EnsureHeader convention).
        out := "zoneName;count`n"

        if !IsObject(perZone)
            return out

        for _, row in perZone
        {
            if !IsObject(row)
                continue
            zone  := row.Has("zoneName") ? String(row["zoneName"]) : ""
            count := row.Has("count")    ? row["count"]            : 0
            out .= CsvFile.FormatRow([zone, count])
        }
        return out
    }

    ; ============================================================
    ; Filter handling
    ; ============================================================

    _OnFilterChanged()
    {
        this._RefreshList(this._GetCurrentFilter())
    }

    ; Reads both dropdowns, treats "(All)" as no-filter, and returns
    ; a Map ready for DeathStatsService.Aggregate. Returns an empty
    ; Map when both dropdowns are "(All)" -- semantically equivalent
    ; to no filter, kept as a Map for consistent caller code.
    _GetCurrentFilter()
    {
        filter := Map()
        patch := this._GetSelectedText("patchDdl")
        if (patch != "" && patch != DeathStatsDialog.ALL_LABEL)
            filter["patch"] := patch
        profile := this._GetSelectedText("profileDdl")
        if (profile != "" && profile != DeathStatsDialog.ALL_LABEL)
            filter["profile"] := profile
        return filter
    }

    _GetSelectedText(ctrlKey)
    {
        if !this._ctrls.Has(ctrlKey)
            return ""
        ddl := this._ctrls[ctrlKey]
        try
        {
            v := ddl.Text
            if (v != "")
                return v
        }
        return ""
    }

    ; Repopulates a DropDownList with "(All)" + the given values, and
    ; selects either `prevSelection` (when it's still in the list) or
    ; "(All)" (when prevSelection vanished or was empty). Done by
    ; rebuilding the entire list because AHK v2's DropDownList lacks
    ; a "clear+add" granular API that's worth the extra code.
    _PopulateDropdown(ctrlKey, values, prevSelection)
    {
        if !this._ctrls.Has(ctrlKey)
            return
        ddl := this._ctrls[ctrlKey]

        options := [DeathStatsDialog.ALL_LABEL]
        for _, v in values
            options.Push(String(v))

        try ddl.Delete()
        try ddl.Add(options)

        ; Pick whichever index matches prevSelection, falling back to
        ; index 1 ("(All)") if no match.
        selectIndex := 1
        for i, opt in options
        {
            if (opt = prevSelection)
            {
                selectIndex := i
                break
            }
        }
        try ddl.Choose(selectIndex)
    }

    ; ============================================================
    ; Bar formatting
    ; ============================================================

    ; FormatBar(count, maxCount, maxChars) -> string
    ;
    ; Returns BAR_CHAR repeated proportionally to count/maxCount,
    ; clamped to [0, maxChars]. Defensive against zero/negative max
    ; (returns "") so a list with all-zero counts can't divide by
    ; zero. Round to avoid sub-character flickering across redraws.
    static FormatBar(count, maxCount, maxChars)
    {
        if !IsNumber(count) || !IsNumber(maxCount) || !IsNumber(maxChars)
            return ""
        if (maxCount <= 0 || maxChars <= 0 || count <= 0)
            return ""
        chars := Round(count / maxCount * maxChars)
        if (chars < 1)
            chars := 1   ; at least one block when count > 0
        if (chars > maxChars)
            chars := maxChars
        out := ""
        Loop chars
            out .= DeathStatsDialog.BAR_CHAR
        return out
    }
}
