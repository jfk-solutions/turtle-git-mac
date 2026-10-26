# Unified Diff column selection and editing

The native patch editor supports column selections with **Option-drag**. Hold
Shift as well to extend an existing rectangle. **Command-Option-Shift-Arrows**
extends a rectangle from the caret using the keyboard. The same modifiers with
Home, End, Page Up and Page Down extend to indentation/line boundaries or by the
native viewport. Home toggles between the first non-whitespace character and the
line start. Vertical movement remembers the intended column across short rows.
These shortcuts apply to
the patch editor; normal macOS word selection and VoiceOver modifiers retain
their usual meanings. Escape cancels an active drag.

Columns follow rendered text positions, including tabs and proportional glyphs.
Short rows clamp to their actual ends: selection does not create virtual spaces.
The active corner's row is the primary selection. Each row retains its direction
and identity through editing and Undo, independently of AppKit's range ordering.
Unified Diff normally displays unwrapped logical lines.

## Pinned source contracts

The reference is TortoiseGit commit
`7338078f8ddd924b8cddee35f512f2286072136d`, particularly
`ext/scintilla/src/Editor.cxx`, `Selection.cxx`, `KeyMap.cxx` and
`ext/scintilla/win32/ScintillaWin.cxx`.

| Behavior | Source reference and native policy |
| --- | --- |
| Rectangle geometry | `Editor.cxx:570–591` measures the two corner X positions and maps them onto each logical row. `Selection.cxx:495–498` makes the last added, active-corner row primary. The Mac uses TextKit insertion points. |
| Keyboard extension | `KeyMap.cxx:94–136` provides rectangle arrows, Home, End and page extension. The Mac uses Command-Option-Shift to preserve normal Option-Shift word selection and Control-Option accessibility commands. Horizontal movement uses native composed-character boundaries; page movement uses the native viewport. |
| Typing and Return | `Editor.cxx:181–184, 2082, 3338` defaults to no additional-selection typing and one-target paste. Ordinary typing and Return collapse to the primary row rather than inserting on every row. |
| Copy and Cut | `Editor.cxx:4500` copies rectangle rows top to bottom, with a line ending after every row, including the last. Rectangle Cut removes every selected row span and leaves thin selections. Unicode text carries a separate rectangular marker, following `ScintillaWin.cxx:3564`. |
| Copy Lines versus Cut Lines | Copy Lines copies complete primary-selection lines. For a rectangle, source `SetSelection` rebuilds the original rectangle before Cut, so Cut Lines cuts that rectangle. This distinction is retained rather than treating both as whole-row operations. |
| Delete Line and Transpose | These source commands target the primary caret line. Other selection endpoints follow document changes; a transposition installs its source caret result. |
| Duplicate and indentation | Explicit Duplicate, Indent, Dedent, Tab and BackTab process live selections. An entirely empty selection set duplicates lines. Indentation finishes with thin rectangular selections, following `Editor.cxx:3294–3332, 4205–4283`. |
| Rectangular Paste | `Editor.cxx:2347–2411` pastes at a measured visual X after clearing the destination selection. It strips trailing clipboard line endings, pads short later rows with spaces, adds LF rows beyond EOF and leaves the caret at the original insertion point. A private TextKit layout supplies measured insertion receipts to the byte editor. |

Ordinary Copy/Cut/Paste interoperability remains Unicode text. The rectangular
marker describes clipboard shape, not an original file encoding or a complete
patch. Existing document bytes are retained for unchanged, moved and duplicated
spans. New pasted text passes through the document's existing encoding policy on
Save. Unknown indivisible byte packets cannot be split silently.

## Ownership and Undo

One command records one reciprocal native Undo/Redo transaction, including the
exact byte buffer, all directional ranges, primary identity and rectangle
corners. AppKit's surrounding input-event or macro grouping still applies.
Restyling retains the selection snapshot. Model replacement, close, Quit,
pending work, sheets, marked text and stale owner revisions fence editing and
cancel an obsolete drag. Read-only patch previews permit selection and copying.

## Validation and remaining scope

The [dated checkpoint](qa/unified-column-edit-family-2026-10-27.json) records 35
focused Core methods passing: 13 new column-edit methods, 13 retained line-edit
methods and nine byte-buffer methods. The native Debug build passes after an
explicit CGFloat annotation repair. Its generic exit-code-zero compiler
diagnostics remain recorded.

Native checks pass with bundled Git as a complete group and with system Git
cumulatively across scoped phases. They exercise actual private Option-drag,
keyboard and menu routes; midpoint and tab/proportional geometry; all selection
snapshots; clipboard, exact-byte Save and Undo/Redo; and owner retirement. Three
fixture premise repairs remain recorded: an opaque glyph's assumed cell width,
a proportional glyph/tab midpoint and the distinct stream-paste caret rule.
Product behavior did not change after the app build. All five attempted native
receivers were reaped and independently absent; owned windows, workers and
private pasteboards were closed or released.

This family does not certify every Scintilla selection command, arbitrary
disjoint-selection creation, virtual-space editing, wrapped-line rectangle
equivalence, physical input or VoiceOver acceptance, current signed execution,
minimum-version/Intel execution or the complete hosted suite. The pinned editor
itself notes limitations for rectangle geometry on wrapped lines. Forced native
wrapping is a robustness case, not a claim of Windows layout identity. The native
paste planner bounds one operation to 100,000 clipboard rows and 1,000,000 padding
spaces. Unicode text and a private rectangular marker provide clipboard shape;
they do not interchange exact raw file fragments with other applications.

See also [whole-line editing](UNIFIED-DIFF-LINE-EDITING-PARITY.md),
[the line-number gutter](UNIFIED-DIFF-GUTTER-PARITY.md) and
[byte-backed patch editing](UNIFIED-DIFF-BYTE-EDITING.md).
