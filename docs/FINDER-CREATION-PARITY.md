# Finder creation workflows

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
Clone/Create repository entry points and native toolbar adaptation are implemented.
This is not full shell-menu or activated Finder acceptance.

## Source rules and macOS adaptation

`MenuInfo.cpp` (`aee7f91ad1111fe03ab85b390855885ca940a27f`) allows Clone and
Create repository on ordinary outside folders or ignored folders. Shift's extended
menu allows Clone in versioned folders; Create repository's extended clause
excludes `ITEMIS_INGIT`. `ITEMIS_FOLDERINGIT` is represented independently:
its presence suppresses the ordinary clause but does not exclude extended Create.
Untracked folders inside cached worktrees retain this administrative folder flag;
they offer creation through Shift rather than the ordinary menu.
Bare/inaccessible folders suppress the ordinary clause.
The directory classifier uses cached status, path-component boundaries and
metadata; no Git process is launched in Finder. Cached status is not proof of
fresh Git state. Cache completeness, reftable/invalid administrative structures,
multiple-folder creation and all other shell conditions remain pending.

The bare metadata probe retains the pinned `GitAdminDir.cpp`
(`985eb4e063adf8cf8a59744c917b2c3ec4e780bd`) loose-reference checks for HEAD,
config, with directories at objects, refs and refs/heads. This is a menu eligibility
probe, not repository validation. Administrative `.git` paths, including mixed selections, suppress the
menu, following `ContextMenu.cpp`'s early exclusion.

Finder container menus use the targeted folder rather than selected child files.
Item menus retain the selected paths. Existing repository commands require a
cached repository target, so an unrelated folder does not offer those commands.
All actionable items capture their paths at menu construction and route that
selection when activated; see [selection audit](FINDER-SELECTION-PARITY.md). Clone/Create use the existing native dialogs and permission
pickers; a Finder URL still supplies no security scope.

The Finder toolbar retains original turtle artwork, name and tooltip. The installed
SDK's `FinderSync.h` documents that toolbar menus are requested outside managed
folders, while target/selection URLs may then be nil. In that case the toolbar
offers Clone/Create directly, without an extra TurtleGit submenu or a path, opening the existing Clone/default-location or
Create repository folder-picker flow. Only these two URL actions may omit paths;
all repository actions still require selection. No synthetic filesystem target is
substituted. Context-menu icon settings do not remove the toolbar image.

Context menus remain restricted to Finder Sync's monitored directories. The toolbar
is the native entry point outside those directories; activated appearance, placement
and signed permission behavior have not been verified. macOS Finder Sync replaces
Explorer integration and does not supply its global Explorer context-menu API.

## Verification

The focused suite passes 12 tests (three new creation tests plus existing request
and Finder preference tests). Source clause cases cover ordinary, versioned,
ignored, bare, inaccessible and extended combinations; filesystem fixtures cover
cached status, bare metadata, rejection of a file at objects and an uncached `.git` entry. URL tests require paths
for every action except Clone/Create and reject malformed empty path fields.

The actual extension source is compiled with Swift 6/macOS 13 into a standalone
receiver without constructing a Finder controller or extension. It verifies outside
folder and targetless toolbar Clone/Create-only menus, captured folder/action/target,
request round trips, versioned Shift behavior, admin exclusion and item/container/
toolbar path selection. Existing six-case menu/icon and cached-preference checks
also pass. This does not prove an actual click launches a dialog in a signed app.

Debug and unsigned AppStore builds, bundle audits and site generation are recorded
in [the verification record](qa/finder-creation-2026-10-06.json). Native dialog handoff,
multiple-folder behavior, complete shell command conditions, watch-root management,
activated toolbar/context menus, signed sandbox acceptance and GitHub execution of
these local changes remain pending.
