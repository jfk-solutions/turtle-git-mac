# Combined one-pane comparison

Source baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
`DiffData.cpp::m_YourBaseBoth`, `MainFrm.cpp::LoadViews/OnViewOnewaydiff`,
`BaseView.cpp::SaveFile` and `SetMainPage.cpp::OnePane`.

The two-file viewer now offers **Two-pane view**; uncheck it for the combined
Base–Mine view. **Use one-pane view as default for 2-file diff** is exposed in
Merge Editor General settings and saved under the source-equivalent OnePane
preference. A combined region shows all removed Base lines before all added
Mine lines, followed by common lines. Alignment gaps are omitted. Whitespace
ignored by the comparison collapses to Mine; filtered non-whitespace payload
differences retain removed/added lines. Original bytes/endings and source row
IDs stay separate from the synthetic display LF. The whitespace continuation
below supersedes the earlier generalization about all ignored whitespace collapsing.

The combined view edits Mine. Untouched removed rows stay display-only. Editing
a removed row retains its unselected payload in the result, corresponding to
upstream's Edited state, while other removed rows remain excluded. Typing,
selection replacement, Find/Replace All, tab/indent operations, Undo/Redo and
Save use destination coordinates. Saving retains the chosen Mine encoding/BOM
and original line endings and does not write Base. Copy includes selected
removed rows. Source-row mappings continue to drive block actions and marks.

The line-diff bar is suppressed in one-pane mode, and the locator uses the
combined state's single column. Difference navigation targets the combined
removal first. Inline highlights follow the source's adjacent Removed/Added
pair rule, font/word options and inline length bound. Source line numbers for
removed rows are absent. Format controls and Save As target Mine.

Switching modes prompts Save/Don’t Save/Cancel when drafts are dirty. Successful
switches reread the saved files and reset history; Cancel preserves mode/drafts.
The preference changes only after the switch is accepted. Single-file and
three-pane viewers do not use this combined workflow. Create patch file is
disabled while the combined view is active, matching upstream's two-valid-view
command gate. Retirement and attached-sheet/busy states fence mode changes.

Remaining: the Mac editor recomputes Subversion alignment after typing; upstream
retains its in-place Edited row presentation until reload. Full moved/filtered
state aliases, exact full context-menu contents/physical acceptance, source whitespace line
number variants, physical switch/Save prompts, clipboard/Find/indent acceptance,
light/dark whole-window screenshots, large-file and signed/minimum-OS acceptance
remain open. This batch does not certify complete TortoiseMerge parity.


## Batch evidence

Four focused Core tests passed; the changed range-validation case passed again
after guarding invalid multi-ranges before computing their ends. Unsigned Debug
builds passed. The first native run exposed late preference injection; window
construction now accepts preferences before it loads. The focused retry exposed
a shared render path still using two-pane cells; it now uses the combined
projection. The final grouped run passed all thirteen Merge families, including
native combined Replace All/Tab and Save/Cancel/Discard mode switches. See
[the batch record](qa/merge-one-pane-2026-10-12.json).
Test-owned processes/windows/helpers and the verified failed-startup fixture
were cleaned up. No installed app, user repository or clipboard was used.


The context audit now identifies the source combined pane as the left view,
disables hidden-opposite transfer commands and removes right-only mark actions.
Clipboard menu targets capture their pasteboard and support actual combined
Copy/Cut/Paste/Undo without affecting a newer menu. See
[one-pane context parity](MERGE-ONE-PANE-CONTEXT-PARITY.md).


## Source whitespace aliases and visibility — October 15, 2026

`DiffData::DoTwoWayDiff` now supplies the common-row policy in both native modes.
Two-pane whitespace/EOL-only common rows use Normal, while payloads made common
by case/comment/regex filters use FilteredDiff and stay visible when folding.
A separate hide flag preserves the distinction between folding and modified-only
Find; neither comparison keys nor displayed line numbers supply edited bytes.

The combined common-row branch follows the pinned CompareWithIgnoreWS rule:
Compare whitespaces retains different payloads as RemovedWhitespace/AddedWhitespace;
Ignore whitespace changes collapses only a leading-space/tab-only difference and
otherwise retains a hidden pair; Ignore all whitespace changes keeps only Mine
for common rows, including those made common by another filter. Neutral pairs
retain Mine's displayed line number on both rows. They remain searchable by
modified-only Find but do not increment Added/Removed counts. Their source color
channels keep the neutral defaults independently of the Normal swatches. Hidden
legacy per-alias color overrides are not exposed by the native Colors page.

Explicit Save As/export follows BaseView::SaveFile: neutral RemovedWhitespace
payloads are retained, while ordinary Removed rows are omitted. Both neutral
versions therefore appear in the exported contents, using the selected Mine
encoding and captured endings; no display LF is substituted. Native editing
uses those retained neutral payloads, with the existing grouped Undo/Redo and
working-file freshness checks. No viewing or export action rewrites the inputs.

Displayed duplicate line numbers no longer add a line to the original Mine
coordinate space. Selection restoration across mode/filter changes uses the
original Mine coordinates; combined editing/export owns its separate serialized
payload. This prevents a neutral Base row from shifting a later working-file
selection. Existing caret-driven expansion of folded rows is retained.

[Grouped evidence](qa/merge-whitespace-states-2026-10-15.json) records source
conditions, actual engine plans, palette/folding/Find and byte mappings, native
mode changes and editing/export/Save/Undo. The two-pane and combined editors now
search active-pane source states on the visible folding projection. Neutral
RemovedWhitespace and AddedWhitespace are separate navigable blocks; Normal and
FilteredDiff are skipped. Forward Added/Removed accepts Empty padding, while
backward Empty accepts Added/Removed, using the entry state throughout as upstream
LinesInOneChange does. Navigation selects the whole block in both panes, retains
the backward entry caret, and stops at boundaries. Toolbar, context commands and
Control-Up/Down use the same search and availability gates.
[Navigation evidence](qa/merge-block-navigation-2026-10-15.json) records the source,
focused Core results, initial fixture failure and final grouped native pass.
This selection is
also the existing transfer/Copy block selection. [Three-pane navigation](MERGE-NAVIGATION-PARITY.md) now shares the search with
explicit engine peer mappings. Independent boundary highlights and insertion carets now preserve block-only
Copy/Cut/Paste semantics; neutral-row Copy uses exact combined display coordinates.
Wrapped screen-row grouping and combined-view inline navigation still require a
further port. Undo/Redo now follows source all-pane selection clearing and target
caret restoration; the earlier block-restoring result history was corrected. In-place Edited row retention,
all whitespace aliases/legacy overrides,
physical/VoiceOver/large-file and signed App Store acceptance also remain open.
This does not certify the complete Merge/editor family.

Initial first-difference selection now searches the combined source-state list,
so a neutral Base alias before the first engine changed region is selected first.
The selected display block remains distinct from the insertion caret.
