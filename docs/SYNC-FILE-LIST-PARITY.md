# Synchronization incoming and outgoing file lists

This family follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, `IDD_SYNC`: `SyncDlg.cpp` 1050–1111 initializes
the two `CGitStatusListCtrl` instances with separate `InSyncDlg` / `OutSyncDlg`
settings and only two-revision and unified-diff action masks. Clipboard commands
remain available through `GitStatusListCtrl.cpp` independently of that mask.
Working-tree mutations and Explorer actions are outside these source lists.

## Source behavior

The source columns are Path, Extension, Status, Added and Deleted. Path remains
visible. Incoming and outgoing column visibility, order and widths belong to
separate layouts. Header sorting toggles direction; a new column starts ascending,
line counts sort numerically and paths break ties. Reset column order asks before
restoring source column defaults.

Double-click compares the clicked file. Return compares the selected files in
display order. Shift chooses the alternate comparison tool and the existing
multiple-file warning remains in the comparison session. Historical rename paths,
gitlinks, file-type changes and source status colors use the pinned comparison
snapshot, rather than current working-tree contents.

Git names can contain tabs and line separators on macOS. Native row captions show
those controls as ⇥ and ↵ so one file occupies one row; tooltips and every
clipboard format retain the original path. Exact UTF-8 identity also distinguishes
canonically equivalent Unicode spellings in historical trees.

The source Copy to Clipboard submenu includes full paths, relative paths, file
names, extended information and the clicked column. “Extended” means visible
columns with headers; it does not mean file extensions. The Extension column
provides the latter. The native shortcut adapts source Ctrl-Shift-C to
Command-Shift-C for paths and status with headers. Clipboard text follows the
shared status-list formatting and exact repository paths.

## Native implementation and ownership

`SynchronizationFileList.swift` replaces both SwiftUI file tables with native
tables. The shared state retains byte-exact paths and independent layouts;
historical file-type/submodule icons and configured row colors remain visible.
Return and double-click use the existing comparison session, including warnings
and alternate tools. Shared comparison readers accept an optional exact display
order without changing default callers' ordering.

Row and header actions expire after changes to their owner, tab, selection or
snapshot. Reset owns its Yes/No sheet and rejects late answers after closure or
replacement. Keyboard copy belongs to the actual focused table and key window,
preserving text-field copying elsewhere. Forced closure cancels and drains actual
comparison preparation and reset questions before releasing the parent.
Comparison errors appear in the active list's parent status and clear on a new
attempt or projection. Invalid outgoing comparisons hide Out Changelist; a valid
empty file projection retains the source no-differences caption.

The Debug build and both native cases pass with both system and bundled Git.
After visual inspection exposed the newline display defect, only the affected
list cases were repeated with both engines. Strict actual cell geometry and raw
tooltip assertions pass. Core operations are unchanged; no Core suite was repeated.
The [checkpoint](qa/sync-file-list-2026-10-20.json) records actual row/menu/keyboard
behavior, independent preferences and private pasteboards, snapshot/tab/selection
changes, busy/Quit/sheet/closure guards, exact comparison dispatch, failures,
affected repairs and owned process cleanup. The hidden receiver injects only the
exact key-window query while retaining actual first-responder ownership.

Four complete owned-window captures were reviewed. They deliberately show a saved
Status-first layout with Lines removed hidden, two canonically equivalent historical
paths and a literal tab/newline filename; the list scrolls independently of the
fully visible tabs and footer.

| List | Light | Dark |
| --- | --- | --- |
| Incoming | [Light](site/assets/sync-incoming-files-light.png) | [Dark](site/assets/sync-incoming-files-dark.png) |
| Outgoing | [Light](site/assets/sync-outgoing-files-light.png) | [Dark](site/assets/sync-outgoing-files-dark.png) |

Physical pointer/menu tracking, VoiceOver, installed signed grants and complete
source acceptance remain independent requirements. This family does not certify
the entire Synchronization dialog or full port.


## Captured file drag delivery — October 21, 2026

The [revision-list drag family](FILE-LIST-DRAG-PARITY.md) adds native datasource file writers to both lists. It deliberately reads snapshot.from, matching SyncDlg's Rev2=old/base convention. Missing base paths fail instead of substituting target or rename-source bytes. Render-epoch and live owner guards reject stale/new requests, while accepted file promises retain their own authority. See the family checkpoint for actual delegate delivery and remaining physical/signed acceptance.
