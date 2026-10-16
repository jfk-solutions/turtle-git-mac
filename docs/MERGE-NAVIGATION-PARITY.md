# Merge block navigation

The October 16 [aligned result-record continuation](MERGE-RESULT-STATES-PARITY.md)
adds logical result counts/locator coordinates and exact per-row mappings after
single-side marker resolution. Later source/result one-row choices can reuse
those mappings. Whole-group mappings remain for both-order copies and fallback
conflicts. The result now renders aligned records and uses the same row space
for active-pane navigation, source peers, context choices and locator scrolling;
both-order choices now retain aligned source/result geometry and precise maps.
Unknown mappings from serialized whole-file transforms retain fallback.

## Ordinary block choices — October 16, 2026

The source and result context menus now also apply Mine, Theirs and both source
orders to ordinary and non-conflicting changed blocks. Non-conflicting engine
groups record a mapping for each aligned row: removed Base records have an exact
zero-byte result anchor, while additions have their own payload ranges. Selecting
one addition no longer implies its neighboring addition. After a source choice,
the chosen rows retain their new result range and later rows shift by the actual
UTF-16 delta. Both text selection and independent block selection are supported.

`MergeSourceBlockEdit` follows BottomView::UseBlock/UseBothBlocks serialization:
removed/empty records are omitted, the first chosen block uses result endings,
and the appended second block retains its captured endings. Source states/colors
remain intact except that conflict states resolve. An explicit choice carries a
presentation revision, including when it changes no bytes; the modified/savepoint
state, Undo and Redo retain that revision. Result history retains the exact map,
colors, ignored-conflict metadata and choice revision together.

Each native block menu entry captures its rows, choice, result presentation,
source generation and owner identity. Later selection changes keep that target;
edits, reloads, busy/modal/Quit state and closed owners reject an obsolete action.
Unresolved marker/ignored conflicts keep their existing atomic block resolution.

This is still partial editor parity. Marker groups and groups produced by a
multi-row choice can retain a whole-group mapping; selecting only part of such
a group is disabled until a complete alignment can represent it precisely.
Arbitrary edits crossing mappings can invalidate them. The full aligned result
view (including removed/empty records), wrapped screen-row
traversal, source-state mutations after UseBothBlocks, physical input/VoiceOver,
large-file performance and signed acceptance remain open.

[Batch evidence](qa/merge-source-blocks-2026-10-16.json) records both builds,
focused Core results, the retained fixture selection repair, four passing grouped
native receivers and cleanup.

Source inspection of BaseView::CheckOtherView and IsViewGood also confirms that
inline navigation requires a visible opposite pane. Combined mode correctly
keeps it disabled; it is not a missing navigation feature.

This partial port follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, especially
`BaseView.cpp::LinesInOneChange`, `SelectNextBlock`, `SetupAllSelection`, and the
TortoiseMerge navigation accelerators. It does not certify the Merge dialogs.

Two-pane and combined comparison navigation is recorded in
[the preceding batch](qa/merge-block-navigation-2026-10-15.json). Three-pane
navigation now shares that state search: it uses the active pane, skips the
current block, searches visible source rows, excludes Normal/FilteredDiff for
differences, and searches ConflictAdded/ConflictEmpty/Conflicted/Ignored conflict
states for conflicts. It retains the entry state for directional grouping,
including asymmetric Empty padding. There is no wrap at either boundary.

The native three-pane result has marker lines and omits alignment-only rows.
The engine presentation therefore records explicit source-row/result-UTF16
relationships for common lines and changed groups. Navigation maps peer
selections through those relationships rather than assuming equal row indices or
matching repeated text. Source peers share alignment rows. Within a changed
engine group the result mapping selects that group's payload, including its
markers; it does not invent a per-line relationship inside that payload.
Unmapped peer selections are cleared instead of retaining an unrelated highlight.

Typing and a block choice retain mappings wholly containing the replaced range,
shift following groups, and invalidate groups crossed by an ambiguous edit.
Boundary insertions belong before a following group; an insertion at a zero-byte
anchor invalidates that ambiguous anchor. Undo/Redo stores the entire previous
presentation, including these mappings. Reload starts from new engine evidence.
Initial retained results that differ across groups can consequently have fewer
peer mappings; navigation within a pane still works, while unavailable source
choices remain disabled. There is no text-based guess to restore missing maps.

The native toolbar exposes Previous/Next difference and conflict. Context menus
use the original source icons. Control/Option-Up/Down and F7/F11 navigate differences;
Shift-F7/F11 reverses direction, and F8/Shift-F8 navigates conflicts. Source-pane
block choices locate the corresponding unresolved result conflict. Selecting an
unrelated common line disables those choices; it cannot resolve a stale footer
selection. Busy, preparation, export, Quit and attached-sheet gates apply to the
new navigation and choice routes. Mark as resolved also treats ignored conflicts
as unresolved, even when no literal markers are present.

The native block highlight now follows DrawBlockLine: two horizontal boundaries
retain source-state colors and remain separate from the insertion caret. Forward
navigation places the caret at the entry row; reverse navigation places it at the
bottom entry row. Native text selection stays empty. Peer highlights use the
engine mapping, and the entry row is centered where the scroll limits permit.
In two-pane Compare, Next/Previous block also advances within the entry line,
following GetNextInlineDiff's start/end order and similarity/length/display gates.
Explicit inline navigation preserves the block. Three-pane inline caret navigation
remains unavailable while the Bottom/result view is visible, matching upstream.

