# Cherry Pick parity audit

Status: backend implemented; native Log handoff and Cherry Pick dialog are pending.
This document does not establish complete Cherry Pick or Rebase parity.

## Upstream reference

Pinned TortoiseGit revision: `7338078f8ddd924b8cddee35f512f2286072136d`.
`src/TortoiseProc/GitLogListAction.cpp`, `ID_CHERRY_PICK`, opens `CRebaseDlg`
in Cherry Pick mode with every selected Log commit. It does not execute a lone
`git cherry-pick` immediately. `RebaseDlg.cpp` prompts for Parent 1 or Parent 2
when replaying a merge commit. Pick, Skip, Edit, Squash and ordering belong to
the selected commit plan.

## Implemented backend

`GitRepository.cherryPickPlan(revisions:)` accepts the Log's newest-first
selection and prepares oldest-first replay. It captures immutable commit IDs,
target HEAD and symbolic branch identity. Starting on a different branch at the
same hash is rejected. Duplicate selections, stale targets, invalid plans,
first-retained Squash and missing/invalid merge mainlines are rejected.

Cherry Pick uses Git's interactive replay based at the captured target HEAD.
Existing target history remains the base; selected commits are appended.
Pick, Skip, Edit, Squash and reordered plans share the existing Rebase recovery
commands. Originally empty commits are retained; commits whose patch becomes
empty stop for recovery instead of silently dropping their changes.

For a merge, the selected mainline determines the patch. A temporary one-parent
Git object preserves the merge tree, original author/date and message, with that
mainline as parent. It changes no reference or index while preparing the plan.
The replay then copies its patch onto the target. This differs internally from
upstream's direct `cherry-pick -m` engine. Both mainlines have been compared
against actual `git cherry-pick -m` output trees and author/message metadata.

The application's headless sequence-editor entry point records the Cherry Pick
mode and synthetic-to-original commit mapping in the worktree's `rebase-merge`
directory before Git starts executing the todo. Reopened sessions display the
original selected merge IDs and metadata, including after a conflict or Edit
stop. Continue, Skip and Abort use Git's persistent replay state. Aborting
restores the captured target branch and HEAD. Git removes session metadata when
the operation ends.

## Verification and remaining work

Focused `RebaseTests`: 15 tests, zero failures on 2026-10-06. These include
ordinary Rebase regression coverage and Cherry Pick selection/Skip, stale branch
identity, both merge mainlines, Edit/reopening/Continue, conflict/reopening/Abort,
merge-conflict/Skip, reordered Squash, detached HEAD and originally empty commits.
They execute the real application's headless editor rather than a mock editor.
Unsigned Debug and App Store build/package results are recorded separately in
`qa/cherry-pick-backend-2026-10-06.json`.

Pending: route single/multiple Log selections to the native plan; match Cherry
Pick labels, controls and merge-parent interaction; implement remaining upstream
options such as cherry-picked-from attribution and squash author/date choices;
verify root/Octopus commits, linked-worktree Cherry Pick, patch-becomes-empty
interaction, dirty-target handling and displayed UI/keyboard/accessibility.
The current Log still uses its old single-commit Cherry Pick confirmation.
Signed sandbox execution and App Store acceptance are not established by these
unsigned checks.
