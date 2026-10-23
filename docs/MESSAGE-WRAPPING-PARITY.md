# Commit and Rebase message wrapping

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
This family covers the existing project message border, automatic line splitting
and the selected-text Split lines command in Commit and Rebase message editors.
It does not certify all Commit/Rebase dialogs or the whole port.

## Source behavior

`src/Utils/MiscUI/SciEdit.cpp:348–359` uses `tgit.logwidthmarker` to choose
unwrapped horizontal editing with an edge marker when nonzero, and ordinary
word-wrapped editing without the marker when zero. Installing a message or
changing presentation does not itself split its saved text.

`SciEdit.cpp:942–953,1315–1328` responds to text insertion/deletion by splitting
logical lines in the union of the visible and edited range. The width is the
configured column multiplied by the measured width of the space glyph. Automatic
splitting inserts line endings; it does not join preexisting lines.

`SciEdit.cpp:1191–1197,1231–1245` exposes Split lines for an editable editor with
an edge column, enabling it only for a selection. Its explicit command first
joins line endings through the selected target, then splits the affected logical
lines at that measured width. `ext/scintilla/src/Editor.cxx:1772–1825` defines the
join rule: add a separating ASCII space unless the previous character was already
an ASCII space. The target's first and last logical lines participate in splitting.

## Native implementation checkpoint

The shared `ProjectMessageTextView` path supplies Commit and Rebase, retaining
the existing project setting and model bindings. Nonzero width enables horizontal
scrolling; zero width retains visual wrapping. The border and reflow measure the
space glyph with the same eight-space tab policy used by the displayed editor.
A localized Split lines item uses the existing source wrapping icon.

Automatic edits split the visible/edited logical range without joining it. The
explicit command joins and splits as one native undo group, mapping selections
through the edits. Marked input is deferred until composition completes. Initial
message/settings installation does not reflow content or clear undo. Immediate
Commit ownership and Rebase stopped-form identity fence edits and commands even
before SwiftUI updates disabled controls. Read-only, busy, sheet/modal and retired
owners reject mutations; closing an owner retires its retained editor.

The Debug app and four distinct Commit/Rebase case and Git-engine pairs pass
cumulatively after fixture-only startup and cleanup repairs. The fixture checks
loaded CRLF/decomposed Unicode, both width modes, automatic and selected reflow,
Undo/Redo, marked composition, exact join rules, owner guards and unchanged
HEAD/index. All six receiver attempts were reaped and independently confirmed
absent. [Batch evidence](qa/message-wrap-2026-10-23.json) records actual results
and failed attempts; the app build exited zero with one contradictory generic
“failed with exit code 0” diagnostic. No Core production changed and no full Core
suite was rerun for this native-only batch.

## Remaining acceptance

New native line breaks use LF, matching the macOS platform convention; opening
an existing message preserves its original line endings. Explicit joining recognizes
CR/LF/CRLF rather than removing Unicode separator characters from user text.
TextKit font shaping and line-break layout are native adaptations; exact Windows
Scintilla pixel boundaries are not established by source mapping. Physical input
methods, keyboard/VoiceOver, signed installed entry points, complete hosted CI and
all upstream Commit/Rebase state/layout parity remain separate acceptance work.
