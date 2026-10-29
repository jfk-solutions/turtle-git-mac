# Dragging files from Git lists

This family follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. It covers file delivery from
Changed Files, Log's changed-file list, Rebase's Revision Files, and the incoming
and outgoing Synchronization file lists. Repository Browser has a separate
existing drag implementation.

The [raw historical-file continuation](RAW-HISTORICAL-FILE-TRANSFER-PARITY.md)
connects raw namespace identities to safe native promised filenames across the
historical Log/comparison consumers and Browser. Working-tree URL delivery remains
strictly representable; an empty endpoint remains text-only. Its implementation
and checkpoint are separate from the earlier ordinary-name evidence below.

The October 23 continuation also connects the shared working-file list used by
Commit, Working Tree and Add; its scope and evidence are recorded below.

## Source contract

`FileDiffDlg.cpp` 1425–1463 creates `GitDataObject` with the selected paths and
`m_rev2`, the comparison target. The shared `GitStatusListCtrl.cpp` 3766–3806
uses `m_Rev2` when present, otherwise `m_CurrentVersion`. `LogDlg.cpp` 1025
sets the latter to the selected commit; `RebaseDlg.cpp` 2943 uses the selected
revision. Log clears the file list before processing selection and fills it
only for a single commit (`LogDlg.cpp` 808, 850–1048). A combined native Log
selection without a single captured revision therefore cannot offer a historical
file drag.

Synchronization deliberately has a different revision convention:
`SyncDlg.h` 186–198 stores `AddDiffFileList(new, old)` as `m_Rev1=new` and
`m_Rev2=old`. Incoming (`SyncDlg.cpp` 537) and outgoing (1438) drags therefore
read the comparison's **base**, not its target. A newly added or renamed path
absent at that base fails delivery. Substituting the new revision or old filename
would change upstream behavior.

`GitDataObject.cpp` 115–205 provides delayed `GetOneFile` contents for a
historical hash and actual working-file URLs for the zero/empty hash. It skips
missing/deleted files and directories. The default `stripLength=-1` uses each
leaf filename (177), rather than recreating a relative directory tree. Separate
selected occurrences with the same leaf name must remain separate items. Log's
merge-parent group headers are not files; repeated file occurrences in separate
parent groups retain their own identities.

The source advertises preferred copy (233) while the initiating controls permit
copy and move. Native historical delivery creates private copies; no repository
file or index entry is moved. Physical modifier and cross-application move
semantics remain a separate acceptance requirement.

## Native implementation

`FileListDragPlan` captures an already resolved 40- or 64-character object hash,
literal paths in display order, leaf names and the selected materialization
backend. It rejects symbolic references such as `HEAD` rather than resolving
them later when another application requests content. Working-tree plans offer
the actual file URL. Historical plans materialize each occurrence independently
through the existing filtered `GetOneFile` policy, preserving executable mode
and representing historical symlinks as regular files containing their link text.
Deleted/missing rows, directory entries and gitlinks cannot offer file contents.

The native providers retain the originating repository access lease and accepted
backend independently of their source window. Closing or changing that window
prevents new drags but does not retarget an already accepted delivery. Actual
provider requests count as application-owned work before dispatch to the main
actor, so Quit cannot race a queued read. Item-provider cancellation reaches the
materialization operation. Private historical copies belong to their providers
and are removed when released or during application termination.

SwiftUI file tables retain their native columns, selection and menus and attach
item providers to file rows. Synchronization's AppKit tables use native file
promise writers for historical items and file URL writers for working files.
Promises write to receiver-supplied destinations with exclusive coordinated
delivery and a Foundation-owned same-volume replacement workspace. Existing
destinations are preserved, including a collision between
two equal leaf filenames; the receiving application controls destination naming.

This adds delivery behavior to the existing tables without introducing another
dialog, setting or column layout.

## Grouped checkpoint and acceptance still required

### Working-file list continuation — October 23, 2026

Pinned `GitStatusListCtrl.cpp` 3767–3804 starts a drag from the highlighted rows;
`FillListOfSelectedItemPaths` preserves their list order. `GitDataObject.cpp`
284–315 supplies real working-file paths, excluding missing/deleted files and
directories from file delivery. Its text representation retains selected paths
independently of file eligibility. Checkbox membership belongs to Commit/Add,
not to this selected-row transfer.

The native continuation connects the existing working-file transfer contract to
Commit's classic/staged/unstaged tables, Working Tree and Add. Repository,
selected rows and access are captured at the gesture. New gestures obey the
originating owner's operation/Quit/retirement gates; accepted writers retain
their captured access until the receiver releases them. Group/checkbox/header
gestures keep their existing native behavior. An originating list refuses its
own incoming drag rather than inadvertently launching a second Git operation.

