# Merge view controls and input orientation

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`,
`MainFrm::OnViewSwitchleft`, `OnUpdateViewSwitchleft`, the Toolbar/Status Bar
commands in `IDR_MAINFRAME`, and the source toolbar/ribbon Switch artwork.

Two-file comparison now provides **Switch left and right view** in View and in
the native toolbar customization palette. The source Save/Don't Save/Cancel
workflow runs before exchanging inputs and reloading. Cancel retains drafts and
orientation; accepted reload rebuilds differences, moves, annotations and Undo.
The command also works in combined view and is disabled in single-file/image/
three-way contexts and while an operation, question or replacement owns the editor.

The exchange includes exact source bytes, encoding, source revisions, writable
identity and Save As targets. Reload continues to use the exchanged orientation.
Storage API calls retain original repository/working-file order; normal Save
writes the displayed file, even when its writable side changes. Save As targets
move with their source and continue to reload and save independently. No Git
index/HEAD change is part of switching. The original Switch bitmap is copied
unchanged and recorded in icon provenance.

Both editor families now expose saved Toolbar and Status Bar checkboxes. A hidden
native toolbar retains its owner and customization without reintroducing the
fallback command row. Native AppKit show/hide updates the same owning preference
store. File/Open replacement installs the next owner with the saved visibility;
retired toolbar items cannot act on it. Toolbar order/display-mode preferences
remain independent of visibility. Status Bar hides the native bottom footer.

The two-pane split now owns its divider fraction in the supplied preference store.
Combined view does not replace that fraction with its single-pane width. Returning
to two panes and reopening a comparison restore it, with bounds for minimum pane
widths. Resizing clamps the visible split without overwriting the user's preferred
fraction. Divider tracking persists the accepted position; programmatic layout
avoids redundant frame changes and writing to another preference domain.

Source Windows dock/ribbon layout and saved MFC workspace state are adapted to
AppKit. Complete input-route, split-accessibility, physical gestures, all dialog
visuals, minimum-OS and signed sandbox acceptance remain open.

[Grouped evidence](qa/merge-view-family-2026-10-16.json) records three icon Core
cases (two initially passed; the repaired bitmap registration/alpha case passed),
the Debug build and all eight native case/engine runs. New view routing passed
with system and bundled Git; retained toolbar, File/Open, moved-block, wrapped,
two-pane and three-pane workflows passed. The new receiver had a missing engine
argument and a native focus assumption corrected before that full pass. All owned
receiver processes were reaped and independently absent. Final inspection added
an explicit Switch refusal while the owner retains File/Open or is preparing its
replacement. The affected view workflow then passed again with both Git engines,
including held File/Open ownership without an attached sheet; the six unaffected
retained workflows were not repeated.

Optional light/dark captures were inspected, but their toolbar icons look faded
after the visibility/replacement sequence. They remain local QA candidates;
physical toolbar appearance and its cause are unresolved. No new accepted gallery
frame or complete Windows/editor/signed acceptance is claimed.
