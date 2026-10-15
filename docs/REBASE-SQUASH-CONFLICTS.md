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

Squash conflict checkboxes are active, including Space/check toggles and retained
choices during refresh. As upstream does, Squash Continue consumes the resolved
staged index rather than passing checkbox selection through the Pick/Edit index
loop. Unchecking a group file does not remove it from the staged combined commit.
Full physical checkbox/keyboard/layout acceptance remains open.
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


## Message preparation and continuation — October 15, 2026

Replay actions capture the draft, checked paths, phase, HEAD and message
preferences before asynchronous work begins. Pick/Edit resolution, applied Edit
and combined Squash approval use the shared Strip Commented Lines and Sanitize
Commit Message formatter with its operation token. The configured Git comment
character is respected. An empty prepared message returns to the message tab
without committing and retains the editable draft.

Squash conflict Continue retains its separate staged-index semantics and waits
for combined-message approval. The checkbox UI now remains active in that phase
without enabling the Pick/Edit checked-file commit path. Checkbox changes never
stage or unstage files by themselves.

Continuation validates the stopped occurrence, phase, durable Squash/Split state,
remaining commands, conflict set and HEAD before preparation, after answers, and
again in the backend before continuing or amending. A changed session is refused.
The checked-file commit now receives the same cancellation token as preparation.
Cancelled or retired preparation cannot publish a late commit. Changes to the
visible draft or preferences while preparation is pending do not redirect an
already captured action. Failed preparation in the same phase retains the draft.

[Grouped evidence](qa/replay-message-family-2026-10-15.json) separates actual Git
commit messages, combined group files/first author/Latest date, empty-message
refusal and cancelled/retired preparation from physical input and signed
acceptance, which remain open. This is a partial replay port.
