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

## Verification

The full Swift suite passed 162 tests. Four new real-Git tests verify checkout-based
Base versus captured stage 1, subjects/history availability, forward/rewind,
uninitialized exact-index resolution, rebase stage reversal and regular-file rejection.
After the final reference-label change, all four focused tests passed again.

Native QA on `/private/tmp/TurtleGitSubmoduleChooserQA` displayed the expected
checkout and destination revisions. No retained the chooser; Use this followed by
Yes resolved to the checked-out HEAD. Git independently verified the exact stage-0
gitlink, unchanged parent HEAD/refs and working files, and retained MERGE_HEAD.
The chooser closed; parent-window restoration remains unverified because the UI
observer reported no windows while the app inventory still showed the app running.

`site/assets/submodule-conflict.png` and `submodule-conflict-dark.png` are actual
native captures (1560 × 1204), inspected before copying. They show a same-time
conflict, so the colored ancestry cases are tested in the core but remain pending
native visual QA. The first QA request incorrectly used form-style plus encoding
for a space; a percent-encoded request opened the intended dialog successfully.

## Remaining parity

Native child Log handoff, Reset/resume from this chooser, resizing/persistence,
uninitialized/error/rebase controls and all menu consumers still need broader QA.
Missing-object handling and the full uninitialized decision table need further
fixtures. Mixed regular-file/gitlink replacements and submodule deletion must be
audited against the upstream per-item Delete/Abort handling; existing generic
Resolve behavior is not evidence of full parity for those cases. Full progress,
cancellation and signed permissions for external submodule administrative directories
remain pending. Dark-mode original Log artwork also needs contrast adaptation.

All 26 resource controls and related source files remain **partial**.
