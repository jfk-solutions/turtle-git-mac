# Rebase and Cherry Pick amend-failure recovery

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This is one recovery family within the partial native `IDD_REBASE` replacement.

## Pinned behavior

`RebaseDlg.cpp` at 1630–1745 validates the stopped message, attempts the
Edit/Squash commit and handles failure before advancing the current row:

- A dirty tracked worktree or index receives the ordinary error and stays stopped.
- A clean tracked worktree and index receive the Git diagnostic with **Retry**
  as the default and **Ignore** as the second choice.
- Retry returns to the stopped dialog. It does not immediately execute the
  failing command again. The user can correct the problem or message and Continue.
- Ignore advances using the actual HEAD. When the next retained row is Squash,
  source metadata comes from that HEAD while the requested message remains the
  squash accumulator. It does not pretend the failed amend succeeded.

`Git.cpp` at 2618–2654 defines this cleanliness check over tracked worktree and
index changes, excluding submodules. Untracked files do not make this check dirty.
The native port reuses the existing replay-inspection implementation.

The earlier conflict path has a separate boundary: initial commit failure at
1480–1486 always reports an error. Only a subsequent message amendment at
1509–1533 offers the clean Retry/Ignore choice. The native checked-file backend
combines selection and message in one commit; its initial commit failure must
remain an ordinary error. Subsequent stopped-message amendment uses the shared
recovery contract.

## Native ownership and persistence

The implementation records the reached stopped occurrence, actual HEAD, intended
message and Git diagnostic together with session/plan witnesses. The owned alert
keeps replay, repository access and Quit ownership while the answer is pending.
Closing or retiring the owner cannot approve Ignore. A late answer is revalidated
against the live repository before continuation.

Reopening retains a pending failure instead of silently repeating the failed
amend. Retry retains the editable draft. Ignore consumes the captured decision
and advances without another invocation of that amend. Changed HEAD, plan,
session or tracked payload requires a fresh review; cancellation preserves the
actual stopped state for Continue or Abort. Accepted continuation bookkeeping
must be resumable without treating a partial return as a successful replay.

Git's native sequencer can issue another amend for a clean pending fixup chain.
Ignore therefore also captures the exact native fixup metadata and retires that
matched bookkeeping when accepting a pending Squash. It does not run the rejected
message commit implicitly through `rebase --continue`. The requested accumulator
and actual HEAD metadata retain their distinct roles. The existing metadata
journal records the complete before/after transition; an interrupted publication
recovers the committed side or restores the old side without overwriting unknown
external bytes. A resumed accepted Ignore checks cleanliness again.

## Verification boundary

The [grouped checkpoint](qa/rebase-amend-recovery-2026-10-25.json) records 37
distinct selected Core methods cumulatively passing, a current Debug build and
all three native families passing with system and bundled Git. The real owned
alert, default Retry button, diagnostics, actions, draft/Undo preservation,
reopening, cancellation/retirement and stale-session refusal are exercised.
All seven attempted receivers, including the initial failed fixture run, were
reaped and independently absent. No complete Core or hosted suite was repeated.

Two new Core cancellation fixtures initially expected the wrong error type.
Their focused repair checks the established partial-output cancellation result
while retaining the recovery assertions. One native Squash fixture incorrectly
assumed every group member was absent after a private reset; it now compares the
actual captured tree, index and file presence/bytes. Passing cases were retained.
The clean Squash case explicitly discards its private pending changes before the
failure; ordinary dirty Squash does not qualify for Ignore. Actual hook counts
remain exactly one through Ignore, including native sequencer continuation.

The native checked-file path still consolidates the source's initial original-
message commit and subsequent rewritten-message amendment. This batch preserves
its initial-failure behavior; complete two-phase hook invocation equivalence for
that consolidated path remains open.

Physical keyboard/VoiceOver, signed installed replay, minimum supported macOS,
physical Intel execution, complete hosted CI and full source-dialog parity remain
open. This family does not certify the complete Rebase dialog.
