# Merge resolved and edited presentation

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
