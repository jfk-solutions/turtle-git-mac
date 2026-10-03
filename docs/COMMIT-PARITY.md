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
- Bottom Find bar with selection-seeded search, next/previous and native search
  options; Command-F and Command-G / Shift-Command-G shortcuts. Escape hides Find
  first, then closes the patch. Save As exports the displayed patch through the
  native save panel. Patch width is saved; buttons switch to Hide Staging/Unstaging
  while the corresponding patch window is open.
- Staging mode commits the entire index, including changes outside the displayed
  scope. Later unstaged edits remain on disk; partial staging prepared by another
  tool is preserved.
- Amend last commit, optional author override, Add Signed-off-by using configured
  Git identity. Empty checked selection plus amend supports message-only amend.
- Show unversioned files, scoped Finder requests, Show Whole Project, refresh,
  double-click diff, cancel and help. Successful commits close the dialog and
  refresh the main window; errors preserve the message and checked paths.

## Verification

The Swift suite has 95 tests, including real Git commits exercising both modes,
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
`site/assets/partial-staging.png` captures both actual native windows and Find.
The native Find bar was seeded from selected text, returned five matches for
Preview, and was dismissed with Escape without closing the patch. Next/Previous
shortcuts were exercised. A second Escape closed the patch and restored the button
labels. Native Save As output matched the current Git diff byte-for-byte. The
closed window wrote its width preference, which is read on reopening.

Integration tests cover line and hunk staging/unstaging, adjusting offsets across
multiple hunks, unusual filenames, and rejection of stale diffs. Partial operations
currently support ordinary modified UTF-8 text files. The pinned upstream
`StagingOperations::FindHunkEndGivenHunkStartAndCounts` explicitly limits partial
staging to modified files and excludes added/deleted files. Those files use
whole-file staging in this port too. Renamed, binary, mode-changing and non-UTF-8
files also currently require whole-file staging; their behavior still needs audit.
Enabling staging support itself retains the same file list and switches its
checkbox semantics. Staged files remain visible outside Finder-requested scope.

## Remaining upstream behavior

- Audit partial changes for renamed/binary/mode-changing files and other encodings;
  broader mixed-stage QA and multi-display placement. Native Find follows macOS
  search conventions (including wraparound); upstream flashes at a search boundary.
  Added/deleted file partial changes would extend the pinned upstream behavior.
- Full issue controls and message-history behavior; native root/merge/
  rename amend QA and broader date/author combinations. Native new branch,
  submodule toggle and broader Commit action combinations remain.
- Message-history native workflow QA, template native workflow QA and other text encodings,
  completion, spelling, issue IDs and tracker plugins.
- Groups/changelists, dirty-submodule commit prompts, unversioned file preview,
  file counts for untracked paths, staged/unstaged rename interactions.
- Remaining file context commands: revert, skip-worktree, assume-unchanged,
  restore after commit, file log, blame, export, external editor/open/reveal.
- Progress window with cancellation, interactive hooks/editors/signing and
  authentication prompts; remaining persistent dialog preferences.
- Checkbox mode completion of merges/cherry-picks. It rejects active merges
  before changing the index; staging mode uses normal Git index commit behavior.
- A failed checkbox commit can leave checked files staged, as index preparation
  occurs before Git invokes hooks. Unchecked staged contents remain intact.

These entries remain partial in the file/dialog inventory. Passing tests establish
these workflows, not full TortoiseGit parity or App Store readiness.

## Control audit correction

The user-supplied Commit and action-menu screenshots exposed missing controls.
The native window now groups Amend / Set author date / Set author under Message;
Staging support, Show Unversioned Files and Do not autoselect submodules sit below
the file list inside Changes made. Show Whole Project and Message only sit below
that group. Extra Stage/Unstage/Staged diff controls have been removed from the
footer; staging commands remain in the file context menu and attached patch links.
Files/Submodules category links and conditional category enablement were added.

Set author date uses Git --date. Amend exposes Reset (--date=now); no separate
committer-date checkbox exists in the pinned upstream resource. New branch creates
and checks out the named branch before committing; a hook failure may leave the
new branch selected, as the branch creation precedes the commit.

Message only disables the file list. Checkbox mode creates an empty/message-only
commit while preserving staged and working-tree content. Staging mode follows
upstream's --allow-empty index commit, so existing staged content is included.
ReCommit keeps the window and clears commit-specific message/options; Commit &
Push opens the existing native Push window after a successful commit, without
sending a push automatically. The native action menu exposes those three actions.

Real tests verify message-only tree/index/worktree preservation, author timestamps,
amend date reset, staging-mode message-only index behavior, new-branch history,
invalid branch rejection and Gitlink metadata including tab/Unicode paths.
Native layout, configured author text, date-control visibility and enabled action
menu were observed. Initial menu-opening interruptions prevented execution QA;
the native checks recorded below subsequently exercised both actions. `site/assets/commit-controls.png` is an actual
window capture; older screenshots describe earlier layouts. Full Commit parity
is still incomplete, including amend comparison and hidden/conditional workflows.

