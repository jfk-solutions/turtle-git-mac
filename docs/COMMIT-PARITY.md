# Commit dialog parity

Issue-matching runtime, native property/field/warning behavior and remaining work
are tracked in [issue tracker parity](ISSUE-TRACKER-PARITY.md).

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
- Broader grouped-list selection and conditional workflows, dirty-submodule commit prompts, broader binary/ignored preview acceptance,
  file counts for untracked paths, staged/unstaged rename interactions.
- Remaining file context command audit, including broader grouped-list and clipboard verification, plus broader Delete selection verification. File Blame/log/open/reveal
  are implemented, with external launch and Log handoff native QA pending.
- Progress window with cancellation, interactive hooks/editors/signing and
  authentication prompts; remaining persistent dialog preferences.
- Broader operation completion: native cherry-pick/revert, octopus/linked-worktree
  merges, empty merge selection UI, hooks/signing and multi-step sequencer workflows.
  Resolved-operation checkbox completion is implemented; staging mode uses normal
  Git index commit behavior.
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
parity evidence. Native unchanged-template warning and No were subsequently exercised, and native
ReCommit template restoration was verified. Proceed-anyway/suppression and
draft-preserving Refresh remain pending. Initial automation failures are recorded
in the later native verification notes; they do not establish failed app behavior. Recent-message history and its selection dialog are now implemented as described below;
revision-picker insertion commands are now implemented and checked as described below.

## Recent-message history and editor commands

The message editor now uses a native plain-text `NSTextView`, with undo and
selection-aware insertion. Its context menu adds Paste file list, plus Paste last
message and Recent messages when history exists. Original upstream Copy and Log
icons accompany these commands. Paste file list uses the displayed checked paths
(or staged paths in staging mode), maps unversioned status to Added, and pads
status labels to ten columns. Pick commit hash and Pick commit message open the
native Log window in revision-selection mode, as described below.

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
Native insertion, selection, deletion, successful commit history, Cancel Yes/No,
keyboard selection, Undo and readable light-mode layout were subsequently verified.
Cancel/window-close suppression, failed-commit history, pre-amend draft combinations,
dark appearance, saved sheet geometry and broader resize checks remain pending.

### Native history and template verification

A cancelled multiline draft in `/private/tmp/TurtleGitTemplateQA` was retained
after choosing No, saved after Yes, and recovered from Recent messages over the
untouched template. Paste last message replaced the native context-menu-selected
word; the editor value and model character count agreed. HEAD, index diff and
working-tree diff remained byte-identical during cancellation and history checks.
The unchanged-template warning appeared; choosing No returned without committing.

A two-entry isolated history fixture exposed a real rendering defect: calling
`NSTableView.sizeToFit()` against its initial zero-width frame collapsed the
message column to one character. The port now gives the table an explicit full
message document width and retains horizontal scrolling. Running native pixels
verified the correction. Shift-Down selected both messages; OK inserted them in
displayed order with a blank line and native Undo restored the template. Delete
removed one entry, selected the adjacent row and persisted removal; cancelling
Log History left the editor unchanged. Double-click also accepted one message.

Paste file list inserted only the checked `file.txt`, with the padded Modified
label. Native ReCommit committed that disposable change, retained the window,
restored the configured template, cleared the completed checked file and saved
the submitted message to history. Git verified the new parent, file contents and
clean tracked index/worktree; the unchecked unversioned template remained outside
the commit. `site/assets/commit-history.png` is an actual captured sheet using
copies of the natively committed and cancelled messages in an isolated screenshot
app preference domain. No user repository was modified.

Automation's physical Y/Z key positions are reversed on the German keyboard;
using its Y-position shortcut invoked native Undo. Main Edit-menu automation
returned stale IDs, so no main-menu Undo execution is claimed. The Debug-only
capture helper now uses Command-Option-Shift-S and resolves `sheetParent` before
capturing, producing the verified parent-and-sheet PNG without screen permission.

## Pick commit hash and message

The editor context commands follow `CommitDlg.cpp::HandleMenuItemClick`: open
Log in selection mode, omit the working-tree pseudo revision and accept exactly
one commit. `LogDlg.cpp::EnableOKButton` disables OK for zero or multiple selected
rows; native selection can still span rows, with acceptance disabled. Normal Log
continues to close on OK. The chooser retains its graph, reference colors, full
message, changed files, filters and revision menus. Reference creation, checkout
and Push route to the existing native dialogs. Double-click retains Log's diff
behavior rather than silently accepting a commit.

OK inserts the full hash or complete subject/body at the message editor's selected
range and restores editor focus. Cancel inserts nothing. Only one chooser can
be attached to a Commit window, and completion is cleared before closing to avoid
duplicate insertion. Commit refreshes status after dismissal so changes initiated
from Log can be reflected without replacing the existing message.

Native QA in `/private/tmp/TurtleGitRevisionPickerQA` verified the six-revision
merge history, single-selection OK, multiple-selection disabled OK, complete
145-character merge-message insertion, full 40-character hash replacement, Cancel
preserving the draft and checked files, and native Undo restoring the message.
A no-match search cleared the selection and disabled OK. HEAD, cached diff and
working-tree diff remained byte-identical to the fixture baseline. Picker mutation
flows, empty repositories, dark appearance, broader keyboard/resize behavior and
full Log parity remain pending.

The documentation capture helper now includes attached-sheet frames when sizing
images, including sheets wider than their parent. A fresh capture attempt failed
with macOS ScreenCaptureKit's audio/video stream-start error; bounds output is
therefore not yet visually verified and no new picker image was published.

## File access and clipboard context commands

Audited `GitStatusListCtrl.cpp` menu construction and command handling for
`IDGITLC_LOG`, `LOGOLDNAME`, `OPEN`, `OPENWITH`, `EXPLORE` and the clipboard submenu.
Commit's native menu now offers Show log for one versioned file, including deleted
files, and Show log of old name for a rename. These requests retain the originating
repository and security-scoped lease and open Log scoped to the selected path.
The shared root/Finder Log dispatch uses the same helper. Submodule-specific Log
semantics and rename-following history remain separate outstanding requirements.

For one existing non-deleted file, Open uses the macOS association and Open With
opens an application-bundle chooser. Submodules omit file-opening commands.
Reveal in Finder replaces upstream Explore to. Original `open.ico` and
`explorer.ico` artwork is copied byte-for-byte from the pinned source, with
SHA-256 provenance. Errors from application launch are surfaced in Commit.

Copy to Clipboard preserves the submenu and offers full paths, relative paths,
file/folder names and all displayed information. It operates on context selection
in displayed order, independently of Commit checkboxes. All-information output
has the visible column headings and tab-separated statistics; path outputs have
one selected path per line and the upstream trailing newline, using macOS LF.
Copy-current-column and native path-copy shortcuts are now implemented as detailed below.

