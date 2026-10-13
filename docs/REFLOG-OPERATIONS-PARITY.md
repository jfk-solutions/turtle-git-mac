# RefLog revision operation handoffs

The pinned `GitLogListBase.cpp` offers Merge, Rebase, Cherry Pick and Revert to
eligible historical rows, and `GitLogListAction.cpp` opens their existing workflows.
RefLog inherits those actions. Its single-row Revert has one entry for a normal
commit, a parent submenu for a merge, and no root-commit entry. Cherry Pick gates
on the first displayed selected commit matching HEAD; it does not filter each
selected hash independently.

The native RefLog context menu now offers those four operation families with
original icons. Merge/Rebase require one non-HEAD, non-stash row and a working tree.
Cherry Pick retains the source first-selected-row gate, display order and event
duplicates. Revert preserves normal/merge-parent/multiple-selection behavior.
Picker windows omit the mutation family. An active merge disables all four.
RefLog reload now reads the worktree-specific MERGE_HEAD state through the shared
Core helper.

RepositoryModel connects the entries to the existing Merge window, Rebase/Cherry
Pick window and History Revert workflow. Merge receives the displayed commit hash;
Rebase prefers a known local reference, then a known reference, then the hash.
These are review/open handoffs, not a new mutation implementation. Their existing
confirmation, progress, conflict recovery, cancellation and Commit post-actions
remain responsible for execution.

`referenceLogOperationEntries` reads raw immutable author/message/parent metadata
for Cherry Pick/Revert. It validates the captured selectors/hashes, queries unique
objects in batches of 128, then restores event order and duplicates. A display
mailmap must not become the author of a replayed commit. Optional index writes are
disabled; the reader does not change HEAD, index or working files.

The model owns a cancellation token and generation for that read. It captures the
reference, selected event records, callbacks' inputs and repository grant. Closing
or refreshing cancels it; late or replaced-record results cannot open a workflow.
The reader remains in global Quit accounting until it settles, including if an
injected read ignores cancellation after its window closes. The table's retained
context target also validates its snapshot before starting this pipeline.

Core checks use repeated reflog events, full Unicode message/author data and a
mailmap to verify display order/duplicates, raw signatures, validation/cancellation
and repository preservation. Native checks dispatch the actual menu targets,
verify local-reference Rebase defaults, HEAD/root/active-merge gates, merge Revert
parent selection, and forced-close cancellation/late-result fencing. Callback
probes capture the requests; they do not execute an actual replay or revert. The
shared production workflow bindings are inspected separately in code.

Edit Notes, patch creation, Bisect and commit combination were subsequently added
with their own partial caller checks; see REFLOG-NOTES-PATCH-PARITY.md and
REFLOG-ADVANCED-PARITY.md. Exact whole-menu ordering/conditions, remote/tag guessing,
physical workflow/window recovery from RefLog, multi-revision merge/root error
variants, moving references during execution, signed file grants and full
application parity remain open. Existing workflow tests do not certify every new
RefLog caller end to end.

Twelve focused Core tests, the Debug build, four grouped native receivers across
system/bundled Git and two site documentation checks passed. All four receivers
were reaped. [Evidence](qa/reflog-operations-2026-10-13.json) records the limited
routing/read scope; these passes do not prove full RefLog execution or signed
App Store readiness.

## RefLog transport family (2026-10-13)

Push, Pull and SVN DCommit now open the existing native workflows from RefLog.
The pinned `GitLogListBase.cpp` lines 2207–2250 and `GitLogListAction.cpp`
lines 965–1010 define the source visibility and Push preset behavior. Ordinary
Push requires one non-stash event with an associated local branch or tag;
Shift-right-click exposes Push for other single events. Push prefers the local
branch, then tag, then immutable commit hash, strips annotated-tag peeling,
and preserves the saved All Branches option because RefLog has no pointed graph
label. A name moved externally falls back to another matching name or the captured
hash instead of opening Push at a different commit.

