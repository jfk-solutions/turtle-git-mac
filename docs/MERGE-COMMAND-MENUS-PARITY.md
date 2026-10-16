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
interaction, minimum OS or signed/App Store behavior. The initial focus-only owner did not restore external main-menu replacements;
the continuation below implements that missing lifecycle.

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


## Rebuilt menus and source accelerators — October 16, 2026

The active editor now detects replacement of the application menu or one of its
submenus. An application update restores only its own contribution, preserving
unrelated rows. An unchanged menu does not rebuild or invalidate its items.
Current-root and parent-chain checks reject detached items immediately, before
queued repair. Normal focus epochs and retirement fences remain in place.

Structural root and filter-list changes defer while the main menu is tracking.
Tracking completion schedules one current-owner refresh. Old filter actions still
check current definitions; removed definitions cannot dispatch while their row
is retained for tracking. Application and tracking subscriptions retire with the
editor; a late update cannot reinstall a closed window's commands.

Added source block keys: F12 and Alt-Right use the left block in comparison;
Ctrl-F9 chooses Theirs, Ctrl-F10 or Shift-F12 chooses Mine, Ctrl-Shift-F9 chooses
Theirs before Mine and Ctrl-Shift-F10 chooses Mine before Theirs in a merge.
F11/Shift-F11/Ctrl-F11 and Ctrl/Alt-Up/Down share the existing difference commands.
Ctrl-R and Command-R use the owned Reload workflow. Ctrl-F3/Shift-Ctrl-F3 and the
native Command-Option-G variants share selected-text search, now also in Edit
alongside Clear Search Highlights. These aliases use the same checked active
window/field/operation state; they do not bypass Save or Undo ownership.

The renderer diagnostic confirms full-opacity original images and enabled native
buttons/layers before and after the captured replacement fade. Style reset,
reattachment and redraw did not restore the observed colors. Those experiments
are diagnostic-only; no speculative renderer workaround is shipped. The [grouped batch record](qa/merge-menu-lifecycle-2026-10-16.json) records ten
passing native case/engine runs, including the new lifecycle workflow. The first
grouped attempt passed; no Core suite was rerun. All owned receivers were reaped
and independently absent. The fixture injects menu roots and tracking notifications;
physical menu interaction, accessibility and signed acceptance remain open.
