# Compare and Merge word input

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
This continuation of [pane input](MERGE-PANE-INPUT-PARITY.md) covers word
movement, Shift selection and word deletion in the actual Compare and Merge
text views. It does not certify the full editor.

## Source behavior

`TortoiseMerge/BaseView.cpp::GetCharGroup`, `IsWordSeparator`,
`IsCaretAtWordBoundary` and `MoveCaretWordLeft/Right` define word movement by
separator transitions. Space, tab, control characters and the configured
`WordSeparators` are separators. Other characters, including an underscore by
default, remain letters for this operation. Consecutive punctuation and whitespace
form a separator run even though double-click marking distinguishes their groups.
A nonempty line edge is a boundary only when its adjacent character is a letter.
Empty lines have no word boundary. Word traversal therefore crosses blank and
alignment Empty rows until the next boundary or document edge.

The source word-delete handlers first move the caret to that same boundary,
then remove the resulting range. An existing selection is removed as selected.
`RemoveSelectedText` normalizes endpoints off Empty alignment rows. Ordinary blank
lines and removed/resolved-empty records are not reclassified as alignment gaps.
Collapsed marker and hidden rows are skipped as caret destinations while the
selected/deleted source span can include their payload.

## Native implementation

A shared cached `MergePaneInput.WordDocument` provides source word geometry for
all actual Compare and Merge pane subclasses. Native Option-arrow selectors,
forward/backward aliases and their Shift variants retain the original selection
anchor. Option-delete selectors and delivered Control-Backspace/Delete events
use the same boundaries. macOS composed characters and CRLF are indivisible;
invalid interior UTF-16 positions are refused. This deliberately adapts the
Windows single-code-unit caret to native text editing.

Every command reads `TurtleGitMerge.WordSeparators` from its owning preference
domain. Preference changes take effect on the next command without rebuilding
the document. Source revision and text-change invalidation prevent same-length
edits or Undo from retaining stale word geometry. The implementation walks the
cached rows and current line rather than repeatedly reconstructing the document
for every character step. Plain unaligned text uses the same boundary rules and
preserves its real line endings.

Word deletion uses the existing aligned Compare/Merge edit delegates and one
Undo transaction. It preserves peer bytes and saved-source ownership. Registered
window/pane identity, busy state, sheets, read-only mutation and retirement gates
apply before movement or deletion; read-only panes still permit navigation.
Marked-text composition continues through AppKit's composition handling.

## Validation and remaining work

The grouped native receiver is `qa/merge-word-input-native-2026-10-20.swift`,
invoked by `scripts/test-merge-pane-input.py`; focused Core tests exercise source
boundaries independently of the native adapter. The
[dated checkpoint](qa/merge-word-input-2026-10-20.json) records the actual grouped
run, the CRLF failure and repair, and final passes: 11 word Core methods plus
seven existing pane-input methods, final Debug app, and four native cases on
system and bundled Git. Native checks include actual readonly source navigation,
same-length edit/Undo cache invalidation, private separator changes, ghost/blank
rows, collapsed Compare/Merge deletion with peer preservation and Undo/Redo,
selected deletion, aliases and owner refusal. All eight owned receivers were
reaped and independently absent. Passed diff/history Core checks were not rerun
for the word repair.

Physical keyboard layouts and OS-reserved Control shortcuts, live IME input,
VoiceOver, Windows font/page geometry and every possible source state remain
separate acceptance work. These commands do not change Find, marking, inline
difference tokenization or the selected Git comparison engine.