## Amend comparison and selection

Amend now displays changes against the previous commit's first parent by default.
Show diff to last commit is visible while amending and enabled when HEAD has a
parent. CommitDlg temporarily disables it while refreshing, then enables it for
non-root revisions. It switches the comparison to HEAD. Root revisions select
HEAD comparison in the native window, as upstream does. The backend also supports
explicit parent-mode root amendments against the empty tree in its object format.
Statistics, three-state checkbox status, whole-file unstaging and partial unstaging
use the same comparison base. The patch window labels Parent → Index in that mode.

Checkbox-mode parent-based amendment builds a temporary index from that parent and
includes only checked whole-file contents. Unchecked changes from the prior commit
are omitted from its replacement and remain in the real index; unrelated staged and
working-tree edits are preserved. Git --amend preserves the original commit parents,
including both parents of a merge. The existing programmatic CommitOptions default
continues to use HEAD unless amendDiffToLastCommit is explicitly false; the native
window selects the upstream parent-based mode.

Amend exchanges the draft and amendment messages on toggle rather than discarding
the draft. Set author date initializes from HEAD's author timestamp during amend;
Reset requests the current author date. Author override initializes from HEAD's
identity in amend mode. Separate native date/time fields now expose seconds.
The Amend checkbox is disabled
for unborn HEAD, and an empty checked parent-based selection needs Message only.

Five real tests cover selective amendment, unchecked index/worktree preservation,
root/rename baselines, parent-based unstage/partial patches, hook failure and merge
parents. All 87 tests pass. Native QA verified draft restoration, parent/HEAD list
switching in both modes, staging enablement without index mutation and a selective
amendment. The final checkbox-mode comparison control was checked as enabled for
a revision with a parent; both views were exercised after that enablement fix.
Git verified its parent hash, committed file contents and preserved mixed edits.
`site/assets/commit-amend.png` captures that actual checked plan before committing.
Native root/merge/rename and broader action combinations remain unverified; this is
still a partial Commit port. Specific date/override checks are recorded below.

## View Patch and repository mode preferences

The normal checkbox mode now exposes View Patch / Hide Patch in the Changes made
section. Like CommitDlg::FillPatchView, its attached right-hand window follows
highlighted file rows independently of checked commit paths, compares complete
working-tree contents with HEAD (or the amend parent), and includes both rename
paths. Unversioned/ignored rows are excluded. The read-only view has colored unified
patches and Save As, Copy, Select All and Find; no staging actions are exposed.
Staging mode retains the separate partial staging/unstaging links and comparisons.

The original local Git settings tgit.commitstagingsupport and tgit.commitshowpatch
now restore the mode and patch visibility on opening Commit. Hiding/closing the
patch clears its visibility preference; closing the parent preserves it. Changing
staging mode closes the existing patch and stores the new mode. Native verification
covered staging restoration after Cancel/reopen and restoring an explicitly saved
show-patch preference after relaunch. Parent-close/reopen with the patch still open,
rapid mode changes, and external config changes still need native lifecycle QA.

Three real Git tests cover combined staged/unstaged previews, explicit parent and
rename comparison, unborn-index fallback, preference persistence and preservation
of HEAD/index/worktree. All 90 tests pass. Native QA displayed both staged and later
working-tree edits against HEAD, confirmed the read-only context menu, and switched
staging without modifying the index. The actual attached window is captured in
site/assets/commit-view-patch.png. Highlight changes, amend switching while open,
non-UTF-8/binary preview and multi-display behavior remain to be verified natively.

## Native author date/time controls

Commit now uses separate AppKit text-and-stepper date and time fields, matching
IDC_COMMIT_DATEPICKER and IDC_COMMIT_TIMEPICKER. The time field includes seconds;
labels identify both controls for accessibility. Reset appears only with Amend
and Set author date, and disables both fields while requesting Git --date=now.
The controls also honor the Commit window's disabled state during operations.

Native QA used a disposable repository with an author timestamp of
2021-02-03T04:05:37+01:00. Amend loaded that exact local time. Editing its seconds
from 37 to 38 and entering an override identity produced an actual commit with
Git timestamp 1612321538 and the specified author. Date components and the original
parent were preserved. A second native amendment with Reset selected stored the
current author timestamp, preserved the author and parent, and left a clean index
and worktree. site/assets/commit-author-date.png is the actual pre-commit window.
The existing real Git date/message-only/reset integration test also passes.

Broader locale, time-zone/DST and date-component editing checks remain pending;
these two native workflows do not establish every date/author combination.

## Native completion actions

The action-menu verification gap is now closed for a disposable amendment workflow.
Selecting ReCommit completed a real Git amendment, kept the Commit window open,
cleared its message, reset Amend/options, reloaded status and disabled Commit until
another valid message/selection was supplied. Git reflog records the amendment.
Selecting Commit & Push on a subsequent amendment completed the Git operation and
opened the native Push window for the same repository with local main and origin
selected. The disposable bare destination remained empty before Push's OK button.
Broader action combinations (ordinary/staging/failed commits, scoped Finder entry
and remote errors) remain pending; these checks do not establish all completion
paths or the full upstream progress/post-action workflow.

