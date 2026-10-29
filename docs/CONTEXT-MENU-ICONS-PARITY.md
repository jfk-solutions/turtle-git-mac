# Application context-menu icon preference

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This ports the application icon preference; complete menu content, native popup
interaction and signed Finder acceptance remain pending.

## Report-header follow-up — 2026-10-29

Log, Reflog, Repository Browser, Browse References, both synchronization lists,
Rebase and LFS Locks now decorate their column menus with the existing source
`dialogs` artwork. Reset uses the source `reset` icon. LFS sizing and default-width
actions also use `dialogs`; sizing gestures in other headers remain unchanged.
The reference/tag synchronization result headers use the same artwork for their
Hide unchanged control. All use the owning window's preferences rather than a
global override.

Pinned `TortoiseProc/ColumnManager.cpp:561–633` supplies the reset/column-choice
behavior. Its ordinary CMenu does not establish a distinct icon for each column;
these macOS decorations fulfill the requested application-wide icon treatment
using the existing Commit/Add column-menu convention. No new commands, artwork
or column layouts are introduced. Existing captured action guards, selection,
width/order/visibility persistence and reset confirmation remain in place.
Rebase's persistent header and retained LFS header menus refresh decoration on
their menu-update callback without rebuilding the captured actions. Other header
builders read preferences when constructing or rebuilding the menu. This does
not claim immediate external preference updates while a popup is tracking.

The inventory also checked the existing Commit/Add, Blame and Worktree headers
and Import Patch's row-menu builder. It is an audit of the named native report
menus, not proof that every application or system-provided context menu has
identical upstream content. Remaining full-port and physical acceptance work is
tracked separately.

The [batch receipt](qa/report-header-icons-2026-10-29.json) records the successful
Debug build and grouped native check. An actual private Log window exercises
both revision and header menus, false/true icon preferences, a real column
hide/restore, saved visibility and consumed-action refusal, with unchanged HEAD
and index. The remaining named headers were source-reviewed and compiled; this
does not establish physical popup acceptance for each of them. No Core suite was
rerun for these native decoration changes.

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


The [Finder language handoff](LANGUAGES.md#finder-command-language-handoff)
localizes command and group captions from the extension's compiled catalogs.
Captured actions, routing payloads, first-level Git placement, source order and
icons remain independent of translated text. Filenames, masks and marked paths
are never translated as keys. Full installed Finder acceptance remains open.


## TurtleGit application branding — October 19, 2026

The application/Finder root mascot and legacy TortoiseSmall lookup now use the
custom green TurtleGit turtle with Git on its shell. App icons, native About
views and standalone authentication prompts share that source. This is fork
branding; command icons, status colors and Finder badge artwork retain their
pinned upstream assets. The existing application/Finder icon preferences still
control whether the corresponding context-menu images appear.
See [source and evidence](APPLICATION-IDENTITY.md).

## macOS 27 image visibility and command coverage — October 25, 2026

AppKit 27 can hide assigned menu images under its automatic policy. The native
menu policy requests explicit visibility for existing images through the public
`preferredImageVisibility` accessor. Runtime availability and selector checks
keep earlier macOS versions and build SDKs supported. It neither creates artwork
for a nil image nor overrides the app/Finder preference that decides whether
artwork is supplied. Apple's [API documentation](https://developer.apple.com/documentation/appkit/nsmenuitem/preferredimagevisibility)
describes this visibility policy.

The application observes native menu insertions, image changes and tracking so
lazy SwiftUI menus receive the same policy without replacing their delegates,
targets or validation. Finder applies the recursive policy to its completed menu
tree before handing it to the host process. Observer retirement belongs to app
termination. Original colorful command assets and TurtleGit branding remain in
use; Finder badge artwork, placement and size are unchanged.

The related command audit covers history/reference/browser/replay/Sync menus,
Commit and file-list commands, editor/comparison/Blame/image menus, completion
and progress actions, Settings/provider/SSH menus and the Finder builder. Missing
command/parent images were added and injected preference ownership corrected.
Column checkmarks and arbitrary data choices remain native choices, rather than
receiving unrelated command icons. The earlier dated verification sections above
remain historical; this batch's actual grouped results are recorded separately.


### Focused checkpoint

The [related checkpoint](qa/context-registration-2026-10-25.json) records the
passing Debug build and native menu-image receiver: actual Log command tree,
lazy image assignment, private icon preferences and observer retirement. The
compiled Finder menu builder also passes its action/parent/submenu icon and
preference assertions. No current installed Finder screenshot or full physical
menu/VoiceOver acceptance is claimed; signed candidate acceptance is pending.
The record retains all earlier failures and the separate Services sandbox
extension diagnostics.

### Installed acceptance — 2026-10-25

The [batch receipt](qa/context-registration-2026-10-25.json) records a signed
universal development build installed with a recoverable prior bundle. A real
Finder folder outside published roots showed Clone/Create/Add with icons. A local
Clone used actual destination-parent and source permission pickers and saved both
recent and watch records automatically, without a second registration picker.
The installed Log context menu displayed its assigned command artwork.

The first installed Add attempt exposed a real modifier mismatch: Finder supplied
`alternateTool: false`, which registration correctly rejects. The repaired
dispatch preserves the original registration request; the focused builder check
passed all four Shift/Control combinations. After the incremental signed repair,
actual Finder Add opened the folder picker and persisted the selected repository
in both archives while leaving the workspace unselected. Temporary recent/watch
entries and Clone preferences were removed, original record IDs retained, and
owned app/Finder windows closed. Background refresh stayed disabled. This covers
one private local-folder workflow, not every Finder provider or upstream dialog.
