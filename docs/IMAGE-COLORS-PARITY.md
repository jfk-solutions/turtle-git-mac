# Image transparent colors and local appearance

Reference: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
TortoiseIDiff/MainWindow.cpp `ID_VIEW_TRANSPARENTCOLOR`, `ID_VIEW_DARKMODE`
and `SetTheme`, PicWindow.cpp `GetTransparentThemedColor`, the two View menu
resources and Utils/Theme.cpp `GetThemeColor`.

Comparison and conflict View menus provide “Transparent color…” and “Dark Mode”.
The native owned sheet contains an AppKit color well with OK/Cancel. Only OK
commits the selected opaque RGB color; Cancel retains the prior value. All panes
in the same image window share one presentation model. The selected color fills
transparent image pixels and the canvas, including alpha and XOR composition.

Dark Mode and the unmodified D key switch the containing image window between
native Aqua and Dark Aqua. They do not change the application's appearance or
other open windows. The containing application replaces a standalone image-diff
process, so this preserves independent viewer behavior. Theme switching clears
the custom transparency color for all panes, matching upstream SetTheme.
White uses the macOS text background in dark appearance; other custom colors use
the existing source CTheme HSL conversion. Default colors follow native appearance.
The chooser stores the original RGB value rather than its themed projection.

Owned sheets and generation fences prevent a retired window's response from
changing its model. Native close/key routing is fenced while a sheet is attached.
Selection color is session-local; the source does not persist it. Reloading
comparison content retains the window-owned chosen RGB color, matching SetPic.
Pane updates retain an attached chooser; pane retirement cancels its pending
response, and a newly loaded pane reattaches to the owning presentation. The source
resource's B accelerator refers to ID_VIEW_BACKGROUNDCOLOR without a matching
MainWindow command case; no unimplemented behavior is claimed for that entry.

## Verification and remaining work

The final native receiver passed with system and bundled Git. It exercised
actual color wells and OK/Cancel sheet buttons, transparent-pixel raster colors
in both comparison panes and three conflict panes, alpha/XOR composition, native
D-key routing and appearance reset. Same-window native swatches account for the
display profile; a fixed source HSL RGB result checks custom dark colors.
Close/Quit guards, chooser survival across native view updates, color retention
across source reload and retirement of a pending chooser also passed. Comparison
HEAD/raw index/image bytes and conflict raw index/working bytes stayed unchanged.
Native light/dark captures were visually inspected. Existing comparison/player
regressions passed with both engines, including original slider/keyboard/XOR
behavior and multi-frame conflict selection. Final unsigned Debug and AppStore builds and bundle audits passed, including
all 116 original icon resources and the required AppStore runtimes. These checks
do not establish signing, sandbox runtime acceptance or App Review eligibility.
See the [QA record](qa/image-colors-2026-10-10.json). Physical color-picker gestures and focus
return, VoiceOver, high contrast and exact Windows/macOS color-management
matching remain incomplete. Full image and application parity and signed
App Store/Finder acceptance remain open.
