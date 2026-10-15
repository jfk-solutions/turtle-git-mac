# Merge block navigation

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
use the original source icons. Control-Up/Down and F7/F11 navigate differences;
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
Explicit inline navigation in Compare preserves the block while moving its caret.

Copy reads the exact highlighted display block, including a neutral combined row
without accidentally copying its adjacent alias. Block-only Cut copies without
deleting; Paste and typing insert at the caret. Ordinary text selection retains
normal Copy/Cut/replace behavior. Caret moves, mouse selection, source generation
changes and edits invalidate stale block highlights in all panes. Merge result
Undo/Redo restores the independent block and caret alongside its presentation.
Compare text Undo remains supported but does not restore its retired block.

Remaining source parity includes wrapped screen-row traversal, automatic inline
advancement, Compare block-selection history, the complete aligned result view
including removed/empty rows, and
editable source-pane block application beyond unresolved marker/ignored conflicts.
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
