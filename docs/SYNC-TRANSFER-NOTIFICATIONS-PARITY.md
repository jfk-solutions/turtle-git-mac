# Synchronization Fetch reference-result log

Source baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`SyncDlg.cpp` Fetch dispatch, `ProgressCommands/FetchProgressCommand.cpp`,
`RemoteProgressCommand.cpp::RemoteUpdatetipsCallback` and
`GitProgressList.cpp` result menus, copying and Action/Path columns.

## Selected transport and execution

Synchronization's Log tab uses the shared Action/Path result table when its
actual Fetch command uses the optional libgit2 backend. The global switch and
Fetch command-mask bit retain the source defaults: ordinary CLI Fetch remains
the default. The choice belongs to the accepted operation and its actual command,
including a Pull that resolves into Fetch followed by Rebase after checkout and
transport preparation. Changing Settings during a running attempt does not
retarget its backend or presentation.

Core delivers typed reference updates separately from textual diagnostics.
Text that resembles an update is not parsed into an actionable result. Callback
buffers drain before the actual command-completion receipt; metadata and Rebase
follow-up work retain their separate operation lifetime and outcome. Existing
checkout continuations preserve the same notification contract.

## Results and actions

The Action column contains Update ref. Path preserves the reference name,
abbreviated old/new hashes and the source change classification: Same, New,
Deleted, Forward/Rewind counts or relative committer time for divergent history.
Full hashes and producing repository identity remain in the row's immutable
payload. Classification is supplied by the existing typed transfer protocol.

A completed selected reference row offers **Show Log** and the shared Copy
commands. Show Log uses the captured full old/new endpoints, omitting zero
endpoints as the source does. Later movement of the named reference cannot
retarget that Log request. The child retains the initiating window's appearance,
preferences and repository permission. File Open/Explore and double-click file
actions do not apply to reference rows.

Context Copy retains the source Path-column behavior; keyboard Copy includes
Action and Path, and Select All/keyboard Copy remain available while work runs.
Completed-result actions wait for actual operation settlement and are blocked by
owned sheets, competing children, Quit and retired windows. Sorting retains the
shared result table's auxiliary-row boundaries and transient Action/Path sizing. The pinned progress list has no saved-column manager; no new persistent column settings are introduced.

Failure and cancellation retain updates already reported by the backend. A new
attempt starts a fresh result set and retires old menu receipts. Notification
framing warnings remain visible without claiming that a successful reference
mutation was rolled back. CLI operations retain the rich text log, styled
completion and existing progress/recovery behavior. Main Sync does not gain a
new persistent Action log; its source does not write that transcript through the
standalone Git Progress dialog's action logger.

## Remaining fetch-refspec lifecycle difference

The pinned Windows command loads a named remote, appends its selected fetch
refspec to repository configuration, then fetches through the already-loaded
remote with a null refspec argument. Its existing configured refspecs therefore
determine that invocation's rows. The current Mac transport supplies its selected
refspec per operation and leaves that configuration unchanged. Porting the source
configuration/refspec lifecycle remains a separate concrete gap; this notification
integration does not certify it.

On the current Mac backend an unchanged explicit refspec may produce no callback,
whereas configured Fetch All can report Same. An unmatched explicit refspec can
settle successfully with no reference rows. The log preserves the actual backend
receipt and does not invent a failure or an update. Real unavailable-remote
failure is checked separately.

## Verification and limits

The [dated grouped checkpoint](qa/sync-transfer-notifications-2026-10-23.json)
records actual Core and native checks, source comparisons, failures, repairs,
reviewed captures and owned-process cleanup. The native group uses private local
repositories and the actual pinned transfer helper; injected held replies cover
otherwise nondeterministic ownership/cancellation boundaries.

This family does not certify every Synchronization control or transport provider.
Public authentication, physical pointer/keyboard/VoiceOver, complete Windows
layout/font identity, installed signed grants, minimum-version/Intel and a full
current hosted CI pass remain separate acceptance requirements.
