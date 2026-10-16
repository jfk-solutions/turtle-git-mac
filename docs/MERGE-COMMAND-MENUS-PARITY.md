# Native Merge command menus

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`,
TortoiseMerge `IDR_MAINFRAME` File/Edit/Navigate/View/Help menus and accelerators,
`MainFrm` command/update handlers and `BaseView` pane/selection navigation.

Compare and Merge now contribute native commands to the macOS main menu while
their window owns focus. File adds Open, Save, active-pane Save As, resolution/
patch/reload where supported and Enable editing. Edit adds the applicable block
and file choices, Find/Next/Previous and Go to Line. Navigate supplies difference,
conflict and supported inline navigation plus next/previous pane. View supplies
source comparison choices, regex filters, toolbar/footer, whitespace, wrapping,
moved blocks, one/two-pane and left/right switching, folding and applicable
native view controls. Help opens TurtleGitMerge help and its About dialog.

Existing native clipboard and Undo/Redo items remain on the responder chain;
unrelated workspace menus and item identities are preserved. Source artwork,
checked/radio state and the existing model/toolbar gates drive editor commands.
Save As uses the active pane instead of invoking a toolbar dropdown with no
selected target. New Settings windows open the Merge Editor page; an already
open Settings draft retains its context and unsaved state.

F6/Shift-F6 cycle actual visible native text panes and set accessibility focus.
F7/Shift-F7 and F8/Shift-F8 retain source navigation. The existing Ctrl-G and
Ctrl-Option-arrow bindings are displayed with the corresponding actions.
Ctrl-P/T/D/U/L/E expose source wrap/whitespace/pane/switch/collapse/edit actions;
standard macOS Command-O/S/F/G and Shift variants remain. The new scoped key
router refuses field editors so it does not reinterpret their text input.

Menus contribute only the supported window variants. Focus loss removes only
owned rows/empty created roots. Each installation has a fresh epoch; retained
items from a prior focus cycle or a retired File/Open owner cannot dispatch.
Busy, sheets, field input, background windows and pending replacement are checked
again at acceptance. Hidden toolbar commands remain accessible through menus.
Dynamic filter rows rebuild only when names change and keep current model checks.

This connects the current model commands; it does not certify the entire source
menu/resource catalogue, physical menu tracking, VoiceOver shortcuts, Settings
interaction, minimum OS or signed/App Store behavior. Automatic reattachment after an external
replacement of the main-menu roots is not covered by this focus-based owner.

[Grouped evidence](qa/merge-command-menus-2026-10-16.json) records the Debug build
and nine passing native case/engine runs. The first two menu attempts exposed an
incorrect fixture assumption about macOS adding Writing Tools/AutoFill/dictation
items; the corrected check preserves original Undo/Copy identities and rejects
any surviving editor-owned target. After the final toolbar transition adjustment,
only the affected menu/hide/show/replacement workflow repeated and passed.
No Core behavior changed or Core suite ran. All owned receiver PIDs were reaped
and independently absent; no complete hosted result is claimed.

Toolbar commands are enabled in the faded-icon captures even when the app/window
is active. Applying saved visibility before toolbar attachment avoids the previous
attach-visible-then-hide transition, with implicit transition animation disabled.
The inspected final light capture still fades, so this did not resolve the visual
issue. Capture candidates remain local QA, not accepted documentation screenshots.
The toolbar rendering cause and physical appearance remain open.
