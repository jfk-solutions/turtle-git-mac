# Dragging files from revision lists

This family follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. It covers file delivery from
Changed Files, Log's changed-file list, Rebase's Revision Files, and the incoming
and outgoing Synchronization file lists. Repository Browser has a separate
existing drag implementation.

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
