# Submodule conflict dialog parity

Reference: `SubmoduleResolveConflictDlg.cpp`, `CAppUtils::ConflictEdit`,
`CGitDiff::GetSubmoduleChangeType`, `SubmoduleDiffDlg::GetChangeTypeBrush` and
`IDD_RESOLVESUBMODULECONFLICT`, pinned to `upstream.json`.

## Implemented

The native resizable window follows the upstream path/Help header and three
vertical groups. Base shows revision, subject and Show log; each destination adds
Type and Use this. Parent-operation reference identities label the destination
groups. Rebase reverses displayed sides while retaining their actual stage choices.
Show log opens the child repository with history ending at the displayed commit.
Unavailable history buttons are disabled and unavailable subjects are red.

For initialized submodules the displayed Base is child HEAD, as upstream specifies.
The captured index stages remain separate and are revalidated before resolution.
Ancestry classifies Fast Forward and Rewind; unrelated revisions use commit times.
The upstream green, pink, blue, orange and gray type backgrounds are retained in
both appearances. Subjects and hashes remain selectable. Window geometry is saved.

Use this asks the upstream Yes/No question. A matching child checkout resolves the
exact selected gitlink without changing parent HEAD or continuing the merge.
A differing initialized checkout opens the existing native Reset dialog and resumes
after successful reset, repeating stage/checkout validation. Uninitialized gitlinks
can be resolved without constructing a checkout. The window retains its repository
permission lease and uses the existing App Store mutation guards.

Edit conflict and double-click dispatch are extended for submodules in Commit,
Working Tree and Resolve. The workspace conflict context menu also offers the editor.

Choosing an uninitialized gitlink now first uses checkout-index when the current
path is a regular file, creating the destination directory before recording the
exact gitlink. For a missing destination stage, failed Git removal of a nonempty
submodule directory presents the upstream Delete/Abort choices. Abort is the
Return action; Delete moves the complete folder to macOS Trash and retries Git rm.
The actor revalidates captured index stages and containment after confirmation and
before each remaining item. A failure after moving to Trash reports the recoverable
location rather than implying that nothing changed.

## Verification

The full Swift suite passed 167 tests. The initial four real-Git tests verify checkout-based
Base versus captured stage 1, subjects/history availability, forward/rewind,
uninitialized exact-index resolution, rebase stage reversal and regular-file rejection.
Nine submodule tests plus ten general Resolve tests also passed after the edge-case
changes. New fixtures verify file-to-gitlink directory replacement, Delete/Abort,
recoverable Trash contents, stale stages after confirmation suspends the actor,
and deterministic newer/older/same committer-time classification. Original icon
decoding/template assertions passed; the final shared SwiftUI renderer compiled.

Native QA on `/private/tmp/TurtleGitSubmoduleChooserQA` displayed the expected
checkout and destination revisions. No retained the chooser; Use this followed by
Yes resolved to the checked-out HEAD. Git independently verified the exact stage-0
gitlink, unchanged parent HEAD/refs and working files, and retained MERGE_HEAD.
The chooser closed; parent-window restoration remains unverified because the UI
observer reported no windows while the app inventory still showed the app running.

Native `/private/tmp/TurtleGitSubmoduleDeleteQA` selected the deleted side, showed
the failed Git removal message and Delete/Abort prompt, and used Return to Abort.
Git verified unchanged HEAD, refs, all index stages, working files and child .git.
An independent `/private/tmp/TurtleGitSubmoduleDeleteExecuteQA` case selected Delete.
The index became resolved/deleted, parent HEAD/refs stayed unchanged, and the complete
child checkout was verified recoverable in macOS Trash. Post-action window
observations failed while the apps remained live, so parent restoration and fully
enabled Abort recovery are not claimed.

`site/assets/submodule-conflict.png` and `submodule-conflict-dark.png` are actual
native captures (1560 × 1204), inspected before copying. They show a same-time
conflict in light mode and green Fast Forward types in the updated dark capture.
The dark Log/Help glyphs retain the original shapes with readable native tinting.
Rewind and divergent-time colors still need native visual QA. The first QA request incorrectly used form-style plus encoding
for a space; a percent-encoded request opened the intended dialog successfully.

## Remaining parity

Native child Log handoff, Reset/resume from this chooser, resizing/persistence,
uninitialized/error/rebase controls and all menu consumers still need broader QA.
Missing-object handling and the full uninitialized decision table need further
fixtures. Reverse gitlink-to-file replacement, registered submodule removal,
multiple-item failure/recovery and other mixed type changes need broader QA. Full progress,
cancellation and signed permissions for external submodule administrative directories
remain pending. Child Log handoff attempts failed in the UI observer, so that
workflow is still unverified. Native signed Finder icon appearance also remains pending.

All 26 resource controls and related source files remain **partial**.
