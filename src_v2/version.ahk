; Version — global version constant for SpeedKalandra.
;
; Appears in: tray tooltip (A_IconTip in speedkalandra.ahk), Settings
; dialog title, and the run plot footer.
;
; Bump STRING below before each release. There is no build-script
; automation for this yet. SemVer (MAJOR.MINOR.PATCH):
;   PATCH — bug fixes only, no new features
;   MINOR — new features, backward-compatible
;   MAJOR — first "stable" release at 1.0; after that, bump only
;           when public compatibility breaks
;
; Pre-1.0 signals "functional but still evolving, no commitment to
; API stability". Pairs with the disclaimer shown on first boot.
; Per-release changes live in CHANGELOG.md.

class Version
{
    static STRING := "v0.1.3"
}
