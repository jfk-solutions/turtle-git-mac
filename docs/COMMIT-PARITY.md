# Commit dialog parity

The reference is `src/TortoiseProc/CommitDlg.cpp` and `IDD_COMMITDLG` in
`src/Resources/TortoiseProcENG.rc`, pinned to the commit in `upstream.json`.
`PrepareIndexForCommitWithoutStagingSupport` implements checked whole-file commits;
`PrepareStagingSupport` enables three-state checkboxes in the same file list and
bypasses checked-file index preparation. These are distinct commit modes.

## Implemented

- Separate native macOS Commit window, retaining its repository permission lease.
- Branch destination, multiline message above the file list, character count.
- Checked paths independent of highlighted rows; All, None, Unversioned,
  Versioned, Added, Deleted and Modified category links.
- Original upstream status icons and context menu artwork; Path, Extension,
  Status, Lines added and Lines removed columns.
- Whole-file checkbox mode stages checked contents, commits only those paths,
  and preserves unchecked index changes. Renames include their old path.
- Enable staging area switches the same file list to native three-state staging
  checkboxes: off for unstaged, on for staged, mixed for staged plus working-tree
  changes. Clicking mixed stages the remaining contents; Unstage selected removes
  them from the index. Switching modes itself does not modify the index.
- Staged diff selects index versus HEAD; unstaged diff selects working tree versus
  index. Stage / Unstage buttons and context commands act on highlighted rows.
- Attached right-hand partial staging/unstaging patch window, colored unified diff,
  selection of individual lines or hunks, and original icons in its context menu.
  Applying a selection changes the index and preserves working-tree contents.
  A stale patch is rejected before applying; disabling staging closes the patch window.
- Staging mode commits the entire index, including changes outside the displayed
  scope. Later unstaged edits remain on disk; partial staging prepared by another
  tool is preserved.
- Amend last commit, optional author override, Add Signed-off-by using configured
  Git identity. Empty checked selection plus amend supports message-only amend.
- Show unversioned files, scoped Finder requests, Show Whole Project, refresh,
  double-click diff, cancel and help. Successful commits close the dialog and
  refresh the main window; errors preserve the message and checked paths.

## Verification

The Swift suite has 39 tests, including real Git commits exercising both modes,
unchecked staged changes, unusual literal filenames, unborn HEAD, staged renames
and deletions, amend, author and sign-off, later unstaged edits, and hook rejection.

The native checkbox workflow was exercised on the disposable documentation
repository: only README.md was checked and committed, while the unchecked staged
Sources/Repository.swift remained in the index. Double-click opened its actual
Git diff. `site/assets/commit.png` captures that real native window.

Native staging mode was also exercised on the sample repository. The mixed
checkbox displayed a staged file with later working-tree edits. Clicking an
unversioned file's checkbox staged it; clicking again unstaged it. A native
staging-mode commit included only the previously staged repository model line and
left the later working-tree edit, README changes and unversioned file on disk.
`site/assets/staging.png` records the actual mixed-state window.

`PatchViewDlg::ShowAndAlignToParent` places the upstream partial-staging patch
window to the right of Commit. The native attached window now follows that layout
and tracks the parent's movement and height. Native UI checks staged one added
line, staged a separate hunk, and unstaged the first line while retaining the
second hunk and an unrelated staged file. Working-tree edits remained unchanged.
`site/assets/partial-staging.png` captures both actual native windows.

Integration tests cover line and hunk staging/unstaging, adjusting offsets across
multiple hunks, unusual filenames, and rejection of stale diffs. Partial operations
currently support ordinary tracked UTF-8 text files. Unsupported new, deleted,
renamed, binary, mode-changing and non-UTF-8 files require whole-file staging.
Enabling staging support itself retains the same file list and switches its
checkbox semantics. Staged files remain visible outside Finder-requested scope.

## Remaining upstream behavior

- Partial changes for new/deleted/renamed/binary/mode-changing files and other
  encodings; broader mixed-stage QA, patch search, keyboard shortcuts and saved
  patch width, upstream show/hide button labels, and multi-display placement.
- Author date and committer date controls, new branch, amend diff to previous
  commit, explicit message-only checkbox, commit/push/recommit split button.
- Message history, templates, completion, spelling, issue IDs and tracker plugins.
- Groups/changelists, submodule auto-selection options, unversioned file preview,
  file counts for untracked paths, staged/unstaged rename interactions.
- Remaining file context commands: revert, skip-worktree, assume-unchanged,
  restore after commit, file log, blame, export, external editor/open/reveal.
- Progress window with cancellation, interactive hooks/editors/signing and
  authentication prompts; persistent dialog preferences and mode setting.
- Checkbox mode completion of merges/cherry-picks. It rejects active merges
  before changing the index; staging mode uses normal Git index commit behavior.
- A failed checkbox commit can leave checked files staged, as index preparation
  occurs before Git invokes hooks. Unchecked staged contents remain intact.

These entries remain partial in the file/dialog inventory. Passing tests establish
these workflows, not full TortoiseGit parity or App Store readiness.
