# Add dialog and progress

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This is a native first pass, not complete Add/status-list/progress parity.
The [official Add manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-add.html)
and pinned AddDlg/AddCommand/AddProgressCommand/resource sources were compared.

## Implemented behavior

File-only selections go directly to Add progress, following AddCommand; folder
or mixed selections open a checked native list scoped to the requested paths.
The Add dialog keeps the upstream list above Select/deselect all and Include
ignored files, with OK/Cancel/Help below. Path and Extension are visible by
default; native header menus expose optional Size and Modification date columns.
Original status/menu icons, shared status colors, light/dark adaptation and
resizable saved geometry are used. Add selector and progress now use the unchanged
pinned AddBackground.ico, a translucent blue plus at the lower right of the list
viewport. The native background draw preserves alpha and original colors without
tinting, respects ShowListBackgroundImage (default on), and clips to the visible
list. Progress uses the upstream two columns, Action and Path, with original Add
icons and shared status colors; its former extra Status column has been removed.
See [the artwork verification record](qa/add-artwork-2026-10-06.json). Native table sorting, separate highlighted
and checked rows, check/uncheck, preview and Explore context commands are present.
Right-clicking a different row selects it before the menu is prepared. Space
checks/unchecks highlighted rows. Open, Open With and alternative-editor actions
use the working file and retain the repository grant; Open With uses a native
application picker and a scoped launch. Clipboard actions provide full paths,
relative paths, file/folder names, dotted extensions and all visible columns in
displayed order. Single-column text has no heading; multiple columns use tabs
and headings, with native LF separators. Command-C copies relative paths. Menu
commands and nested icons update with selection, busy/quit state and icon preferences.
File-opening commands are hidden for folders. Ignore adds source-shaped filename,
extension-mask and containing-folder commands: a shared extension uses a submenu,
and mixed extensions use direct name/mask entries. Names are captured in display
order and passed to the existing five-radio native Ignore dialog as a sheet.
The Add list is blocked while the sheet is open; Cancel preserves its checked
selection. Successful Ignore writes refresh Add, Working Tree/Commit and the
active repository cache. Hidden newly ignored files leave the Add list and
unchecked unrelated rows stay unchecked. Ignore writes rules without staging
or deleting working files. See [the Ignore integration record](qa/add-ignore-2026-10-06.json)
for actual model checks and remaining sheet/signed acceptance. See [the status-menu receiver record](qa/add-status-menu-2026-10-06.json) for verification and native acceptance limits.
Context images follow ShowAppContextMenuIcons when a menu is prepared.

Tracked-file context menus now expose Compare with base, Show log, old-name Log
for renames/copies, and HEAD Blame with original icons. Newly added and deleted
rows omit Blame; unversioned/ignored rows omit history and base comparison while
retaining double-click preview. Two existing non-directory files expose Compare
two files in displayed selection order, using the shared working-file comparison
backend. Right-click records the marked row even inside an existing multiple
selection; base comparison, Ignore and Delete availability follows that row.
Actions preserve the Add window's repository lease and are blocked during Add
work and quit confirmation. See [the history verification record](qa/add-history-2026-10-06.json).

Unversioned rows start checked; ignored rows are hidden until Include ignored is
selected and start unchecked unless directly requested. Direct files in a mixed
scope and removed-but-present copies are included. Refresh retains existing
checks and initially checks new unversioned rows. F5 and Command/Control-Return
are wired to refresh/accept. Same-repository drops extend scope/checks; native
drop acceptance remains unverified. Folder selections use path boundaries.
Git still cannot track empty directories.

OK submits only checked paths and closes the selector. Direct file requests and
accepted lists enter a separate progress window. The existing forced-add
private-index transaction now accepts owned cancellation, checks it at operation
boundaries and preserves the original index when cancelled before replacement.
Preflight checks reject outside/admin paths and files owned by nested foreign
repositories. Git path arguments stay literal, including Unicode/newline/glob
names. File selection can add before the initial commit. Adding does not create
a commit or push; progress offers a Commit handoff after success. Its adjacent action menu also
provides Add as Executable (+x) and Add as Symlink with the original Add icon.
These post-actions change only current stage-zero index modes: staged blob IDs,
working file contents/permissions and unrelated staged files are preserved, even
if a working file was edited or deleted after Add. Folder children and submodule
gitlinks keep their modes. Missing/conflicted entries fail without replacing the
real index. The shared private-index transaction retains lock and cancellation
handling; controls are disabled during mode changes and quit confirmation.

