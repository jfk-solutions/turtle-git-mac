# Rebase and Cherry Pick execution recovery

Target: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
The connected implementation has a focused Core and grouped native checkpoint;
its scope and repairs are recorded below.

## Source behavior

This family extends `IDD_REBASE` and `IDD_REBASECHERRYPICK` from
`src/Resources/TortoiseProcENG.rc`. The pinned `RebaseDlg.cpp` blob is
`92f8f3d666bcc43a83b311e6e35d84feb895be05`; source checkbox and failure
captions are retained from `Languages/Tortoise.pot`
(`5f9bcca2ac872bf55098b6dfa53c477a03378534`).

`src/TortoiseProc/RebaseDlg.cpp:2265–2323` distinguishes a failed replay with
working-tree conflicts, an empty result, and an ordinary Pick that failed without
conflicts. The last case shows `IDS_CHERRYPICKFAILEDSKIP` with **Skip**, **Retry**,
**Cancel**, and **Do the same for the rest**. Retry reruns the current item; Skip
resets its failed changes before marking that occurrence skipped. The remembered
choice applies to subsequent failures in this replay, and Retry clears it.
The source's separate `RunGitCmdRetryOrAbort` (`:3045–3062`) retains the command
through an owned Retry/Abort decision when reset/checkout cleanup fails.

The native Git sequencer owns its replay state. Retrying a stopped occurrence
must resume that sequencer using checked original-session/occurrence/HEAD and
index/worktree intent. Issuing a fresh cherry-pick blindly could apply the same
change twice. A failed Skip must retain the requested Skip/reset intent rather
than retrying the original Pick. Empty-result, conflict, Edit/Squash-message and
split recovery remain distinct workflows.

## Connected native implementation

- Typed non-conflict Pick failure classification and captured replay intent.
- Checked Retry and Skip/reset over the same failed occurrence, with changed
  session, HEAD, todo, index or working-tree rejection.
- Native source-labelled choices and a per-replay remembered Skip decision.
- Prompt ownership, cancellation, retirement and late-answer fencing while the
  existing replay worker/access/Quit ownership remains active.
- Recoverable cleanup failure handling and refreshed progress/occurrence rows.
- Focused real-Git Core and hidden native fixtures, ready for the grouped checkpoint.

The failed-Pick prompt keeps source order **Skip / Retry / Cancel**, with Skip
as default and Escape cancelling. Its checkbox retains **Do the same for the
rest**. Cleanup retains **Retry / Abort**, with Retry as default. The actual
failed occurrence, exact cleanup command and diagnostic appear in the owning
prompt; a fixed-height selectable native text view bounds the diagnostic while
keeping the complete progress log available. Original Skip/Refresh artwork
accompanies recovery controls. Both prompt families inherit their owner's
visibility for hidden checks.

Native Cancel always stops recovery even if the checkbox is checked. The pinned
source condition also evaluates its checked rest flag when handling the button,
which can cause checked Cancel to skip; that destructive button/checkbox quirk
is deliberately not reproduced. Cleanup **Abort** stops the cleanup decision;
it does not silently invoke the main replay **Abort** rollback. A durable
approved Skip remains distinct from Pick/Commit, including reopening and ordinary
Continue after cleanup failure. Cleanup Retry preserves an accepted rest choice;
failed-Pick Retry clears that choice as upstream does. Recovery refreshes the
owned sequencer's saved signing option from current effective `commit.gpgsign`,
matching source fresh per-Pick commands. A requested signature stays requested;
explicitly disabling signing or repairing its configuration can unblock Retry.

The classifier supports applied-but-commit-failed Picks and safely identified
pre-apply Picks rescheduled by Git's sequencer. Failures before any replay or
Pick exists—such as rejected checkout, a pre-rebase hook, invalid setup or dirty
preconditions—are not skippable occurrences. They retain the existing corrected-
cause Start retry with plan/reference revalidation. Conflicts, true empty
commits, Edit, Squash and split retain their separate prompts and recovery.
Actual structural Merge instructions, external/apply-backend/custom sessions
without TurtleGit occurrence identities, and terminal non-Pick failures retain
their existing error/recovery routes; this batch does not certify those paths.

The hidden receiver renders actual AppKit alert content offscreen as
`rebase-failed-pick-light.png`, `rebase-failed-pick-dark.png`,
`rebase-cleanup-retry-light.png` and `rebase-cleanup-retry-dark.png` when
`TURTLEGIT_REBASE_RECOVERY_CAPTURES` is set. No screen-capture API or visible
window is needed. The final captures were inspected after the focused capture-only repair. They
show inactive native content without compositor chrome; they do not prove
physical keyboard behavior or complete upstream visual parity.

The [batch checkpoint](qa/rebase-execution-recovery-2026-10-19.json) records
executed checks, repairs and acceptance limits. Two reference-update Core cases
require Git 2.38 or newer; their fixture cannot exercise updateRefs on older Git.

No complete dialog, physical keyboard/VoiceOver, signed Finder/sandbox or hosted
CI acceptance is claimed by this scoped record.
