# Working Tree dialog parity

Reference: `ChangedDlg.cpp`, `ChangedDlg.h`, `IDD_CHANGEDFILES` in the resource
file, and `RepoStatusCommand`, pinned by `upstream.json`.

## Implemented

- Standalone native Working Tree window, repository permission retained while open.
- Branch link above a dense file list, followed by lower-left filters, lower-right
  summary, and Save unified diff / Stash / Commit / Refresh / OK actions.
- Original status artwork; Path, Extension, Status, Lines added, Lines removed
  and Modification date columns. Columns sort on their displayed values.
- Unversioned, ignored and assume-unchanged/skip-worktree filters. The core also
  supports clean files, although upstream's unmodified checkbox is hidden.
- Finder file/folder scope and Show Whole Project. Show all staged files includes
  staged files outside that scope; switching it off keeps staged files inside scope.
- Context commands for Diff, Stage, Unstage, path-filtered Log, Reveal and Copy paths.
  Enter/double-click opens selected-file HEAD-to-working-tree unified comparison.
- Unified diff export uses the requested scope, independently of out-of-scope staged
  rows and row highlighting. Staged and later unstaged changes are included.
- Commit forwards the dialog's project/file scope. Stash save/pop and branch Switch
  currently open the existing operation confirmations; their full dialog ports remain pending.
- Explicit refresh and completed operations update the file list. Background Finder
  cache polling does not disable status controls or replace the current selection.

## Verification

The suite has 42 tests. New real-Git tests cover literal Unicode/newline paths,
folder scope, staged files outside scope, a mixed index/worktree file, ignored and
unversioned files, clean paths, assume-unchanged and skip-worktree flags, and unborn
HEAD. Reading status and diff leaves the index and working-tree contents intact.

Native checks on disposable sample data verified unversioned/ignored/flag filters,
opening a mixed-file comparison, and staging/unstaging an unversioned file through
its context menu. Native Save unified diff output matched Git's HEAD-to-working-tree
patch byte-for-byte. Added-line sorting was verified in ascending and descending
order (3, 2, 1, unknown); Stash save opened the foreground confirmation and was
cancelled without changing the repository. `site/assets/status.png` shows the running native window.

## Remaining upstream behavior

- Full GitStatusListCtrl menus: revert, conflict editor, blame, index-flag changes,
  file export/editor/open, submodules, groups/changelists and associated enablement.
- Full Stash save/apply/pop/list dialogs and conditional menu visibility. Current
  Stash menu exposes only save/pop. Switch still uses the generic operation dialog.
- Remote status checking, refresh cancellation/progress, F5 shortcut, persisted
  filters/window geometry/column widths, empty-state text and selection restoration.
- File/folder-specific filter enablement, alternative diff tools and broader
  multi-repository, rename, conflict and submodule native QA.
- Native scoped Finder invocation and signed Finder menu/badge appearance still
  need end-to-end validation; core scope tests do not establish that integration.

The main workspace overview still exists. The status command now opens this
standalone replacement; these entries remain partial until the remaining behavior
and UI have been compared and exercised.