Cancel terminates owned Git work through the shared cancellation machinery and
closes a loading selector after cancellation finishes. Progress remains open to
show success/cancellation/error. Closing/quit is blocked while Add work is active;
other quit-confirmation flows freeze the new models. Native Add work retains its
repository grant. Repository refresh after completion uses the existing app/cache
flow when the same repository is still active. App menu and Finder entries use
the original Add icon. Finder adds the four upstream visibility alternatives and
the deleted-state flag; implemented root-menu projection now has 32 entries.

## Verification and remaining work

Three new core cases cover scoped unversioned/ignored selection, unchecked ignored
defaults, direct normal files, reviewed literal force-add with unchanged HEAD and
working contents, unborn indexes, pre-cancelled unchanged indexes and foreign/
invalid paths. Existing WorkingFileAdd transaction/mode tests also pass. The
focused run passes 21 tests; the final full regression passes 489 with zero failures.

The actual native Add model/table receiver verifies refresh/check retention,
ignored defaults, path-captured checkboxes, native column definitions and disabled
worker controls, checked-only OK/close, real Add progress and cancelled unchanged
index. The actual Finder receiver verifies the 32-entry pinned source projection
and prior icons/selection/cache routes. Both use Swift 6/macOS 13 minimum and
display no windows/menus; they prove receiver behavior, not native gestures or
screenshots. Debug and unsigned AppStore builds, bundle audits and site generation
are recorded in [the verification record](qa/add-2026-10-06.json).

Delete now captures exact status entries from the Add list and routes to the
existing guarded working-file delete backend. A native confirmation sheet offers
Trash by default; Shift selects permanent deletion with a separate warning.
Both keyboard Delete keys are wired, using the upstream unversioned/ignored/copy
eligibility rule. The Add parent is blocked during confirmation/work, Cancel
preserves checks before acceptance and can cancel work at backend boundaries.
Successful deletion refreshes Add and repository consumers; failure shows the
backend error and any recoverable Trash locations, then refreshes partial effects.
Unrelated unchecked rows remain unchanged. See [the Delete record](qa/add-delete-2026-10-06.json)
for actual effects and acceptance limits. The final Delete regression passes
491 tests with zero failures; both unsigned builds and bundle audits pass.

Save As and Export now use native save/folder panels and current working-file
copies, matching FileSaveAs/FilesExport rather than exporting staged blobs.
Save As's working-copy default stem includes the upstream trailing dash before
the extension. Existing destination files are replaced by a complete temporary
copy; source aliases and Git metadata destinations are rejected. Binary bytes
and file attributes are retained, and file symlinks supply their target contents.
Export preserves repository-relative folders, skips directories and omitted
removed rows, and uses the existing preflighted working-file export backend.
Chosen destination scopes are held for the operation; picker sheets and queued
copies block close/quit. Cancellation is checked between exports and before
replacement; a synchronous individual copy completes before cancellation is
observed. Earlier completed exports remain when a later copy fails or cancels.
See [the copy verification record](qa/add-copy-2026-10-06.json) for actual model
checks and remaining native/signed picker acceptance. The final copy regression
passes 492 tests with zero failures; both unsigned builds and bundle audits pass.

Index-only executable/symlink post-actions are implemented; real native action-menu
acceptance is pending. Full status-list commands (current-column clipboard, remaining tracked-row commands and
other shared consumers), missing-file comparison eligibility, Shift alternative comparison, Space/column/drop/keyboard gestures,
progress notification granularity, saved histories/preferences, broader direct/
removed/ignored/submodule cases and real native visual/light/dark comparison remain
unfinished. Signed Finder/picker/grant/quit acceptance and GitHub execution of
these local changes remain unverified. This work does not complete the full port.
