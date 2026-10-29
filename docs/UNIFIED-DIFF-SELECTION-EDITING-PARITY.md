# Unified Diff selection transformations and boundary deletion

Source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`, pinned
Scintilla `Editor.cxx:3191–3232,3863–3932`, `Document.cxx:2012–2150`,
`Selection.cxx:481–487,515–516`, `KeyMap.cxx:139–154,174–177` and
`win32/ScintillaWin.cxx:2948–2973`.

## Case conversion

Lowercase/Uppercase Selection transforms every nonempty selected range, including
multiple and rectangular ranges. Empty selections are no-ops, rather than an
instruction to select and transform the current word. Direction, primary range
identity and changed UTF-16 lengths are retained. Case expansion can make a
rectangle's accepted row ranges uneven: ß / X becomes SS / X, with a two-character
first row and one-character second row. Native layout must not recreate a wider
rectangle and accidentally include additional text. Source row state, including
this explicit geometry, survives Undo and Redo.

Generated tables retain the pinned Scintilla scalar mappings and Unicode category
data, with verified Git blob identities. They do not use host locale, the host
Unicode version or search case folding. Lowercase Σ becomes σ independently of
context; ß uppercases to SS, İ lowercases to i plus combining dot, and a decomposed
accent stays decomposed. Only changed scalars become inserted byte-buffer
fragments. Unchanged source, including opaque or original legacy fragments inside
selected ranges, retains its original byte provenance.

The native editor applies these source UTF-8 rules to its decoded display and
retains its existing document-codec Save policy. This does not reproduce Windows'
machine-dependent non-UTF8 `LCMapString` linguistic-casing branch. Unrepresentable
changed text retains the existing explicit encoding/Save failure and Undo policy;
it is not permission to replace bytes silently.

## Word and line boundaries

Delete to Previous/Next Word uses the pinned `NextWordStart` rules and character
classes, including punctuation, underscore, Unicode marks, whitespace and newline
classes. Native composed characters and CRLF remain indivisible. Delete to Line
Start/End uses logical CR/LF/CRLF boundaries; it does not join lines at an existing
line boundary. Both word and line commands start from the main caret, ignoring
the selected range as a deletion target. Left deletion moves the existing anchor
through the removed interval. Right deletion first collapses the range at the
caret, matching the source's virtual-space realization branch.

Additional rows are dropped by deletion under the source default typing policy.
Its residual rectangle mode and tracked corner positions remain, with one actual
row. An explicit-row receipt keeps the native adapter from rebuilding the dropped
rows. Case conversion retains all currently accepted rows, including that residual
one-row state. Native virtual-space padding retains the existing bounded policy;
this batch does not introduce arbitrary virtual carets beyond line ends.

## Native access and ownership

Edit → Selection Editing and the text context menu expose all six operations
with existing source editing icons. Case shortcuts are Command-Option-U and
Command-Option-Shift-U, following the existing Mac shortcut adaptation policy.
Option-Backspace/Forward Delete invokes word deletion; Command-Backspace/Forward
Delete invokes logical line deletion. Native lowercase/uppercase and word/line
deletion responder selectors share the same implementation. The Control-U case
binding is not installed over the macOS text binding.

Captured context-menu commands retain source owner, document/reset revision and
exact selection receipts. A changed selection, replaced document, marked-text
composition, modal/sheet, busy operation, error, Quit or retired editor cannot
repurpose the command. Shared menus follow the focused patch window and editing
availability. Read-only previews refuse all six edits. Byte-buffer snapshots,
source segments and full selection shape participate in the existing single
native Undo/Redo transaction and document Save/recovery flow.

## Validation and remaining work

The [grouped checkpoint](qa/unified-selection-edit-2026-10-29.json) records the
full-scalar pinned C++ oracle passing and 37 distinct Core methods cumulatively
passing across focused repairs. It does not claim a single full rerun of those
37 methods. The first full Debug build and the incremental build after the
linear-assembly repair passed. After the codec repair, only the affected current
Core framework was rebuilt; native receivers load that framework and existing
unchanged app objects. The Debug app bundle was not re-embedded at that step.

Both system and bundled Git native workflows pass real keys/menus, case expansion,
reverse/multiple/uneven rectangle ranges, primary-caret deletion, exact Unicode,
regional and opaque bytes, Undo/Redo, Save and admission/retirement guards. All
five receivers across failed and successful attempts were reaped and independently
confirmed absent. The original byte and normalization assertions remain intact.

Actual failure records distinguish the source codec bug from fixture errors.
A codec test initially referenced a private property and was repaired to use an
independent platform-codec oracle. One BOM test assumed ambiguous FF FE 00 00
could identify UTF16LE plus NUL; it now retains longest-signature detection and
asserts exact unchanged bytes. A native extra selection used an offset inside
CRLF; it now uses the actual literal word bounds. Only affected checks were rerun.

## Combining-character codec repair

Native case conversion exposed a shared round-trip bug: codec decoding prepended
an ASCII sentinel, then inspected and removed a whole Character. A leading
combining mark joined that sentinel into one grapheme and was incorrectly refused.
Both the shared codec and automatic BOM document-load branch now remove exactly
one Unicode scalar. Leading marks, variation sequences and literal FEFF are not
normalized or discarded. Exact-byte Core coverage includes all Unicode output
formats, all five automatically detected BOM forms, regional representability,
NUL policy and the actual case-plan-to-buffer path. Compare/Merge's existing NUL
refusal and unrepresentable Save behavior remain unchanged.

Physical keyboard layouts, IME/VoiceOver, receiving applications, current signed
installation and complete UDiff parity remain separate. Installed build32 predates
this family; later consolidation must embed the repaired framework.
