# Synchronization file activation

This family is compared with pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, `SyncDlg.cpp` incoming/outgoing
menu masks and `GitStatusListCtrl.cpp` Return, double-click and default-menu
handling. It is a partial workflow audit, not certification of the Sync dialog.

The incoming/outgoing reports retain the source Rev1/Rev2 pairing, five optional
file columns, icons, immutable revision drag payloads and ordered multi-selection.
Their default **Compare two revisions** popup item is bold. Return/keypad Enter
operates on all highlighted rows; double-click retains its pointed-row scope.
Native key handling requires the actual event window, visible report, originating
key owner and first responder. It cannot take Copy or Return from a text field,
foreign window, retired report or unavailable operation.

The conflict report has a separate selected Return callback. It reads actual Git
conflict stages for all highlighted paths, preserves report order, captures rebase
identity, backend, repository access, source window, preferences and Shift intent,
then uses one owned selection warning. Root rechecks those exact stages and rebase orientation after the suspended
fresh-entry read and before each editor handoff. The explicit popup Edit Conflict mask remains singleton-only;
selected Return does not reuse a `paths.first` context-menu callback.

Incoming/outgoing preparation also retains a per-operation Sync source predicate
through the warning and every selected launch. This predicate distinguishes the
accepted comparison's own busy/sheet lifecycle from replacement of the Sync form,
tab, selection, sort order, snapshot or settings. A presentation menu epoch is
unsuitable because the accepted operation itself publishes busy changes.

Conflict workers retain the existing Sync/global operation counter until actual
Git reads, injected replies and paired progress-sheet drainage finish. Source
invalidation cancels their tokens; a late answer cannot launch replacement rows.
Completed native editor resolution retains the existing originating-preferences
refresh-after-resolving policy.

The dedicated receiver is
`docs/qa/sync-primary-activation-native-2026-11-23.swift`, callable as
`SyncPrimaryActivationVerification.verify(base:git:)` within the private grouped
native cohort. It checks four real conflicts, selected keypad Return, one warning,
captured Root launch intent, actual progress preparation, source retirement and
Quit ownership, plus incoming/outgoing revision order, default menu appearance,
strict keyboard scope and selection replacement during a held warning. It uses
private repositories, preferences and pasteboards, with invisible owned windows
and injected child presentation. It does not establish physical Finder behavior,
external tool behavior or every upstream Sync control's visual parity. Actual
execution results are recorded in `qa/add-resolve-sync-family-2026-11-23.json`.
The scoped private system and bundled Git checks passed. The fixture initially
lacked the tracked remote needed for real tab admission and then observed the
initial idle state before SwiftUI started loading; both fixture repairs and the
focused reruns are retained in that receipt.

Remaining scope includes full physical interaction/visual comparison of every
Sync tab, hosted integration results for the final source, and upstream controls
outside this file-activation family. No completion percentage is inferred.
