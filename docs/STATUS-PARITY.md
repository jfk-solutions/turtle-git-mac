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
- Context commands for Diff, Stage, Unstage, Rename, path-filtered Log, Reveal and Copy paths.
  Rename opens the native source/name/browse window; see RENAME-PARITY.md.
  Enter/double-click opens selected-file HEAD-to-working-tree unified comparison.
- Unified diff export uses the requested scope, independently of out-of-scope staged
  rows and row highlighting. Staged and later unstaged changes are included.
- Commit forwards the dialog's project/file scope. Stash save/apply/pop/list and branch Switch
  open dedicated native windows. Their remaining parity is recorded in STASH-PARITY.md,
  REFLOG-PARITY.md and SWITCH-PARITY.md.
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
- Full conditional Stash/Switch menus and post-operation behavior; the dedicated
  dialog ports remain partial.
- Remote status checking, refresh cancellation/progress, F5 shortcut, persisted
  filters/window geometry, empty-state text and selection restoration.
- File/folder-specific filter enablement, alternative diff tools and broader
  multi-repository, rename, conflict and submodule native QA.
- Native scoped Finder invocation and signed Finder menu/badge appearance still
  need end-to-end validation; core scope tests do not establish that integration.

The main workspace overview still exists. The status command now opens this
standalone replacement; these entries remain partial until the remaining behavior
and UI have been compared and exercised.

The file menu now offers upstream Ignore name/extension and containing-folder actions
for unversioned/deleted selections. [Ignore parity](IGNORE-PARITY.md) records rule
semantics and native Commit/Working Tree handoff evidence; post-close restoration
remains unverified.


## Local-change index flags

Skip worktree, Assume Unchanged and Unflag are now shared with Commit. The
existing Show ignore local changes flagged files filter exposes flagged rows for
unflagging. Native confirmation, restoration to Modified and assume-unchanged
status were verified; Git tests cover clearing both flags and linked-worktree
index separation. See [Commit's index flag audit](COMMIT-PARITY.md#index-flag-context-actions)
for source review, test evidence and remaining acceptance work.

## Shared native columns and clipboard

Working Tree now reuses Commit’s native AppKit header integration without a
leading checkbox column. Nine physical text columns retain the source six-column
default: Path, Extension, Status, Lines added, Lines removed and Last modified.
Filename and File size are optional; LFS Lock is offered only with the common
repository LFS marker. The header saves visibility, order and adjusted widths
under WorkingTree.FileColumns, independently of Commit’s layout. Existing saved
LFS visibility migrates on read without rewriting preferences. Path stays visible.

The shared header supports content fitting, automatic header/content widths and
confirmed Reset columns. No retains the layout; Yes restores the six-column
default, clears adjusted widths/order and ownership. Busy and Quit confirmation
block settings changes. All nine headers retain a single ascending/reverse sort
column with path ties. Metadata is read once per refresh, including size/date
and missing paths; dates and sizes use the existing native shared formatting.

Copy to Clipboard offers original-icon Full paths, Relative paths, File/folder
names and Copy all information. Text follows displayed row order; Copy all uses
the saved visible-column order and headings. The shared integration also routes
Command-C/Control-Insert to relative paths, Shift to paths/status, and the clicked
column to single-column copy. Native LF replaces Windows CRLF. Flagged and staged
status text follows the actual table; renamed rows include their source path in
the displayed Path column. Literal names retain tabs/newlines.

See [column QA](qa/working-tree-columns-2026-10-09.json) for current evidence and
limits. Physical pointer/keyboard/context menu input, full status-list menus and
signed sandbox/Finder acceptance remain pending. This is partial dialog parity.

Copy all now retains its heading when Path is the only visible column, using
the shared source command-mask rule. Explicit column/path copies omit headings.
See [menu/copy QA](qa/lfs-menu-copy-2026-10-09.json).