Native QA on the disposable six-revision fixture verified tracked/untracked menu
conditions, absence of single-file actions for multiple selection, relative-path
clipboard output and the two-row information table with correct columns/counts.
Open With displayed the native application chooser; successful external launch,
its cancellation/error variants, Reveal in Finder, deleted/renamed-file variants,
scoped Log handoff and sandboxed runtime remain unverified. Repeated Log menu
automation returned invalidated targets without opening a verified Log window.
No success is inferred from these attempts.

Visual QA found status-colored path/count text unreadable on selected blue rows.
Selected rows now use native primary text color, while unselected rows retain
status colors. Actual native pixels verified readable white path/count text for
two selected modified files and one selected untracked file.
`site/assets/commit-file-selection.png` captures this fix. Dark and inactive
selection checks remain pending. The existing icon test passes for all 39 assets.

## Rename entry point

A single existing versioned row offers Rename with the original upstream artwork.
The native window and collision → retry workflow were exercised, including a rename
from Commit that preserved separate staged/worktree contents. Check/selection/scope
remapping is implemented; its post-close native observation still needs verification.

## File Blame entry point

Commit's single-file context menu now includes Blame with the original artwork.
The pinned `GitStatusListCtrl.cpp` excludes unversioned, ignored, added, deleted
and directory rows. The native menu applies those state gates and excludes
submodules. The request retains Commit's repository and permission lease and uses
the shared native viewer. `CAppUtils::LaunchTortoiseBlame` omits an empty revision,
and `TortoiseGitBlameDoc.cpp::OnOpenDocument` defaults it to HEAD and invokes blame
with that revision. The port likewise annotates committed HEAD contents, preserving
independent staged and working-tree edits. This entry point does not add a
working-copy annotation mode.

Native QA opened Blame from a modified file with different committed, staged and
working-tree text. The viewer showed the committed UTF-8 source, including its
turtle emoji, origin hash and two annotation rows. HEAD, exact index bytes, all
files and porcelain status matched the pre-test baseline. Closing the child window
timed out in the UI tool, and normal Quit did not stop the process; the isolated QA
process was terminated and process absence verified. No second instance was
launched. Added/deleted/untracked and submodule menu gates, renamed/conflicted files,
dark appearance and signed sandbox handoff still need native checks.

Swift and unsigned Debug/AppStore builds passed without compiler warnings. Both
bundle audits passed with 62 icons, including the packaged Git 2.55.0 runtime's
architecture and local-operation checks. The static documentation build passed.
The core reader is unchanged; its preceding 274-test run remains the baseline.
See [Rename parity](RENAME-PARITY.md).

The file menu now offers upstream Ignore name/extension and containing-folder actions
for unversioned/deleted selections. [Ignore parity](IGNORE-PARITY.md) records rule
semantics and native Commit/Working Tree handoff evidence; post-close restoration
remains unverified.


## Index flag context actions

Commit and Working Tree now expose Skip worktree and Assume Unchanged for
eligible versioned selections. Working Tree also offers Unflag as skip-worktree
and assume-unchanged for selections containing either flag. The pinned
GitStatusListCtrl.cpp menu gates, command dispatch and
SetGitIndexFlagsForSelectedFiles were reviewed, together with the confirmation
strings and resourceshell.rc's exact Assume Unchanged label. The native menus
use the existing original Ignore artwork; upstream gives these particular
status-list entries no explicit icon resource.

Both mark actions retain the other flag. Unflag clears both, without changing
staged object IDs or working bytes. Git accepts one flag mode per invocation, so
Unflag holds the real index lock, changes a private index twice and replaces the
real index only after both succeed. It preserves index permissions and resolves
the per-worktree index path. Eligibility is re-read with optional Git index
refresh disabled before mutation; invalid mixed selections fail before a write.
App Store builds require the model's active repository security scope.

Native QA used one app at a time. Commit showed both actions for a modified file;
Skip worktree's Return-default No preserved the row, while Yes removed it from
the Commit list. Working Tree's Show ignore local changes flagged files exposed
the skip-worktree row. Its Unflag confirmation restored Modified with the
original added/removed line counts. Assume Unchanged then displayed its matching
status. Process checks confirmed both test apps exited immediately after their
checks. Working bytes, staged bytes and the single original commit were retained.
An application-menu handoff attempt produced stale observer targets; Working
Tree acceptance therefore used a separately launched status preview after the
Commit preview had exited. No menu-handoff success is claimed.

Real Git tests cover both flags simultaneously, clearing both, mixed staged and
working contents, newline/Unicode and pathspec-looking filenames, invalid mixed
selections, existing index locks, linked-worktree separation and index permissions.
The first combined-clear attempt failed these tests because Git retained one
flag; the locked private-index implementation fixes it. A second test exposed
optional status-refresh writes changing permissions during validation; disabling
that refresh fixes it. The 16 Working Tree/Git repository tests passed after
those fixes. Final native rendering used the earlier sentence-case menu label;
the final exact upstream capitalization and sandbox access guard were compiled
and tested afterward; all six final Working Tree tests passed.
Dark/multiple-selection/native error paths, staged rename
and amend-comparison eligibility, and signed sandbox acceptance remain pending.

## Restore after commit

The pinned `GitStatusListCtrl.cpp` restore commands and `CommitDlg::RestoreFiles`
now have a native implementation. Marking a versioned file saves its current
working contents once and adds the unchanged upstream restore overlay to its
status icon. The context command then becomes Restore. Marking does not stage
the file. A successful commit restores saved working contents automatically;
HEAD and the index retain the newly committed contents. ReCommit consumes the
saved copy and removes the overlay while retaining the dialog.

Manual Restore asks before replacing later edits. Failed commits offer Keep
current state (the default) or Restore old state. Closing Commit also allows
Cancel. Application Quit now routes open Commit windows through this cancellation
path, pauses mutations in the repository and attached patch windows, and cancels
termination when a prompt is declined or restoration fails. Remaining saved
copies are retained after restoration errors for retry.

Copies are disk-backed, support binary contents and executable permissions, and
preserve symbolic-link target text without reading or overwriting its target.
Restoration replaces the working file atomically and rejects another repository,
a directory destination or a parent escaping the working tree. It does not change
the Git index or HEAD. Copies are owned by the dialog; crash recovery is not yet
implemented.

Four real Git tests cover binary bytes, permissions, post-commit index/HEAD
preservation, symlinks, unversioned rejection, escaping parents, invalid
destinations and retry. The focused restore, icon and rebase suite passed 15 tests.
Native QA marked a file, committed later contents through ReCommit, and verified
that only the working file returned to the saved contents; HEAD/index held the
later contents and the overlay cleared. `site/assets/commit-restore.png` is the
actual native capture before that commit.

