# Add commits to Rebase / Cherry Pick

This records a partial native port at pinned TortoiseGit revision
`7338078f8ddd924b8cddee35f512f2286072136d`.

## Source behavior

`RebaseDlg.cpp::OnBnClickedButtonAdd` opens `CLogDlg` in selection mode, allows
multiple selection and leaves the plan unchanged on Cancel. It loads the selected
commits, assigns Pick and inserts them above the existing newest-first list.
Repeated commits are permitted. Add is disabled during replay and with Preserve
Merges. `LogDlg.cpp` returns selected hashes in visible row order.

## Native implementation

Add now opens the native Log window as a sheet, with multiple-selection OK/Cancel.
The same Log search/history controls and original action artwork are used. Existing
single-selection pickers keep their behavior; their callbacks are explicitly
labeled to avoid ambiguous trailing-closure matching.

Accepted rows are resolved to immutable commit objects and inserted above the
current visible plan in picker order. Their replay follows the existing entries,
oldest first. Existing actions, destination hashes, branch identity and attribution
options are retained. New rows default to Pick. Cancel and empty selections leave
the plan unchanged; failures are atomic. The parent plan cannot start or receive
another handoff while the sheet is open. Pending handoffs resume after selection
and any resulting insertion have completed.

Repeated commits have distinct row identities. These identities and source hashes
are written by the application's headless sequence editor into worktree-local
replay metadata before execution. The Git todo contains commit hashes, not row
identifiers. Edit/conflict recovery keeps the original commit hash and separately
identifies the stopped occurrence, so selection and remaining rows remain distinct
after reopening. Git removes that metadata when the session ends.

An added plan becomes executable even when the original Rebase was up to date.
The backend forces the custom todo to run while preserving the user's Force Rebase
checkbox value. Capture validation still rejects stale references and malformed
plans. Active replay and Preserve Merges disallow additions.

## Add before a plan is loaded

Add remains enabled while branch/upstream are incomplete or invalid, matching the
upstream Choose Branch state. Accepted revisions become an editable draft with
numbered rows, actions, ordering and file/message inspection. Cancel retains that
draft. Start stays disabled until a valid destination plan is captured; resolving
and editing draft entries changes no HEAD, reference, index or working file.

Changing the references rebuilds the commit list from those references, as upstream
`FetchLogList` does. That replaces earlier draft entries; choose the references and
then Add again to include commits outside the generated range. If Add supersedes
an in-flight reload with valid references, the backend captures a fresh plan and
appends the accepted selections instead of leaving the window without a runnable
plan. Incomplete references remain a draft without an interrupting revision alert.

## Evidence and limits

20 focused `RebaseTests` pass: the earlier Rebase/Cherry Pick coverage plus picker
insertion order, repeated identities, actual replay, repeated Edit/reopening/
Continue, up-to-date Rebase execution, Preserve Merges rejection and atomic draft
resolution with unchanged HEAD/index. The native
receiver additionally checks multiple-selection acceptance/order/guards, original
single-selection behavior, Add cancellation, default actions, duplicate rows and
recovery selection. System and packaged Git checks, build/package audits and exact
source hashes for the latest draft work are recorded in
`qa/rebase-draft-add-2026-10-06.json`; the previous `c86aa06` checkpoint is recorded
in `qa/rebase-add-2026-10-06.json`.

The native receiver hosts real views without displayed windows; it injects picker
results rather than displaying and clicking the actual sheet. Displayed picker
focus, close/OK/Cancel gestures and screenshot acceptance remain unverified.
Preserve Merges customization, Split and complete conflict/
squash controls remain pending. Signed App Store execution is not established.
