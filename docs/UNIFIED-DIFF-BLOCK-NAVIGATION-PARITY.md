# Unified Diff text blocks and viewport navigation

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`ext/scintilla/src/KeyMap.cxx:90–101`, `Document.cxx:1970–2011` and
`Editor.cxx:871–904,1112–1130,3478–3498,3945–3974`.

The focused patch text exposes Previous/Next Text Block, selection extensions and
Scroll One Line Up/Down through Edit → Caret and its icon-bearing context submenu.
Control-brackets and Control-Shift-brackets retain source paragraph bindings;
Control-Up/Down retain source viewport commands. Ordinary AppKit word/document
shortcuts and other text fields keep their existing bindings. macOS may consume
Control-arrow shortcuts for desktop navigation before the editor receives them.

## Logical blocks and selections

The pure Core helper uses logical CR, LF and CRLF boundaries. Only ASCII spaces
and tabs make a blank separator line. Unicode separators, NBSP, vertical tabs,
form feeds and opaque byte-display characters remain ordinary source text.
Previous from inside a block reaches its start; previous at a line start scans
the preceding block. Next skips the current block and following blank lines,
reaching the next block start or the final logical line end. Native composed
characters and CRLF interiors are indivisible caret positions.

Block movement starts from the main caret. Ordinary movement collapses to the
new point. Extension retains the main anchor; rectangle extension converts to a
stream using the main row’s existing anchor. The source's default single-selection
policy reduces additional native selections to the main selection. This differs
from word-part movement's initial directional rectangle-collapse command.

## Viewport and lifetime

Viewport commands scroll one native displayed text fragment, including wrapping.
They retain the entire selection while the main caret remains visible. Source
`MoveCaretInsideView(false)` clamps an offscreen caret to the nearest visible
line, collapsing the selection and preserving its horizontal position where the
line permits. Native layout geometry handles the corresponding wrapped fragment.
The desired horizontal column survives clamp-induced movement across short lines.
An actual selection/text change, replacement document, font or container geometry
change resets that column. The explicit viewport is preserved after that selection
change. Document edges
clamp to actual scroll bounds.

These are read-only navigation operations: no edit-buffer reencoding or Undo
transaction occurs. Existing focused-source identity, document reset, owner
revision, busy, modal/sheet, error, marked-text and retirement fences apply to
keys and menus. Retained menu receipts cannot navigate replacement documents.
Read-only previews permit navigation without enabling editing or Overtype.

## Validation and remaining acceptance

The [grouped checkpoint](qa/unified-block-navigation-2026-10-29.json) records
17 focused Core methods with zero failures, the final successful Debug build and
the native family passing with system and bundled Git. It includes actual key
and menu routes, reverse/rectangle selections, wrapped/unwrapped viewport state,
short-line column recovery, stale and retired owner refusal, and unchanged
original bytes, Undo, HEAD, index and working files. Both final receivers were
reaped and independently confirmed absent.

The first Debug attempt was interrupted to include the desired-column source
review correction. Two native attempts failed viewport setup: direct sizeToFit
had not reconciled the document extent, then width tracking followed a wide
frame instead of the intended wrap width. Production extent reconciliation and
a fixed-width native layout repaired those fixtures without removing behavioral
assertions. Only the affected receiver group was rerun; Core and app build were
not repeated for fixture changes. These checks do not add a Wrap preference.

Physical keyboard layouts, OS shortcut interception, VoiceOver, signed installed
build acceptance and whole UDiff/TortoiseGit parity remain separate. Installed
build32 predates this batch.
