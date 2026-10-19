# Missing staged files

Commit and Working Tree can encounter a file whose staged version still exists
in Git's index but whose working copy has disappeared. For example, a newly
added file may have been deleted in Finder after staging it.

When the dialog reads its changes, it offers the same recovery choices as
TortoiseGit:

- **Restore from index** restores the staged version to the working tree. It
  retains the staged contents, rather than restoring the last commit's version.
- **Remove from index** removes the missing path from staging. For a previously
  committed path, this stages its deletion; for a newly added path, it removes
  the addition. It does not delete an existing working copy.
- **Ignore** leaves this path unchanged and continues reading the list.

**Do the same for the rest** applies the selected choice to the remaining missing
files in this read. It is not saved as a preference for later refreshes. An error
reports the affected file and continues through the remaining candidates.

After a successful restore or removal, the dialog asks you to refresh, for
example with **F5**. Its current list describes the snapshot it already read;
it does not silently present that old snapshot as fresh status. Refresh before
choosing further file actions or committing.

Recovery checks the captured index entry and missing destination before acting.
If another application changes that entry or recreates the file while a choice
is pending, recovery refuses the stale operation. Refresh and review the new
state. Cancellation stops the remaining files; an already completed restore or
removal remains in effect.

This recovery concerns missing staged additions, modifications and replacements.
It does not resolve unmerged index stages or restore every deleted file. Use
normal Revert and conflict-resolution workflows where appropriate.
