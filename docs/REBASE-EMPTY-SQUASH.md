# Empty Squash groups

A Squash group can become empty when later commits remove earlier group changes
and conflict resolution restores the destination contents. TurtleGit now checks
the staged group tree against its destination parent when approving the combined
message and offers **Commit**, **Skip** and **Cancel**.

Commit keeps one message-only group commit, with the first author's identity and
the captured first/latest/current author-date policy. Skip drops the entire
group, including its first commit, then replays later commits against the group
parent. Cancel stays in the message editor with the draft, HEAD and index intact.
No decision is applied merely because the group is empty; the core also requires
an explicit choice. Native prompts retain their Cancel default.

## Recovery

The native decision captures HEAD, replay step, stopped entry identity and
original replay head. Changes to that captured state reject the decision.
Skip rejects unstaged tracked changes before changing history. A durable Skip
intent records the old group HEAD and destination parent before the soft reset.
If Git fails after the reset, reopening retains the approved Skip and Continue
retries it. Split remains unavailable during that recovery. The intent is scoped
to its replay step and is ignored once Git advances.

## Verification and limits

Real Git fixtures cover all three choices after a Squash conflict, including a
later commit whose parent must be the kept empty group or the destination for
Skip. Tests verify first author/latest date, cancellation, retained index/files,
stale HEAD rejection, unstaged-change rejection and an index-lock failure after
reset followed by reopening/retry. The whole-native receiver drives the actual
models through conflict resolution, reopened combined approval, each choice and
final replay. Prompt answers are injected and views remain hidden.

Two consecutive conflicts within one empty group are also exercised; see
[repeated Squash conflicts](REBASE-SQUASH-CONFLICTS.md#repeated-conflicts-within-a-group).

Displayed prompt focus, gestures and accessibility, advanced rewritten-reference behavior and
signed sandbox/App Store acceptance remain unverified. Squash checkbox acceptance
also remains pending. This is not complete replay or TortoiseGit parity.

Pinned upstream: `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/RebaseDlg.cpp` (`Squash_Edit`, `IsResultingCommitBecomeEmpty`,
`IDS_CHERRYPICK_EMPTY` and `ResetParentForSquash`).
Evidence: [QA record](qa/rebase-empty-squash-2026-10-06.json).
