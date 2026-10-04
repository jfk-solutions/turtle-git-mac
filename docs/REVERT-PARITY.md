# Working-file Revert parity

The references are the `IDGITLC_REVERT` branch in `GitStatusListCtrl.cpp` and
[RevertProgressCommand.cpp](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/ProgressCommands/RevertProgressCommand.cpp),
pinned by `upstream.json`. The latter source blob was verified as
`8efbc404abacc78e8a1ff0b92d7bbc724e91356e` before implementation. This is working-file
Revert, distinct from reverting a historical commit in Log.

## Native Commit menu

Revert appears for selected versioned rows with the original `menurevert.ico`.
Modified/conflicted selections ask before proceeding; No is the native default.
Added-only selections become unversioned without deleting their working contents.
Successful actions clear selected checks and refresh the list and patch view.
Saved Restore after commit copies remain available independently.

Normal Revert restores HEAD contents to both index and working files. Amend Revert
uses the first parent regardless of the displayed comparison. An unborn repository
can revert staged additions without creating HEAD. Files replaced during Revert
are moved to macOS Trash, adapting the upstream default recycle-bin behavior.
Deleted files are recreated; renamed files return to their original names.
Submodule pointers are reset without changing their checkout or local edits.
Renamed initialized submodules use Git's reverse move to preserve checkout
metadata and update their path in `.gitmodules`, followed by pointer restoration.

The backend rejects mixed unversioned/ignored selections, changed status rows,
unsupported filesystem objects and parent paths escaping the working tree before
working-file changes. It locks the actual index, including linked-worktree indexes, and runs
Git writes against a private copy. The real index is replaced only after all steps
succeed. A checkout/filter error leaves the original index intact and reports
structured Trash locations for recovery. Working-file changes are not a filesystem
transaction: partial Git checkout or submodule moves can still require recovery.
Concurrent external filesystem edits are not fully prevented.

## Verification

Eleven real Git tests cover binary/staged/later working contents, unrelated staged
changes, literal Unicode/newline/pathspec-looking filenames, additions before the
first commit, renames, deletions, parent-based amend, symlinks, escaping parents,
invalid/stale selections, existing index locks, initialized/uninitialized gitlink
conflicts, submodule rename metadata, linked worktrees, text conflicts with an
active merge and a failing required checkout filter.

The focused Revert/Restore/Working Tree suite passed 21 tests. The unsigned Xcode
Debug app build and bundle audit passed, including the embedded Finder extension
and all 59 original icon assets. Native QA used one
disposable application instance: No preserved HEAD and selected/unrelated staged
and working contents; Yes restored only the selected modified file and left its
later working bytes in Trash. Its row disappeared. Added-file Revert preserved
disk bytes, removed its index entry and displayed an unchecked unversioned row.
The process was closed after these checks and process absence verified. A transient
UI observation failure was investigated using the same live process.

## Remaining parity

Dedicated Revert dialog and Finder dispatch, upstream progress/notifications and
cancellation, recycle-bin preferences, post-Revert submodule comparison, copy and
case-only rename combinations, renamed-but-missing destinations and root-amend
behavior still need audit. Native multi-selection, staged mode, amendment, conflict
and submodule UI acceptance remain to be exercised. Signed sandbox Trash access
and external-volume behavior are unverified. These source inventory entries
remain partial; the app is not yet ready for App Store distribution.