A subsequent single-window native Quit scenario reached both sheets. The default
No kept Commit and its draft open. After marking a tracked file, later edits were
made on disk: Yes followed by Cancel in the restoration sheet retained those
edits, the saved copy, index and HEAD. Yes followed by Restore old state returned
the saved working bytes while preserving the exact index bytes and HEAD hash.
The UI observer then presented a fresh empty draft, consistent with relaunching
the preview after termination. That preview was closed through Quit/Yes without
another UI observation, and the process list confirmed no TurtleGit process.

Manual Restore, hook-failure choices, Keep current state, window-close gestures,
multiple Commit windows, staging-mode combinations, renamed paths, dark
appearance and signed sandbox access remain unverified natively. This remains a
partial port, not completion of either upstream source file.

The unsigned Xcode Debug app build passed after this addition. Its bundle audit
verified the embedded Finder extension, licenses and all 59 upstream icon assets,
including both restoration icons. This proves packaging, not signed Finder
activation or App Store approval.

## Revert selected files

The file menu now includes Revert with the original icon. It resets the selected
index and working files, leaves added file contents unversioned and unchecked,
and restores renamed files to their old names. Existing replaced file contents
go to macOS Trash. The native No/Yes prompt and selected-file acceptance, added
file handling and unrelated-content preservation were exercised on a disposable
repository. Revert during amend targets the parent even when the list shows HEAD,
as in the pinned source. See [Revert parity](REVERT-PARITY.md) for backend coverage,
recovery behavior and remaining dedicated-dialog/Finder/progress work.

## Native file comparison routing

Reviewed `CGitStatusListCtrl::StartDiff` at upstream commit
`7338078f8ddd924b8cddee35f512f2286072136d`. Commit's Compare with base and
file double-click now open the native two-pane viewer instead of the unified
patch sheet. The viewer uses HEAD versus working contents, including staged
edits; amend-with-parent uses the pinned first parent, while Diff to last commit
uses HEAD. A root commit has an empty parent base. Staging-list comparison uses
working contents, following upstream file-list behavior. The separate unified
command keeps its existing index/working patch selection. Submodule comparisons
receive the same pinned base through their dedicated window.

A real-Git test checks root empty-base and parent/HEAD comparison bytes with
staged-plus-working changes and verifies that comparisons preserve the index.
One native QA process verified Commit double-click opening the two-pane viewer
with exact committed and working text. After the viewer was closed, the UI
observer timed out; the same disposable process was terminated and absence
verified. HEAD, index and working bytes stayed unchanged. Context-menu unified
output, staging/amend combinations, multi-file and submodule native acceptance,
and signed sandbox execution remain pending. Full Commit parity remains partial.

Validation: all 258 Swift tests passed. Final unsigned Debug and App Store
builds, both bundle audits and the static Pages build passed. The App Store
audit exercised universal Git 2.55.0 local operations and verified 11 Mach-O
files, the Finder extension, licenses and 61 original icons. These checks prove
compilation and packaging; signed execution and App Store approval remain
unverified.

## Working-file Export

Pinned `CGitStatusListCtrl::FilesExport` copies selected working files into a chosen
folder, retaining repository-relative paths and replacing existing copies. The
Commit file menu now provides Export… with the original `IDI_EXPORT`
(`menuexport.ico`) artwork. It acts on highlighted rows independently of commit
checkboxes and exports working contents even in staging mode. Deleted/missing
selections hide the command; directories/submodules are skipped by the exporter.
Symlink sources export their target contents, matching upstream `CopyFile`.

The native macOS folder chooser offers folder creation and retains its temporary
security scope through the copy operation. Errors leave the dialog and selection
intact. Each destination replacement is atomic; earlier successful files remain
if a later copy fails, as upstream does. Source overwrite, Git metadata paths and
destination parent symlinks escaping the chosen folder are rejected. Destination
leaf symlinks are replaced rather than writing through them.

Four focused export tests cover binary and Unicode contents, nested paths,
untracked files, overwrite, executable permissions, directory skipping, symlink
sources/destinations, missing files, source overwrite and metadata/path escape.
They verify exact HEAD/index preservation. The original icon decode test passes.
Native QA selected both a modified nested text file and an unchecked untracked
binary, invoked Export from their shared context menu, selected an existing folder
and verified both outputs byte for byte against the working tree. HEAD and raw
index were unchanged; the single QA app was quit normally. Export/New Folder were
disabled after Go to Folder entered an empty destination, then enabled when its
row was selected from the parent folder. Native overwrite, cancellation, staging,
dark appearance and signed sandbox permissions remain to be exercised; this
folder-chooser result does not resolve the separate Log Save As issue.

## Alternative editor

Upstream `IDGITLC_VIEWREV` calls `OpenFile(ALTERNATIVEEDITOR)`, which uses
`LaunchAlternativeEditor` with Notepad as its fallback. Commit now has the same
separate editor/Open/Open With commands and original `IDI_NOTEPAD` artwork. Export
precedes these file-opening commands, matching upstream order. The editor action
opens current working contents; it does not extract HEAD or stage the file.

Settings → Alternative Editor ports the upstream Notepad/Custom radio choices,
path field, enabled-state dependency, Browse and Apply. TextEdit replaces Notepad;
Custom chooses a native .app rather than a Windows executable. Disabling Custom
retains the chosen app, and blank Custom falls back to TextEdit as upstream's blank
configuration falls back to Notepad. The native picker records an application
permission bookmark; editing the path invalidates it only when the path changes.
Launch resolves the bookmark and retains its temporary scope through completion.
Unavailable apps/bookmarks report an error; they do not silently choose another
custom application. Settings Cancel discards the draft.

Two preference tests verify defaults, custom/disabled persistence, path and bookmark
retention, blank fallback, and invalid paths. The original icon decoding test passes.
Native QA verified the working Unicode file in default TextEdit and a custom app
chosen through Browse, closing the QA document without edits each time. Final QA
verified Apply disables after saving, tab reload keeps Apply disabled, the real
bookmark persists on disk, and launch succeeds with that bookmark. HEAD, raw index
and source contents remained exact. Three sequential QA instances were closed;
none ran concurrently. `site/assets/alternative-editor.png` is an inspected actual
Settings capture showing the saved Custom choice and disabled Apply.

Other editor applications, missing/moved apps, typing/Cancel combinations, dark
appearance, signed sandbox file handoff and editor routes outside Commit remain
pending. This implements the Commit command and Settings page, not all upstream
external-tool configuration or complete status-list menu parity.

## Explicit Add commands and Commit menu mask

The pinned `CommitDlg::OnInitDialog` calls status-list `Init` with
`GITSLC_POPALL ^ (GITSLC_POPCOMMIT | GITSLC_POPSAVEAS | GITSLC_POPPREPAREDIFF)`.
Save As, prepare-diff and the status-list Commit command are deliberately absent
from this dialog upstream. Their earlier listing as Commit gaps was incorrect;
the corresponding commands still need audit in the other windows that enable them.

