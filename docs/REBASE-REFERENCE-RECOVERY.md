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

Arbitrary external todo edits, notes/post-rewrite mapping after whole-group
Skip, displayed dialogs and signed sandbox execution still need separate
verification. This is not complete Rebase or TortoiseGit
parity. Evidence: [reference recovery QA](qa/rebase-reference-recovery-2026-10-06.json).

Upstream comparison: pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, `RebaseDlg.cpp`'s
`m_rewrittenCommitsMap`, group completion and `RewriteNotes`. TurtleGit uses Git's
sequencer for this macOS integration; Git's reference-update configuration is
separate from TortoiseGit's notes rewrite mapping.

The focused native fixture can be rerun with
`python3 scripts/check-cherry-pick-native.py --references-only --git /usr/bin/git`.
The default receiver continues to run all replay fixtures.

## Repeated Add and omitted commits

A repeated Add row has its own occurrence ID. Generated reference updates remain
associated with the original occurrence, including when the copy moves before
it and is skipped. The sequence editor reads the captured identity metadata
before merging reference commands; it rejects duplicate original identities
without replacing Git's todo. It no longer treats repeated source hashes as an
ambiguous reference anchor.

Git does not generate a reference update for a patch-equivalent commit that it
omits from the initial todo. TurtleGit preserves that behavior: the omitted
source reference stays at its original commit while references for retained
commits update after native Edit approval. This distinction follows Git's
sequencer rather than inventing an update for a command Git did not generate.

Real fixtures and the native receiver cover repeated Add, duplicate IDs, Skip,
end moves, reopening at the original occurrence, and final reference
associations. They also cover a genuinely omitted patch-equivalent source and a
retained source edited after reopening. Native feature checks run on supporting
Git versions; older runtimes are explicitly skipped for this feature. Evidence:
[repeated/omitted reference QA](qa/rebase-repeated-references-2026-10-06.json).

Source check: packaged Git 2.55.0's `sequencer.c`,
`todo_list_add_update_ref_commands` attaches branch decorations to commit items
present in the generated todo. The complete pinned source archive is retained
under `build/git-source` and included with the packaged runtime's license files.
