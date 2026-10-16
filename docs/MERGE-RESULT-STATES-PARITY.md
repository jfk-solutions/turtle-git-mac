# Merge resolved and edited presentation

## Aligned formatting and operation ownership — October 16, 2026

Result line-ending and whitespace commands now transform view records rather than
replace the serialized result as one string. They skip Empty/ConflictEmpty gaps,
retain row states and logical numbers, and can update the display-only removed
Base records. Existing unended final lines remain unended. Unresolved marker
blocks and their original source payloads are retained independently of result
record formatting. Formatting an ignored-conflict Mine payload updates its range
and Mine metadata without silently resolving that conflict. Native command
availability and the result format ribbon inspect view payloads, not synthetic
display LFs or hidden marker text.

The output line-ending choice is retained separately from serialized marker
endings and controls subsequent typing/paste and source block normalization.
Encoding-only and combined Encoding/EOL choices use one history transaction;
Undo/Redo restores text, all-pane layout/provenance, encoding and output ending.
The combined choice validates the selected encoding before applying any change.
Whitespace/direct ending commands leave encoding validation to Save, so a legacy
Mine file with Unicode in Theirs remains editable without accepting lossy output.
Save records the selected format baseline, and Undo across that savepoint makes
the earlier format dirty again.

The native format sheet is owned by its document, participates in active-operation
Quit accounting, and blocks concurrent Save, reload, block choices and editing.
Cancel leaves state/history intact. Duplicate requests and responses for a retired
owner cannot apply. Forced owner closure ends its own format sheet and releases
accounting. Keyboard/model Undo, typing and clipboard writes read model operation
gates immediately, including before a deferred isEditable refresh during Save.

These built-in formatting commands retain aligned editing after either source
order. Arbitrary external serialized-result replacement can still invalidate
precise row mapping; it retains the existing serialized fallback. Complete IME,
large-file, physical visual parity and signed acceptance remain open.

## All-pane block choices and empty records — October 16, 2026

Mine/Theirs and both ordering choices now operate on aligned view records. The
both-order commands replace the selected source rows with two complementary
blocks: the first source occupies the first block opposite new gaps, and the
second source occupies the second block opposite gaps. Original source payloads
and numbered coordinates remain available in their respective source views.
As in BottomView::UseBothBlocks, occupied first/second source rows acquire
YoursAdded/TheirsAdded states (including the upstream asymmetry when Theirs is
first). The first result copy normalizes endings, while the second preserves its
source endings. The source's final-no-ending join behavior is retained.

The result stays aligned after copying both sources, and each row has a precise
result range for later choices and typing. Footer conflict choices select actual
conflicted result slots, excluding preceding removed Base records. Explicit
source/result text selections can resolve one slot within an unresolved group;
neighboring slots keep their source payloads and unresolved state. Whole-source
choices use the current source layout, including gaps introduced by earlier
both-order commands.

ConflictEmpty resolves to a distinct resolved-empty record, rendered with the
resolved palette and no line number. It is omitted from saved bytes and no longer
counts as unresolved. It deliberately does not satisfy BaseView::IsStateEmpty.
Cleanup removes a record only if Mine, Theirs and result are all Empty or
ConflictEmpty, preserving resolved-empty records, real empty text lines, removed
records and rows with a real source peer. Typing, source choices and their Undo
snapshots use the same cleanup/serialization path.

Source views carry a layout revision. Menus and navigation refuse stale geometry
until the current source rows reach the native view, and captured source commands
cannot revive after an edit/Undo returns to identical file text. Undo/Redo restores
all source states, gaps, result records, byte provenance and logical numbers.
Unknown mappings after arbitrary serialized whole-file transforms still use the
existing serialized editor fallback. Such transforms, complete IME behavior and
large-file acceptance remain open; this is not full dialog certification.

## Native aligned result editor — October 16, 2026

The result pane now renders aligned result records with removed Base text,
blank conflict slots, state colors and logical line numbers. Conflict markers
remain in the serializable result, not the displayed rows. Result and source
panes share wrapping heights and synchronized scrolling. Navigation, context
choices, Go to Line, clipboard, Find, locator and folding use view coordinates;
raw-file ranges are converted only at the model boundary. Edited common rows
stay visible in all three panes when unchanged sections are collapsed.

Typing in a removed record makes its displayed content an Edited result line.
Typing in one blank conflict slot resolves only that slot; remaining slots stay
unresolved and serialize their corresponding Mine/Theirs payloads. An unchanged
conflict keeps its original marker bytes. After a partial manual resolution,
remaining conflict runs use two-way markers, following BaseView::SaveFile's
Mine/Theirs serialization. Untouched removed records and source gaps are never
written as result bytes. Ignored conflicts retain their separate metadata until
the corresponding row is edited or resolved.