Unversioned file selections now expose Add with the original Add icon. Holding
Shift when opening the menu also exposes Add as Executable (+x) and Add as Symlink,
as upstream does for file selections. Normal Add force-stages the selected paths,
including ignored files when explicitly passed. Extended commands retain the staged
blob and set only its index mode to 100755 or 120000; they do not chmod the working
file or create a filesystem symlink. Directory children retain their normal modes,
matching `AddProgressCommand::SetFileMode`'s directory skip.

Successful Add refreshes the list and checks the added files, clearing their old
unchecked state as upstream does. Existing checks remain unchanged. Operations
retain repository access and serialize through GitRepository. A real index lock is
held while a private index is prepared; only successful completion replaces the
real index. Missing/invalid paths, mode errors and pre-existing locks preserve it.

Four integration tests verify force-add, all three modes, raw binary/Unicode and
literal paths, unchanged working contents/permissions and HEAD, retained staged
entries, split indexes, unborn indexes, directory modes, existing locks, failed
selections and linked-worktree index isolation. Native light-mode QA selected one
unchecked untracked Unicode file, invoked Add, and verified Added status, its checked
box and the updated two-file count. Its staged blob and disk bytes matched exactly;
HEAD and the previously staged entry stayed unchanged. The single QA app quit
normally. `site/assets/commit-add.png` is the inspected actual refreshed window.

Native Shift-menu exposure, extended-mode actions, staging/dark mode, cancellation
and a dedicated upstream-style Add progress window remain pending. Checkbox Commit
now preserves staged modes that differ from disk while updating checked-file bytes,
as detailed below. An explicit normal Add/Stage recalculates modes from disk;
staging mode commits the current index directly. Full Add-dialog/progress and
Commit completion parity remain partial.

## Staged modes through checkbox Commit

`PrepareIndexForCommitWithoutStagingSupport` updates checked entries with
`git_index_add_bypath` or CLI `update-index`, while staging mode skips preparation.
Our previous `git add` plus `git commit --only` path could discard an explicitly
staged executable or symlink mode when disk still held a regular non-executable
file. This made the extended Add commands ineffective in default checkbox mode.

Checkbox Commit now captures selected staged regular/executable/symlink modes
that differ from disk. It reads the latest checked-file bytes into a separate
commit index, reapplies those modes to the commit and real indexes, and commits
that prepared tree without --only. The existing separate-index path also handles
parent-based amendments. Matching staged modes and wholly unstaged changes keep
the ordinary path; unstaged native chmod changes still commit their disk mode.
No global core.filemode/core.symlinks configuration is changed. Explicit normal
Add/Stage replaces the mode intent with disk's current mode. Staging Commit retains
its original behavior of committing the index exactly as supplied.

The 27 focused Add, Commit-selection, amend, mode and removal tests passed. Four new
mode tests include both explicit Add modes, later working edits, unchecked staged
contents, literal Unicode/comma/newline filenames, unborn HEAD, parent amendments,
ordinary unstaged chmod, staged executable-bit removal and resetting with normal
Add. Disk-mode comparison follows Git’s owner execute bit, including a file with
only another execute bit set. Actual tree/index modes, blobs, working permissions and unaffected staged
entries are asserted.

Native light-mode checkbox Commit was exercised with pre-staged executable and
symlink entries backed by regular files and edited after staging. Both were checked;
a third staged file was unchecked. The resulting commit contained 100755 and 120000
with the latest exact working bytes. The unchecked file was excluded from the
commit and retained its staged entry. Disk contents and permissions were unchanged;
the only QA app quit normally. This verifies native Commit completion with the
prepared modes, not Shift-menu invocation of extended Add.

Native Shift extended Add, staging/dark mode, root/amend mode combinations, signed
sandbox behavior and hook-driven changes to prepared indexes remain to be checked.
Later unstaged disk type/permission changes after a successful commit still follow
Git's macOS behavior; broader subsequent-commit virtual-link and executable-file
usability remains under audit. Passing these cases does not establish full dialog
parity or distribution readiness.


## Delete from the Commit file list

Upstream `GitStatusListCtrl::OnContextMenuList` offers Delete when the selection
mark is unversioned, ignored or missing. `DeleteSelectedFiles` removes selected
exact index entries and sends existing paths through the shell’s Recycle Bin;
Shift requests permanent deletion. The command appears after Open/Explore and
before Ignore. This differs from the separate Delete/keep-local dialog.

Commit now offers Delete with the original delete icon when the selection mark
is unversioned, ignored or missing, including mixed selections. Its native confirmation defaults
to No. Normal deletion uses macOS Trash; Shift at invocation selects a separately
worded permanent-delete confirmation. Missing paths only lose their index entries.
No commits or HEAD changes are made. The list refreshes after success or error;
success clears selected paths’ commit checks. A staged deletion remains visible.

The repository operation rechecks the status snapshot, validates paths and holds
the real index lock while preparing exact removals in a private index. It publishes
the prepared index only after file operations succeed. Trash failure never falls
back to permanent deletion. If a later operation fails, the error lists any files
already moved to Trash so they can be recovered. After publishing, Add and Delete
no longer attempt to remove a lock path that a subsequent writer might acquire.

Six integration tests passed: recoverable binary/Unicode/literal-path contents,
raw-index preservation for untracked-only deletion, missing tracked entries with
a split index, mixed tracked/untracked selections, stale snapshots, cancellation,
existing locks, a trashed symlink with an unchanged outside target, and a broken
symlink in a linked worktree. Permanent deletion is exercised only on a test-created
fixture. Native light-mode QA verified No leaves
the exact file/index unchanged, Yes removes an untracked binary from the list,
and Delete of a missing tracked file removes its index entry. HEAD and an unrelated
staged entry were verified unchanged. The single QA app quit normally, with no
remaining TurtleGit processes. The 14 focused Add/Delete/Commit-mode tests, both
unsigned Xcode builds, both bundle audits and the site build passed.

## Delete selection mark and keyboard behavior

The native file list now retains a selection mark separately from selected paths.
Plain clicks and non-range keyboard moves establish the mark. Shift range
selection and right-clicking an already selected row preserve it. The menu uses
that marked entry’s status to enable Delete, matching upstream’s focused-row gate
rather than requiring every selected path to qualify. A mark can remain outside
the selected set after Command deselection; the core verifies that marked status
snapshot before using it to authorize deletion of the selected paths.

An AppKit event observer is scoped to each Commit table and removed when its view
is detached. Delete/forward Delete and Shift-Delete run only while the table itself
has keyboard focus. The keyboard gate accepts unversioned/ignored marks, including
an index-deleted path that retains an unversioned working copy; missing tracked
paths remain menu-only as in upstream `PreTranslateMessage`. Text editors and
other controls retain their normal Delete behavior. Shift opens the explicit
permanent-deletion prompt; plain Delete uses Trash. The three staging/checkbox
lists keep separate marks.

