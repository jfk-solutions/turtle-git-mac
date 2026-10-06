# Log Revert parity

Pinned source: `7338078f8ddd924b8cddee35f512f2286072136d`.

## Upstream mapping

`GitLogListBase.cpp` offers **Revert change by this commit** for one non-root,
ordinary revision with a working tree and no active merge. Merge commits get a
submenu for every parent. Parent titles contain the 1-based number, subject
truncated at 20 UTF-16 units and an eight-digit hash; a failed metadata read falls
back to number/hash. Root, bare, active-merge and stash/index-parent cases omit the
command. The native menu now maps these rules and original `menurevert.ico`.

Parent subjects load using the Log detail reader's owned cancellation token.
Selection replacement/reload/close cancel the reads and prevent stale metadata
publication. Failed individual subjects retain hash-only labels; the menu can use
those labels while metadata loads. Cached immutable metadata is pruned on reload.
AppKit needs no Windows accelerator escaping, so ampersands remain literal.

`GitLogListAction.cpp::RevertSelectedCommits` asks **Revert the selected commit(s)?**
with Yes/No and No as the default. The native parent-window alert retains that
question and default, with the selected parent label in its supplementary text.
The captured revision and mainline are not taken from a later table selection.
No does not invoke Git. `Git.cpp::GitRevert` uses `--no-edit --no-commit` and the
selected mainline; core revalidates the actual commit and parent range and checks
bare/active-merge state before mutation.

Success presents **Revision(s) reverted. All changes are integrated into your
working tree now.** with OK/Commit. Commit routes to the existing native Commit
workflow with the original repository grant. Status/Commit views and workspace
state refresh after successful or failed mutations; Log reloads after the result.
Git conflicts remain in index/worktree for resolution, with an error reported.
No automatic commit or conflict rollback is introduced.

## Evidence and remaining work

[The verification record](qa/log-revert-2026-10-06.json) records focused real Git
and headless native checks. Tests exercise both merge mainlines, ordinary commits,
root/invalid/active-merge rejection, unrelated staged/working preservation,
conflicts and unchanged HEAD. The bundled App Store Git audit also exercises both
mainlines. Parent metadata tests cover labels, fallback, owned cancellation,
child reaping and independent reading.

Displayed submenu, confirmation default/focus/keyboard, result prompt/Commit
handoff, progress and light/dark acceptance remain pending. Multi-revision Revert,
Skip/Abort continuation, detailed conflict/continue/abort flows, linked-worktree
acceptance and signed sandbox checks remain partial. Cherry Pick still needs its
upstream Rebase-dialog workflow; this change does not provide merge Cherry Pick.
The complete Log/application port remains unfinished.
