# Branch, tag and worktree creation outcomes

Pinned source: `7338078f8ddd924b8cddee35f512f2286072136d`,
`AppUtils.cpp:1200–1210` branch/tag creation and subsequent Switch, description
and Push, plus `CreateWorktree` at 1217 onward and its successful progress
post-command Submodule Update choice. Related resources are `IDD_NEW_BRANCH_TAG`
and `IDD_WORKTREE_CREATE`. These remain partial family mappings.

## Accepted mutation and later cancellation

Cancellation before creation and a failed Git command remain failures. An actual
successful Git exit is a distinct outcome even when cancellation arrives before
its caller resumes. Branch/tag and worktree creation now retain that accepted
outcome rather than pretending no mutation occurred or retrying creation blindly.
The generic Git runner retains its cancellation contract for unrelated operations.

Creation receipts retain command output and the exact reference or destination.
A separate bounded read records the current object identity or registered
worktree state. Verification failure is an explicit warning on an accepted
command, not permission to recreate it. Remote branch bases retain Git's existing
tracking and moving-reference semantics; annotated tag identity is distinct from
its peeled target. Successful verification stderr is retained separately from
stdout object IDs, so diagnostics cannot turn a valid creation into an invalid
identity. An unrelated writer can move a reference after creation, so
fresh observation is not cross-process serialization.

The native owner adopts accepted creation before checking whether optional work
may continue. A late Cancel stops new checkout, description, Push or submodule
handoffs while retaining the completed creation and its parent refresh. Explicit
recovery uses that remembered outcome; it does not rerun branch/tag/worktree add.
Closed owners cannot publish new dialogs, optional child actions or stale errors.
Existing access leases and operation/Quit counters remain held until work drains.
No cancellation path deletes an accepted reference or checkout to simulate rollback.
A completed verified worktree still permits a new explicit Submodule Update
request after cancellation has drained; cancellation suppresses automatic close
and follow-up, not that later user choice.

## Evidence and limits

The [dated grouped record](qa/creation-outcome-2026-10-29.json) records focused
Core and actual native workflows, real Git publication boundaries, failure and
pre-command cancellation, duplicate/retry behavior and owned process cleanup.
Authored fixtures are not evidence of a pass. Installed build34 predates this
family. Physical menu/prompt gestures, signed external repository grants,
minimum-version/Intel execution, complete hosted integration and full source
layout/accessibility parity remain separate gates.
