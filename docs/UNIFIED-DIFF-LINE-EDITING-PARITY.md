# Unified Diff whole-line editing

The native Unified Diff editor provides line operations through its Edit menu and
context menu. They act on the patch document, rather than changing a repository
or staging files. Read-only previews permit line copying; edits require an
editable document and an available owner.

## Source behavior

Pinned TortoiseGit commit: `7338078f8ddd924b8cddee35f512f2286072136d`.

| Operation | Source contract |
| --- | --- |
| Copy Lines / Cut Lines | Expand both selection endpoints to complete logical lines, including the line containing an endpoint at its start. Cut removes that expanded range. |
| Delete Line | Remove the caret's logical line, including its ending; update both selection endpoints through that deletion. Other selected lines are not deleted. |
| Duplicate | Duplicate selected text after itself; with an empty selection, insert a new line ending and copy the current line's content. Retain the original selection/caret. |
| Transpose Lines | Exchange current and previous line content while keeping their respective line endings in place. Move the caret to the current line's start. The first line is unchanged. |
| Indent / Dedent | Adjust leading whitespace by the configured tab width, using source tab-stop rules. Exclude a last line selected only at its start. Skip genuinely empty lines when indenting. Preserve selection direction over the affected lines. |
| Tab / Shift-Tab | Multi-line selections use block indentation. On one line, Tab inserts a tab or adjusts leading indentation; Shift-Tab reduces leading indentation or moves back to the previous tab stop. |

The source implementation is in `ext/scintilla/src/Editor.cxx:3236–3265,
3294–3320, 4138–4153, 4205–4283`, `Document.cxx:1871–1882`, and
`Selection.cxx:54–81, 133–144`. Live default keyboard bindings are in
`KeyMap.cxx:159–170`. TortoiseUDiff sets its configured tab width in
`src/TortoiseUDiff/MainWindow.cpp:628`.

## macOS controls and data

Native shortcuts preserve macOS's inherited Control-T character transpose and
Control-D forward delete. Line actions have editor-specific shortcuts and native
menu icons. Find fields and unrelated windows keep their normal keyboard input.
The line shortcuts apply while the patch text is the active editor:

