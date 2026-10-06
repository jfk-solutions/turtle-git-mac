# Cherry Pick parity audit

Status: native Log handoff and Cherry Pick plan implemented; displayed acceptance
and advanced options remain pending.
This document does not establish complete Cherry Pick or Rebase parity.

## Upstream reference

Pinned TortoiseGit revision: `7338078f8ddd924b8cddee35f512f2286072136d`.
`src/TortoiseProc/GitLogListAction.cpp`, `ID_CHERRY_PICK`, opens `CRebaseDlg`
in Cherry Pick mode with every selected Log commit. It does not execute a lone
`git cherry-pick` immediately. `RebaseDlg.cpp` prompts for Parent 1 or Parent 2
when replaying a merge commit. Pick, Skip, Edit, Squash and ordering belong to
the selected commit plan. The pinned documentation screenshot is
`doc/images/en/GitCherryPick.png`; its disabled reference row, numbered commit
list, Pick ALL/ordering controls, attribution checkbox, lower tabs and initial
Continue/Abort buttons were compared with the native implementation.

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

The Cherry Pick checkpoint `a2a00d8` recorded 16 focused `RebaseTests`, zero failures
on 2026-10-06. The subsequent [Add audit](REBASE-ADD-PARITY.md) records 20 passing
focused tests and the extended native checks. These include
ordinary Rebase regression coverage and Cherry Pick selection/Skip, stale branch
identity, both merge mainlines, Edit/reopening/Continue, conflict/reopening/Abort,
merge-conflict/Skip, reordered Squash, detached HEAD, originally empty commits
and attribution compared with `git cherry-pick -x` for ordinary/merge commits.
They execute the real application's headless editor rather than a mock editor.
Unsigned Debug and App Store build/package results are recorded separately in
`qa/cherry-pick-native-2026-10-06.json`. The earlier backend checkpoint
`021e611` is separately recorded in `qa/cherry-pick-backend-2026-10-06.json`.

## Native handoff and plan

Log now routes its single/multiple visible-order selection to the shared native
plan. The old one-command Cherry Pick confirmation is no longer reachable from
that menu. The original icon appears beside the single/multiple menu labels.
First-selected HEAD, bare and active-merge contexts omit the operation; busy/note/jump
states disable it. Merge, root and stash rows can be handed to the plan; HEAD
later in a multi-selection does not suppress the command, matching upstream.

Cherry Pick mode disables Branch/reverse/Upstream/browse/Onto, with an empty Branch
and HEAD Upstream, and hides Force/Preserve. Numbered rows show action icons,
hash, message, author and formatted date. Pick ALL, action menus and Up/Down edit
the plan. The attribution checkbox persists `CherrypickAddCherryPickedFrom` and
adds the original commit ID (including for merge commits). Initial Continue/Abort
and Revision Files/Commit Message tabs follow the pinned resource/screenshot.

Retained merges prompt for a mainline using parent subjects and hashes. These
prompts occur before any replay, rather than upstream's just-in-time prompts.
Cancel leaves HEAD unchanged. All Git-supported parents are offered; upstream
explicitly offers two. Active sessions recover Cherry Pick mode, original commit
IDs and Edit/Continue/Skip/Abort controls. Closing is blocked during mutations or
a parent sheet; closing an idle active window leaves recovery metadata intact.
Repository status/Commit and all Log scopes are refreshed after mutation.

A whole-native-source headless receiver hosts the actual Log table and Rebase
view. With both system Git and packaged Git 2.55.0, it checks menu labels/icon,
single/multiple/merge/root/stash handoff, first-selected HEAD semantics, selection
order and guards, numbered rows,
actions/order, attribution persistence, parent metadata, cancel-with-unchanged-HEAD,
Edit/reopening/mode recovery and Continue. Parent answers are injected: this does
not establish displayed NSAlert appearance, default focus, keyboard behavior or
window title/close gestures. No displayed app or receiver windows were launched.

Add now uses a native multi-select Log sheet, preserving picker order and repeated
row identities through recovery. See [Add audit](REBASE-ADD-PARITY.md).

Pending: remaining author overrides; root/Octopus replay,
linked-worktree Cherry Pick and dirty-target interactions;
full conflict tabs and stash/restore; displayed layout/keyboard/accessibility and
signed sandbox execution. Existing Rebase screenshots predate these changes and
are not presented as Cherry Pick screenshots. App Store acceptance is unverified.

Empty-patch recovery now passes the actual native receiver with Git 2.37.1,
2.39.5, system 2.50.1 and packaged 2.55.0. An already-applied patch stops without
conflicts, selects its original ID and native Skip leaves target HEAD unchanged.
The focused suite contains 21 passing tests, including reopening that state.
See [Git compatibility](REPLAY-GIT-COMPATIBILITY.md) and
`qa/replay-git-compatibility-2026-10-06.json` for scope and reproducibility.

Squash now pauses for an editable combined message and applies the captured
first/latest/current author-date preference. Each group requires approval, with
the first author retained. See [Squash workflow](REBASE-SQUASH.md).

Edit now has a multiline tab; Continue applies its message. Split reuses full
native Commit selection with parent-based first amendments, normal subsequent
parts and reopening after cancellation. See [Edit/Split](REBASE-SPLIT.md).

The shared Conflict Files tab now retains resolved changes and routes existing
native editors and Resolve commands with replay-specific side labels. A
conflicted Edit cannot Split or amend destination HEAD before application.
Checkbox-selected Continue and displayed acceptance remain pending.
See [Conflict Files](REBASE-CONFLICT-FILES.md).
