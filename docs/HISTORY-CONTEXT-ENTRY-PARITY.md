# File and history keyboard context menus

This connected native batch follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. It adds missing keyboard and
accessibility entry routes to existing commands; it does not certify the complete
dialogs or add a different Git command implementation.

## Source and native behavior

`src/Git/GitStatusListCtrl.cpp::OnContextMenuList` handles the Windows
`WM_CONTEXTMENU(-1,-1)` request at the selection mark's label rectangle. Its
selected count and selection mark remain separate from the pointed column.
Add's native file list now exposes Shift-F10 and accessibility **Show Menu**.
It keeps all selected files, anchors on the selected mark (falling back to the
first selected file), and clears the previous mouse column. The same existing
menu delegate provides command availability, source icons, checked-file actions,
history, comparison, clipboard and captured callbacks. A keyboard request does
not stage files or change the checked set. Pointer entry still selects an
unselected pointed row and preserves an already selected group.

Synchronization's incoming/outgoing file grids use the same selected-row menu
route, including the existing file actions and multi-selection. Its history
grids populate the existing menu before native tracking begins. Reference/tag
menus scroll the selected result into view before anchoring. File selection
repaints native cells without resetting the table data; unchanged-catalog refresh
retains the native selection instead of waiting for a later model refresh. Keyboard events
belong to their actual focused key window; accessibility targets the available
selected native view. Hidden tabs, owned reads/questions, Quit and retirement
retain their existing command restrictions.

Blame's embedded Log gains accessibility **Show Menu** and anchors keyboard
menus at the selected revision rather than treating a key event as a pointer.
The existing captured parent read, revision menu and source icons remain shared.
Pinned `TortoiseGitBlameView.cpp::OnLButtonDown`, `OnViewNext` and `OnViewPrev` describe the
annotation-to-Log selection and selected-commit change navigation. Native gutter,
source selection and next/previous navigation now use the same live document
admission as Find and menu commands. Retired views release their event targets.

Ordinary Log and Revision Graph already have their own native keyboard and
accessibility routes. They are retained rather than replaced by these changes.

## Explicit remaining work

Synchronization's SwiftUI conflict table still lacks an explicitly verified
accessibility Show Menu bridge; its pointer menu and existing keyboard actions
remain. This batch does not replace SwiftUI tables by runtime subclasses.
Physical VoiceOver/keyboard tracking, complete light/dark layout comparison,
signed Finder invocation, all dialog commands and full hosted CI remain separate
acceptance gates. Native receiver evidence covers only its recorded cases.

## Grouped checkpoint

[The dated record](qa/history-context-entry-2026-11-22.json) retains six distinct
case/engine passes: Add, Synchronization and Blame with system and bundled Git.
Actual native menus verify source icons, captured commands/clipboard subjects,
selection and viewport anchors, keyboard owner checks, blocking sheets/Quit,
retired views and unchanged fixture repository contents. Sync covers both
commit/file directions and actual private Fetch reference results; tag-specific
menu content is not newly certified. Blame separates native source-caret selection
from the explicit annotation operation; it does not simulate a physical margin
click.

The first Sync failure exposed native selection clearing during reload. A
diagnostic recheck isolated it, and the affected incremental build and Sync
cases passed after the source repair. Blame fixture corrections separate caret
selection from commit highlighting and exclude the newline from selected line
contents, matching the actual operation. All attempts and assertions are retained.
The initial app build and affected rebuild exit zero; the local Xcode log also
emits contradictory failed-command-with-exit-zero diagnostics. The receivers
link current Debug objects and enforce source/object freshness; this is not a
clean hosted-SDK or full-suite claim. Core/Git operations were unchanged, so no
Core suite was repeated.
