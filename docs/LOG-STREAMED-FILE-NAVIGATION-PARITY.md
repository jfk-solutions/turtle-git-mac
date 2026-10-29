# Log file navigation during a history walk

This continuation covers read-only commands in the changed-file list after a
historical revision and its files have loaded, while the independent history walk
continues. It complements the existing revision-selection and graph-projection
work; it does not change history limits or claim full Log visual parity.

## Pinned source contract

The source pin is `7338078f8ddd924b8cddee35f512f2286072136d`.
`src/TortoiseProc/LogDlg.cpp::OnLvnItemchangedLoglist` (1869 onward) has its
thread-running selection guard commented out; suppressed display updates are
still a guard. A background walk alone therefore does not make the displayed
revision unavailable for inspection.

The shared changed-file menu and dispatch in `src/Git/GitStatusListCtrl.cpp`
retain the displayed file/revision context:

- `OnContextMenu` (1796–1810) offers Compare two files for two file rows;
  dispatch at 2260 onward carries their selected paths and displayed revision.
- The single-row menu at 1862–1870 offers Show log, old-name history for
  rename/copy rows, and eligible Blame. Dispatch at 2403–2447 passes the current
  revision for ordinary Log/Blame. Old-name Log follows the old path without
  forcing an ending revision when no displayed branch range applies.
- Mark/Compare with dispatch at 2155–2171 stores both the marked path and its
  revision, then compares those endpoints with the later current path/revision.
- The menu at 1875–1888 and dispatch at 2120–2125 and 2682–2686 retain
  historical Export, Save as, Open and Open With. Copy commands at 1997–2004
  and 2671–2680 distinguish paths, names, all information and the pointed column.
- `OnBeginDrag` at 3767 onward constructs the transfer from selected paths and
  the displayed revision. The Mac adaptation offers historical files as copy
  promises rather than permitting mutation of a historical source.

These source clauses describe inspection actions. They do not authorize index,
working-tree or history mutations while another owned operation is active.

## Native action family

Historical Show log, Show log of old name, Blame, Compare two files, Mark for
comparison and Compare with marked file share the inspection admission used by
loaded revision details. Their menu wrappers use the captured inspection receipt
instead of the blanket history `busy` flag. Historical file/path/rename/parent
records remain those selected in the native table; they are not reconstructed
from the workspace repository or a later file highlight.

Show log and Blame retain the selected historical hash. Representable old-name
Log keeps the source's path-following policy. Pair comparisons retain the exact
selected `CommitFile` occurrences, including parent identity. A prepared mark
retains its original revision when another revision becomes current. Existing
raw-path and working-tree eligibility rules remain in force.

Historical Open, Open With, alternative editor, Save revision and Export also
use inspection admission. They retain the selected bytes, backend and editor
settings through the chooser, preview and application handoff. Simple file Copy,
status/column Copy and historical file promises remain available during the
independent walk. Historical promises read through an independent captured Git
actor, so their blob read does not queue behind a held history notes batch.

Root receives the accepted navigation repository captured with the original
preferences and backend. This also prevents an earlier child-submodule route from
supplying a later ordinary file comparison's repository. New independent work,
selection/mark changes, revision navigation, reload, controls, Quit and retirement
revoke obsolete source authority.

Mutation commands retain stricter admission. Historical Restore/Revert and
working-tree Add/Commit/Revert, deletion, flags and lock changes do not become
available merely because loaded historical files can be inspected during a walk.
The default mutation menu wrapper remains separate from inspection admission.

## Owned asynchronous navigation

Submodule history and working-file Blame retain a dedicated file-navigation read.
While that read prepares its exact source, another inspection command cannot
replace it. History completion does not clear the read's busy state; read
completion does not clear an unfinished history walk. The process/read counter
remains owned until the actual work has drained.

`cancelFileNavigationRead` requests cancellation without pretending the worker
has finished. Normal Close first cancels an accepted read and closes after its
actual drain. Forced retirement also retains cleanup ownership. Stale results
and errors cannot present a child against another revision, selection or closed
owner. A successful submodule handoff carries the initialized child repository,
the selected gitlink revision when the captured source backend permits lookup,
and the captured backend. Pinned `CGit::GetSubmoduleHash` returns without a hash
when the libgit master flag is disabled; this request then opens unpinned child
history even if that preference changes before delivery.

