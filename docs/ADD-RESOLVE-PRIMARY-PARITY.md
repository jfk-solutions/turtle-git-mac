# Add and Resolve default file activation

This continuation implements the connected Add/Resolve list activation family.
The grouped local checkpoint passed with system and bundled Git; see
`qa/add-resolve-sync-family-2026-11-23.json` for its exact scope and retained
fixture failures. This does not certify the complete Add or Resolve dialog.

## Pinned source contract

At pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`, AddDlg.cpp
62–69 and ResolveDlg.cpp 60–66 instantiate the shared GitStatusListCtrl. Their
PreTranslateMessage handlers (AddDlg.cpp 165–174, ResolveDlg.cpp 157–166) reserve
Control+Return for OK. Ordinary Return belongs to the focused list through
GitStatusListCtrl.cpp 3611–3667: one NumDiffWarning decision, followed by every
selected row in display order. Conflict entries use ConflictEdit; unversioned,
ignored and retained-copy entries use the working preview; ordinary direct
tracked entries use their accepted comparison base. Checkbox membership is
separate from this highlighted selection. The shared double-click handler at
2926–2976 uses its clicked row and excludes the checkbox state icon.

## Native implementation

AddNativeTable has an optional selected-Return handler. Opted-in tables accept
Return/keypad Enter only for their exact visible, enabled native table, first
responder, event window and key owner, with no other sheet/modal owner.
Command/Control/Option combinations pass through. The Add/Resolve native
windows consult the same handler before their default-button equivalent;
Command/Control+Return acceptance and text-field editing remain independent.
Empty or temporarily mismatched selected projections are consumed without
submitting the dialog. Unrelated native report consumers are not opted in.

Add's actual double-action uses clickedRow/clickedColumn, including when other
rows are highlighted. Its checkbox column cannot launch a file action. Explicit
Preview and Compare retain their menu-selected contracts. Resolve keeps its
existing clicked-row callback and receives a separate ordered activateSelection
callback, shared with the native conflict-report control. It does not convert
selected Return into the aggregate Compare command.

Add uses the existing StatusListPrimaryActivation session and retains actual
AddDialogEntry status/type metadata. Resolve uses ConflictListPrimaryActivation
with actual ConflictEntry stage modes/object IDs and captured rebase orientation,
without synthetic porcelain statuses. Source admission captures the original
backend, preferences, tools, conflict identity, alternate-tool intent and exact
source window before asynchronous work. Root consumes the already-confirmed
ordered plan and verifies fresh conflict stage identity before presentation.
After a suspended entry read, Root also rechecks the captured rebase orientation
before launching any external/native editor; equal stages alone cannot certify
the original ours/theirs meaning after the repository operation changes.

## Ownership and refresh

Both source models retain an operation counter and cancellation token through
the warning, Git preparation and Root handoff. Add uses a dedicated receipt that
permits its own busy state instead of rejecting itself through the older idle
comparison guard. Changes to source selection, accepted records, tools/backend,
window ownership or retirement revoke delivery. New refresh requests are queued
until the accepted batch drains.
Stale requests and cancellation of child preparation leave Add open; only its
own Cancel/close request closes that source after acknowledgement.

The source can cancel its own attached warning. Forced Add closure defers its
onClosed callback until the worker acknowledges; Resolve's existing paired-sheet
and release contract includes the primary operation. Quit remains blocked by
the existing real operation counters. An actual conflict-preparation Cancel
stops the batch, so later selected files cannot launch after cancellation.
Conflict editor launch acceptance remains separate from resolution and refresh.

## Prepared coverage and remaining scope

The existing combined native driver retains its prior assertions and adds the
Add/Resolve continuation in the same cached receiver. Private real repositories
contain four conflicts, direct tracked changes, untracked/ignored files and a retained
index-deleted disk copy. Checks cover ordered selected Return/keypad Enter,
one warning and decline, clicked-row activation with multiple highlights,
checkbox exclusion, default-key/field/key-owner guards, real Root child delivery,
actual progress Cancel stopping later files, native source-warning cancellation,
forced source retirement, original Git bytes and close/Quit drainage. These
checks passed in the private system and bundled Git cohort. Physical and signed
acceptance remain separate.

The held-read orientation case changes a private rebase marker while retaining
the exact conflict stages, and requires stale refusal without a viewer or source
closure. Stale tool intent and child-progress Cancel likewise keep the source.

Physical desktop focus, every mixed conflict/tree/submodule combination,
translated bundled presentation, signed sandbox handoffs and the complete
TortoiseGit port remain separate acceptance scopes. Synchronization's consumer
is implemented and documented in its own coordinated continuation; this page
does not claim its checkpoint.
