# Missing staged-file recovery source family

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.

## Source behavior

`src/Git/GitStatusListCtrl.cpp`, `UpdateFileList`, lines 4130–4193 reads
working-tree changes and visits each entry. Added, replaced or modified entries
whose working paths no longer exist receive three choices: Restore from index,
Remove from index and Ignore. A checked Do the same for the rest retains that
choice only within this read. Restore uses `git checkout -- <path>`; Remove uses
`git rm -f --cache -- <path>`. Errors are reported per file. Successful operations
produce the refresh-required notice; the source does not automatically reread
status after its own recovery operations.

`CommitDlg.cpp` and `ChangedDlg.cpp` invoke this shared status-list path. Resource
captions are in `src/Resources/TortoiseProcENG.rc` (the missing-file, restore,
remove and apply-to-rest strings). This is distinct from ordinary Revert or a
selected-file Remove command.

## Native connected workflow

Commit and Working Tree run the shared recovery within the status read that
owns the candidate snapshot. The native three-choice sheet belongs to that exact
window. Remembered choices, individual errors and the final refresh notice share
that owner; cancellation, close, a superseding read and Quit confirmation must
prevent late prompts or mutations. A successful recovery leaves the current read
as a snapshot until the user explicitly refreshes.

Core candidates capture literal stage-zero blob/link entries and absent-path
state. Recovery validates the captured entry, HEAD and destination; other index
entries are preserved. Restore exports through Git's checkout filtering into
private output and publishes without replacing a recreated destination. Remove
uses a private index and commits under the real index lock. This adaptation
preserves the source action's purpose while refusing stale destructive work.
The last publication rename uses the same pinned parent directory, including
when the working tree is on another volume. Existing symlink parents and nested
repositories are refused. A noncooperating process can still relocate a pinned
parent after the final identity check; descriptors prevent symlink traversal and
the exclusive leaf rename prevents replacing a recreated file, but this does not
claim a filesystem-wide transaction. External-volume runtime acceptance remains
open.

See [the user guide](MISSING-STAGED-FILES.md).

## Grouped checkpoint

The [dated record](qa/missing-staged-recovery-2026-10-20.json) records 16 distinct
relevant Core methods passing, the final Debug app, and eight native case/engine
pairs across Commit, Working Tree, choices and ownership using system and bundled
Git. It retains the initial Unicode fixture failure, actor-isolation fixture
compilation failure, and production repository-owner URL-metadata defect. Only
the affected Core methods/app/native group were repeated after their repairs.
The native checks use private repositories/preferences, offscreen windows and
actual owned sheets; all nine receivers, including the failed first receiver,
were reaped and independently observed absent. This is scoped local evidence,
not a complete hosted CI or full dialog parity claim.

## Remaining acceptance

Physical keyboard, accessibility, installed/signed Finder entry points, external
filter providers and the full hosted integration suite remain independent gates.
Unmerged index stages and gitlinks are outside this recovery action. Complete
Commit and Working Tree parity remains tracked in their respective audits.
