# Compare and Merge pane input

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
This family concerns ordinary caret movement, keyboard selection and deletion in
the native two-file comparison and three-pane Merge editors. Difference/conflict
navigation, Find, Go To Line and pane switching already have separate workflows.

## Source behavior

`TortoiseMerge/BaseView.cpp::MoveCaretLeft/MoveCaretRight`,
`OnCaretUp/OnCaretDown` and the Home/Page handlers in `OnKeyDown` navigate the
source view/screen mapping rather than a flat concatenated string. Collapsed
rows whose HideState is not Shown are skipped; the marker is a display affordance,
not a caret destination. Shift retains the original selection anchor as the
caret moves. A selection may span collapsed source rows without opening them.
Word movement repeatedly uses this same caret traversal until a source word
boundary. The native implementation retains macOS text-navigation aliases and
TextKit geometry rather than copying Windows font metrics or splitting composed
Unicode characters to mimic individual UTF-16 code units.

The source Home handler toggles between the first non-space/tab position and
column zero. Plain Home is distinct from document-start movement; Shift extends
selection using the same destination. Page and vertical motion retain their
caret-column/viewport role and must not accidentally unfold unchanged sections.

`OnKeyDown` Backspace/Delete and `RemoveSelectedText` distinguish an alignment
Empty record from an ordinary empty text line. Backspace skips Empty records
before choosing its deletion start, and removal normalizes endpoints off Empty
records. For source rows `A`, alignment gap, `B`, Backspace at B's start joins A
and B; deleting only an artificial display newline would have no serialized
effect. A real blank line remains a real editable line. Source edits still form
one Undo transaction, preserve untouched peer records and retain real endings.

## Native ownership and reveal boundaries

The shared pane-input adapter belongs to the actual native text views. Character,
word, vertical and page selectors and their Shift-selection variants use the
fold visibility map while retaining the real source/display coordinates. Its
bounded keyboard-selection receipt prevents deferred native selection callbacks
from treating an intentional folded traversal as an explicit reveal request.

Explicit Find, Go To Line, accepted history restoration and marker expansion
keep their existing reveal behavior. A plain programmatic selection is not
silently reclassified as keyboard navigation. Existing active-pane/window,
read-only mutation, busy, sheet, replacement and retirement checks remain in
force. Navigation does not create Undo, change source bytes or save files.
Deletion continues through the existing Compare/Merge edit transactions rather
than maintaining a second history implementation.

## History restoration

Restoring a Merge history snapshot replaces the aligned document and rebuilds
its shared fold map. Intermediate selection collapse in source panes must not
expand unrelated sections at their old caret positions. The native history
transaction suppresses those incidental selection callbacks across registered
panes, then reveals only the final restored result selection through the existing
history navigation path. Text, peer bytes and folding are checked independently.
Removed and resolved-empty result records remain visible editing coordinates;
like `BaseView::SaveFile`, serialization excludes them. They are distinct from
Empty alignment records for caret movement and deletion.

## Evidence and limits

The [dated checkpoint](qa/merge-pane-input-2026-10-19.json) records actual
outcomes and failed attempts. The independent native receiver is
`qa/merge-pane-input-native-2026-10-19.swift`; its grouped runner is
`scripts/test-merge-pane-input.py`. The focused Core checkpoint passed 98 related
editor methods. Final navigation passed on system and bundled Git across actual
Compare/Merge panes with wrapping both enabled and disabled. The native-only history repair then passed editing, ownership, retained typing and
document-history workflows on both engines. In total the checkpoint covers five
native cases on two engines. Navigation code remained unchanged after its pass;
only affected failed cases were repeated. The Debug app builds, localization and
bundled Help checks pass. Every owned receiver was reaped and independently absent.

Initial native checks exposed offscreen caret geometry and wrapped subline
movement defects, then an unrelated fold expansion during Merge Undo. Their
production repairs and bounded rechecks are recorded in the dated evidence.
Fixture repairs distinguished actual Empty records from resolved removals,
matched source SaveFile exclusions, and awaited the registered combined pane after
its asynchronous projection reload; all behavioral assertions remain.

The executed checks cover actual production panes, folded movement/selection,
smart Home, ghost versus real blank deletion, Undo/Redo and unchanged peer bytes,
explicit reveal and owner refusal. Physical keyboard layouts, IME composition,
VoiceOver, exact Windows page geometry, signed runtime access and every editor
state remain separate acceptance work. This family does not certify the entire
editor or application.

The [word-input continuation](MERGE-WORD-INPUT-PARITY.md) replaces the initial
AppKit word-boundary proposal with the source separator rules and adds owned
word deletion. The October 19 checkpoint above predates that continuation and
does not prove its subsequent changes.
