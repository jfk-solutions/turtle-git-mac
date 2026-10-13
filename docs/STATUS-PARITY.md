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

- Full GitStatusListCtrl menus: submodule-specific handoffs, groups/changelists
  and complete marked-row enablement. Revert/conflict/index flags are available;
  file history/Blame/export/editor/Open/deletion now have native routes below.
- Full conditional Stash/Switch menus and post-operation behavior; the dedicated
  dialog ports remain partial.
- Remote status checking and complete displayed/signed acceptance. Refresh ownership,
  cancellation/progress, F5, source filter persistence and selection restoration
  are implemented in the October 14 lifecycle batch below. Window geometry uses
  the shared native persistence.
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

## Exact status row color roles

Working Tree applies the pinned default CColors role to all nine text columns,
with source combined index/worktree priority and semantic selected text. Rename
is distinct from modification; unversioned/ignored/normal rows stay neutral.
See [Appearance](APPEARANCE.md) and [status color QA](qa/status-colors-2026-10-09.json).
Native RGB/appearance resolution is checked separately from current pixel and
accessibility/contrast acceptance.

## Working Tree operation family — October 14, 2026

ChangedDlg's refresh/F5/cancel flow and saved AddBeforeCommit,
ChangedFilesIncludeStaged and repository-specific ShowWholeProject choices now
have native counterparts. Ignored/local-change flags remain session choices,
as in source. Scoped reopening restores Whole Project; an unrestricted root
forces it on without overwriting the scoped choice. Changing filters retains
visible selections. The empty table uses the source explanation of settings.

Refresh reads status, branch, rebase state, submodules, LFS availability, metadata
and line statistics into a replacement snapshot before publishing. Failure or
cancellation preserves the previous table, selection and branch. LFS owner reads
remain separately optional and cannot overwrite a retired window. Refresh,
Stage/Unstage, index flags, diff export/viewer preparation and column reset share
owned cancellation/lifetime accounting. Current work and a cancellable progress
control remain visible while the table is disabled. Close requests cancel and
wait; forced retirement cancels work and fences late state, panels, viewers and
preferences. Quit protection survives removal of the owner window.

Core cancellation now reaches Unstage's HEAD inspection and actual mutation,
diff HEAD inspection and diff child, and every private-index flag command.
Cancellation cannot be swallowed as an unborn HEAD; private index flags check
cancellation before replacing the real index and remove their temporary lock
on failure. Completed Git mutations are retained rather than claiming rollback.

Debug compilation and all ten affected Core checks have passing evidence.
The new lifecycle and existing LFS/column receivers passed with both system
and bundled Git; all four receivers were reaped. Only the actual failing Core
fixture was repeated. See [results and repairs](qa/working-tree-lifecycle-2026-10-14.json). Remote status, physical scrollbar/keyboard/panel
acceptance, signed security scopes and full status-list/menu parity remain open.

## Captured file-menu workflow family — October 14, 2026

The pinned GitStatusListCtrl's working-copy menu supplies two-file comparison,
single-file Log/old-name Log/Blame, Export, alternative editor, Open/Open With,
Explore and Delete. Working Tree now exposes these with the original source
icons and explicit row gates. Missing tracked files retain historical Blame
and Delete but do not offer Open or Export. Unversioned/ignored rows omit
Log and Blame. Directories/gitlinks omit file editors and two-file comparison.
The ChangedDlg mask excludes Save As, Restore and Prepare Diff; this batch
does not add those excluded commands.

A snapshot retains displayed row order, exact status records, the focus mark
and a generation. The mark can sit outside the highlighted set, as in source;
it controls Delete eligibility while the highlighted paths remain its targets.
Selection-away/return, filter changes and refresh invalidate
old menus. Existing Stage, flags, Ignore, Resolve, clipboard and comparison
closures also check that snapshot before dispatch. The shared native Delete
key integration accepts an unversioned/ignored focus mark; context Delete
also supports a missing tracked mark. Shift requests permanent deletion.

Open With and Export use dialog-owned native panels; deletion uses a default-No
confirmation. Their pending responses retain operation/Quit ownership, repeat
the snapshot gate and refuse late responses after retirement. External launch
and editor errors use the shared operation diagnostics. Export retains working
contents and relative paths independently of staged contents; directories are
skipped by the shared source-compatible exporter. Deletion retains the shared
fresh-status/index preflight, Trash behavior and partial-outcome diagnostics.
All deletion Git inspections/private-index commands are now cancellable.
Successful or failed deletion refreshes the table while retaining its error.

Debug and all 17 affected Delete/Export Core tests passed. The file-menu and
existing LFS/column receiver families passed with system and bundled Git after
an obsolete Delete-key expectation was updated and outside-highlight focus
marks were retained. The initial system-Git lifecycle regression also passed;
it was not repeated. All seven initial/final receivers were reaped. See
[results and limits](qa/working-tree-file-menu-2026-10-14.json). Actual application/editor launches, physical panels,
Trash/Finder appearance, signed grants and full status-list parity remain open.
