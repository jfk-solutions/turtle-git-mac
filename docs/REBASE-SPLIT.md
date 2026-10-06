# Edit and Split Commit

An **Edit** action pauses after applying its commit. The Commit Message tab now
contains a multiline editor. **Continue** amends with the edited message and
resumes replay; blank messages are rejected. Working Tree remains available for
file edits and staging.

To divide the stopped commit, check **Split commit**, then **Continue**. TurtleGit
opens its full native Commit dialog over the replay window. The first dialog uses
Amend Last Commit with comparison against the parent, matching TortoiseGit's
`m_bCommitAmend` and `m_bAmendDiffToLastCommit` settings. Select the files for the
first part and enter its message. The existing staging/partial-patch tools are
also available. Subsequent parts open normal Commit dialogs.

Tracked changes remaining after a part automatically open another Commit dialog.
When the tracked tree is clean, **Add another commit?** offers No and Yes. No
continues the original replay; Yes opens another normal Commit dialog. Untracked
files alone do not force the loop, matching upstream's clean-worktree check.
The dialogs cover the whole project, retain their compare, Log, Blame, resolve,
ignore, revert and rename interactions, and expose Commit without ReCommit or
Commit & Push. New-branch and amend-mode changes are disabled for this workflow.

Cancel before the first part changes no commit, index or file and returns to the
Edit pause. When that pause came from a checked conflict-resolution commit,
unstarted Split retains a return record. Cancel restores the prior applied Edit
phase, approved message and recovery count without moving HEAD or altering the
index or working files. Repeated Split/Cancel and reopening remain possible.
A changed recovery HEAD is rejected before replacing the prior record.
Cancel after a part retains the partial history and remaining files;
reopening Rebase or Cherry Pick restores split mode and Continue opens the next
normal Commit dialog. Abort restores the original destination branch and HEAD.
Parent replay controls remain disabled while a child selection is open.

Splitting is also available at a squash-message pause. The first part inherits the
first author's identity and captured first/latest/current date choice. Its commit
consumes the pending squash-message request so Continue does not amend a second
time. Additional parts use the normal Commit author controls.

## Recovery and limits

Worktree-local `turtlegit-split.json` records the stopped entry ID, replay step,
expected HEAD and completed part count. Each commit checks these values before
using the existing checkbox/index commit backend. Stale child dialogs and attempts
to continue with uncommitted tracked changes are rejected. Git keeps its original
todo and branch restoration state throughout the split.

This remains a partial port. Displayed child-sheet layout/gestures, all shortcuts,
accessibility, empty-result choices, complete conflict tabs and signed sandbox
execution are not established. The parent is native macOS; upstream's Windows
modal Commit dialogs are adapted as native sheets. No new screenshots establish
the layout of this workflow yet.

Focused Rebase tests cover file-selected first amendments, later
parts and future replay, stale part rejection, unchanged-HEAD cancellation,
multiline Edit continuation (including originally empty commits), Abort and
squash splitting without a second amend. The whole-native receiver passes with
Git 2.37.1, 2.39.5, system 2.50.1 and packaged 2.55.0. It hosts real Rebase/Commit
views and drives the actual models through selection, automatic next part,
Cancel/reopening and final Continue. It also checks captured squash-date retention
through the Commit date callback. Sheets and prompt answers are injected; this
does not establish displayed acceptance. Unsigned builds, package audits, NOTICE
comparisons and site generation pass. Evidence: `qa/rebase-split-2026-10-06.json`.

Pinned upstream: `src/TortoiseProc/RebaseDlg.cpp` (Edit/Squash_Edit,
`m_bSplitCommit`, the Commit dialog loop and `IDS_REBASE_ADDANOTHERCOMMIT`), and
`src/Git/Git.cpp` (`CheckCleanWorkTree`).

The checked-conflict Edit → Split → first-dialog Cancel transition has a real
Git regression fixture and whole-native coverage, including reopening and final
message approval. Evidence: [Split return QA](qa/rebase-split-return-2026-10-06.json).
