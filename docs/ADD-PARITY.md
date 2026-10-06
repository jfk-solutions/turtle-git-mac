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
resizable saved geometry are used. Native table sorting, separate highlighted
and checked rows, check/uncheck, preview and Explore context commands are present.
Context images follow ShowAppContextMenuIcons when a menu is prepared.

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

Index-only executable/symlink post-actions are implemented; real native action-menu
acceptance is pending. Full status-list commands (Ignore/Delete/clipboard/open/editor and
other shared consumers), background artwork, Space/column/drop/keyboard gestures,
progress notification granularity, saved histories/preferences, broader direct/
removed/ignored/submodule cases and real native visual/light/dark comparison remain
unfinished. Signed Finder/picker/grant/quit acceptance and GitHub execution of
these local changes remain unverified. This work does not complete the full port.
