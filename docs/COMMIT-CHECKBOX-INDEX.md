# Checkbox commits and unchecked index entries

Checkbox mode follows TortoiseGit's whole-file Commit preparation. Checking a file
commits its current whole-file contents. Before committing, unchecked ordinary
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
the existing Commit list. Unversioned, ignored and unresolved-conflict rows do not
acquire ordinary reset behavior. The existing explicit Ignore-unresolved workflow
retains its unmerged stages. Staging mode never applies this checkbox policy.
Amend, message-only and pending-operation commits retain their existing selected
commit-tree and author/parent rules while the unchecked real index is prepared.

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
should be repeated. Preparation can leave partial index changes if a later Git
command fails; this is not a transaction against external Git writers. Files,
other branches and repository history are not rolled back.

Source: pinned `CommitDlg.cpp::PrepareIndexForCommitWithoutStagingSupport` and
post-progress `mgtReAddAfterCommit`/`mgtReDelAfterCommit`, at
`7338078f8ddd924b8cddee35f512f2286072136d`. Full action-mask combinations, external
writers/hooks, physical controls and signed sandbox acceptance remain under audit.