Pull appears for selected HEAD with a working tree and no active merge. Its
preparation rechecks HEAD and merge state. SVN DCommit shares Push's source
visibility and additionally requires Git-SVN metadata. Metadata is resolved from
the common Git directory, including linked worktrees; the existing SVN workflow
retains responsibility for runtime availability and execution. These menu actions
open review dialogs; they do not push, pull or publish merely by opening the menu.

Transport preparation retains the repository grant, owns cancellation and Quit
accounting, and rejects closed/refreshed/replaced event results. Revision choosers
omit the transport family. Menu grouping now puts single-row Merge before Reset,
Rebase before Export, Revert/Notes before reflog deletion, Combine beside the
multi-revision comparison, and transport before Clipboard. Named reference deletion is implemented in the batch below;
full dynamic-menu parity and signed physical acceptance remain open.

Three focused Core tests, the Debug build and four grouped native receivers with
system/bundled Git passed. Core covers annotated-tag peeling, branch preference,
moved-name fallback, old-HEAD/merge Pull rejection and missing/present SVN metadata.
The native table checks Push/Pull callback dispatch, ordinary versus Shift Push,
original transport icons and busy retained-command refusal. It does not execute
remote transport or SVN publication. Existing table/advanced regression checks
also passed; all four receivers were reaped. See
[batch evidence](qa/reflog-transport-2026-10-13.json).

## Named reference deletion (2026-10-13)

RefLog now includes the inherited source `ID_DELETE` family in addition to its
separate reflog-event Delete action. One associated reference produces **Delete
refs/…**; multiple references produce **Delete branch/tag** with named entries and
**All**. The current branch is excluded. Annotated-tag names are normalized to
one target so peeling cannot produce duplicate deletions. The original Delete
artwork is used for the parent and choices. Choosers omit mutation menus.
The source references are `GitLogListBase.cpp` lines 2241–2284 and
`GitLogListAction.cpp` lines 1031–1068.

Each target uses the existing History deletion engine: ordinary branch/tag
Delete/Abort (including unmerged-branch warning), remote server-and-local versus
local-tracking choices, and stash Delete/Drop one/Abort. Log and RefLog now share
one native confirmation builder with Abort as default. SSH preparation and prompts
use the existing transport coordinator, retaining the repository grant. There is
no new Git command implementation for the menu family.

Before prompting, a named reference must still peel to the captured event's
commit. After confirmation, the shared engine reloads object/stash state and
rechecks the current branch. A moved reference fails visibly. This is preflight
validation, not an atomic lock against another Git process during local deletion.
All processes names in source order, stops on Abort/local failure, and retains
successful earlier deletions; source remote/stash error continuation remains.
Partial success refreshes the RefLog reference map and repository views.
Deletion failures use one acknowledged sheet instead of also triggering the
general RefLog alert; standalone model owners retain the general-error fallback.

Reads/mutations own a cancellation token and global Quit accounting until settled.
Busy/menu-sheet gates and captured reference/event guards prevent retained menus
from redirecting commands. Forced close cancels pending work; a late confirmation
cannot authorize deletion. Actual remote/stash partial effects are not rolled back.
The existing Git progress/SSH behavior remains shared with History.

[Native fixture](qa/reflog-reference-deletion-native-2026-10-13.swift) checks actual
branch/tag deletion, current-branch exclusion, annotated-tag normalization, original
submenu/All icons, shared Abort default, stopping All after a successful first
reference then Abort, a reference moving in confirmation, deletion on a private
bare remote, stash Drop one/Delete all, forced-close refusal and Quit ownership.
Table regression runs also check transport/copy/columns. Tests use private Git
repositories and injected choices, not physical button clicks. Signed remote
credentials, physical menus/confirmation, bare/chooser permutations and whole
RefLog visual parity remain open. [Batch evidence](qa/reflog-reference-delete-2026-10-13.json)
records accepted results and limits.
