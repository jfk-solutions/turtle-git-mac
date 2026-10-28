# Unified Diff caret editing modes

Unified Diff's **Edit → Caret** menu and text context menu provide word-part
navigation, selection extension and an editable document's **Overtype** mode.
These commands belong to the focused patch text. Find fields, other windows and
read-only previews retain their own editing policies.

## Pinned behavior

The source baseline is TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`:

- `ext/scintilla/src/KeyMap.cxx:114–117,140` binds word-part movement/extension
  and the Insert-key overtype toggle.
- `Document.cxx:2890–2985` supplies the word-part algorithm. ASCII lowercase,
  uppercase acronym boundaries, digits, punctuation and whitespace form parts.
  The default underscore word separator attaches to the adjacent part in the
  direction of travel. Non-ASCII scalar runs retain the source grouping; this
  is distinct from AppKit's ordinary whole-word navigation.
- `Editor.cxx:2090–2135` replaces a nonempty selection during typing, otherwise
  deletes one source character when overtyping away from a line ending.
  `InsertPaste` and `NewLine` are separate insertion paths.
- `Editor.cxx:3770–3840` collapses a rectangle to its directional outer limit
  before a nonrectangular word-part command. Other additional selections are
  reduced to the primary selection with the source's default typing policy.
  `4063–4068` toggles the editor's overtype state.

The native helper adapts the source algorithm to UTF-16 selection offsets and
native composed-character boundaries. It does not normalize Unicode. Combining
sequences, emoji and CRLF remain indivisible native caret units even where a
source byte/scalar boundary could otherwise fall inside them. ASCII classification
is deliberate: accented letters are not silently reclassified as ASCII camel-case
letters.

## Native controls

| Command | Shortcut |
| --- | --- |
| Overtype | Command-Option-O |
| Previous Word Part | Control-/ |
| Next Word Part | Control-Backslash |
| Select Previous Word Part | Control-Shift-/ |
| Select Next Word Part | Control-Shift-Backslash |

Overtype has a checked menu state and a translucent block caret. Its Mac shortcut
makes the mode accessible on keyboards without Insert. The Mac Help key and
ordinary Help routing remain available. Menu actions use the existing source
editing/navigation icons and respect the context-menu icon preference.

Movement starts from the active selection's caret. An extending command retains
its anchor; ordinary movement collapses the selection at the resulting boundary.
At document boundaries it stays within the document. Read-only previews permit
navigation and selection, but cannot enable Overtype or modify their bytes.

A word-part command on a column selection first switches to a single stream
caret at the rectangle's left/start or right/end outer limit. It does not perform
a second word-part move or retain a rectangular extension on that command. A
subsequent command performs ordinary word-part navigation.

## Typing, bytes and ownership

Overtype replaces an explicit selection exactly. With an empty caret it replaces
one complete native character, including a complete emoji or combining sequence.
At EOF or immediately before CR, LF or CRLF, it inserts without consuming the
existing line ending. A committed input string replaces one character, rather
than deleting one following character for every input scalar.

Paste, Return/newline, native marked-text composition and explicit input-method
replacement ranges keep their existing insertion/replacement paths. They do not
consume a neighboring character merely because Overtype is enabled. Ordinary
column typing continues to act on the active row; Overtype follows that primary-row
policy and produces a single stream caret.

Typing uses the existing byte-backed line transaction. Untouched source fragments
retain their exact bytes, including regional or opaque fragments. An unknown
byte projection is refused rather than regenerating the entire patch from its
display text. Each accepted overtype input is an Undo/Redo transaction; Undo
restores the previous document bytes and selection, including a previous rectangle.
Changing Overtype itself neither edits the document nor adds an Undo transaction.
Save retains the mode; replacing the document resets it to insertion mode.

Menus capture their source owner and document revision. Busy/error/modal states,
marked text, detached or retired editors and document replacement refuse stale
editing actions. Main-menu commands resolve the focused owner again, so a Find
field or unrelated window cannot alter a background patch document. Existing line,
column, gutter, Find, Save and partial-staging policies remain independent.

## Checkpoint scope

The [caret family checkpoint](qa/unified-caret-modes-2026-10-28.json) records the
actual Core/native checks, failures, repairs and cleanup for this family.
The focused Core fixture exercises source word-part cases, literal Unicode and
native boundaries, overtype selection/line-ending behavior and backing-byte
preservation. The native fixture exercises the real editor commands, input,
Undo, menu ownership and document lifetime.

This behavior description does not certify every Scintilla command, physical
keyboard layout, VoiceOver, IME implementation, visual metric, signed file grant,
hosted CI run or the complete port. Those acceptance scopes remain separate from
the recorded focused checkpoint.
