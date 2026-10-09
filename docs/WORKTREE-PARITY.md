# Worktree port audit

Target: TortoiseGit commit `7338078f8ddd924b8cddee35f512f2286072136d`.
This is a port in progress. A native New Worktree dialog and create command are
implemented, together with native Worktree List and management menus. Full
native visual/interaction and signed acceptance remain pending.

## Audited source

| Source | Pinned blob | Behavior |
| --- | --- | --- |
| `CreateWorktreeDlg.cpp` | `e15ff43dcc0a6bf4c09429792dd644919dcf0f1a` | Directory, revision, Checkout, Force, Detach, Create New Branch; native implementation and revision-dependent model checks, visual acceptance pending |
| `CreateWorktreeDlg.h` | `cdc58bd112fec3d4a3f35953202928997235436a` | Checkout enabled by default; Force, Detach and New Branch disabled |
| `WorktreeListDlg.cpp` | `701eaacccef376c67f0816246939e9801d8f856e` | List, Add, Prune, Explore, Lock, Unlock, Remove and Remove with Force; main repository excluded from lock/removal |
| `WorktreeListDlg.h` | `8111e8605867ff3dcf6a9ee50018bd1e1f9e8e83` | Native five-column list and column customization implemented; visual acceptance pending |
| `Commands/WorktreeCommand.cpp` | `9a0e2c343b5b99ba372ec0ecec4222e78b46e1f6` | Create/list entry points implemented; Finder drag/drop creation pending |
| `AppUtils.cpp` | `ad5cf29edc933f6469fb9a961b84e8251f5fc563` | CreateWorktree argument construction and post-create submodule action |
| `ChooseVersion.h` | `9bc3080bd557ba11f814e6d9221aa322b1414f1c` | Short branch/tag labels unless names conflict; remote labels and picker dispatch |
| `TortoiseShell/MenuInfo.cpp` | `aee7f91ad1111fe03ab85b390855885ca940a27f` | Worktrees uses the same original copy/branch icon |
| `ProgressDlg.cpp` | `557988a1303dc86b11c9c74d29be4797aa7e6090` | Close returns IDOK; Cancel returns IDCANCEL; post-action runs then returns IDOK to resume the caller's batch |
| `ColumnManager.cpp` | `6776d4d47a80a9af042223ebd5f8589cd48b57f3` | Saved visibility/order/adjusted widths, confirmed Reset columns and header fitting |
| `ColumnManager.h` | `bd12076609badaecb865f168ebefd1e235a7315b` | Path omitted from visibility menu; divider double-click and Shift behavior |
| `ResizableColumnsListCtrl.h` | `84350420f3d5dfd6eb685f21415559487dd59611` | Header context/drag/resize routing and saved columns |

`CAppUtils::CreateWorktree` supplies the actual creation argument construction.
HEAD is omitted from the command, leaving Git's directory-name branch behavior
intact. Force passes `--force`, never `-B`: existing branches are not reset.
Unchecked Checkout passes `--no-checkout`; Detach passes `--detach`; a new
branch passes `-b`. Contradictory detach/new-branch input is rejected before
mutation. Non-HEAD revisions are validated without option interpretation while
retaining the chosen reference for Git's branch/tracking behavior.

## Repository implementation

