# Worktree port audit

Target: TortoiseGit commit `7338078f8ddd924b8cddee35f512f2286072136d`.
This is a repository-layer port in progress. Native New Worktree and Worktree
List dialogs, application/Finder routing and visual acceptance remain pending.

## Audited source

| Source | Pinned blob | Behavior |
| --- | --- | --- |
| `CreateWorktreeDlg.cpp` | `e15ff43dcc0a6bf4c09429792dd644919dcf0f1a` | Directory, revision, Checkout, Force, Detach, Create New Branch; native layout and revision-dependent checkbox behavior still pending |
| `CreateWorktreeDlg.h` | `cdc58bd112fec3d4a3f35953202928997235436a` | Checkout enabled by default; Force, Detach and New Branch disabled |
| `WorktreeListDlg.cpp` | `701eaacccef376c67f0816246939e9801d8f856e` | List, Add, Prune, Explore, Lock, Unlock, Remove and Remove with Force; main repository excluded from lock/removal |
| `WorktreeListDlg.h` | `8111e8605867ff3dcf6a9ee50018bd1e1f9e8e83` | Native list presentation remains pending |
| `Commands/WorktreeCommand.cpp` | `9a0e2c343b5b99ba372ec0ecec4222e78b46e1f6` | Create/list/drop entry points; native routing remains pending |
| `AppUtils.cpp` | `ad5cf29edc933f6469fb9a961b84e8251f5fc563` | CreateWorktree argument construction and post-create submodule action |

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

This does not establish dialog parity. Remaining work includes native revision
controls and branch suggestions, main/list columns, icons, multi-selection,
Continue/Abort handling, removal confirmation and retry, post-create submodule
update, Finder drop/routing, screenshots, native interaction and signed sandbox
acceptance. The full-app goal remains open.