Native light-mode QA verified both directions of a mixed three-row range:
untracked anchor exposes Delete and opens a three-item keyboard confirmation;
tracked modified anchor hides Delete and ignores the key. No preserves all exact
working bytes and the raw index. The message editor changed `abc` to `ab` without
a file prompt. A missing tracked row ignored the Delete key. Shift-Delete on the
untracked row showed the permanent-delete warning; No preserved the file. Ordinary
keyboard Delete followed by Yes removed that untracked file and refreshed the
list, preserving HEAD, the raw index and unrelated working edits. The single QA
app quit normally, and no TurtleGit process remained.

Eight Delete integration tests now include a cached removal with an unversioned
copy, and a marked unversioned entry outside a tracked selection. A stale marked
entry is rejected before deleting the tracked file or updating its index entry.
The 16 focused Add/Delete/Commit-mode tests, both unsigned Xcode builds, both
bundle audits and the site build passed.
Native Command deselection, forward-Delete hardware, ignored directories,
staging/dark mode, partial filesystem failures and signed sandbox checks remain
pending. Other context-menu gates still need their own focus-sensitive audit;
full status-list and Commit parity remain partial.


## Clipboard column selection and native shortcuts

Upstream `IDGITLC_COPYEXT` is named misleadingly: its resource text is “Copy all
information to clipboard,” and it copies all visible columns. It is not a separate
extension-only command. `IDGITLC_COPYCOL` copies the column hit by the context-menu
request without a heading. The menu label is `column '<name>'` and uses the original
clipboard icon. `PreTranslateMessage` also maps Control-Insert to relative paths
and Shift-Control-Insert to relative paths with status and headings.

Commit now supplies that column item through the native menu tracking notification.
The AppKit table’s public geometry determines the clicked row/column. It is added
before the menu is displayed, avoiding SwiftUI’s cached menu content, which initially
required reopening the menu. The item follows a subsequent request on a different
column. Clicking an unselected row uses that context row; an already selected row
copies the current selection in displayed order. The checkbox column has no text
command. Observers are removed when their Commit view is detached.

Command-C is the macOS shortcut for relative paths; Shift-Command-C copies paths
and status. Control-Insert variants are also handled for keyboards that supply the
Insert/Help key. These shortcuts run only with keyboard focus in the file table;
message and other text editors retain their native copy behavior. The shared
clipboard formatter supplies full/relative/name, all-information and single-column
text with macOS LF and the upstream trailing newline. Only multi-column output has
headings. Native count placeholders remain the displayed en dash.

The extension column now includes its leading dot, matching `GetFileExtension`,
including dotfiles; directories/submodules have no extension. Renamed paths display
the upstream `(from old-path)` suffix. Column/all-information copying retains that
visible suffix; raw full/relative/name commands and path/status shortcuts do not.
This updates Commit’s display and formatter, not all other file lists yet.

Three formatter tests cover Unicode paths and selected order, raw path commands,
rename annotations/status, dotfiles/directories, missing and staged statistics,
header rules, displayed column order and empty selections. Together with the eight
Delete tests, all 11 focused tests passed. Native light-mode QA verified Command-C
raw paths, Shift-Command-C paths/status, first-request `column 'Status'`, then
`column 'Extension'`, headerless status/leading-dot extension values, and the
all-information headings/renamed path/counts. Values were pasted into the actual
Commit message editor for verification; no commit was made. HEAD, raw index and
working bytes stayed exact. QA apps ran sequentially and each quit normally.
`site/assets/commit-clipboard.png` is the inspected actual 2000 × 1584 final window.
Both unsigned Xcode builds, both bundle audits and the site build passed; the
App Store bundle audit verified the pinned universal Git runtime and original icons.

Native keyboard navigation with four Down presses and Return copied the expected
headerless Status values without changing the two-row selection. Control-Insert hardware,
checkbox/empty-area menus, column reordering/hiding, optional filename/date/size/LFS
columns, staging/dark mode and signed sandbox execution remain pending. Full
status-list, clipboard and Commit parity remain partial.


## Changelist commands and successful-commit cleanup

`GitStatusListCtrl.cpp`'s changelist commands and `CreateChangelistDlg` now have
native Commit counterparts: Remove from changelist, Move to changelist with
`<new changelist>`, `ignore-on-commit` and existing names, and Keep changelists.
The Create Changelist sheet has the original prompt, an initially focused name
field, Cancel and OK. OK stays disabled until the name is nonempty. Names are
not trimmed. Cancel discards the draft without writing metadata.

Assignments are local to the worktree. An atomic, locked
`turtlegit-changelists.json` file in Git's worktree administration directory
retains Unicode and literal newline filenames. A preexisting `tgitchangelist`
file is imported when no native file exists, accepting UTF-8 and BOM-marked
UTF-16 LE/BE, without rewriting the original file. Other legacy encodings and
Windows path conversion remain pending. Mutations reload assignments under the
lock; invalid paths, symlink metadata, corrupt or unsupported documents and
existing locks fail without overwriting metadata or touching the index.

Moving a file to `ignore-on-commit` unchecks it; staging mode also unstages the
selected paths. Removing membership does not automatically check the file.
Freshly opened checkbox-mode dialogs omit ignored paths from automatic checks;
users can still check them explicitly. Keep changelists is persisted. After a
successful commit, with Keep disabled, cleanup retains visible unchecked files,
restore-after-commit paths and assignments outside the displayed directory scope.
File-only scopes do not prune, matching upstream. A cleanup failure reports that
the commit succeeded and keeps the dialog open rather than claiming rollback.

The pinned upstream menu gate compares the action bitfield with the older
`git_wc_status_unversioned` enum. Both that enum value and the modern ADDED bit
are 1, so the native gate excludes a pure Added marked row, rather than silently
changing this observable upstream behavior. Broader combined-action gates still
need native comparison.

Six real Git tests cover assignment persistence, unusual literal names, reloads
across repository actors, mutation validation and existing locks, legacy import,
linked worktrees, scoped cleanup, and corrupt/unknown/symlink metadata. Native QA
verified initial focus and disabled/enabled OK, Cancel without metadata/index
changes, exact `Feature 雪` creation, ignored-file unchecking, and membership-only
removal. A real checkbox commit pruned the committed assignment and retained the
unchecked ignored file; its HEAD, index and disk contents were checked directly.
Reopening Commit kept the ignored file unchecked. Explicitly checking it and
committing with Keep enabled retained its assignment. All QA instances were
closed after testing. `site/assets/commit-changelist.png` is the inspected actual
Create Changelist sheet, captured before dismissal.

The initial Create Changelist screenshot predates grouped rows. The grouped-list
work and its separate native captures are described below. ReCommit, scoped,
restore-after-commit and broader signed sandbox changelist workflows still need
native acceptance.


## Status/changelist group layout and actions

