# First-use history and reference Services

The expanded public Services registration described below is historical.
Current commands appear in Finder’s **TurtleGit** submenu; the system Services
menu advertises only **Open in TurtleGit**. The typed handlers and eligibility
checks below remain in use. See [current Finder delivery](FINDER-SERVICES.md).

This batch connects five existing native workflows to selected-item macOS
Services outside previously watched Finder roots. It does not certify their full
dialog parity or physical Finder integration.

## Pinned source and selection

The source revision is `7338078f8ddd924b8cddee35f512f2286072136d`:

- `src/TortoiseShell/MenuInfo.cpp:84–97` defines RefLog, RefBrowser, Daemon,
  RevisionGraph and RepoBrowse. RefLog/RefBrowser use folder-in-Git plus ONLYONE
  or a bare-repository context. RepoBrowse adds ONLYONE to its bare clause.
- Daemon/RevisionGraph retain the Log clauses: one tracked item excluding Added,
  one folder-in-Git excluding Added, or a bare repository.
- `src/TortoiseShell/ContextMenu.cpp:1414–1453` dispatches those existing commands.
  `FinderShellRules` already models their conditions. The new Services invoke
  that shared oracle against fresh authorized metadata rather than a badge cache.
- `src/Git/GitStatus.cpp:741–745`, `AdjustFolderStatus`, maps aggregate added or
  deleted folder status to modified. Parent aggregation now follows that rule;
  selected file/gitlink leaf states and exact overlay entries stay distinct.
  A folder containing added files therefore retains its graph/daemon commands
  while an individual added file remains ineligible.

The five declarations append to the previous forty-two, preserving their order.
RefLog, Browse references and Repo-browser advertise `public.folder`; Revision
Graph and Daemon advertise `public.item`. Every new Service requires one explicit
normalized item. This is a macOS Services adaptation: there is no independent
Explorer background-folder context. Multiple selected roots are refused rather
than arbitrarily choosing the first. There is no new restriction based on merge,
bisect or HEAD beyond the source clauses.

The private Services pasteboard, literal Unicode/path spelling, typed URL envelope,
request bounds and cold/standalone startup ownership remain shared with the other
Services. Generic provider dispatch resolves the new command enum cases. A URL
carries a selection, never repository authorization. An owned chooser or existing
primary repository grant must cover it before discovery. Linked metadata grants
do not substitute for a containing repository grant. Mixed repositories cannot
silently retarget an accepted operation to the workspace's current root.

## Native workflow family

The selected command opens the existing RefLog, Browse References, Repo-browser,
Revision Graph or Daemon window. It retains source artwork, native controls,
menus, configuration and Git operations. RefLog begins at HEAD and the browsers
retain their existing revision navigation. Graph uses its configured graph font
and source display settings. Daemon retains warning/Proceed/Abort, the saved
warning decision and actual owned server progress; Services does not introduce a
second execution path or change its default listen interfaces.

The implementation batch includes captured repository/access/preferences,
existing-window reuse eligibility, actual native presentation, asynchronous child
handoffs and owner/cancellation/Quit drainage. A retired cached controller cannot
be shown again while old work drains; old callbacks cannot remove a replacement.
An accepted workflow remains attached to its original repository if the workspace
opens a different one. Closing or cancelling preparation fences late authorization
and does not create a child window. Actual workers and sheets remain owned through
completion even after forced UI closure.

macOS manages Services visibility and ordering and supplies no supported per-entry
Explorer-style icon field. Finder Sync continues to use the existing source icons
and menu placement inside watched roots. Native windows retain their icon-bearing
menus. This batch does not add right-drag interception.

## Validation and remaining work

The [dated checkpoint](qa/finder-history-services-family-2026-10-21.json) records
67 distinct Core methods and eight native scenarios passing across the recorded
focused repairs. The original 43-method request/source group passed first;
the confirmed folder-state defect then received its new regression and affected
collection/query/status-policy checks, 24 methods. Passed unrelated groups were
not repeated. The initial app compile needed the Branch/Tag pending-work accessor;
the first exit-zero repair log retains contradictory compiler diagnostic noise.
The final affected build exited zero without those messages.

The new native provider passed before routing exposed the folder aggregation bug.
Fixture repairs corrected Swift visibility/preference access and supplied the real
built graph helper to the unbundled receiver. Source gates, geometry, parent/child
ownership and actual worker assertions were retained. Only failed or unrun groups
repeated. All five actual dialogs, bare/tracked/added/untracked scopes, accepted
preferences/grants, later Log actions, actual Filter/Save sheets, real held Git
reads, historical Save writing and a socket-free injected Daemon runner were
checked. The original provider and older graph-save ownership cases also passed.

All ten receiver attempts, including failures, are independently absent. Private
helper identities are verified before any cleanup; cleanup needed after a success
fails the check. No new screenshots or installed app activation were performed:
these are hidden/offscreen workflow checks of existing native dialogs. Source and
built declarations match all 47 entries and bundled Help matches its saved bytes.
Earlier Services/dialog checkpoints do not independently certify this family.

Physical Services activation/menu gestures, signed sandbox grants, minimum macOS
and Intel execution, keyboard/VoiceOver/complete layout acceptance, current hosted
CI and App Store distribution remain separate gates. Deferred arbitrary-file
comparison and patch/export delivery Services remain outstanding first-use
workflow families; their existing in-app operations are not claimed missing.