## Message/file divider

Commit now has a draggable divider between the Message and Changes made groups,
following IDC_SPLITTER, CommitDlg::DoSize and SaveSplitterPos. Moving it changes the
editor height and moves Amend/date/author controls with their group; the remaining
height goes to the file group. The chosen message-group height is saved in macOS
preferences as Commit.MessagePaneHeight. Smaller windows clamp the visible height
without discarding that preference. Both panes retain minimum usable heights.

The divider is implemented in the native SwiftUI layout with an AppKit resize
cursor and accessibility Increment/Decrement actions. It does not modify the file
selection or draft. Native QA dragged from 300 to 340 points, checked upper/lower
limits (372 and 245 points in the default window), exercised adjustment actions,
and reopened Commit at the saved 325-point position. A minimum 900-by-680-point
outer window clamped it to 260 points and retained usable controls; enlarging restored
325 points. The draft and unchecked second file survived dragging. HEAD, index and
working-tree diffs matched their original values. site/assets/commit-resize.png
captures that actual adjusted window. Full VoiceOver, dark-mode resizing,
conditional controls at the bounds and multi-display checks remain pending.

## Commit templates and pending operation messages

The native Commit model now reads `commit.template` once when the dialog opens,
without replacing a draft on Refresh or when changing comparison options. Git
resolves the configured path, including `~/`; relative paths resolve against the
repository root. UTF-8 text (with optional BOM) is normalized to LF with one final
newline, matching the upstream loader's newline treatment. Missing, unreadable or
invalid UTF-8 templates report the path and error while leaving the dialog usable.
Sandbox access remains subject to the repository lease and macOS permissions;
external-template authorization UI and alternate encodings are still pending.

Upstream `CGit::LoadTextFile` appends to the message buffer. The port therefore
appends `SQUASH_MSG` and then `MERGE_MSG` to the template, rather than replacing
it. `git rev-parse --git-path` resolves each worktree's own administrative files.
ReCommit reloads only the template after a successful commit. An unchanged
nonempty template invokes a native warning with Proceed anyway, No and a
suppression checkbox; suppression is remembered only after proceeding.

Three real Git integration tests cover relative Unicode and absolute newline
paths, UTF-8 BOM/CRLF normalization, absent/missing/invalid templates, operation
message append order, ReCommit's template-only seed, linked-worktree separation,
and unchanged index/working-tree diffs. These are backend checks, not native UI
parity evidence. Native warning execution, suppression, draft-preserving Refresh
and ReCommit template restoration remain unverified: the QA app ran, but the
computer-use service returned stale menu IDs and did not reliably deliver input.
No new native screenshot is claimed for this change. Recent-message history and its selection dialog are now implemented as described below;
revision-picker insertion commands remain pending.

## Recent-message history and editor commands

The message editor now uses a native plain-text `NSTextView`, with undo and
selection-aware insertion. Its context menu adds Paste file list, plus Paste last
message and Recent messages when history exists. Original upstream Copy and Log
icons accompany these commands. Paste file list uses the displayed checked paths
(or staged paths in staging mode), maps unversioned status to Added, and pads
status labels to ten columns. Pick commit hash and Pick commit message still
require the upstream revision-selection workflow and are not exposed as stubs.

Log History is a resizable native sheet with a horizontal/vertical scrolling
`NSTableView`, flattened one-line messages, multiple selection, OK and Cancel. OK
joins selected messages in displayed order with a blank line; double-click accepts
one message. Delete removes one selected entry immediately from persisted history
and selects an adjacent row. Recent-message insertion replaces an untouched
template, otherwise inserts at the current selection with the upstream trailing
newline behavior, and avoids inserting a message already at the start of the draft.
Paste last message always inserts at the selection.

History lives in user defaults, keyed by the canonical Git common administrative
directory; linked worktrees share it. The default limit is 25, with an internal
`Commit.MaxHistoryItems` preference (settings UI still pending). Empty entries are
ignored and exact duplicates move to the front. Each mutation reloads the current
store so other open dialogs' newer entries are retained. Successful commits save
the submitted message, and amendments also retain the pre-amend draft. Failed
commits do not save a success entry. Cancel and the window close button use the
upstream-style confirmation, save a changed draft and any pre-amend draft, and
leave Git untouched; the suppression checkbox follows upstream's cancel prompt
behavior, including suppressing future prompts when No is selected.

Two persistence tests cover reopen, deduplication, limits, Unicode identity,
repository isolation, removal and interleaved dialog mutations. The linked-worktree
Git test now checks shared history identity. The running native Commit window
was observed with the new editor and loaded template in its original pane.
Native insertion, selection, deletion, successful/failed commit history, Cancel
confirmation/suppression, keyboard focus, undo, dark appearance and resize checks
remain pending: subsequent native input was interrupted by app-focus changes.
The sheet layout is implemented but not claimed as visually verified.