`PrepareGroups`, `GetChangeListIdForPath`, `SetItemGroup` and
`OnContextMenuGroup` now have native Commit counterparts. Grouping activates
when there are changelist assignments or displayed unversioned/ignored/locally
ignored paths. Explicit changelist membership takes precedence over status and
index flags. Unassigned files appear in Modified Files, Not Versioned Files,
Ignored Files or Local changes ignored; named changelists follow in name order,
and `ignore-on-commit` is last. Empty headings are omitted. The upstream
`(no changelist)` heading is inserted but `SetItemGroup` routes unassigned files
to their status categories; the native list follows that effective placement.

Headers appear within the original columned file list with accent-colored names
and horizontal rules in light and dark modes. Their context menu has the upstream
Check group and Uncheck group commands. Checkbox mode changes the group's checks;
staging mode stages or unstages its paths. These actions retain other groups,
working contents and unrelated staged edits. Membership tooltips remain available.

Headers have IDs containing NUL, which cannot be Git paths. Every file command
filters header IDs, and the AppKit interaction bridge maps actual table row
positions through the grouped row model. This prevents extra headings from
shifting the files targeted by keyboard Delete and clicked-column clipboard
commands. Plain header clicks are consumed; ordinary Up/Down and Home/End skip
headers. Range selection retains native AppKit behavior and may highlight a
header, while file commands resolve only the real file rows.

Four model tests cover category precedence, name ordering, ignore-last placement,
hidden memberships, empty groups, duplicate-looking heading names, literal newline
filenames, index-based file target resolution and nonwrapping navigation. Together
with clipboard/Delete regression coverage, 15 focused tests pass. Both app build
configurations and bundle audits pass.

Native QA verified the status/Alpha/Beta/ignored order, Check and Uncheck changing
only the two Alpha files, initial Down and Home skipping headings, selection of
both Alpha files and exact Command-C path output. Staging-mode Check group staged
both Alpha files; Uncheck group restored their original index blobs, retaining the
unrelated staged `a-modified.txt` blob, HEAD and all working bytes. Keyboard Trash
showed a one-file prompt for the untracked row; No preserved it and Yes removed
only that file while leaving the exact raw index, HEAD and all other files intact.
The unversioned heading disappeared when its last row was removed.

`site/assets/commit-groups-light.png` and `commit-groups-dark.png` are inspected
actual 2000 × 1584 captures after that disposable Trash check. Dark appearance was
verified in a fresh preview after an appearance-menu automation failure; this does
not establish native menu-switch acceptance. QA instances ran sequentially and
were closed. The stuck menu instance required SIGTERM of its identified disposable
process after normal Quit failed; no system services were terminated.

Audit correction: changelist drag/drop is disabled behind `#if 0` in the pinned
`CGitStatusListCtrlDropTarget::OnDrop`, and `DragOver` rejects drops on group
headers. We do not count disabled group movement as an active upstream workflow.
Normal file-drop behavior remains under audit. Merge-parent grouping belongs to
historical comparison views and is not implemented here. Broader range selection,
first-request grouped clipboard-column acceptance, ignored/local-flag native
variants, accessibility group semantics and signed sandbox workflows remain
partial.


## Unversioned preview and first-request comparison menu gates

The pinned `OnNMDblclk` routes unversioned/ignored rows to `StartDiffWC`.
`CGitDiff::Diff` permits an absent repository blob (`mustExist` is false), while
retaining the working file. The native two-pane viewer follows that behavior:
explicit untracked and ignored selections have an empty base when the path is
absent from the chosen revision. The existing Commit double-click route was
verified natively with a Unicode untracked filename and exact working text.

`workingFileComparison` now reuses the selected-file mode lookup. This handles
ignored files below an ignored directory, ignored binary content and symlink
contents without staging them. A file removed from the index with `git rm --cached`
but retained on disk uses its actual working bytes; a cached deletion is no longer
misrepresented as an absent destination. The status-list route continues to omit
clean tracked files, and ordinary staged/working, renamed, amend-to-first-parent
and root/empty-base behavior retains its regression coverage.

Commit's Compare with base and unified-diff menu entries now follow the marked
row's tracked/unversioned gate. Unversioned/ignored marks and retained unversioned
copies omit those tracked-only menu commands. Double-click preview remains
available. Unified diff is omitted without HEAD, matching the upstream init-repo
gate. Full raw missing/action-mask and alternative-tool variants remain under audit.

Native QA exposed a first-request context bug: right-clicking an unselected tracked
row could use the previously highlighted untracked row's gates, hiding Compare and
showing Delete. `StatusListSelection` resolves the requested clicked row immediately
when it differs from the existing highlight; existing mixed-selection marks,
including a mark outside the highlight, remain available. The interaction bridge
preserves the real highlighted selection's anchor during contextual clicks, so
canceling another row's menu does not silently move that anchor.

Three additional tests cover ignored text/binary/broken-symlink and cached-removal
bytes with raw index/HEAD preservation, comparison state gates, and first-request
mark resolution while retaining existing mixed/outside anchors. Together with file
comparison, grouped rows and Delete regressions, 28 focused tests pass. Both build
configurations and bundle audits pass.

Native checks verified the first untracked menu omits tracked-only diffs and
Double-click opens an empty left side with the two original working lines on the
right. After the fix, the first tracked menu with a prior untracked highlight
shows Compare/unified diff and omits Delete. Canceling it leaves the prior selection
intact, whose untracked menu still has its own gates. The reverse first-request
case, an unselected untracked file with a tracked highlight, also has the expected
Add/Delete and comparison omission. Exact HEAD, raw index, working files and the
unrelated staged/later edits remained unchanged throughout. Both QA apps were
closed normally and no TurtleGit test processes remained.

`site/assets/commit-unversioned-preview.png` is the inspected actual 2240 × 1504
native viewer capture. Native ignored/binary/symlink/cached-removal preview variants,
unborn menu acceptance, mixed selections, alternative tools and signed sandbox
handoff remain pending; this capture establishes only the tested untracked text
workflow, not full comparison parity.


## Compare two selected files

The pinned `GitStatusListCtrl.cpp` menu and dispatch at lines 1795–1811 and
2260–2280 enable Compare two files for two selected non-directory rows. Commit's
context mask includes this action. Each path independently uses working contents
when present or HEAD when deleted; this is distinct from two separate base diffs.

Commit now exposes the original Diff icon action and sends the two paths in visible
table order to one native two-pane viewer. The core reads exact working bytes,
including literal Unicode/newline paths, binary and broken symlinks, and pins HEAD
for missing sides. Directories, gitlinks, duplicate paths, metadata paths and invalid
selections are rejected. Viewer reuse includes both paths to prevent a different
left-hand file from reusing an unrelated comparison window.

Four file-comparison tests pass, including a new real Git regression covering both
deleted-side directions, pinned history after HEAD advances, staged versus working
bytes, symlinks and invalid paths. Debug and unsigned App Store builds and both
bundle audits pass. Native QA selected two tracked rows, invoked the first context
menu action, and verified the actual working contents and colored inline differences
on opposite sides. HEAD, raw index and all working file bytes remained identical;
the QA app quit normally and no test instances remained.

