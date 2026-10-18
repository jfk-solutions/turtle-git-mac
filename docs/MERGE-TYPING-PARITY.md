# Merge typing and current-line endings

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`, TortoiseMerge
`BaseView.cpp::OnKeyDown`, `OnChar`, `UpdateCaret` and per-view `m_bInsertMode`.

The native Compare and merged-result editors now support Insert/Overwrite mode.
Insert toggles the focused writable pane; Edit → Overwrite mode and the footer's
INS/OVR control expose the same state on keyboards without an Insert key.
Comparison panes retain separate modes for their window lifetime. A new editor
starts in Insert mode, as upstream does; this is not a global saved preference.
An overwrite caret covers the character with a translucent native color, keeping
it readable in either appearance.

Committed single-character input replaces the next composed Unicode character.
This adapts upstream UTF-16 code-unit overwrite to macOS grapheme boundaries so
emoji and combining sequences are not split. An existing selection is replaced
exactly, with no extra overwritten character. End-of-line typing inserts before
the ending. Tab, Return, explicit paste/replacement ranges and ongoing marked-text
input retain the existing native insertion path. Full IME/dead-key interaction
and physical caret rendering still require acceptance.

Ctrl-Enter (or Edit → Cycle current line ending) cycles only the current row:
CRLF → CR → LF → CRLF. Other recognized endings change to CRLF, matching the
source default branch. An unended row is unchanged. Comparison changes retain
view records and original opposite payload; combined view preserves removed rows.
Cycling a removed row makes it Edited and includes it in the result, as source
OnChar does. Combined records are remapped so returning to two-pane view retains
the same saved text. Combined row remapping retains moved-block links in their stable display
coordinates. Original source-coordinate tooltip labels retain the existing editor
limitation after source rows are materialized.

Merged-result changes use aligned row transforms, retaining conflict records and
source rows; a non-aligned result changes its actual ending range. Both editors
record one Undo step and retain the selected output encoding/default newline.
Save continues through the existing snapshot/permission/backup/resolution guards.
Ctrl-M and Edit → Mark block now toggle the first selected block's mark in the
comparison's Mine pane, reusing the existing mark/save machinery and Undo while
retaining its text/block selection and engine rows.

All actions recheck writable pane, operation/sheet/owner state. Detached or retired
menu actions use the existing command-menu fences. Source panes in a three-way
merge remain read-only and cannot enable Overwrite or cycle endings.

The [batch evidence](qa/merge-typing-2026-10-16.json) records 73 passing focused
Core checks and the one affected row-state recheck, successful Debug builds, and
eleven passing grouped native case/engine runs. Initial Core/native fixture compile
errors and the real Undo-group exception are recorded with their repairs. The
exception left AppKit idle; its owned receiver was explicitly terminated and reaped
after diagnosis. All final receiver PIDs were independently absent. No full Core
suite, complete hosted CI or physical input/caret acceptance is claimed. This is partial source parity;
complete editor state transitions, physical input/accessibility, native menu and
caret appearance, signed sandbox/Finder/App Store acceptance remain open.

## Document-owned editing history — October 18, 2026

Hosted CI at `12f29e1e` passed the earlier Unicode/paste, row cycle and marking
phases but failed `Combined cycle Undo failed`. The ordinary typing receiver
passed locally. A separate production-representable fixture reproduced the owner
failure locally: reusing a Base coordinator as Destination left Undo routed through
the departed Destination coordinator's weak callback.

Comparison Undo/Redo now targets the document model and its ordered all-view
history. Each edit captures exact target text, annotations, edit identities, row
alignment/combined records, moved-row links and caret. Restoring history updates
live native panes synchronously; when a pane is temporarily absent, the restored
caret is consumed after its replacement attaches. New edits discard the abandoned
Redo branch. History resets on document reload/close and retains the existing
operation, sheet and retirement gates.

Undo remains available while a text/block edit's comparison request is pending;
restoring the snapshot cancels that request. Redo of a pending projection starts
the authoritative engine comparison again, preserving comparison options such as
Ignore Case rather than accepting provisional row differences as final.

Native editor registration follows logical role changes as well as initial
creation. Base/Destination accessibility labels follow the actual role. Captured
edit actions recheck their original role and viewport owner, so a stale Base
callback cannot mutate a reused Destination editor. Detached editors cannot
register text mutations. Editing callbacks remain native-window scoped; Undo no
longer needs a coordinator which may have been dismantled by SwiftUI.

This follows pinned `TortoiseMerge/Undo.cpp`'s ordered all-view text/state/ending/
mark history and `BaseView.cpp`'s grouped editing actions. Existing encoding choice
and typing granularity remain unchanged. Three-pane result metadata continues to
use its existing result-editor transactions; this batch does not certify every
possible three-pane view replacement or native IME interaction. The source icons,
menus and shortcuts remain the existing native controls. See
[batch evidence](qa/merge-edit-history-2026-10-18.json) for the reproduced failure,
grouped validation and remaining hosted/visual limits.