| Action | Shortcut |
| --- | --- |
| Copy Lines | Command-Option-C |
| Cut Lines | Command-Option-X |
| Delete Line | Command-Option-K |
| Duplicate Selection or Line | Command-Option-D |
| Transpose Lines | Command-Option-T |
| Indent Lines / Dedent Lines | Command-] / Command-[ |

Tab and Shift-Tab remain available inside editable patch text. Explicit menu Indent/Dedent applies to the current line even with a
caret at its first column. This is a macOS menu adaptation: the source
LineIndent API can otherwise exclude that line through its endpoint rule. The
actual source Tab/BackTab keyboard behavior remains separate.

Scintilla defaults to LF on non-Windows platforms (`Document.cxx:163–174`). New
line endings inserted by Duplicate use LF on the Mac. Existing CR, LF and CRLF
terminators are retained where the source operation retains them. The source
uses tabs and enables tab indentation; the Mac editor uses its existing Unified
Diff tab-size preference.

Whole-line Copy/Cut uses the native Unicode clipboard, matching ScintillaWin's
Unicode-text clipboard contract (`ScintillaWin.cxx:3564–3574`). It does not label
an arbitrary copied line as a complete patch. Document byte preservation and
ordinary text clipboard conversion are separate operations.

## Bytes, Undo and ownership

Line transactions retain the original byte spans when moving or duplicating
content. Each operation records one native Undo/Redo transaction, with the original
selection direction restored by Undo. AppKit's surrounding event or explicit
macro grouping still applies. Byte changes remain real edits even when
two opaque packets have the same displayed replacement characters. The dirty
indicator compares exact bytes when the displayed text matches the saved text.
Save continues to use the existing document's codec and file-session policy.

An unrepresentable unsaved character remains editable. Line deletion can remove
it; Undo restores that draft. Encoding diagnostics remain on explicit export or
Save, rather than preventing further editing. Unknown byte-to-text boundaries
are refused atomically instead of silently regenerating an opaque packet.

Menus, shortcuts and queued Undo operations are bound to their source owner and
document revision. Pending work, Quit, sheets, replacement or a retired owner
refuse stale actions. Find fields and read-only viewers retain their own policies.

## Verification and remaining work

The [dated checkpoint](qa/unified-line-edit-family-2026-10-26.json) records 22
focused Core methods passing: 13 new line-editing methods and nine retained byte
buffer methods. The native app build passes. Native checks pass with bundled Git
as a full group and with system Git cumulatively across focused phases. They
cover actual menus/actions, editor input, exact packet Undo/Redo/Save, draft
recovery, read-only behavior and ownership/cleanup. Fixture compile, keyboard
metadata, error-type and native input-event-boundary repairs remain recorded;
no product source changed after the app checkpoint.

All owned receiver windows/processes were closed. The native harness supplies
private input events and key-window lookup; physical input/menu-bar dispatch and
current signed execution remain separate acceptance. This family does not
certify every Scintilla command, rectangular/multiple selections, physical input,
VoiceOver, printing, signed distribution or the complete port. The independent
[gutter family](UNIFIED-DIFF-GUTTER-PARITY.md) covers line numbering and whole-line
selection; ordinary text edits retain the [byte-backed editor](UNIFIED-DIFF-BYTE-EDITING.md).
The later [column editing family](UNIFIED-DIFF-COLUMN-EDITING-PARITY.md) extends
selection and clipboard behavior with its own implementation and validation scope.


## Integrated column submenu fixture — 31 October 2026

The later Column Selection family appends a separator and its own eight-direction
submenu after the seven whole-line commands in the actual Lines context menu.
Older editors CI job124385294454 still expected exactly seven nonseparator items
at fixture line126; that assertion predates the integrated group, rather than
establishing incorrect production menu order.

The corrected fixture requires the exact seven line command captions/order, then
the separator and Column Selection group with no extra entries. It independently
asserts all eight direction captions/order, source icons, enabled state and actual
text-view action ownership; dispatching Right must extend a rectangle without
changing bytes or Undo. Icon suppression covers both parent entries and direction
leaves. Retained column receipts must not act through busy, sheet, Quit, equal-byte
replacement or retired-owner boundaries, alongside the existing line-command
checks. No production menu or receipt guard changes are made.

The initial focused recheck passed the seven-command ordering assertion, then
failed the newly added expectation that the attached submenu parent retained nil
action/target (system receiver1365, reaped). The fixture now checks the parent's
public submenu topology, exact localized caption and absence of a leaf command
receipt, leaving AppKit's submenu dispatch to the native menu. It reports actual
parent title/action/target/topology on failure. Every leaf's exact direction,
icons, text-view target/action and behavioral dispatch assertions remain intact.
No product change or private AppKit selector dependency was introduced.

The final focused commands and ownership group passes with system and bundled
Git, as recorded in the [native consumer checkpoint](qa/native-service-line-host-2026-10-31.json).
The runner is
`python3 scripts/test-unified-line-edit.py --only commands --only ownership`.
The existing keyboard/bytes/draft assertions remain unchanged and were not
repeated; Core was not rerun for these native-only fixture corrections. Both
successful receivers were reaped and private windows/pasteboards released.
This does not prove physical context-menu interaction, signed installed acceptance
or complete current hosted CI success. The preceding failures remain recorded
below and in the checkpoint.

The next focused check passed the actual menu/topology/dispatch command cohort
but found a second pre-column expectation in ownership (system receiver5132,
reaped): the old test required Duplicate to reject multiple stream selections.
Pinned `Editor.cxx:3294–3316` explicitly iterates every live selection for
Duplicate, and the later native multiple-line engine implements that contract.
The corrected ownership cohort first leaves rectangle mode through the native
selection controller, requires two nonrectangular native selections, then checks
exact duplication of both spans and single Undo/Redo restoration of original
bytes, both ranges, direction and mode. It resets through native mode transitions
before the original equal-byte replacement, held Save and retirement assertions.
No secondary-selection assertion is removed and production behavior is unchanged.
