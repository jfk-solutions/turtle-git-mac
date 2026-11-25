# Log changed-file primary activation

This is a separate implementation batch after the November 22 native changed-file
report and toolbar-context checkpoint. Model and Root integration now pass the
[connected checkpoint](qa/log-primary-activation-family-2026-11-23.json): one
Debug build and eight native case/Git combinations. A fixture-only missing
assertion-helper dependency was repaired before any receiver case ran; the
failed compile and focused receiver recompile remain recorded. No Core suite
was repeated for these native consumers. All thirteen logged native processes
are absent. This source is not installed or included in signed54.

## Pinned behavior

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d` initializes the Log
changed-file list in `src/TortoiseProc/LogDlg.cpp:308`. The shared
`src/Git/GitStatusListCtrl.cpp` distinguishes these inputs:

- `OnNMDblclk`, lines 2926–2976: activate the clicked file, including editing a
  conflict, comparing unversioned/ignored working content, and selecting the
  appropriate historical parent comparison.
- `OnNMReturn`, lines 3618–3667: confirm the entire selected count once, then
  activate each selected row in list order according to its own status. A mixed
  selection retains conflict editing for its unmerged members. After conflict
  editing, removed or resolved entries trigger the appropriate parent refresh.
- `StartDiffWC`, lines 2996–3023: reset the action flags before working-file
  comparison; unversioned/ignored entries must not inherit added/deleted rules.
- `CheckMultipleDiffs`, lines 4360–4371: the selection-count warning uses
  `NumDiffWarning`, with an effective minimum threshold of three.

The Mac report already distinguishes clicked-row double-click from selected-row
Return. Before this batch its model default action only admitted conflict editing
for a single selected row, so multiple/mixed selections fell through to ordinary
comparison. The old Log conflict handoff also omitted its source preferences while
normal comparisons explicitly retain them.

## Connected implementation scope

`LogFilePrimaryActivation` plans accepted rows in actual report order using exact
Git row IDs, including parent-group occurrences. It captures the working-tree
base, repository backend, source preferences/window, alternate-tool choice,
merge tools and conflict identity options. Its typed actions retain each
conflict, ordinary comparison or unversioned working-file role.

The model owns one `FileListComparisonSession` and selected-count warning around
the complete activation. Its admitted file-navigation activity allows its own
warning and Root preparation while refusing a second source command. Target row
records, original selection, document/control epochs and source window must
remain current; changing raw tool data, conflict identities or diff backend
retires the accepted request. The default navigation-owner contract remains
unchanged for other callers.

Closing, document replacement and selection invalidation cancel the session;
its existing navigation activity and Quit counter remain owned until the async
handoff and actual warning detachment finish. Standalone consumers without the
typed Root callback retain their legacy callbacks.

Explicit **Edit conflict** now uses the same typed primary activation. Quick
**Resolve** choices keep a cancellable preflight/navigation activity through
conflict and rebase-state verification and the synchronous owned handoff. Their
reads use the captured backend and actual cancellation token; the callback
receives the accepted repository before the source activity releases. Conflict
paths follow the report order. Resolve children own their subsequent work.

`showLogPrimaryFiles` executes the ordered plan under a child cancellation token
and an owned Root session with `selectedCount: 0`; only the source model asks the
selected-count question. Ordinary comparisons use the accepted base and exact
selected path. Working-file previews retain their captured current-version
sentinel: the working Log row opens the actual working file on both sides,
including an unversioned copy retained after index deletion. Neither route
queries a replacement HEAD.
Conflict actions verify the captured rebase direction before calling the async
owned conflict preparation API with the original tool and identity settings.

`showOwnedConflictEditor` acknowledges preparation and accepted native/external
launch after its progress window drains. Acceptance is not resolution. The
preparation retains its source token, owner receipt and security lease through
Git reads, public native progress cancellation, parent closure and actual
paired sheet detachment. Both success and error paths await that drainage
before removing the preparation from Root's pending-work registry. External
tool preparation awaits the same detachment before its own permission/launch
handoff. Native editors then own their independent document lifetimes.

Native conflict caches include repository runtime/backend, source preferences
identity and captured index stages. Native changes and accepted external tools
request repository Log refresh; the source Log defers this refresh while its
current file-navigation activation is pending, then services it on returning
to idle. The existing conflict-list refresh preference still controls the
other affected status/commit/Resolve lists. Quick Resolve receives the
accepted repository and source preferences through its existing owned child
handoff. Existing comparison and merge-tool implementations remain the content
renderers.

## Remaining limits

The [working-row continuation](LOG-WORKING-ROW-AFFORDANCES-PARITY.md) now
uses the backing raw index/worktree status for Missing/Added/Deleted captions,
color priority, physical-content actions and comparison eligibility. It skips
missing added/renamed/copied rows in primary activation while preserving the
original warning count and selected order; plain deleted/missing rows still
compare. The macOS retained-copy row keeps one path identity, which remains an
explicit adaptation from separate upstream deletion/unversioned rows. Its
[scoped checkpoint](qa/status-activation-family-2026-11-23.json) passed with both
Git engines; it does not certify the complete Log dialog.

Source review does not establish a missing automatic multi-commit Log file
list. `LogDlg.cpp:793–806` clears the views and `1041–1050` leaves them empty
for multiple selections; its deduplication comment has no implementation.
`m_Rev1/m_Rev2` are wired by `SyncDlg.h:186–198`, not by Log. Existing Mac
explicit revision comparisons remain the appropriate separate workflow.
Likewise, upstream unversioned rows come from `ls-files --others` rather than a
generic directory-diff workflow. No new folder comparison is inferred here.

The checkpoint uses injected selected-count answers and external execution,
actual private Git conflicts, native table Return, real text children and
resolution, plus retained routing/command/image ownership. The safe SDK fixture
holds the async prepared boundary before acknowledging its injected launch;
actual Word/LibreOffice applications and permission dialogs remain unexecuted.
Physical input, VoiceOver, signed Finder/platform execution and complete upstream
dialog parity remain separate acceptance scopes.

## Event modifier capture — November 25, 2026

The native changed-file table now captures Shift from its Return event before
starting comparison. It does not depend on the keyboard state after that event.
The selection plan retains this choice through the warning and asynchronous reads.
The regression uses a real Shift+Return event and separately checks repository,
preferences and alternate-tool capture.
