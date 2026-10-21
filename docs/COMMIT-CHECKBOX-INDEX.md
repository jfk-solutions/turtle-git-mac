# Checkbox commits and unchecked index entries

Checkbox mode follows TortoiseGit's whole-file Commit preparation. Checking a file
commits its current whole-file contents. Before committing, unchecked tracked
rows in the captured dialog scope are reset in the index to the comparison base:
HEAD normally, or the parent for a parent-based amendment. Working files are not
rewritten. Unchecked modifications become unstaged; checkbox mode does not preserve
partial staging. Use **Staging support** to commit the exact existing index instead.

The default-on Advanced setting **ReaddUnselectedAddedFilesAfterCommit** restores
unchecked added and renamed destinations from their current working bytes after
the Git attempt, and re-applies unchecked staged deletions/rename-source removals.
This runs after success or a rejected/cancelled commit, matching the source queues.
Turning it off leaves these rows unstaged or untracked after preparation. An
unchecked missing working file is not turned into a staged deletion merely by
this restoration. Literal paths, including newlines and wildcard-looking names,
use NUL-delimited Git path packets.

The native Commit owner captures the visible rows and preference for each attempt.
Staged paths remain visible even when outside the initially selected scope, as in
the existing Commit list. Unversioned and ignored rows do not
acquire ordinary reset behavior. After an explicit or remembered Ignore-unresolved decision,
unchecked tracked conflicts follow the comparison-base reset policy too. This
changes their index stages while retaining the working files. Staging mode never
applies this checkbox policy.
Amend, message-only and pending-operation commits retain their existing selected
commit-tree and author/parent rules while the unchecked real index is prepared.

When **Select files automatically** is enabled, checkbox mode also selects
conflicted files, matching the source mask. With that preference off, they can
still be checked explicitly. Live unmerged entries begin unstaged in staging
mode. Checking or staging a conflicted file records its current working content,
including any conflict markers still present. A missing selected file resolves as removal where that
operation applies. The unresolved warning and merge information hint retain their
own remembered choices; Saved Data can clear them. See the
[source and checkpoint boundary](COMMIT-CONFLICT-INDEX-PARITY.md).

In staging mode, Stage and Unstage apply to both the displayed old and new names
of a renamed file. Unstaging and then staging the same retained row keeps that
rename intact, even when Git temporarily lists its destination as untracked or
pairs identical contents with another deleted file. Copies affect their destination;
they do not stage unrelated edits in the copied source. The operation checks the
current conflict state before changing the index, while retaining the rename paths
selected in the dialog. Other staged files and working bytes remain in place.

The selected commit tree uses the existing private index. This keeps unchecked
contents out of the commit and preserves selected staged modes. The real index
receives checked whole-file contents and the source's unchecked-row updates.
Programmatic selected-file APIs can omit the explicit dialog policy; those callers
retain their existing index-preservation contract.

Restoration uses a fresh cleanup token after cancelled Git progress so an already
cancelled commit token cannot skip the source queues. The owner/operation remains
alive through that cleanup. If restoration fails, the original attempt's success
or failure remains authoritative; progress receives a warning to refresh and
inspect the index. A completed commit is not reported as a failed commit that
should be repeated. CLI preparation applies the source command groups in order;
an earlier group's index changes can remain if a later group fails. Libgit2
prepares its index with one write. Post-progress restoration starts only after
Git commit progress was actually attempted. Neither workflow is a transaction
against external Git writers. Files,
other branches and repository history are not rolled back.

Source: pinned `CommitDlg.cpp::PrepareIndexForCommitWithoutStagingSupport` and
post-progress `mgtReAddAfterCommit`/`mgtReDelAfterCommit`, at
`7338078f8ddd924b8cddee35f512f2286072136d`. Full action-mask combinations, external
writers/hooks, physical controls and signed sandbox acceptance remain under audit.