Multiline typing and paste add matching gap records to both source views.
Deletions preserve the read-only source coordinates and gap the unused result
rows. Immutable Undo/Redo snapshots include result provenance and all three pane
layouts. Format transforms operate on serialized file contents, and Find replaces
actual displayed matches through record edits. Display-only final line breaks do
not become extra saved file content.

The grouped receiver exercises actual native conflict-slot/removed-row typing,
multiline source gaps, per-row alternatives, locator clicks, marker-free display,
Save bytes, unchanged inputs and Undo/Redo. Core checks cover CRLF/UTF-16 offsets,
empty documents and final empty edited records. The subsequent all-pane block batch above retains both-order alignment,
resolved-empty aliases and all-pane cleanup. Arbitrary serialized whole-file
transforms still use the existing fallback; IME and complete large-file
acceptance remain open. No complete upstream dialog parity is claimed.

## Aligned result records and precise resolution — October 16, 2026

The Subversion presentation now retains the pinned DiffData result records in
source-row order. Removed Base records retain their payload, removal state and
absent result number. Common/added records carry logical result numbers; each
conflicted source slot has a blank Conflicted result record rather than becoming
the several serialized marker lines. Ignored conflicts retain their plain Mine
payload and separate unresolved state. These records are distinct from saved
file text and the existing editable marker-text view.

A checked projection combines those initial records with the current result
mapping and provenance. Result statistics and the middle locator column use it
when every source and serialized position is accounted for. Search/marked locator
rows and locator clicks convert between serialized and aligned coordinates.
Unknown mappings or expanded multi-copy/multi-line groups retain the existing
serialized-view fallback; no correspondence is fabricated. The cache invalidates
when source comparison or result presentation changes.

Single-side block resolutions now retain a separate result range for each
source row, including zero-byte removed/empty records. Footer, source and result
context choices use that path for ordinary complete marker groups. Selecting one
line afterward can take its opposite source without replacing neighboring lines;
Undo/Redo retains each precise map. Both ordering choices retain a whole-group map
until their duplicated source-row geometry is implemented. Ignored and unusual
leading-separator conflicts keep their existing atomic resolution path.

This earlier phase supplied the row model and coordinates used by the native
aligned editor above. Resolved-empty aliases, multi-copy source mutations and
complete wrapped/large-file acceptance remain open.
No full aligned-window, dialog or application certification is claimed.

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
`BaseView` resolved-state conversion/editing and `SetColorPage::SaveData`.

The General/Colors controls were already implemented. This batch connects their
remaining resolved/modified channels to actual editing behavior. Picking a conflict
block or whole side creates resolved presentation. Manual text edits use Modified
background and Added foreground, matching Edited's channel assignment in upstream
SaveData. Actual conflict marker ranges continue to override these colors.

Result provenance uses UTF-16 runs separate from file contents. Several disjoint
edits retain unchanged middle regions and previous resolved choices rather than
painting everything between the first/last change as added. Emoji and line-ending
changes retain the authoritative String. The result pane, locator and modified-only
Find consume the same projected states. Two-pane manual editing uses its existing
edited annotations for display/locator colors without changing alignment rows.

Block and ordinary native typing Undo/Redo retain presentation snapshots along
with text. Saving retains editing presentation while writing exact encoded bytes;
reload regenerates engine states and resets history. Palette/theme changes repaint
existing runs without changing text, dirty state or Undo. Format/ending edits use
Edited; explicit whole-side choice uses Resolved. No color metadata is written into
source files or the index.

Source state aliases beyond the current native normal/removed/added/conflicted/
resolved/edited/empty/filtered catalogue remain incomplete. Empty resolved display
gaps, full multi-pane source alias painting, physical/VoiceOver and signed/minimum-OS
acceptance remain open. These changes do not certify every Merge dialog/state or
the whole application. The Debug build and 23 relevant Core cases passed after exposing the immutable
display-cell initializer. The native receiver first required a corrected two-pane
wait property, then exposed Undo grouping that combined choice and typing. Native
typing now follows the complete edit path with explicit command groups. Core was
not repeated for those native-only repairs. The final two-case native group passed
result/history/colors and clipboard regression checks with all owned processes
reaped. No duplicate Git-engine run was needed for standalone file-state checks.
See [batch evidence](qa/merge-result-colors-2026-10-14.json).


## Source state aliases and pane statistics — October 15, 2026

The authoritative three-pane presentation now retains IdenticalRemoved/Added,
YoursRemoved/Added, TheirsRemoved/Added and ConflictAdded/Empty identities instead
of collapsing all source rows into Removed/Added/Conflicted. Common changes use
identical aliases; single-side changes retain the changed side. The source's
Mine-only source-row IdenticalAdded convention is retained, while the result
records YoursAdded. Conflict Base padding is IdenticalRemoved; real source lines
are ConflictAdded and shorter-side gaps are ConflictEmpty. The unresolved result
continues to use Conflicted and its exact marker text.

