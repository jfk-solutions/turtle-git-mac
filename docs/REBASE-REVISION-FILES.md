# Rebase Revision Files

The native Rebase and Cherry Pick `IDD_REBASE` lower pane now embeds the same
file inspection controls as Changed Files. The comparison is against
`RebaseDlg.cpp`'s `m_FileListCtrl` creation/Init, `Log` selection handling and
`GitStatusListCtrl.cpp` at pinned upstream commit
`7338078f8ddd924b8cddee35f512f2286072136d`.

## Connected behavior

Selecting a replay occurrence captures its exact commit and first parent. A root
commit uses the empty tree. Cancellable comparison reads populate the file table
with rename origins, status, added/deleted counts and original status icons and
colors. This retains the existing first-parent semantics of the revision file
list. Conflict recovery continues to show the separate checked Conflict Files
workflow.

The native file menu supplies comparisons, unified diff, both-version Revert,
file Log, child-submodule Log, Blame, export, historical Open/Open With/alternative
editor, Save revision, Save list and clipboard commands with the original icons.
Deleted-file Blame uses the Base commit; historical Open and Save require an
existing non-gitlink destination. Historical operations use pinned blob bytes,
including binary data, rather than the current checkout. Export skips deleted
files. Both-version Revert retains the existing Changed Files checkout rules and
refresh callback. These controls are shared with standalone Changed Files.

Native header menus, column order/width/visibility, column clipboard commands and
copy shortcuts are shared too. Rebase stores its layout under
`RebaseDlg.RevisionFiles.Columns`, independently of `FileDiff.Columns`.

A popup captures the comparison identity and files and can be claimed once.
Replacing the selected commit invalidates old payloads and cancels preparation.
File operations retain the repository access lease and Quit accounting. While
an operation is active, Rebase plan editing, row selection and execution are
blocked. Cancel/Close cancels preparation and owned panels; forced retirement
invalidates commands, cancels work and closes comparison viewers. Export,
application and Save panels and file-operation errors belong to the Rebase
window rather than a hidden auxiliary dialog.

## Display review and limits

These are unaltered native compositor captures from the connected fixture. The
review checked both file/replay panes, visible labels, original colored status
artwork and footer controls in both themes.

![Native Rebase Revision Files in light appearance](site/assets/rebase-revision-files-light.png)
![Native Rebase Revision Files in dark appearance](site/assets/rebase-revision-files-dark.png)

The current row fixture covers an added binary file, deletion and rename. These
captures do not establish menu placement, all selected-row color combinations,
VoiceOver, minimum-size layouts, arbitrary merge graphs or signed deployment.
External application launching, physical Open/Save panels and actual Finder
handoffs still need displayed/signed acceptance. Full GitStatusListCtrl menu
coverage, working-copy-only commands and full Rebase parity remain open.

See [dated results](qa/rebase-revision-files-2026-10-16.json) for the exact grouped
checks, receiver cleanup and build diagnostics.


The shared [per-file recovery continuation](SUBMODULE-DIFF-PARITY.md#per-file-recovery-and-empty-tree-revert--october-16-2026)
adds source Ignore/Abort preparation handling and eligible empty-tree Revert for
root revisions. The root still has no parent. Destination export reads only its
chosen revision, and the shared result/operation ownership remains in effect.
Physical/signed and complete source-menu acceptance remain open.
