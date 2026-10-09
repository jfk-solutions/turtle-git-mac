# TurtleGit documentation

Start with [Getting started](GETTING-STARTED.md) for the first native workflows,
or the [project README](../README.md) for build instructions and current limits.
The [manual plan](MANUAL-PLAN.md) tracks the remaining user-guide chapters.

Parity documents compare implementation against the pinned TortoiseGit source.
They contain checkpoint evidence and explicit gaps; an implemented command or
passing receiver is not proof of complete dialog, physical UI or signed sandbox
parity. Dated machine-readable evidence is in [qa](qa/).
Historical test counts describe the checkpoint at which they were recorded.

The [file inventory](upstream-files.csv), [dialog inventory](upstream-dialogs.csv)
and [control inventory](upstream-controls.csv) track source review.
Inventory entries are not completion counts. See [Port tracking](PORTING.md)
for baseline and update rules.

## Guides and project status

- [Getting started with TurtleGit for Mac](GETTING-STARTED.md)
- [Saved progress action log](ACTION-LOG.md)
- [Saved Data settings](SAVED-DATA.md)
- [Dialog sizes and positions](DIALOG-GEOMETRY.md)
- [Temporary files and Saved Data cleanup](TEMPORARY-FILES.md)
- [Editing Git notes](GIT-NOTES.md)
- [Reverting a commit from Log](REVERT-COMMIT.md)
- [Cherry Pick from Log](CHERRY-PICK.md)
- [TurtleGit user manual plan](MANUAL-PLAN.md)
- [TurtleGit for Mac — full port tracking](PORTING.md)
- [UI comparison requirements](UI-PARITY.md)
- [Historical implementation notes](IMPLEMENTATION-NOTES.md)

## Build, distribution and verification

- [Distributing TurtleGit for Mac](DISTRIBUTION.md)
- [Privacy in TurtleGit for Mac](PRIVACY.md)
- [Testing TurtleGit for Mac](TESTING.md)
- [Replay Git compatibility](REPLAY-GIT-COMPATIBILITY.md)
- [Project website and screenshots](WEBSITE.md)
- [Git command progress parity](PROGRESS-PARITY.md)

## Working files and commits

- [Working Tree dialog parity](STATUS-PARITY.md)
- [Commit dialog parity](COMMIT-PARITY.md)
- [Commit filename completion audit](COMMIT-COMPLETION-PARITY.md)
- [Commit code-symbol completion audit](COMMIT-CODE-SYMBOL-PARITY.md)
- [Add dialog and progress](ADD-PARITY.md)
- [Delete / Delete (keep local) parity](REMOVE-PARITY.md)
- [Rename parity](RENAME-PARITY.md)
- [Ignore parity](IGNORE-PARITY.md)
- [Working-file Revert parity](REVERT-PARITY.md)
- [Clean port](CLEAN-PARITY.md)
- [Resolve parity](RESOLVE-PARITY.md)
- [Delete/modify conflict parity](DELETE-CONFLICT-PARITY.md)

## History and repository browsing

- [Log Messages parity](LOG-PARITY.md)
- [Expanding compressed history](LOG-GRAPH.md)
- [Log Merge and Rebase commands](LOG-MERGE-REBASE.md)
- [Log Revert parity](LOG-REVERT-PARITY.md)
- [Log statistics port](LOG-STATISTICS-PARITY.md)
- [Statistics](STATISTICS.md)
- [RefLog and Stash List parity](REFLOG-PARITY.md)
- [Blame parity](BLAME-PARITY.md)
- [Edit Notes parity](EDIT-NOTES-PARITY.md)
- [Repository Browser parity audit](REPOSITORY-BROWSER-PARITY.md)
- [Revision Export](REVISION-EXPORT.md)
- [Bisect parity](BISECT-PARITY.md)

## Repositories, branches and remote operations

- [Clone dialog parity](CLONE-PARITY.md)
- [Create Repository parity](INIT-PARITY.md)
- [New Branch/Tag dialog parity](BRANCH-TAG-PARITY.md)
- [Switch/Checkout dialog parity](SWITCH-PARITY.md)
- [Fetch dialog parity](FETCH-PARITY.md)
- [Pull dialog parity](PULL-PARITY.md)
- [Push dialog parity](PUSH-PARITY.md)
- [Manage Remotes parity](REMOTE-SETTINGS-PARITY.md)
- [SSH agent and identity port](SSH-AGENT-PARITY.md)
- [Encrypted SSH key response port](SSH-PASSPHRASE-PARITY.md)
- [Native SSH key selection and permissions](SSH-IDENTITY-PARITY.md)
- [SSH transport preparation boundaries](SSH-TRANSPORT-PARITY.md)
- [Merge dialog parity](MERGE-PARITY.md)
- [Stash Save parity](STASH-PARITY.md)
- [Reset parity](RESET-PARITY.md)
- [Cherry Pick parity audit](CHERRY-PICK-PARITY.md)
- [Worktree port audit](WORKTREE-PARITY.md)
- [Export parity](EXPORT-PARITY.md)
- [Format Patch port audit](FORMAT-PATCH-PARITY.md)
- [Request Pull dialog parity](REQUEST-PULL-PARITY.md)