A separate `captureFileNavigationOwner` receipt protects Root's delayed viewer
handoffs. It captures the load generation, selected hashes/files, source records
and a dedicated owner epoch. Successful history prefix/final publication preserves
that receipt when its inspected source is unchanged. Native menu receipts still
retire when their presentation/busy state settles. A later refresh or independent
operation cannot revive an earlier viewer request after returning to idle.

The delayed owner receipt excludes its own comparison question's sheet check so
that an attached warning does not cancel itself. New command admission still
refuses sheets and modal windows. The existing file comparison session owns its
question, cancellation and teardown.

Panel and document activities participate in the same aggregate lifetime. A
chooser, queued write or launch does not become unowned when history finishes.
Explicit Cancel, Quit and Close cancel undispatched delivery, detach an owned
panel and reject a late affirmative reply; accepted work keeps its lifetime
until actual completion. A later native selection cannot redirect an earlier
historical Open With request to different bytes. Successful history completion
also preserves an unchanged historical drag source; independent work or source
changes retire the earlier capture.

## Checkpoint and remaining boundaries

[The family receipt](qa/log-streamed-file-navigation-2026-10-29.json) records the
actual grouped build/native outcomes. The new family passed with system and
bundled Git; the retained document Open, historical/range drag and shared-list
regressions also passed. Debug exited successfully with known contradictory exit-zero command
diagnostics; a pristine build log is not claimed. The fixture uses real Git
history, native revision/file selection and the production captured-menu
admission. Its private Git wrapper delays actual notes batches and initialized
child discovery; it does not invent expected history or file records.

The checks exercise read-only callbacks during a held 128-row prefix,
exact old-name/hash/parent and cross-revision mark endpoints, mutation refusal,
stale navigation/reload/Quit receipts, successful-stream owner retention, and
independent submodule read cancellation/normal Close with actual process drain.
The same group exercises exact historical Save/Export bytes, all three document
open routes through an injected application launcher, stale chooser suppression,
actual Save-sheet cancellation, private clipboard values and production promise
delegate delivery. A separate Root-created Log uses its installed comparison
callback to open a real viewer while history remains held, checking source
paths/bytes, preferences and appearance. These adapters do not claim a physical
menu click, external application launch or drag gesture.

The current changed-file adapter makes the actual native table first responder,
clears selection once, and sends a deterministic sequence of owned Down and
Shift-Down events for the contiguous requested rows. Every native index transition
and the final exact model selection must agree. It does not retry selection or
assign the model. This verifies native key handling, not physical desktop input.
On this host SwiftUI supplies an `NSOutlineView`; its original delegate remains
installed while the shared selection decoration observes it. Ordinary
`NSTableView` decoration retains its existing path.

Earlier direct programmatic selection attempts failed. Restoring the original
delegate and retrying appeared to help, but a subsequent unchanged-delegate/style
retry also succeeded; neither delegate assignment nor highlight style was
established as the cause. Stable layout and explicit delegate admission did not
make that setter a reliable user-event simulator. Those failed controls remain
in the receipt and are not counted as functional passes.

The complete keyboard-driven group exposed a real reload/EOF ownership bug.
Reload retained an earlier selected revision and its files, but their detail
context belonged to the preceding load. Final history settlement reselected that
same revision, clearing file selection and revoking an accepted viewer and drag
source. The first accepted prefix containing the selected hash now refreshes
details once for the current load, before inspection. Final settlement preserves
that already-current source. Both Git engines passed the full group with the
original owner, drag epoch and stale-menu assertions.

The retained historical document Open and historical/range drag groups passed.
The existing immediate visual Close contract for preview preparation remains,
with worker/Quit ownership retained until actual drain. The shared-list regression
then located a regular AppKit column-reorder label rectangle defect, separate from
revision selection. The repair anchors real native caption insets to the current
column only for regular AppKit tables (`!observesOutline`); outline geometry is
unchanged. The shared-list group and final adapter recheck passed.

This family checks accepted revision/model files rather than rendered message or
physical input. Earlier native-selection-delivery evidence covers rendered message
and native revision keys. The reported user process is installed build27; its known
rendered-projection gate was repaired in956/newer signed30. User-specific physical
acceptance awaits updated installation; the latest report is not claimed reproduced
in this source. Signed30 excludes the new streamed-file family described here.
