# Log changed-file identities and captured commands

This continuation compares the Log changed-file list with the pinned upstream
`7338078f8ddd924b8cddee35f512f2286072136d`, specifically `LogDlg.cpp`'s
`IDC_LOGMSG` setup and `src/Git/GitStatusListCtrl.cpp`'s `OnContextMenu`, selection
mark, selected-row iteration and `IDGITLC_COMPARETWOFILES` dispatch. The existing
five-column list, parent headers, source artwork and status palette are retained.
This is a behavior continuation, not a new full-window visual acceptance claim.

## Native list and exact file occurrences

Git paths remain byte-exact through highlighted selection, focus/selection mark,
clipboard statuses, working index flags, unversioned filtering, selected-file
counts and action preflights. The SwiftUI table uses lossless ASCII row identities;
its shared AppKit keyboard/copy/column adapter continues to receive raw Git IDs.
Parent prefixes remain part of the occurrence identity: two spellings across two
parents occupy four independently selectable file rows. Parent headings are not
accepted as file selections or command targets.

Selection additions retain the most recently added file mark. Focus movement
inside an existing multiselection updates that mark without replacing the
highlighted set. Path ordering breaks ties using raw UTF-8 bytes. File actions
iterate the displayed file rows; per-parent comparisons retain the corresponding
actual Git parent rather than deriving a parent from the visual row number.

Historical blob lookups disable Git's macOS argument precomposition. Historical
Compare two files accepts distinct byte spellings even if Swift String
considers them canonically equivalent. It retains each side's path and bytes.
Historical Revert validates the exact path/old path/action in the selected parent
group; a canonically equivalent unchanged neighbor cannot impersonate that entry.
Export deduplicates only exact Git paths. When two selected Git spellings would
map to the same macOS destination filename, it refuses the plan before writing
and explains how to export them separately. It does not silently omit one path
or overwrite the first with the second. Export execution rejects an unselected
canonical neighbor as well.

## Context menus and delayed work

Every changed-file menu leaf, including nested flags, Resolve, Ignore, Copy,
prepared comparisons and historical open/save choices, shares one captured
receipt. It runs at most once and only for its originating model and original
file projection. Selection, focus/mark, revision/details replacement, filter,
sort/column layout, comparison mark, busy transition or retirement invalidates
that receipt. Blocking child windows/sheets refuse dispatch.

Async file reads and confirmation workflows retain a separate selection
generation, which remains stable during their own busy interval. Changed targets,
including changes away and back to the same selection, cannot launch a later
Blame, Finder, chooser, conflict/Add/Commit/Revert handoff or index-flag mutation.
Historical Save/Open reads also check their owner before presenting their result;
stale read failures cannot replace a newer dialog's error state. Patch previews
retain exact selected occurrences in their existing generation guard.

Log's Save, Export and Open With panels now share `OwnedFilePanelSession`. The
owner stays busy until the native panel has released its sheet. Cancellation,
repeated callbacks and forced retirement cannot start a later copy/export/open.
The chosen target must still belong to the captured file selection. Historical
Save holds the chosen destination's security scope while writing atomically.

## Acceptance limits

The batch evidence is recorded in [Log file identity QA](qa/log-file-identities-2026-10-17.json).
The final affected Core run passed 75 cases; 158 distinct cases passed across
retained and affected runs. Six native case/engine combinations passed with
system and bundled Git. The older Log/Cherry Pick receiver also compiles. All
nine recorded receiver/helper PIDs were reaped and independently absent. Actual
compile/runtime failures and their repairs remain recorded in the evidence.

The focused checks cover private repositories/preferences/pasteboards and owned
native windows. Native table selection and native sheet cancellation are exercised;
menu receipt checks invoke the production dispatch guard and callbacks directly.
They do not establish physical popup tracking, mouse/keyboard layouts, VoiceOver,
Open With application delivery or signed security-scoped grants. The [external document opening continuation](LOG-DOCUMENT-OPEN-PARITY.md)
connects launch completion ownership, captured editor settings and preview retirement. Existing broader Log view,
reference chooser, merge/group presentation and signed Finder acceptance gaps in
[Log parity](LOG-PARITY.md) remain open. Complete application parity, hosted CI and
App Store acceptance are not established by this batch.
