# Reverting a commit from Log

Reverting applies a commit's reverse changes to your index and working tree.
It leaves the current commit and branch history intact until you create a new
commit with those changes.

1. Select a non-root commit in Log Messages.
2. Choose **Revert change by this commit** from its context menu. For a merge,
   choose the parent against which the changes should be reversed.
3. Confirm **Yes** to apply the reverse changes. **No** is the default and keeps
   the repository unchanged.
4. Review the result. **Commit** opens the Commit workflow; **OK** leaves the
   changes available for review and committing later.

For a merge, Parent 1 is usually the branch on which the merge was made. Choosing
it reverses the changes introduced relative to that parent. Each submenu item
shows the parent commit's title and abbreviated hash to help you choose. Check
those values rather than assuming which branch a parent represents.

Revert is unavailable for root commits, stash rows, bare repositories and active
merges. If Git reports conflicts, resolve them before finishing the operation.
The app leaves conflict state available; it does not silently roll back changes.
Unrelated changes can remain in your working tree, but overlapping edits may
prevent Git from applying the reverse patch.

Only one selected commit is supported by this native workflow so far. See
[Log Revert parity](LOG-REVERT-PARITY.md) for remaining workflows and verification.
Displayed macOS screenshots for this workflow are still pending.
