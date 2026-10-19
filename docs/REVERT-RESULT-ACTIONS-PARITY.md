# Revert completed-file results

The Revert result window now connects its completed file notifications to the
same native result-action family as Add and Resolve. This fills a concrete
consumer gap: Revert previously showed Action/Path rows with a whole-output Copy
menu, without completed-file launches, selected-path Copy or native double-click
handling.

## Pinned source contract

The source remains the repository's pinned TortoiseGit checkout:

- `src/TortoiseProc/GitProgressList.cpp:1142–1209`,
  `WC_File_NotificationData::GetContextMenu` and `HandleDblClick`: a single Revert
  file offers Show Log, Open, Open With and Explore; a directory omits application
  commands and double-click explores it. Original command icons are retained.
- `GitProgressList.cpp:864–927`, `OnContextMenu`: result actions require a stopped
  worker and selected rows. Context Copy contains selected path-column text, in
  display order, rather than the complete command output.
- The source command-copy route preserves `Action: Path` formatting. Native
  Command-C retains that distinction from context Copy. Command-A selects the
  actual notification table; auxiliary command/finished notifications retain
  their own displayed text.
- `GitProgressList.cpp:670–698`, `OnHdnItemclickSvnprogress`: Action/Path sorting
  becomes available after the worker stops. A new attempt restores its original
  notification order and clears the previous result selection.
- `GitProgressList.cpp:930–963` contains a disabled drag implementation (`#if 0`);
  it is not treated as a missing live source behavior.

## Connected native implementation

`RevertProgressWindow.swift` retains ordered worker notifications and their
status, exposing them through the shared `FileOperationProgressState` and
`FileOperationProgressTable`. Command and Finished rows remain separate from
file rows. Existing Revert row icons, status tooltips and light/dark colors are
retained. Shared menus capture attempt and selection epochs and consume actions
once; stale, busy, retired, closing and Quit-deferred callbacks cannot launch,
copy or replace a result.

The result controller owns `FileOperationProgressFiles`, including its scoped
Core path reads, application picker and asynchronous launch callback. Revert,
Resolve, Rebase and workspace callers retain their existing repository grant,
preferences and path-specific Log route. The pending application sheet and file
launch protect ordinary Close and application Quit. Forced retirement cancels
owned sheets and retains the operation until its callbacks drain; a late Core
read cannot create another picker or launch.

Open retains the selected working path, including a leaf file symlink. Escaping
parent aliases and Git metadata remain confined by Core. Explore selects an
existing item or opens its nearest existing parent. Explicit Open/Open With of
a missing item reports an error instead of silently opening a parent. After an
application picker accepts, the target's file identity is checked again so that
a replaced file is not launched under the original result receipt.

The existing recoverable Trash copies, Retry selection refresh, cancellation and
auto-close policy are retained. Whole-output Copy remains available separately.
The submodule post-action captures the comparison revision and gitlink paths,
then closes and drains the result window before handing them off once. An owned
sheet, forced closure or deferred Quit prevents that handoff.

## Grouped verification

The final Debug application build, three focused Core Open/Reveal path contracts
and all six native case/engine combinations passed. The cached grouped runner
combines new result actions with retained Revert operation/retry/cancellation and
shared Add/Resolve progress checks, using private repositories, preferences,
pasteboards and action logs. Every receiver window was hidden/offscreen and all
six successful receiver processes were reaped and independently absent.

The native checks exercise actual Revert restoration and parent Log wiring,
source menu captions/icons, both selected-copy formats and whole diagnostic Copy,
AppKit double-action dispatch, completed sorting, selection/attempt replacement,
directories and missing-path fallback, leaf/parent symlinks, replaced Open With
targets, panel cancellation, held launch and real held Core preflight retirement,
and actual gitlink handoff ordering. Double-action tests inject the clicked row
and dispatch the actual native target/action; physical mouse input remains open.
The retained direct Add-dialog fixture was adapted without removing file icon,
tooltip, color or copied-row assertions; it was not separately executed here.

[Batch evidence](qa/revert-result-actions-2026-10-19.json) records the initial
compile/fixture failures and the real selection-loss repair: Open previously
cleared selected rows during a busy redraw; ordinary reloads now preserve their
UUIDs, while Retry clears old selection and sorting. Only the affected native
flow and application build were repeated; passing Core checks were retained.

Actual inactive content captures were inspected in
[light](site/assets/revert-completed-results-light.png) and
[dark](site/assets/revert-completed-results-dark.png) appearances. The light
capture includes a settling native progress animation; the dark capture shows
the completed bar. These captures establish the shown content rather than
physical input or complete source-layout acceptance.

The focused local pass establishes only these paths. Physical Finder behavior,
external application behavior, signed sandbox grants, every upstream progress
consumer, accessibility and complete dialog visual parity require separate
evidence. No complete application or hosted CI pass is implied.
