# Squash conflict recovery

TortoiseGit uses a separate Squash conflict path: it verifies resolution and moves
on to combined-message approval. It does not execute the Pick/Edit checked-file
index loop in that branch. TurtleGit continues Squash using the resolved staged
index and Git's durable interactive-replay state.

The Conflict Files tab now compares a Squash group with its destination parent,
so earlier group changes remain visible alongside the latest conflicted files.
Status icons, colors, extension and added/removed line counts use that same base.
The staged resolution survives reopening. Continue prepares the combined-message
pause; the multiline editor retains source messages and literal comment lines.
Commit approves the combined message, keeping the first author's identity and
the captured first/latest/current author-date policy. Reopening also restores that
pending message and policy.

## Phase-specific actions

The primary button now follows upstream's phase captions: Commit for ordinary
Pick/Edit conflict recovery, Continue for Squash conflicts, Commit for combined
Squash-message approval, Amend for an applied Edit, and Done when finished.
The separate native Amend button is removed. The backend rejects amendment
before a commit reaches its applied Edit pause, including after Pick or Squash
conflicts have been staged as resolved.

## Verification and remaining differences

Focused Rebase tests exercise Squash conflict resolution, reopened combined
approval, exact Unicode/comment messages, source-author retention and all three
date policies. They reject premature Pick/Squash amendments without changing
HEAD. The whole-native receiver checks the actual full-group file list and
phase captions, stages a Unicode/newline path, reopens both conflict and message
phases, and finishes with the first author's identity and expected date policy.
Views are hosted hidden and prompt responses are injected; displayed layout,
button focus, keyboard gestures and accessibility remain unverified.

Squash conflict checkboxes remain disabled. Upstream displays active checkboxes,
but its Squash conflict Continue branch does not consume their selection through
the Pick/Edit index loop. Exact checkbox behavior/layout still needs acceptance.
Empty groups now offer Commit/Skip/Cancel, including durable Skip recovery.
See [empty Squash groups](REBASE-EMPTY-SQUASH.md) and repeated-conflict coverage
below. This does not establish complete replay
parity, signed sandbox execution, Finder acceptance or App Store distribution.

Pinned upstream: `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/RebaseDlg.cpp` (`Squash_Conclict`, `ResetParentForSquash`,
`ListConflictFile`, `SetContinueButtonText`).
Evidence: [QA record](qa/rebase-squash-conflicts-2026-10-06.json).

## Repeated conflicts within a group

Continue can stop at another Squash conflict before the combined-message editor
opens. The group stays together across reopening, and final approval uses the
last source commit's date when Latest is selected. If a middle resolution adds
no changes, its source message still belongs in the combined draft, as in
TortoiseGit. TurtleGit captures the source messages and rebuilds the later group
sections while retaining Git's first section, including an approved Edit.
Literal comment lines and cherry-picked-from attribution remain in that draft.

A deliberately skipped step is excluded. Skip records its step before invoking
Git so that an editor launched by the same command sees it. A failed Skip that
has not advanced rolls that record back. Older replay configurations without
captured source messages keep their existing Git-generated draft behavior.

Real fixtures cover two consecutive conflict stops, reopened resolution, retained
middle messages, Latest dates, normal/empty group commits, whole-group Skip and
future ancestry. An index-lock failure verifies that a failed middle Skip does
not remain excluded. The native receiver covers repeated conflict/reopening and
empty-group Commit/Skip/Cancel with injected answers on four Git versions.
Displayed interaction and advanced rewritten-reference behavior remain unverified.
Evidence: [repeated-conflict QA](qa/rebase-multiple-squash-2026-10-06.json).