## Rebase

- [Add commits to Rebase / Cherry Pick](REBASE-ADD-PARITY.md)
- [Rebase completion actions](REBASE-COMPLETION-ACTIONS.md)
- [Rebase Conflict Files](REBASE-CONFLICT-FILES.md)
- [Empty replay results and conflict-message hints](REBASE-EMPTY-RESULTS.md)
- [Empty Squash groups](REBASE-EMPTY-SQUASH.md)
- [Rebase parity](REBASE-PARITY.md)
- [Rebase replay rows](REBASE-PROGRESS-ROWS.md)
- [Rebase reference recovery](REBASE-REFERENCE-RECOVERY.md)
- [Rebase row menus](REBASE-ROW-MENUS.md)
- [Rebase session context](REBASE-SESSION-CONTEXT.md)
- [Edit and Split Commit](REBASE-SPLIT.md)
- [Squash messages and author dates](REBASE-SQUASH.md)
- [Squash conflict recovery](REBASE-SQUASH-CONFLICTS.md)

## Comparison, merge and submodules

- [Unified diff viewer selection](UNIFIED-DIFF-VIEWER-PARITY.md)
- [Text conflict editor parity](TEXT-MERGE-PARITY.md)
- [Comparison marks: app and Finder](COMPARISON-MARK-PARITY.md)
- [Submodule Diff and Changed Files parity](SUBMODULE-DIFF-PARITY.md)
- [Submodule conflict dialog parity](SUBMODULE-CONFLICT-PARITY.md)
- [Submodule Update parity](SUBMODULE-UPDATE-PARITY.md)

## Finder integration

- [Finder creation workflows](FINDER-CREATION-PARITY.md)
- [Finder command order and separators](FINDER-MENU-LAYOUT-PARITY.md)
- [Finder path and selection conditions](FINDER-PATH-CONDITIONS-PARITY.md)
- [Finder repository metadata and command availability](FINDER-REPOSITORY-METADATA-PARITY.md)
- [Finder menu selection dispatch](FINDER-SELECTION-PARITY.md)
- [Finder registered submodule roots](FINDER-SUBMODULE-ROOT-PARITY.md)
- [Finder submodule cache tree](FINDER-SUBMODULE-TREE-PARITY.md)
- [Finder two-file Diff](FINDER-TWO-FILE-DIFF-PARITY.md)

## Settings, artwork and helpers

- [Appearance and color parity](APPEARANCE.md)
- [Application context-menu icon preference](CONTEXT-MENU-ICONS-PARITY.md)
- [Advanced Settings port audit](ADVANCED-SETTINGS-PARITY.md)
- [EditorConfig integration audit](EDITORCONFIG-PARITY.md)
- [Issue tracker integration audit](ISSUE-TRACKER-PARITY.md)
- [Author pictures in Log](GRAVATAR.md)

- [Import Patch native workflow and remaining parity](IMPORT-PATCH-PARITY.md)

## Inventory maintenance

The upstream checkout is ignored, not vendored. To prepare the pinned baseline:

```sh
git clone --depth 1 https://github.com/TortoiseGit/TortoiseGit.git .upstream/TortoiseGit
git -C .upstream/TortoiseGit fetch origin 7338078f8ddd924b8cddee35f512f2286072136d
git -C .upstream/TortoiseGit checkout 7338078f8ddd924b8cddee35f512f2286072136d
python3 scripts/inventory-upstream.py
```

Regeneration reads the commit in `upstream.json`, including resource contents,
independently of checkout HEAD or uncommitted edits. To review a new upstream
revision, explicitly run `python3 scripts/inventory-upstream.py --ref <commit>`
and regenerate controls with `python3 scripts/inventory-dialog-controls.py`.
Changed blobs, dialog resources and control declarations require renewed review.
External libraries and gitlinks are inventoried, but their nested repositories
are not recursively audited.
