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
IDs stay separate from the synthetic display LF.

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
