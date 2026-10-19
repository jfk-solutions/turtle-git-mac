# Local reference engine source family

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
This family connects existing native reference workflows to their selected source
engine; it does not certify complete Browser, Log, Reflog or Sync parity.

## Source contracts

`src/Git/GitRevRefBrowser.cpp:44–205` selects command 18, ForeachRef, only without a
merge-status filter. Only merged / Only unmerged continue through Git commands,
as the source explicitly avoids the library descendant walk for those filters.
The library branch retains original symbolic names while resolving their objects,
uses annotated-tag messages/tagger metadata, leaves noncommit metadata blank,
and supplies commit authors/committers, upstream and branch descriptions.

`src/Git/Git.cpp:1828–1904` selects command 16, BranchContains. Equality and
ancestry both count. Annotated tags are fully peeled, and symbolic local/remote
reference names are preserved. The containing-reference dialog calls this path
from `CommitIsOnRefsDlg.cpp:461`.

The same dialog's completion calls `GetRefList` at line 446. `Git.cpp:2148–2189`
uses the **master libgit2 switch**, independently of command 18's mask bit.
Its library callback lists names without requiring object resolution. The CLI
branch uses `show-ref -d` and suppresses duplicate peeled-tag names. Completion
failure does not prevent a typed revision lookup, matching the owning dialog.

`Git.cpp:3371–3425` selects command 8, DeleteTagBranch. It strips a `^{}` suffix
and deletes the named local branch, tag, remote-tracking reference or other
eligible reference. `BrowseRefsDlg.cpp:784–835` and
`GitLogListAction.cpp:1051–1058` are connected callers. Deleting a branch on a
server remains the separate DeleteRemoteRefs/Push11 route; ordinary Push retains
its existing command workflow.

The source default `0x66780` enables ForeachRef18 and DeleteTagBranch8, and leaves
BranchContains16 off. Disabling the master switch selects the CLI branches.

## Connected native implementation

Core captures the requested backend before the accepted read or deletion batch.
Typed helper replies retain literal reference names, complete object IDs,
symbolic targets and bounded metadata. Native Browser inventory, revision
completion and containment results retain their backend identity so a cached
result cannot be reused for another selected engine.

Local deletion retains the captured name, object and symbolic-target identity.
The helper checks and removes the named reference under reference locks; deleting
a symbolic alias must never delete its target. Checked-out branches, including
linked worktrees, remain protected. A changed selection refuses before mutation.
Browser batches stop on the first error and retain earlier completed deletions.
The shared history route retains its existing choices, stash specialization and
owned remote transport. Log, Reflog, graph and Sync consumers capture the same
accepted backend through confirmation and completion.

Branch configuration cleanup is staged under a held configuration-writer lock,
then committed after checked local-branch removal. This is an
explicit ordering adaptation: the pinned `git_branch_delete` may remove its
configuration before deleting the reference, while the checked adapter first
commits the validated reference deletion. A cleanup failure must report the
already-completed deletion rather than imply rollback. Remote-tracking deletion
does not remove an unrelated local-branch configuration section.

## Validation and remaining scope

The [dated evidence](qa/local-reference-engine-2026-10-20.json) records 45
relevant Core methods, the final Debug app, actual helper contracts on arm64
and x86_64, and the grouped native workflows with system and bundled Git passing.
It retains the XCTest fixture-name compile failure and the unbundled graph-runtime
lookup failure, with only the affected Core/native checkpoints repeated.
The native group covers Browser, containment, Log, Reflog, Sync and graph
consumers, exact warning receipts, partial completion and actual helper/child
cancellation/drain. All three receivers, including the failed attempt, were
reaped and independently observed absent. Offscreen split views emitted zero-size
layout diagnostics; this does not certify physical layout or whole-dialog parity. The pinned library helper currently supports SHA-1
repositories; a selected unsupported object format fails explicitly. The typed
channel bounds reference names/fields, rows and total output instead of
publishing a truncated catalog. Physical keyboard/accessibility, installed signed grant behavior,
minimum-version/runtime acceptance and full hosted integration remain separate
acceptance gates. Other unconsumed source commands include MergeBase7,
CheckCleanWT12, CheckConflicts13, GetCommit14 and GetConflictInfo17.
