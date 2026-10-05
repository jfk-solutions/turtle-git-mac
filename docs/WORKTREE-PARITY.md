# Worktree port audit

Target: TortoiseGit commit `7338078f8ddd924b8cddee35f512f2286072136d`.
This is a port in progress. A native New Worktree dialog and create command are
implemented. Worktree List, management menus and native/signed acceptance remain
pending.

## Audited source

| Source | Pinned blob | Behavior |
| --- | --- | --- |
| `CreateWorktreeDlg.cpp` | `e15ff43dcc0a6bf4c09429792dd644919dcf0f1a` | Directory, revision, Checkout, Force, Detach, Create New Branch; native layout and revision-dependent checkbox behavior still pending |
| `CreateWorktreeDlg.h` | `cdc58bd112fec3d4a3f35953202928997235436a` | Checkout enabled by default; Force, Detach and New Branch disabled |
| `WorktreeListDlg.cpp` | `701eaacccef376c67f0816246939e9801d8f856e` | List, Add, Prune, Explore, Lock, Unlock, Remove and Remove with Force; main repository excluded from lock/removal |
| `WorktreeListDlg.h` | `8111e8605867ff3dcf6a9ee50018bd1e1f9e8e83` | Native list presentation remains pending |
| `Commands/WorktreeCommand.cpp` | `9a0e2c343b5b99ba372ec0ecec4222e78b46e1f6` | Create/list/drop entry points; native routing remains pending |
| `AppUtils.cpp` | `ad5cf29edc933f6469fb9a961b84e8251f5fc563` | CreateWorktree argument construction and post-create submodule action |
| `ChooseVersion.h` | `9bc3080bd557ba11f814e6d9221aa322b1414f1c` | Short branch/tag labels unless names conflict; remote labels and picker dispatch |

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

Eight disposable-repository tests cover directory-derived branches, main
HEAD/index/worktree preservation, listing from a linked checkout, detached and
no-checkout modes, historical branches, newline paths/reasons, lock protection,
dirty removal, main/unregistered path protection, missing checkout unlock/prune,
Force semantics, invalid inputs, bare repositories and future porcelain fields.
All fixture mutations are isolated from the development repository.

This does not establish complete dialog parity. Remaining work includes main/list
columns, management icons, multi-selection,
Continue/Abort handling, removal confirmation and retry, post-create submodule
update, Finder drop/routing, screenshots, native interaction and signed sandbox
acceptance. The full-app goal remains open.

## Native New Worktree dialog

`WorktreeCreateWindow.swift` follows `IDD_WORKTREE_CREATE` group and row order:
Location with Directory/Browse; Base On with HEAD, Branch, Tag and Commit; Options
with Create New Branch/name followed by Checkout, Force and Detach; OK, Cancel
and Help. It reuses the native radio, reference popup and searchable reference/
commit chooser. These shared pickers are partial implementations; full upstream
reference-browser and Log-picker fidelity is still pending.

Checkbox changes follow the audited source: local branches suggest `Branch_…`,
remote branches suggest their local name and enable Create New Branch, while
tags/commits enable it by default. Turning it off for a remote branch/tag/commit
forces Detach and disables its checkbox. Manually choosing Detach clears Create
New Branch without clearing Detach again. HEAD remains the default, and `.git`
directory names lose that suffix for the proposed destination.

The app Git menu and directory-only Finder action dispatch New Worktree with
original branch artwork. This direct create entry supplements the pending
upstream Worktrees management entry; it does not replace that requirement.
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
