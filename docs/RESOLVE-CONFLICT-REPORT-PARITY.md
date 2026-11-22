# Resolve and Synchronization conflict reports

This family follows pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
It replaces the remaining fixed Resolve report and the SwiftUI Sync conflict
report with a shared native AppKit report presentation. The models keep their
separate conflict identities, command masks and child-operation ownership.

## Source behavior and native implementation

`ResolveDlg.cpp:60` initializes `GitStatusListCtrl` with `GITSLC_COLEXT` and the
`ResolveDlg` column namespace. Path and Extension are initially visible; Status
is optional. `GitStatusListCtrl.cpp:302–319` defines the optional Filename,
Status, added/removed lines, modification date, size and repository-gated LFS
lock columns and reads saved column settings. Sync's corresponding initialization
at `SyncDlg.cpp:1069` starts with Extension/Status/added/removed, alongside Path,
and does not restrict the shared optional-column mask.

Native Resolve now uses `ResolveDlg.FileColumns` with that initial Path/Extension
layout, a fixed native checkbox column, configurable optional columns, saved
visibility/order/widths and an owned Reset columns question. Sync retains its
`ConflictSyncDlg.FileColumns` settings and five initial columns and now permits
the shared optional columns. LFS lock columns follow each repository's existing
LFS-availability policy. Resolve reads filesystem facts, optional diff statistics
and requested LFS ownership through its existing cancellation-owned refresh;
the default report does not fetch diff statistics or contact an LFS lock server.

The report keeps one native header/column instance for each definition while
selection, checks or cell contents change. Header sorting uses the model's
stable displayed order, with exact UTF-8 tie-breaking for otherwise equivalent
paths. Resolve mutations still use its `ConflictEntry` stage snapshots, rather
than fabricated ordinary status rows. Sync retains its existing status model
sorting, file actions and quick-Resolve child ownership.

`GitStatusListCtrl.cpp:1639–1668` captures the pointed subitem and places a
keyboard context menu at the selection. Its clipboard group at `1997–2004`
contains Extensions and the pointed-column Copy command. Native reports now
capture row and column for pointer invocation, clear the pointed column for
Shift-F10/accessibility Show Menu, and retain highlighted rows plus the selection
mark. Resolve adds Extensions and pointed-column Copy; Copy all follows current
visible-column order. Sync retains Extensions and adds the pointed-column form.
Literal paths and cell contents are not translated or display-escaped when
copied. The on-screen report escapes line separators and tabs to keep rows on
one physical line.

Native selected-row Space uses Resolve's existing checked-selection rule.
Pointer checkboxes continue to derive their next state from model membership.
Double-click excludes the checkbox column and invokes the captured file's
conflict editor. Native keyboard copy and source icons follow the originating
preferences. Menus retain one-use model receipts plus report presentation epochs;
changed contents, columns, sorting, blocking children or retirement invalidate
obsolete callbacks. Header commands use the same presentation guards.

The shared refresh coordinator now accepts a native report client as well as its
existing SwiftUI probe. Refresh retains its ticket until the exact displayed
native row IDs arrive, or cancellation/retirement releases the wait. Sync retains
working-file drag payload/access through the actual drag-session completion.
Owned reset questions drain the actual native sheet before returning; forced
retirement cancels them. Resolve retains its reset task through controller release.
Sync's report feedback occupies a fixed band to avoid moving the table when its
refresh/error state changes.

## Validation and remaining scope

The authored `conflict-report` receiver covers actual native defaults/header
identity, selection/checks/Space, published focus, Shift-F10/accessibility popup
entry with an injected popup presenter, exact clipboard routes, typed size sort,
request order, saved layout, configured-font auto-size, reset No/Yes/forced
retirement, both Remember policies and changelist-bearing Sync refresh/cancel.
It retains private repositories/preferences/pasteboards and hidden windows.
The grouped driver additionally accepts retained `legacy-sync`, `sync`,
`resolve-files`, `resolve-drop` and `refresh` cases. No new CI invocation is added.

The [grouped checkpoint](qa/conflict-report-family-2026-11-22.json) records one
successful Debug app build and twelve distinct native case/Git combinations
cumulatively. New report interactions, retained Sync conflict/recovery, Resolve
file/drop actions and Commit/Status/Revert refresh consumers pass with system and
bundled Git. Pre-build review repaired ungrouped refresh identities, remembered
selection/focus and custom-font autosizing. No Core source changed or Core suite
was repeated.

The original fixture failures remain recorded: exact callback diagnostics proved
the `/private/var` versus standardized `/var` root mismatch, and an owned Zombie
diagnostic identified the retained drop fixture's manual NSWindow double release.
Root normalization and explicit fixture window ownership preserved the behavioral
assertions; only affected/remaining cases were repeated. All 21 logged compiler
and receiver PIDs are absent, with no workspace runtime images or signals.
The existing Sync CI entry point includes the new report receiver, but no hosted
pass is inferred. Signed build54 is a separate frozen source snapshot and does
not include this implementation; installed52 remains unchanged.

Remaining acceptance includes actual pointer/keyboard/VoiceOver gestures, light
and dark layout, all optional-column metadata/statistics/LFS combinations,
conflicted gitlinks and partial failures, cross-owner drag receivers, signed
Finder grants and supported platform versions. This family does not certify the
whole Resolve/Sync dialog, every GitStatusListCtrl command-mask corner case,
external editors, full application parity or App Store readiness.
