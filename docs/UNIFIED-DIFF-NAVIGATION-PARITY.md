# Unified Diff word, boundary and page navigation

Pinned baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
Source anchors: Scintilla `KeyMap.cxx:105–143`, `Document.cxx:568–579,2113–2150`,
`Editor.cxx:317–322,871–902,3149–3187,3660–3840,4017–4064`.

## Native commands

Edit → Navigation and the text context menu contain three compact submenus:
Words, Lines and Document, and Pages. All eighteen commands use the existing
source editing icons and focused patch owner. Commands are available in read-only
previews; Find fields and unrelated windows retain their own input routes.

| Movement | Mac shortcut | Selection extension |
| --- | --- | --- |
| Previous / Next Word | Option-Left / Right | Add Shift |
| Smart Line Start / Line End | Command-Left / Right, or Home / End | Add Shift |
| Document Start / End | Command-Up / Down, or Control-Home / End | Add Shift |
| Display Line Start / End | Option-Home / End | Source active bindings have no display extension |
| Previous / Next Page | Page Up / Page Down | Add Shift |

Native word, line, document and page responder selectors use these same handlers.
Command-Home/End also accepts the document route. Existing column-selection
shortcuts keep their separate rectangle-extension policy. Menu actions retain
exact selection and document owner/reset receipts; changing the selection or
replacing a document cannot repurpose a retained action. Marked text, busy/error
states, modal/sheets, Quit and retirement fence both menu and keyboard dispatch.

## Logical and displayed boundaries

Words use the pinned Scintilla classification shared with word deletion, including
underscore, punctuation, Unicode marks, spaces and newline classes. The new
shared helper walks only the traversed UTF-16/scalar context rather than building
a scalar-position array for the complete document on each key press.

Smart Home skips only ASCII spaces/tabs, toggling to the exact logical line start
when already at the first non-indentation point. It may move forward out of
indentation. CR, LF and CRLF are logical endings; Unicode separator characters
remain ordinary logical source text. Native composed characters and CRLF are
indivisible caret positions. A rounded composed-indentation point participates in
the same two-press toggle rather than becoming a stuck endpoint.

Display endpoints use actual TextKit glyph fragments and exclude logical line
ending bytes. Document endpoints are zero and the original UTF-16 text length.
Page movement uses actual insertion-point geometry and a step of
max(1, visible display lines − 1). With an initially visible caret, caret and viewport move by the same display-line
step, clamped to native bounds. If the user has manually scrolled the old caret
out of view, the new target is brought into view, following source MovePositionTo
with ensureVisible. Layout-manager line-fragment insertion positions remain
available offscreen and retain exact EOF advances and ligature positions; the
viewport-dependent text-input firstRect is not used for navigation. Desired horizontal position survives page-induced
short-line clamping and shares the existing line-scroll state. A user caret/text
change, replacement owner, font or text-container geometry invalidates it.

## Selection and bytes

Ordinary word and logical/display boundary movement follows source HorizontalMove.
On a rectangle it first switches to a stream at the directional outer limit;
ordinary Smart Home/Line End additionally applies that logical boundary there.
An extending horizontal command on a rectangle still only collapses on that
press. On stream selections, movement starts at the primary caret and extension
retains its anchor; additional rows follow the source default single-selection
policy.

Document and page commands instead follow MovePositionTo. Extension from a
rectangle drops extra rows and preserves the main row's anchor. Ordinary movement
collapses at its new target. No document edit, byte regeneration or Undo/Redo
transaction is performed. Navigation from empty documents and at EOF retains
native-safe bounds.

## Validation and remaining work

The [grouped checkpoint](qa/unified-navigation-2026-10-29.json) records 20 focused
Core methods with zero failures, both successful Debug builds and four final
native case/engine passes: navigation plus the affected block/line-scroll family,
each with system and bundled Git. It covers actual keys and nested icon menus,
source selection transitions, wrapped/unwrapped page geometry, manually hidden
carets, EOF shared-column recovery and owned admission. Bytes, Undo/Redo, HEAD,
index and working files stayed unchanged. All ten receivers across the failed
and successful attempts were reaped and independently confirmed absent.

The record retains fixture corrections and the real geometry defect. The word
fixture first skipped the separate newline class. The EOF failure exposed a
visibility-dependent firstRect request after scrolling; insertion-point layout
and pre-scroll capture repair that route, including manually offscreen page
admission. A wrapped rectangle was expected to retain its unnormalized visual
caret; source SetRectangularRange iterates logical rows and SPositionFromLineX
uses subline0, so the fixture now asserts that first-subline main caret before
checking the exact page target. No underlying assertion was removed. One redundant
diagnostic retry added no evidence and is explicitly recorded.

Only affected native checks and the incremental app build were repeated. Core
and the unchanged pinned case/class table oracle were not repeated for native
or fixture repairs. Physical keyboard layouts, VoiceOver/IME, signed installed
execution, folding not represented by this editor, and full UDiff visual/behavioral
parity remain separate. Wrapped adapter checks add no Wrap preference. Installed
build32 predates this family.