Copy reads the exact highlighted display block, including a neutral combined row
without accidentally copying its adjacent alias. Block-only Cut copies without
deleting; Paste and typing insert at the caret. Ordinary text selection retains
normal Copy/Cut/replace behavior. Caret moves, mouse selection, source generation
changes and edits invalidate stale block highlights in all panes.

A further source check of Undo.cpp::updateActiveView corrects the preceding
block-selection continuation: upstream Undo/Redo clears selections in all panes.
Both native editors now clear block and ordinary text selections and restore the
target caret. Compare records the pre-edit display position and source offset,
then restores after the authoritative engine publishes its new alignment. An
exact restored display uses its saved offset; otherwise it uses source coordinates.
Generation gates discard requests superseded by another edit, reload or option
change. Result history retains text/presentation provenance and target caret,
without resurrecting a block highlight.

Right-click preparation now follows OnContextMenu: it expands both directions
using the clicked row's fixed state, including Normal/Filtered groups. It preserves
an existing selection containing the clicked point. Context selection starts at
column zero and does not automatically advance inline. Copy reads that existing
block or ordinary text selection; it no longer invents a block from a bare caret.
Combined Removed and Added context blocks remain separate even when adjacent.

At that checkpoint, remaining source parity included wrapped screen-row traversal,
the complete aligned result view including removed/empty rows, and source-pane
block application beyond unresolved marker/ignored conflicts. The October 16
continuation above adds ordinary block choices; the complete alignment remains open.
A changed group can map several distinct source-state blocks to one result
payload. Missing mappings after edits require engine recomputation or a future
complete alignment model. Physical keyboard/VoiceOver, large-file performance,
signed Finder integration and App Store acceptance remain unverified.

[Grouped evidence](qa/merge-three-pane-navigation-2026-10-15.json) records the
build, 41 focused Core checks, five native receivers and cleanup, retained
workflow coverage, fixture semantics and the unresolved hosted CI state.

[Independent block-selection evidence](qa/merge-block-selection-2026-10-15.json)
records the native-only continuation, initial helper-visibility compile failure,
repaired build, four grouped native receivers and remaining history/visual limits.

[Source history/context continuation](qa/merge-editor-history-2026-10-15.json)
records the correction to upstream Undo semantics, automatic two-pane inline
advance, context preparation/focus and exact target-caret checks. The following continuation adds explicit user-input revocation and initial
source-block selection. This remains a partial editor port.

Initial Compare navigation now waits for the authoritative alignment and current
text/geometry in all required panes. It searches Mine (or combined Base/Mine)
states with skip-current disabled, matching MainFrm/GoToFirstDifference. It selects
peer blocks, applies the same inline entry advance and centers the caret. Neutral
combined rows can be the first block even when the engine's first changed region
is later. The initial preference remains optional. Transfers/marks use explicit
block or ordinary text-selection rows, without an engine-index fallback.

Mouse/key input, context selection, navigation, Find and Go to Line revoke pending
initial/Undo caret writers. A line chooser captures an input revision as well as
text/window identity; a later input action or document generation invalidates its
answer even if the text is byte-identical. Rendering and automatic entry advance
do not revoke their own requests. Closing, busy/filter, preparation and sheet
checks still gate navigation. Initial selection consumes after layout, avoiding
publication from representable updates.

Remaining acceptance includes physical input, selected-text direction/affinity,
wrapped-screen-row behavior, complete result alignment,
large-file performance and signed installed behavior.

[Initial navigation and input ownership evidence](qa/merge-initial-navigation-2026-10-16.json)
records actual initial/neutral blocks, explicit transfer refusal, input during
Undo realignment, same-text stale/fresh line chooser responses, the fixture
configuration race and repaired grouped native checks.

Three-pane source views are read-only in the pinned MainFrm::LoadViews; only
Bottom/result is writable. Two-pane Base/Mine editing is separate and now retains
Edited records through input, history and Save; see [in-place editing](MERGE-ONE-PANE-PARITY.md).

Aligned row-model evidence: [October 16 grouped verification](qa/merge-aligned-rows-2026-10-16.json).

Native aligned editor evidence: [October 16 grouped verification](qa/merge-aligned-editor-2026-10-16.json).

Both-order source choices now also retain source layout revisions and perform
all-pane gap insertion/state changes, resolved-empty handling and cleanup. Explicit
partial conflict selections resolve only their selected rows. Captured commands
are invalid after any intervening source layout edit or Undo, even when file text
returns to the same bytes.

All-pane block-choice evidence: [October 16 grouped verification](qa/merge-both-blocks-2026-10-16.json).

Aligned result-format evidence: [October 16 grouped verification](qa/merge-result-format-2026-10-16.json).


## Wrapped screen-fragment entry — October 16, 2026

The connected [wrapping continuation](MERGE-WRAPPING-PARITY.md#wrapped-navigation-and-viewport-reflow--october-16-2026)
adds native reverse/forward/context fragment entry and coordinated peer centering,
alongside source-row reading anchors during resize/font/wrap changes. Earlier
wrapped-row gaps above are superseded within that scope. The logical source
state search, hidden-row projection, independent block range and two-pane inline
entry advance remain in place. Exact virtual-padding caret geometry and full
Windows/TextKit equivalence remain open.


The [moved-block continuation](MERGE-MOVED-BLOCKS-PARITY.md) adds source detection,
original margin icons, double-click and native context navigation, two/combined
peer selection and editing/history ownership. Its source oracle and grouped native
evidence are separate from ordinary difference/conflict navigation above.


[Margin selection](MERGE-MARGINS-PARITY.md#margin-selection-and-capture--october-16-2026)
adds native gutter text/peer-row selection, fixed Shift/drag origins, wrapped
fragment entry, folded marker expansion and owned autoscroll/retirement.