`site/assets/commit-file-pair.png` is the inspected original 2240 × 1504 native
capture. Native unversioned/deleted/symlink/binary pair variants, alternative diff
tools, historical status-list integration and signed sandbox execution remain
pending. This is a partial port of the status-list action, not full dialog parity.


## Highlighted checkbox changes and keyboard refresh

Pinned `GitStatusListCtrl.cpp::OnLvnItemchanged` applies a clicked row's new check
state to all highlighted rows when that row is highlighted, and changes only the
clicked row otherwise. The native ordinary and three-state staging checkboxes now
follow this rule. `StatusListSelection.checkboxEntries` resolves only actual file
IDs from the displayed list, excluding stale selections and presentation headings.
Table-focused Space applies the focused highlighted row's next checkbox state to
the highlight; mixed staging state stages remaining changes, and fully staged state
unstages. Message-editor Space continues inserting ordinary spaces.

The pinned file context menu contains no Check selected files, Uncheck selected
files, Stage selected files or Unstage selected files items. Those native additions
were removed now that checkbox selection works directly. Upstream group-header
Check group and Uncheck group remain available. Commit's native window handles F5
through the same reload path as Refresh, including message-editor focus, with busy,
quit-confirmation and attached-sheet gates. Command-Return remains the macOS
adaptation of upstream Control-Return.

A regression covers highlighted/unhighlighted checkbox targets, literal Unicode
and newline paths, stale IDs and group IDs. Together with revision comparisons,
file comparisons and groups, 22 focused tests pass. Debug and unsigned App Store
builds and both resource/bundled-Git audits pass.

Native QA verified one checkbox unchecked both highlighted tracked files; checking
an unhighlighted untracked file preserved those highlights and checks. Space
checked the two highlighted files; message-editor Space remained ordinary text.
Creating a disposable untracked file outside the app and pressing F5 in the message
editor refreshed the list while preserving `message preserved` and all checks.
The first selected-file menu omitted the four extra commands. These checks left
HEAD, the raw index and original working bytes unchanged.

In staging mode, Space staged two highlighted untracked files with their exact
working blobs. Clicking either highlighted staging checkbox then unstaged both,
restoring the original index entries while preserving unrelated staged contents,
HEAD and every working file. The test app quit normally and no instances remained.
`site/assets/commit-checkbox-selection.png` is the inspected original 2000 × 1584
ordinary checkbox/F5 capture. Native conflict/dirty-submodule and mixed-state bulk
variants, alternate input devices, full accessibility and signed sandbox workflows
remain pending; this does not establish full checkbox or Commit parity.


## Marked-row index flag actions

Pinned `GitStatusListCtrl.cpp` lines 1815–1832 enable Skip worktree, Assume
Unchanged and Unflag using the selection mark's action mask and flags. Its
`SetGitIndexFlagsForSelectedFiles` (2863–2917) independently looks up selected
index paths, updates found entries and reports missing ones before writing the
index. Commit now uses its resolved mark for flag-menu visibility and confirmation,
including mixed selections and a mark outside the highlight.

The core accepts an explicit marked path for this route, revalidates that mark
under an exclusive real-index lock, and changes flags in a private index before
atomic publication. Selected stage-zero entries are updated, including idempotent
flags and added entries permitted by a different eligible mark; unavailable paths
are reported with the updated count. The existing Status-window route retains its
whole-selection eligibility check. Clearing both flags and setting either flag now
share this transaction and preserve index permissions. Added/deleted combined
actions and retained unversioned copies are excluded from their upstream marked
menu cases rather than relying only on the displayed state.

Eight WorkingTree regressions pass, including two new checks for action-mask gates,
marked mixed-selection updates, missing-path reporting, a mark outside the highlight,
literal paths and unchanged index blobs/HEAD/working bytes. Existing lock rejection,
both-flag clearing and linked-worktree permission checks also pass. Both native
build configurations and bundle/Git resource audits pass.

Native QA highlighted a staged/modified marked file and an untracked file. The
first context menu offered Skip worktree and Assume Unchanged. Its confirmation
then updated only the indexed path and displayed the unavailable untracked path
in a native result sheet. Index blobs, HEAD and all working bytes remained unchanged.
The flagged row moved to Local changes ignored, whose selected-file menu omitted
Skip worktree and offered Assume Unchanged and Unflag. Confirmed Unflag returned
the row to Modified Files and removed the flag without changing those contents.
The same QA process quit normally; no test apps remained.

`site/assets/commit-index-flags.png` is the inspected original 2000 × 1584 native
partial-result sheet capture. Native No/cancel, assume-valid, outside-highlight mark,
conflicted/added/deleted flag variants, split-index and signed sandbox execution
remain under audit. This is partial status-list parity, not completion of all
flag action masks or dialogs.

## Checked-file commits during pending operations

The pinned `CommitDlg.cpp` prepares checked entries against HEAD, resets unchecked
entries for the selected commit tree, and invokes ordinary `git commit`; its merge
condition permits a commit without checked changes. New branch is disabled during
a merge, with the merge-active indicator visible. The old native checkbox path
rejected active merges and used `--only`, which Git also rejects during a cherry-pick.

`commitOperation()` reads Git-resolved MERGE_HEAD/CHERRY_PICK_HEAD/REVERT_HEAD
locations. Checked-file mode now uses the existing selected temporary index against
HEAD and runs normal commit against that index. Git retains merge parents or the
cherry-pick author/date and clears the operation state on success. The real index
stages checked whole-file contents and keeps unchecked entries. Git hooks see the
selected temporary index. A rejection retains HEAD and the operation; checked
contents can remain staged, as in other checkbox paths. The working tree is not
reset. Core preflight rejects amend/new branch during pending operations.

Native Commit shows the operation indicator with original command artwork, disables
new branch/amend, and enables a merge commit with no checked file changes. Settings
and menu/progress parity remain partial. Unresolved index entries still require
resolution; upstream's unresolved-conflict Ignore prompt is not yet mapped.

Thirty-four Commit regression tests pass. New cases verify exact merge parents,
selected whole-file bytes, retained unchecked index and later working edits,
cherry-pick author/date, revert single parent and state cleanup, branch preflight,
hook rejection and an empty selected merge tree. Native QA committed checked.txt
while unchecked Unicode-path staged/working versions stayed intact, verified both
parents and cleared MERGE_HEAD. Both unsigned builds and resource audits passed.
The QA app quit normally and the final process scan was empty.

![Actual native resolved-merge Commit](site/assets/commit-merge.png)

See [recorded acceptance](qa/commit-operation-2026-10-05.json). Native cherry-pick/
revert and hook-failure UI, operation changes while open, dark/narrow layouts,
linked worktrees, octopus merges, multi-step sequencers and signed sandbox execution
remain pending. This is not proof of full Commit dialog parity.