These states propagate into locator stripes, result presentation/history,
modified-only Find and source inline colors. Removal aliases keep removal inline
painting. Empty conflict gaps do not request character comparisons. Clipboard
keeps the upstream distinction between Empty rows and conflict gaps. Source Save
As suppresses removal aliases and conflict gaps unless Save Removed Lines is
requested; ConflictAdded exports actual source contents without inventing the
unresolved-result marker serialization. Original encodings and endings survive.

Two-pane, combined and three-pane footers now show nonzero Removed, Added and
Conflicted line counts using the source status categories. ConflictAdded counts
as added, not as an unresolved result line; Empty/ConflictEmpty gaps, filtered
and edited states do not count. IdenticalRemoved Base padding retains the source
removal count. Text stays in the system foreground with small palette
swatches for readable light/dark presentation.

The existing Colors page groups all side/identical aliases with Added/Removed
without adding unsupported swatches. ConflictAdded uses Conflict channels.
ConflictEmpty follows the source cold default and Colors Apply distinction:
initially the Conflict background, then the Empty background with Conflict
foreground once a Colors palette has been saved. The in-memory palette snapshot
retains that state; no preferences are decoded during per-row drawing.

[Batch evidence](qa/merge-source-states-2026-10-15.json) records actual engine
projections, source export bytes, native attributed source painting in light/dark,
locator/Find and existing history/inline regressions separately from physical
status-bar layout, VoiceOver and signed acceptance. Whitespace-only, ignored
conflict and resolved-empty state production, complete source editing and full
Merge/application parity remain open.

## Ignored conflicts from comparison options — October 15, 2026

The source `DiffData.cpp` post-pass checks Normal/IdenticalAdded rows after the
comparison engine has ignored whitespace, case, endings, comments or a regex
filter. Three distinct original payloads, or three distinct original endings,
produce `Conflicted_Ignored` even though the comparison keys match. The native
projection now retains that identity, marks both source rows ConflictAdded and
leaves the original Mine bytes in the result without inserting marker lines.
Single-sided changes, equal Mine/Theirs values, or differences spread across
payload/ending channels do not invent such a conflict. The source's bounds rule
for the Base index after an IdenticalAdded block is retained, including its
one-past-EOF exclusion.

The editor shows **Ignored conflict** and includes it in normal conflict
navigation, source/result colors, locator, line counts and modified-only Find.
Mine/Theirs and combined-side choices act on original captured text, including
Unicode, mixed endings and absent final endings. Adjacent ignored rows form a
single navigable block, ordered together with ordinary marker conflicts.

Result presentation stores unresolved ignored ranges separately from file text.
Edits outside them remap their UTF-16 positions; editing an affected line resolves
that line's metadata. Explicit choices clear the affected range even when Mine
replaces it with identical bytes. Existing native Undo/Redo snapshots restore
both content and unresolved metadata. As in BottomView::UseBlock/SetModified,
a same-byte choice still marks the result modified until Save; Undo back to the
initial unresolved metadata restores clean state. Close/Quit therefore keep the
existing Save prompt even when resolution did not change any bytes. No color
or resolution metadata is serialized into files or the index. Reload reconstructs
it from source comparison and remaps into a retained result snapshot.

Save warns while ignored conflicts remain; its warning participates in the
existing operation/Quit guard. Mark as resolved is unavailable until all conflicts
are resolved. The Core save route also requires an explicit acknowledgement for
a document with ignored conflicts before staging; choosing comparison options
alone cannot silently stage Mine. Source Save As retains captured original source
bytes; result Save As includes the unresolved-conflict warning.

[Grouped evidence](qa/merge-ignored-2026-10-15.json) records the source conditions,
actual engine plans, byte/range/history behavior, native paint and Git staging
checks. The older statement that ignored-conflict production was missing is
superseded by this batch. Whitespace-state aliases, resolved-empty gap production,
complete physical/VoiceOver/theme geometry and signed Finder/App Store acceptance
remain open. This is not complete Merge/application certification.

The connected [one-pane whitespace continuation](MERGE-ONE-PANE-PARITY.md#source-whitespace-aliases-and-visibility--october-15-2026) now produces neutral RemovedWhitespace/AddedWhitespace rows, separate source hide flags and original Mine coordinate mappings. Resolved-empty gaps and the remaining whitespace aliases remain open.

[Three-pane navigation](MERGE-NAVIGATION-PARITY.md) uses those result states and
engine source/result mappings, retaining the mappings through block choices and
Undo/Redo. This remains a partial port of the fully aligned upstream result view.

Aligned row-model evidence: [October 16 grouped verification](qa/merge-aligned-rows-2026-10-16.json).

Native aligned editor evidence: [October 16 grouped verification](qa/merge-aligned-editor-2026-10-16.json).

All-pane block-choice evidence: [October 16 grouped verification](qa/merge-both-blocks-2026-10-16.json).

Aligned result-format evidence: [October 16 grouped verification](qa/merge-result-format-2026-10-16.json).
