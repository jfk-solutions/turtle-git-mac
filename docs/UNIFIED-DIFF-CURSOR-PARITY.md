# Unified Diff character and display-line cursor movement

Pinned baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
Source anchors: Scintilla `KeyMap.cxx:89–115`,
`Editor.cxx:3382–3481,3646–3663,3716–3740,3763–3867`.

## Connected input and menus

The patch text responder owns all eight plain/Shift arrow commands. Left/Right
move in logical text order; Up/Down move by actual displayed fragments. Native
moveBackward/moveForward and movement-with-selection selectors use the same
handlers. Edit → Cursor and the text context menu expose the commands with
source navigation artwork. Word, boundary, page and rectangle shortcuts retain
their separate source policies.

Ordinary Left/Right collapse a nonempty primary stream selection at the
respective directional edge without an extra character step. Shift extends
from its directional caret and retains its anchor. Extra stream ranges are
dropped, following the default additional-selection typing policy. On a
rectangle, both plain and Shift horizontal arrows first switch to a single
stream caret at the whole rectangle's directional outer limit. This first
press does not move beyond that limit.

Up/Down use the main range's caret and drop additional ranges and rectangle
mode, as the ordinary stream branch of CursorUpOrDown does. Shift retains that
main range's anchor. The desired rendered X is shared with page movement and
caret-aware line scrolling; a short destination row clamps its caret without
forgetting the intended column. Horizontal movement installs its new insertion
X. Direct selection/input, document replacement and font/container changes
invalidate that remembered geometry. Wrapped boundary insertion ambiguity is
backtracked using actual display-row positions. Moving beyond the first/last
display row reaches document start/end.

## Native text and ownership

Logical character stepping preserves native composed characters, surrogate
pairs and CRLF. Grapheme safety is an explicit macOS adaptation: this does not
claim that every source byte/code-point boundary can be a native caret stop.
Bidirectional text is stepped in logical buffer order rather than delegating
to AppKit's visual left/right selection policies. These commands never rewrite
source bytes, create Undo records or change the index/worktree.

Read-only previews support movement. The current focused attached source,
selection and owner/reset receipts fence menu actions; changing a selection
cannot repurpose a retained action. Busy/error, sheets/modal, Quit and retired
owners refuse dispatch. Marked-text key input and responder selectors remain
with the native composition handler. Escape is unchanged: the UDiff accelerator
hides Find or closes the window, while an active rectangle drag consumes Escape
to restore its original selection.

## Validation and remaining acceptance

The [grouped checkpoint](qa/unified-cursor-2026-10-29.json) records five focused
Core methods passing cumulatively, both successful Debug app builds and four
first-attempt native engine/family passes: cursor plus affected navigation with
system and bundled Git. Actual keys, responder aliases and icon menus,
stream/rectangle direction, wrapped fragments, shared desired X and native
ownership passed. Exact bytes, Undo, HEAD, index and working files were retained.
All four receivers were reaped and independently confirmed absent; their private
windows, workers and pasteboards were closed or released.

The initial Core run had three assertions fail in two methods: NSString's
composed-character API split CRLF. Explicit CRLF stepping repaired the actual
implementation; only those two methods were repeated, retaining their original
assertions. The incremental app build embeds the corrected Core framework before
native checks. The other three Core methods were not repeated, and native checks
required no fixture or product repair. Review also preserved the source EOF
exception in downward wrap correction before the first checkpoint.

Physical keyboard/IME/VoiceOver acceptance, bidirectional visual rendering,
wrapped equivalence beyond measured TextKit fragments, current signed execution
and complete UDiff/full-port parity remain separate. Installed build33 predates
this family.
