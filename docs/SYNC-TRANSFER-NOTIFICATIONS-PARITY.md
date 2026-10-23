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

## Source Fetch configuration lifecycle — October 23, 2026

Selected libgit2 Fetch now uses the source command's configuration lifecycle.
The helper loads the remote first, appends the single requested raw fetch spec
with `git_remote_add_fetch`, then fetches through that same loaded object with a
null refspec argument. The current invocation uses its previously loaded specs;
the next invocation sees the appended entry. Repeated requests append duplicate
entries in order, as upstream does. Earlier configured wildcard and negative
specs are retained; an unmatched newly requested branch does not replace the
current invocation's configured updates.

Sync supplies `refs/heads/branch:refs/remotes/remote/branch` for its selected branch,
independently of whether the tracking ref exists. Fetch All branches requests no
addition. The source libgit2 command does not receive Sync's Force setting;
configured `+` refspecs retain their own force behavior. CLI commands keep their
existing per-operation arguments and Force handling. Backend selection remains
captured for the accepted operation, including a Pull whose actual command is
rebuilt as Fetch after checkout or transport preparation.

The helper's private source mode is Fetch-only and accepts at most one raw spec.
It does not rewrite that stored spec or add configuration before loading the
remote. Anonymous URL remotes have no named configuration target: a nonempty
requested spec fails safely before network transport instead of inventing a
remote name. Empty-spec URL handling retains the source's anonymous lookup path.
Successful appends are not rolled back after later authentication, cancellation,
network or follow-up failure. Already received reference rows and actual command
completion retain their existing independent receipts.

The dated [source oracle](qa/sync-fetch-source-oracle-2026-10-23.txt) explains the
pre-implementation difference and demonstrates load-before-append behavior using
the same pinned library. Its original explicit-spec/no-match observations remain
historical evidence, not the current selected source-mode contract. The
[implementation checkpoint](qa/source-fetch-lifecycle-2026-10-23.json) records
validation separately from that earlier notification checkpoint.

Two boundaries remain explicit. All Remotes retains the Mac helper's iteration
over configured named remotes and skip settings; this is an existing adaptation
rather than the pinned caller's empty-URL behavior. Also, pinned libgit2 1.9.4's
`write_add_refspec` can return zero after a failed configuration write, including
a config-lock failure. The port preserves that API outcome; it does not promise
that an entry was persisted merely because the call returned zero. Lookup,
invalid-spec, anonymous-name and transport failures that the API actually returns
remain failures. No additional persistence verification or library patch is
claimed.

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
