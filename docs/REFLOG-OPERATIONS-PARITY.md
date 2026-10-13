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
