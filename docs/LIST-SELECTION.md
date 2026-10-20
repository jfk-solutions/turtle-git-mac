# Choosing list selection highlighting

Open **Settings → Advanced** and edit `FullRowSelect`.

- `true` highlights a selected item's whole row. This is the default.
- `false` highlights its primary label, leaving the other columns in their
  ordinary presentation.
- An empty value restores the default when you Apply.

Apply accepts the change; Cancel discards the draft. The setting belongs to the
preferences of the window that opened the list.

The preference applies to file lists, repository contents, worktrees, LFS locks, reference leaves,
containing references, Synchronization file/reference/tag lists, operation
results, Import Patch, Find results and the corresponding Settings lists.
A checkbox remains a checkbox; selecting a row does not stage, unstage or
change the checked files. Copy, keyboard navigation and context commands still
operate on the selected row identities.

Log, Reflog, Rebase and embedded revision-history lists always highlight full
rows, following TortoiseGit. Repository and reference namespace trees, Blame's
source grid and editors retain their own selection behavior.

The primary label follows its logical column after you reorder or resize
columns. Long labels are clipped to the available cell, and hidden primary
columns do not move the highlight to a different field.