`GitWorktrees.swift` implements list/create/lock/unlock/remove/prune through the
existing serialized Git runner. [Git's stable porcelain format](https://git-scm.com/docs/git-worktree#_porcelain_format)
with NUL separators preserves spaces, Unicode and newlines in checkout paths
and lock reasons. Records retain HEAD, branch, bare/detached state and optional
lock/prune reasons. The first record identifies the main repository, also when
listing from a linked checkout or a bare repository.

Lock, unlock and removal require a fresh registered linked-worktree record.
Missing checkout paths still match `/var` and `/private/var` aliases by resolving
their existing ancestors. Git itself enforces dirty/locked checkout restrictions.
Remove with Force passes one `--force`, matching upstream; it does not silently
override a lock. Prune uses `git worktree prune` without additional expiry flags.

## Verification and remaining scope

Eleven disposable-repository tests cover directory-derived branches, main
HEAD/index/worktree preservation, listing from a linked checkout, detached and
no-checkout modes, historical branches, newline paths/reasons, lock protection,
dirty removal, main/unregistered path protection, missing checkout unlock/prune,
Force semantics, invalid inputs, bare repositories and future porcelain fields.
All fixture mutations are isolated from the development repository.

This does not establish complete dialog parity. The manager implementation below
advances columns, icons, multi-selection, Continue/Abort, confirmation and retry.
Finder drop support, complete shared revision pickers, screenshots, native
interaction and signed sandbox acceptance remain pending. The full-app goal
remains open.

## Native New Worktree dialog

`WorktreeCreateWindow.swift` follows `IDD_WORKTREE_CREATE` group and row order:
Location with Directory/Browse; Base On with HEAD, Branch, Tag and Commit; Options
with Create New Branch/name followed by Checkout, Force and Detach; OK, Cancel
and Help. It now owns the shared native all-reference namespace browser and full
typed-revision single-selection Log, using native revision controls and canonical
fresh-catalog handoff. Both underlying browser/Log implementations remain partial;
complete commands, history combos and physical fidelity are still pending.

Checkbox changes follow the audited source: local branches suggest `Branch_…`,
remote branches suggest their local name and enable Create New Branch, while
tags/commits enable it by default. Turning it off for a remote branch/tag/commit
forces Detach and disables its checkbox. Manually choosing Detach clears Create
New Branch without clearing Detach again. HEAD remains the default, and `.git`
directory names lose that suffix for the proposed destination.

The app Git menu dispatches New Worktree with original branch artwork. Finder's
default menu exposes the upstream Worktrees manager; its Add button opens New
Worktree. The provisional direct Finder create entry was removed when the shell
command order was ported; see [menu layout audit](FINDER-MENU-LAYOUT-PARITY.md).
Browse is an AppKit folder panel that can create an empty directory. In Store
builds, mutation requires scoped source and destination access. Typed destinations
outside granted scope must be granted through Browse. Signed cross-directory and
linked-checkout/common-repository access remain unverified.

Creation opens a progress view, prevents closing during mutation, and exposes
Cancel through the owned Git process-group cancellation token. Failure can return
to the unchanged inputs. Success offers Submodule Update when the new checkout
contains `.gitmodules`, retaining its access lease in the existing update dialog.
This post-action has build verification but not native/submodule acceptance.
Cancellation may leave Git-created files; there is no automatic deletion or
rollback. Retry reports Git's existing-directory/branch errors.

Nine core tests pass, including cancellation before mutation. A separate Swift 6
driver compiles the actual native model and shared views, verifies the checkbox
transitions and successful creation callback, verifies that an explicit local
branch stays attached and a remote base retains automatic tracking, and confirms
the source branch is unchanged. Short label selection follows `CChooseVersion`
instead of unconditionally passing full refs (which can detach local checkouts).
The shared reference-popup callback is main-actor isolated for AppKit access.
Run `python3 scripts/test-worktree-dialog.py` after a Debug build.
This is behavioral model verification, not mouse/keyboard or visual acceptance.

The isolated native preview attempt lost the computer-use native pipe before
returning UI state. Its one owned process (5347, canonical `/private/var` path)
was revalidated and terminated; no app process remained. Normal Quit, layout,
light/dark appearance, menu icons, native directory picker, clicks, screenshots,
active-operation cancellation and signed sandbox acceptance remain pending.

## Native Worktree List

`WorktreeListWindow.swift` follows `IDD_WORKTREE_LIST`: a resizable table with
Path, Hash, Branch, Locked and Reason columns; Add and Prune at the left of the
footer and OK/Help at the right. Reason aligns right as in the source. Main
repository lock columns remain blank. Known-missing linked checkouts display blank
Hash/Branch, even if Git's metadata retains them. Store builds retain that metadata
when the directory is outside granted access; a denied existence check is not
evidence that the checkout is missing. The bare main repository's
HEAD and branch are read separately because porcelain omits them while the
upstream libgit2 list displays them. Detached linked checkouts say `detached HEAD`;
the detached main repository says `HEAD`, following the separate source base row.

The app Git menu and directory-only Finder menu expose Worktrees with the
original copy/branch icon. Single selection adds Explore to; double-click
reveals that path in Finder. Context menus choose Lock/Unlock from the selected
row's state and offer Remove/Force remove for linked rows. Multi-selection
offers both lock actions and both removal actions; mutation skips the main
repository. As upstream does, its main-only Lock entry completes with count
zero rather than changing repository metadata. Original explorer/delete icons
are reused; `menulock.ico`/`menuunlock.ico` are imported unchanged, bringing the
provenance manifest to 74 assets.

Add opens the existing New Worktree dialog as a sheet and refreshes after create/
close. Prune uses the existing Git command and refreshes after success. F5
dispatches refresh through a native key-equivalent receiver. These window,
sheet, Finder and shortcut interactions have build verification; actual clicks
remain pending.

Lock/unlock batches report successful counts and offer Continue/Abort after each
failure. Removal asks Yes/No, pauses at its first failure and offers Force remove
for that failed row. Close continues the remaining original batch; Cancel stops
it. Force retry applies force only to the failed row and then resumes remaining
rows in their original mode, matching ProgressDlg's post-action return. Choosing
the Force button is the explicit retry action; it does not ask another redundant
confirmation. The initial Force context command explains uncommitted/untracked
deletion in its Yes/No confirmation. Store builds retain folder access leases and request
access before deleting checkout directories outside existing grants. Wrong-folder
grants and cancelled grants do not mutate the checkout. Signed scope, nested
confirmation sheets and progress cancellation remain unverified.

Store Prune requests grants for every unlocked linked checkout before invoking
Git, including parent-folder grants for missing directories. Locked checkouts
are exempt, matching Git's lock protection for disconnected disks. All requested
paths must be covered by retained scopes. A `.git` attributes check then accepts
only known no-such-file errors; permission errors abort before any pruning.
This guard follows the bundled Git 2.55.0 source: `worktree.c`'s
`should_prune_worktree` treats a failed `.git` existence check as absence, while
`builtin/worktree.c` defaults Prune expiry to `TIME_MAX`. A denied filesystem
check could therefore remove valid checkout registration and its index.
The injectable scope-policy test proves absent/wrong/cancelled grants and an
actual POSIX permission-denied directory prevent Prune from running; a parent
grant permits pruning after access is restored. This is policy verification,
not evidence of signed macOS sandbox behavior.

Progress prevents closing during mutations and can cancel the owned Git process
group. The actual native model test observes a running delayed removal, cancels
it, and verifies prompt termination with checkout and registration preserved.
This proves the model/process path, not the native Cancel button or sheet.
The application delegate rejects Quit while either worktree dialog has
an active operation or an attached sheet. This follows the existing app policy;
live Quit acceptance remains pending. Row identity retains the unmodified path from Git's porcelain record:
Foundation changes `/var` to `/private/var` when an existing path disappears,
which previously lost selections and failed identity-based lookup. The actual
model regression and core missing-path assertion now preserve identity across
that transition.

The Swift 6/macOS 13 driver verifies actual manager menus and main skipping,
batch counts, Continue/Abort, declined removal, dirty failure stopping a batch,
Force retry with batch resumption, preservation of normal mode on subsequent dirty
rows, Close continuation, Cancel stopping remaining removals, missing-row
presentation, pruning, Explore dispatch and bare HEAD presentation. It also
retains the creation-model checks. Twelve focused core/
icon tests pass, including cancelled management preserving files and locks,
stable missing identity, management of paths constructed without a directory URL
hint, and decoding all menu artwork. Physical path matching ignores the directory
URL's trailing slash while retaining ancestor symlink resolution. The icon uniqueness test
now explicitly recognizes upstream's shared branch/Worktrees artwork instead
of assuming a unique asset for every command.
The full core suite passes after the path regression fix: 456 tests, zero failures.
These tests establish
repository/model behavior within their fixtures, not complete app/UI parity.

No app was launched in this manager check: the previous native controller failure
remains unresolved. Native light/dark screenshots and all native/signed
acceptance remain pending. See [verification record](qa/worktree-list-2026-10-05.json).

## Native column controls

`WorktreeListTable.swift` now uses an AppKit `NSTableView` with five native columns
in source order and initial widths of 150/100/100/100/100 points. Path includes
the folder icon; hash uses a fixed-pitch font; Reason and its header align right.
It preserves the manager's multi-selection menus and original colorful icons,
double-click Explore dispatch, and F5 receiver. No sort action is added: the
source Worktree List has no column-sort handler.

The header context menu offers Reset columns followed by checked Hash, Branch,
Locked and Reason items. Path remains visible, matching the source menu's omission
of column zero. Header dragging changes order; resize notifications save adjusted
widths. Settings use a versioned UserDefaults entry shared by Worktree List windows.
Unknown/duplicate saved IDs are ignored, Path cannot be hidden by malformed saved
settings, and invalid widths are bounded to native usable limits.

Divider double-click fits the column's contents and saves that adjusted width.
Shift-double-click includes the header and clears its adjusted-width persistence,
following the source's default-sizing mode. Reset asks the upstream Yes/No question,
restores natural order/visibility and fits the displayed columns; reopening then
uses the unadjusted initial widths. AppKit text measurement replaces Win32 text/
header sizing. Source Path's header-fill sizing is adapted to measured native
content/header width. Resize handling uses the documented `NSTableColumn` payload
of [AppKit's resize notification](https://developer.apple.com/documentation/appkit/nstableview/columndidresizenotification).

The expanded Swift 6/macOS 13 driver instantiates the actual AppKit table without
displaying a window. It checks columns/default widths, usable header/table geometry, folder/text row cells, menu icons,
selection, disabled actions, hide/reopen/order/width state, protected Path,
normal/default fitting, both reset decisions and malformed preferences using an
isolated defaults suite. It retains all creation/management/scope/cancellation
tests. These are receiver/state tests: actual divider gestures, dragging, header
menus, native light/dark appearance and signed sandbox remain unverified. See
[column verification record](qa/worktree-columns-2026-10-05.json).

## Original list watermark

Worktree List now draws the unchanged `RepoBrowserBackground.ico` resource used by
upstream `IDI_REPOBROWSER_BKG`. Its pinned blob is
`1a3dbbc55ec52cd0c349f3e2fd0cf1b820ec5fca`. The manifest now contains 75 original
assets; bundle audits verify their hashes and the decoder test verifies actual
AppKit pixels. The silver database icon preserves its transparent corners,
original 128/255 center alpha and colors, without template tinting or added opacity.

`CCommonAppUtils::SetListCtrlBackgroundImage` in `CommonAppUtils.cpp` (blob
`e238480c30808908b318d1f419c246ab0c116895`) loads a DPI-scaled 128-pixel icon,
uses alpha blending, and places it at 100% horizontal/vertical offsets. Native
`WorktreeTableView.drawBackground(inClipRect:)` adapts this to a 128-point image
anchored at the lower-right corner of the visible table viewport. Drawing clips
to the viewport and dirty rectangle; scrolling changes the anchor with the
viewport instead of leaving the image fixed to the document origin.

It reads the saved `ShowListBackgroundImage` boolean, defaulting to true as
`SettingsAdvanced.cpp` (blob `1b222ebf9053e0e902f79413899dc92d35071464`) does.
The [native Advanced editor](ADVANCED-SETTINGS-PARITY.md) now exposes this setting.
Other list-background consumers, most Advanced setting effects and the complete
settings host remain pending. Native semantic background colors remain responsible for light/dark;
the original artwork is drawn unchanged in either appearance.

The standalone receiver driver now checks the actual background painter with
offscreen bitmap contexts: original icon pixels, enabled/disabled preference,
light/dark semantic background, 128-point bottom-right placement, scroll offsets,
and zero bounds. All creation, column, management, scope and active cancellation
checks are retained. These checks do not establish the composed window's
appearance, row/selection overlap, high-DPI native screenshots, or signed behavior.
See [watermark verification record](qa/worktree-backdrop-2026-10-05.json).

## New Worktree full revision pickers

`VersionPickerCoordinator` supplies the same full browser/Log routes as Switch
and Branch/Tag. Native base controls receive selection focus, including custom refs
classified into the Commit field. The Worktree parent reapplies its own branch
suggestion/new-branch/detach rules after the handoff, retaining Directory, Checkout
and Force. HEAD/busy/progress/closed states prevent new picker requests; Create,
Directory Browse, duplicate/competing requests, close and Quit remain gated while
a child or return catalog is pending. Closing the parent invalidates the chooser
and releases its children; initial metadata replies to closed Worktree models are
ignored. This does not establish cancellation/rollback of a running creation.

[Creation picker QA](qa/creation-pickers-2026-10-09.json) includes hidden native
Worktree chooser/focus/ownership checks and actual private creation at the commit
returned by Log with Checkout disabled. The existing Worktree dialog/list/scope/
cancellation receiver now compiles all shipping Mac sources in the project's
Swift 5 mode, replacing an incomplete source list that omitted picker dependencies.
It accepts `--git` so real operations and its delayed helper use the selected Git
engine consistently. The old short-list compilation failure is retained locally.
Physical sheets/input/visuals, complete browser/Log commands and signed security
scopes/Finder acceptance remain pending; scope fixtures simulate policy only.