[The connected checkpoint](qa/working-file-drag-2026-10-23.json) records actual
validation, repairs and remaining acceptance. It does not certify physical
multi-file gestures, other applications' move/copy behavior or signed Finder
delivery. No new setting or icon is introduced by this continuation.

All six functional case/engine pairs pass for Commit, Working Tree and Add.
The native adapters/datasource retain display order and checkbox independence,
offer mixed text/file and text-only selections, reject new gestures through
busy/Quit/sheet/retired owners, and reject same-origin drops. Captured providers
deliver after normal source closure. A separate call through the same shared
helper releases its caller's private lease and receipt before loading the
retained provider, proving permission retention without a controller holding it.

An earlier fixture incorrectly required Cocoa controller/model deallocation as
the source-close condition. That strict diagnostic still fails in the headless
receiver and remains opt-in; its failures and reference scans are retained.
The functional checks require closed/retired source ownership and drained work,
and do not claim natural Cocoa object deallocation. Reference scans alone do not
establish an ARC cycle. Pasteboard sandbox-extension diagnostics from unbundled
receivers are also retained; these checks do not establish signed grant delivery.

### Historical-list checkpoint — October 21, 2026

The [October 21 checkpoint](qa/file-list-drag-2026-10-21.json) passes six focused
Core methods, the Debug app build, and all six native case/engine combinations
(lists, delivery and ownership with system and bundled Git). Core was run once
with system Git. The six methods include both raw and filtered historical reads,
exact Unicode identities, repeated leaf names, historical modes/link text,
working URL containment, exclusions, cancellation and repository invariants.

Native checks exercise actual item-provider callbacks, AppKit Sync datasource
writers and file-promise delegates, captured comparison/Log/Rebase deliveries,
live working-file URLs, incoming/outgoing base revisions, stale/busy/Quit/closed
owners, exclusive receiver destinations, repeated loads, retained access leases,
captured filtered output, actual held filter cancellation and process reaping.
The shared exclusive writer also receives a retained Browser delivery check.
Rebase uses its real parent/embedded models with an installed snapshot; this is
not a physical Rebase window drag. SwiftUI row bindings compile in the app; their
physical multi-row gesture behavior remains below.

The first receiver compile failed on fixture actor isolation and a read-only
Sync busy setter. Running the real Refresh workflow replaced that assignment.
Subsequent list attempts exposed the fixture's use of the selected-file API with
an empty selection; the whole-comparison API fixed that setup. Production was
unchanged by these repairs. All nine owned receivers, including failed attempts,
were reaped and independently absent. Existing AppKit reentrant-table and
pasteboard sandbox-extension diagnostics are retained in the record. No full
Core suite or screenshot cycle was repeated for those fixture changes.

Physical multi-file drag gestures, destination naming in other applications,
modifier/move behavior, VoiceOver, installed sandbox grants and signed Finder
delivery remain open. Focused provider or delegate checks cannot certify those
behaviors, full visual parity, or the entire port. Full current hosted integration
and App Store distribution acceptance are independent release gates.

## Log highlighted-selection continuation — October 23

