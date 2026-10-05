# Application context-menu icon preference

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This ports the application icon preference; complete menu content, native popup
interaction and signed Finder acceptance remain pending.

## Source behavior

`src/Utils/MiscUI/IconMenu.cpp` (`35f66245c6176381bbf7355c92065c10b25dedd1`)
reads `ShowAppContextMenuIcons`, default true, interpreting a DWORD as enabled
when nonzero. The native policy preserves that default and interpretation.
`IconMenu.h` (`a773bcb909beba53ddaea65b9cb53dd83659bb4f`) supplies the upstream
menu interface; Win32 bitmap ownership and painting use native menu images instead.

Explorer separately reads `ShowContextMenuIcons` in `TortoiseShell/ContextMenu.cpp`.
That preference does not control application menus. Its Finder consumer and
shared preference handoff remain pending.

## Native application consumers

AppKit custom menus use `MenuIcon.contextImage()` rather than changing the
ordinary artwork loader. This covers Log and clipboard submenus, Commit message
and filename menus, Blame source/revision menus, Worktree List management,
file comparison, text conflict and patch menus (including the native Print icon).
Worktree List honors its injected preferences store as well as normal defaults.
Menus already constructed can retain their images until reconstructed; immediate
updates of every open or cached popup remain unverified.

SwiftUI context builders mark their content with `TurtleGitContextMenu`.
`CommandLabel` observes the app preference in that scope, emitting text alone
when disabled, with no empty icon slot. Existing builders covered are Commit,
Log, Working Tree, Repository Browser (files and folders), Blame, Reflog,
Revision Comparison, Rebase, Revert, Revert Progress, Resolve and the main app.
Nested command groups inherit the context scope. Ordinary buttons, toolbar labels,
file/status icons, original colored artwork and the list watermark retain their
images. This preference does not add commands or establish full menu parity.
System-supplied text menu entries retain macOS behavior.

Advanced Settings now identifies this preference as an implemented consumer.
Its drafts continue to apply through the existing Apply/Cancel lifecycle.

## Verification scope

Two new core tests check default/nonzero values, independent shell preference,
removing an override and all 75 artwork resources remaining available when their
context images are disabled. Together with the existing artwork test, the
focused run passes three tests. The earlier 460-test full run predates this change.

The standalone Swift 6/macOS 13 driver creates the actual Worktree AppKit menu,
checks unchanged Lock/Unlock/Remove/Force remove titles with nil images when
switched off, then original images when the default is restored. An actual
SwiftUI hosting receiver checks the context label loses its icon width while an
ordinary label retains it. These checks display no windows or popup menus and
clean their isolated preference suites and Git fixtures.

Debug and unsigned AppStore builds and bundle audits are recorded in the
[verification record](qa/context-menu-icons-2026-10-06.json). Native popup gestures,
all dialog appearances, live updates of existing menus, signed integration and
remote execution of these local changes remain pending.
