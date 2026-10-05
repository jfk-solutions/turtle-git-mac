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
That preference does not control application menus. The containing app publishes
it separately to `menu-settings.json` in the entitled App Group container on
startup and when its Advanced draft is applied. No repository needs to be open.
A failed write after Apply reports that settings were saved but Finder publication
failed. Unsigned builds without the entitlement skip shared writes.

Finder reads the file on each new menu request, matching the source's per-menu
preference read. Missing, malformed or unavailable cache data uses the source's
true default. Atomic replacement protects readers from partial preference writes.
The status snapshot schema, roots, states and update timestamps are unchanged.
Every existing parent/action/nested ignore/comparison menu image follows this
preference; badge registration and requests continue using original status artwork.
The builder retains existing conditions, targets, selectors and command metadata.
This does not claim that the existing command set covers the complete shell menu.

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

## Finder preference follow-up verification

Two additional core tests verify independent defaults/nonzero values, absent or
malformed presentation cache fallback, atomic false/true handoff, unchanged status
file bytes, no shared URL and publication errors. The focused Finder request/app
menu/settings run passes 11 tests. Full regression was not rerun for this follow-up.

The actual extension source's menu builder is compiled into a standalone driver;
no Finder controller or extension instance is constructed. Six selection cases
(untracked, tracked, conflicted, folder, mixed and empty) preserve command titles,
enabled states, represented actions and selectors while toggling all images,
including the TurtleGit parent, nested ignore items and marked comparison.
A fresh cache read observes false then true, and badge artwork stays available.
The actual Advanced receiver checks draft cancellation, deferred publication,
Apply, blank reset, independent app changes and saved-but-publication-failed errors.

See [Finder verification record](qa/finder-menu-icons-2026-10-06.json).
Actual signed app-to-extension handoff, activated Finder context menus/badges,
full shell menu conditions, popup gestures and screenshots remain pending.
