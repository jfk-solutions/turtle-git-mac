# Rebase reference recovery

TurtleGit retains Git's generated `update-ref` commands when the repository has
`rebase.updateRefs` enabled. Replacing the interactive todo previously discarded
those commands, leaving related branches at their old commits despite the Git
setting. The native plan now carries each reference along with its associated
source commit when the user changes the order.

References within a Squash group move after its final Squash step. They therefore
point at the approved group commit, or at the group's destination parent if the
user skips the whole empty group. References before and after the group retain
their own associations. Git still applies its normal protection for branches
checked out in other worktrees and validates reference updates itself.

Reference commands do not count as commit rows in TurtleGit's progress or replay
identity metadata. Reopened conflict recovery and message approval retain the
correct source identity and author-date policy even when Git's own command count
includes reference updates. This changes behavior only when Git generated such
commands; older Git versions without this feature retain their existing replay.

Cherry Pick explicitly disables `rebase.updateRefs` for its internal replay.
Selecting commits for Cherry Pick must not move the source branches. The
configuration override is confined to the child Git command.

## Linked worktrees

Empty-group Skip stores its approval in the active worktree's Git directory. A
failure after the soft reset can be reopened and continued there. A real
index-lock fixture verifies that the main worktree remains inactive and retains
its original HEAD and source branch while the linked worktree completes Skip.

## Verification and remaining work

Real Git tests cover normal and empty group Commit/Skip; references before, inside
and after the group; reordered commit associations; a branch checked out in
another worktree; and linked-worktree Skip failure/reopening. The native receiver
checks the actual Rebase model's step identity and reopened empty-group approval
with prefix/group/future references on Git runtimes advertising `update-refs`,
including abbreviated todo commands.
It also checks Cherry Pick source branches with the repository setting enabled.
Views remain hidden and prompt answers are injected.

References associated with automatically omitted patch-equivalent commits,
repeated Add occurrences, arbitrary external todo edits, notes/post-rewrite
mapping after whole-group Skip, displayed dialogs and signed sandbox execution
still need separate verification. This is not complete Rebase or TortoiseGit
parity. Evidence: [reference recovery QA](qa/rebase-reference-recovery-2026-10-06.json).

Upstream comparison: pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, `RebaseDlg.cpp`'s
`m_rewrittenCommitsMap`, group completion and `RewriteNotes`. TurtleGit uses Git's
sequencer for this macOS integration; Git's reference-update configuration is
separate from TortoiseGit's notes rewrite mapping.

The focused native fixture can be rerun with
`python3 scripts/check-cherry-pick-native.py --references-only --git /usr/bin/git`.
The default receiver continues to run all replay fixtures.