## Issue field and preflight warnings

The configured issue label/field now occupy the upper-right branch row, matching
IDD_COMMITDLG's BUGIDLABEL/BUGID placement. Configuration precedence, simple
template extraction/insertion, C++ regex detection, numeric validation, and
missing-issue/template/sign-off warning order are mapped. Native cancellation
preserves HEAD/index; native commit acceptance verifies the inserted issue line,
sign-off, selected working contents and retained unchecked index/working edits.
Dark-mode acceptance verifies seeded ID extraction and initial issue focus.
See [full audit and remaining gaps](ISSUE-TRACKER-PARITY.md) and
[control evidence](qa/commit-issue-controls-2026-10-05.json).

Checked-file Message only now excludes checked paths from changelist removal;
staging mode still commits indexed paths and uses them for cleanup. Native
changelist cleanup combinations remain under audit. A preflight rejection no
longer offers saved-copy restoration before a commit has been attempted.

## Issue links and Recent-message field updates

The editor now uses the upstream UTF-8 byte regex styling algorithm separately
from Commit's UTF-16 ID validation. Matched context is bold, IDs bold italic,
and configured tracker targets open through native link clicks. Native checks
verified Undo, no stale links after replacement, Recent-message issue updates,
retention for messages with no ID, and unchanged issue fields after revision
insertion. Light/dark captures and preserved HEAD/index/working contents are
recorded in [link acceptance](qa/commit-issue-links-2026-10-05.json).
See [algorithm mapping and remaining editor gaps](ISSUE-TRACKER-PARITY.md).
Full incremental SciEdit behavior, provider plugins and signed sandbox
invocation remain pending; this is partial Commit parity.

## Ordinary message links

URLFinder's punctuation/bracket scanner and its upstream fixtures are now
ported for ordinary URLs and email addresses. URLs override issue styles in
the same order as SciEdit, splitting any affected ID hotspots. Native checks
without tracker configuration verified regular-font links, email targets,
plain SSH addresses, Undo, replacement clearing and exact local file opening.
See [source mapping and limitations](ISSUE-TRACKER-PARITY.md) and
[recorded native acceptance](qa/commit-message-urls-2026-10-05.json).
Unusual Windows scheme classification, incremental styles and full editor
parity remain pending.

## Marker formatting

TortoiseGit's per-line `*bold*`, `^italic^` and `_underlined_` scanner and
its overwrite order are now mapped to native attributed text. The default-on
Style commit messages preference appears in the native Commit settings tab;
changing it restyles open drafts, retains Undo and leaves links enabled.
Native light/dark acceptance and a real commit verify that literal markers and
message contents remain intact. See [source mapping and classification gaps](ISSUE-TRACKER-PARITY.md)
and [recorded evidence](qa/commit-message-format-2026-10-05.json).
The source supplementary-character boundary quirk is retained. Exact Windows
locale classification, incremental editor state, spelling/snippets and full
Advanced settings remain pending.

## Filename completion in the message editor

Displayed filenames and path suffixes now feed a native completion popup with
the original file icon. Automatic/default-minimum and manual keyboard requests,
unchecked unversioned candidates, saved preferences, extension-free names and
Undo have native acceptance evidence. See [completion audit](COMMIT-COMPLETION-PARITY.md)
for source mapping, screenshots and the remaining code/snippet/spelling work.
This does not establish complete SciEdit or Commit parity.

User/shipped snippets now use the original snippet icon and source parsing,
priority and word-expansion rules. Native multiline/Undo/collision/refresh
acceptance is recorded in the [completion audit](COMMIT-COMPLETION-PARITY.md).
Code symbols are now integrated as described below; complete decoding, spelling
and full editor behavior remain pending.

Keyboard dispatch now gates automatic completion on typed insertions, with
native Tab/Shift-Tab focus routing. Builds and completion/snippet regressions
pass. Initial keyboard QA was interrupted by a locked Mac; subsequent native
arrow/deletion/typing/paste and Tab/Shift-Tab checks passed during code-scanner
QA. Complete keyboard, spelling and input-method acceptance remains pending.
See the [completion audit](COMMIT-COMPLETION-PARITY.md).

## Code-symbol completion in the message editor

The changed-file scanner now feeds the Commit popup alongside filenames and
snippets, using original code.ico artwork. Source definition loading, file gates,
raw UTF-16 decoding/capture transport and row insertion priority are implemented.
Native Tab/mouse acceptance, snippet collision, Undo, unchecked-file contribution
and F5 rescanning were verified. See [code-symbol audit](COMMIT-CODE-SYMBOL-PARITY.md)
for evidence and remaining visual, decoder and signed sandbox acceptance.


Native cancellation follow-up at `07e8895`: No retained the unchanged dialog;
Yes closed it normally for an empty message with three changed files, staging off
and no restore copies. Normal Quit also passed later with a Log unified viewer
open. The previous intermittent close/inspection timeout did not reproduce; no
root cause or speculative code fix is claimed. See
[acceptance record](qa/commit-close-log-unified-2026-10-05.json) for exact scope
and remaining changed-message, restore-copy, suppression and signed cases.

## Shared unversioned-file preference

Show Unversioned Files now defaults to enabled in both Commit and Log, matching
upstream `AddBeforeCommit`. Both dialogs read and save the same application-wide
preference, so reopening either dialog uses the last choice made in the other.
Existing open dialogs retain their own current switch state. Log updates loaded
working rows without a history reload; Commit filters its loaded status list.
Busy/closing guards refuse preference changes. The native receiver uses a private
preference domain and real tracked/untracked files to check default visibility,
hide/show, reopen in both directions and exact repository preservation. See
[the shared unversioned QA record](qa/shared-unversioned-2026-10-07.json).

## Visible checked rows form the non-staging commit selection

The non-staging Commit button, checked-file count and commit request now use the
checked rows currently shown in the file list. This matches upstream
`WriteCheckedNamesToPathList`, which iterates displayed list items. Hiding
unversioned files or restricting the project scope can no longer silently commit
cached checks outside that view; ignored and stale paths are excluded too.
The cached checks are retained so revealing a row restores its checkbox.
The checked-file clipboard already uses the same visible-row filter.
Staging mode continues to commit the whole index, independently of checkbox state.

A native fixture makes an actual scoped tracked-file commit while hidden checks
include unversioned, out-of-scope, ignored and stale paths. It checks committed
paths, the untracked path’s absence from the index, unchanged outside index bytes
and working-file bytes, then makes a full-index staging commit outside the scope.
The fixture also verifies button eligibility and reveal/Whole Project behavior.
Run it with `scripts/check-cherry-pick-native.py --commit-selection-only`; it is
included in the normal native checks as well. See
[the visible-selection QA record](qa/commit-visible-selection-2026-10-07.json).
These model/real-Git checks do not prove displayed gestures or signed sandbox
execution. Full Commit acceptance remains incomplete.