This implementation continuation follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`:

- `LogDlg.h`'s `m_ChangedFileListCtrl` uses `CGitStatusListCtrl`;
  `LogDlg.cpp` installs the selected child commit in `m_CurrentVersion`.
- `GitStatusListCtrl.cpp`, `FillListOfSelectedItemPaths` and `OnBeginDrag`,
  collect highlighted rows in displayed order, independently of checked rows,
  and construct `GitDataObject` with the current materialization revision.
- `GitDataObject.cpp` offers every selected path through newline-separated text
  and filters deleted/missing/directory occurrences out of file delivery. Its
  historical file descriptors are distinct occurrences, including repeated names.

The Log changed-file table now starts one native multi-item gesture from its
actual highlighted rows. The previous row-only SwiftUI item-provider route
could offer only its individual row. `LogFileDragInteraction` observes the
installed AppKit table without replacing SwiftUI's datasource, selection,
column handling or context menus. A group/header cannot originate a file drag.
The model validates current selected row identities and operation/owner state
before accepting the transfer.

`LogFileListDrag` captures literal paths in displayed order, the exact selected
child hash or working-tree identity, backend and repository grant. Parent-group
occurrences retain that same child hash and remain distinct. A combined
multi-commit file union has no single recorded source revision; it remains
unavailable rather than choosing an arbitrary selected hash. A history range
filter does not change the exact selected child's materialization identity.

The aggregate text representation contains all selected paths, including rows
which offer no file contents. It uses native relative POSIX paths with CRLF
separators. A separate native text item accompanies the file items; eligible
historical occurrences use the existing real file-promise writers and item
providers, while working occurrences offer their existing, validated URLs.
A selection containing only excluded rows remains a text transfer. The shared
Core transfer plan owns path validation and materialization; this continuation
introduces no alternate filesystem or Git reader.

Historical promises allow copying. Working URL gestures allow copying or moving
with native modifier handling; the source performs no additional deletion.
New gestures are fenced by busy, child/modal, Quit, changed selection and retired
owner state. An accepted native session retains its source and transfer receipt
until AppKit's terminal callback, so closing the Log window cannot revoke or
retarget an already accepted delivery. Actual provider work retains the shared
cancellation, queued-work accounting and exclusive receiver-write behavior.
Log has no inbound file-drop operation, so its own outgoing payload cannot
recursively trigger a Log mutation.

All six grouped native case/engine pairs passed in the primary worktree:
historical, history-range-filter and working-tree cases with system and bundled
Git. The installed native adapter/table-selection, multiple promise and text/URL
delivery, owner gates, independent caller-grant/helper retention, and unchanged
repository assertions passed. All six receivers were reaped and independently
absent. The Debug build exited zero while emitting 34 contradictory generic
exit-zero compiler diagnostics and existing warnings. Core transfer production
was unchanged and its suite was not repeated for this continuation. The
[dated Log evidence](qa/log-file-drags-2026-10-23.json) records exact scope,
PIDs, diagnostics and limits. Cocoa source deallocation was not used as a grant
independence proxy; the earlier working-drag qualifications remain unchanged.
Remaining acceptance includes physical multi-row gestures and header
behavior, destination naming/acceptance in other applications, copy/move modifier
behavior, VoiceOver, installed security-scoped grants, signed Finder delivery,
full hosted integration and full application parity. These limits also apply
to the new Log continuation independently of earlier family checkpoints.


## Connected revision and conflict lists — October 23, 2026

This continuation implements a complete related outbound list family before its
grouped native checkpoint. It does not certify physical drag interoperability.

- Changed Files uses `CFileDiffDlg::OnLvnBegindrag` (`FileDiffDlg.cpp:1425–1468`):
  every highlighted filtered/displayed row, with the immutable second/destination
  revision. Its shared native list also serves Rebase Revision Files.
- Rebase selects the commit hash for historical rows (`RebaseDlg.cpp:2927–2944`)
  and clears the revision for replay/conflicts (`1331–1335`). Paused Conflict Files
  therefore offer existing working-file URLs, independently of checked actions.
- Synchronization installs new/old endpoints as Rev1/Rev2 (`SyncDlg.h:186–198`).
  Shared status-list dragging chooses Rev2 before CurrentVersion
  (`GitStatusListCtrl.cpp:3767–3805`), so Incoming/Outgoing retain the old/base
  endpoint. Conflicts use working files.
- `FillListOfSelectedItemPaths` (`3595–3609`) uses highlighted displayed rows.
  `GitDataObject.cpp:253–275` provides every path as CRLF text while content
  eligibility excludes missing/deleted/directory/gitlink rows. No alternate
  revision or current index is substituted for a failed historical promise.

A synthetic empty-tree comparison endpoint offers validated path text only; it
has no file contents and cannot fall back to working files or another revision.
This is the native empty-endpoint adaptation, distinct from source working-copy
revision markers.

The shared `FileListSelectionDrag` retains the existing bounded plan,
materialization, independent file occurrences, writers/providers and repository
lease. Log retains a compatibility alias and thin native adapter. The common
adapter captures native selected indexes only when its displayed rows and source
context still match; popup/marked-row changes are separated from the drag context
so ordinary mouse-down highlighting does not cancel its own gesture. Context,
sort/filter, owner retirement, pending work, modal sheets and Quit remain fenced.
Accepted native sessions retain their source and receipt until AppKit completion.

Synchronization captures one aggregate transfer through its actual AppKit table.
Its existing per-file helper remains available to earlier callers. Conflict
lists reuse the existing working-file receipt and interaction machinery, retaining
same-origin refusal where an incoming-drop route exists.

[Grouped native evidence](qa/connected-file-drags-2026-10-23.json) records 24
passing case/engine pairs: standalone Changed Files (historical, working,
ownership), embedded Rebase (historical, paused conflicts), Synchronization
(Incoming, Outgoing, Conflicts, ownership), and the affected Log adapter. Every
case used system and bundled Git, private repositories/preferences and invisible,
strictly offscreen windows. All 25 receiver attempts, including one fixture
selection timeout, were reaped and independently absent. Two fixture compilation
failures started no receivers; all repairs and affected-only checks remain in the
record. Actual adapters/data sources, promise delegates and retained provider
contents were checked; physical AppKit drag sessions were not certified.

One Debug build exited zero, with 24 contradictory generic “failed with exit code
0” diagnostics retained. No Core production code, controls or labels changed,
and no full Core or unaffected native suite was repeated. Signed grants,
physical modifier/move behavior, destination naming, VoiceOver, current hosted CI
and full upstream visual/format parity remain separate acceptance work.
