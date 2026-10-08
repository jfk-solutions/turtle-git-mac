# Clean port

The Clean workflow is incomplete. Native options and progress windows now connect
to Core preview and accepted-plan execution from the main app menu and file context
menu. Finder command construction and the app URL route now include Clean; activated
Finder handoff, displayed acceptance and external sandbox grants remain pending.

## Pinned behavior

At upstream commit `7338078f8ddd924b8cddee35f512f2286072136d`,
`CleanTypeDlg.cpp` and `IDD_CLEAN` provide three radio choices: all untracked files
(`-fx`), non-ignored untracked files (`-f`) and ignored files (`-fX`). Directory
removal defaults on and is remembered per repository together with the type.
Disabling directories clears the additional force switch for unmanaged nested
repositories. Dry run and Submodules default off. Trash is the default unless
`RevertWithRecycleBin` disables it.

`Commands/CleanupCommand.cpp` adds `-n` for dry runs and Trash planning. It cleans
selected folders (or file selections’ containing folders), optionally traverses
initialized submodules, and exposes Retry plus Trash/permanent-delete actions after
a successful dry run. These behaviors are connected in the native app; displayed
and signed acceptance still needs verification.

## Current Core reader

`GitRepository.cleanPreview` runs only `git clean -n` with literal argument-array
scopes, optional directory removal and the selected type. A second force flag
permits previewing unmanaged nested repositories only when directories are enabled.
Its default is all types with directory removal and nested-repository protection,
matching the dialog’s initial choices. The caller must adapt Finder file selections
to containing directories; this low-level reader accepts literal scopes directly.

The reader forces quoted Git output without changing saved config and decodes
C-style escapes and octal UTF-8 filename bytes. It retains raw output and candidate
order, including trailing directory slashes. Skipped-repository messages are not
candidates. Absolute/escaping/admin-directory scopes, bare repositories, canceled
reads and unrecognized or invalid-UTF-8 candidate names fail. No files are removed.
Optional index locking is disabled for the read.

Real-Git tests cover all three modes, directories, a protected nested repository,
explicit unmanaged preview, ignored files, Unicode/newline/quote/backslash names,
pathspec-looking literal names, `core.quotepath=false`, cancellation and rejected
scopes/bare repositories. They compare exact HEAD, index, config and working-file
bytes. See [the preview QA record](qa/clean-preview-2026-10-07.json).

## Accepted-plan execution

`executeClean` defaults to Trash; permanent deletion requires an explicit choice
from the caller. Native callers must confirm the action and retain repository
access. The preview captures SHA-256 content fingerprints and filesystem metadata
for regular files, directory trees and symlink targets without following links.
Execution refuses a foreign repository plan, takes an exclusive index lock, and
reruns the preview before removing any candidate. Changes in candidate paths,
tracking state or directory contents require a new preview. Each candidate is
rechecked immediately before removal. HEAD and index contents are never written.

Trash failure never falls back to permanent deletion. Cancellation and removal
errors return completed paths, recovered Trash URLs and the path where cleanup
stopped. Completed permanent deletions cannot be rolled back. Filesystem checks
and removal remain separate operations; this is not an atomic filesystem snapshot.
Recursive fingerprints read candidate contents in cancellable 64 KiB chunks and
can add substantial work for large cleanup folders. Non-UTF-8 names and special
file types currently fail instead of being removed.

Six real-Git tests include actual recoverable Trash of binary files, directories
and an outside-target symlink, selective permanent ignored-file cleanup, explicit
unmanaged-repository removal, changed folder contents/newly tracked paths, foreign
plans, owned preexisting lock preservation, pre/mid-operation cancellation and an
injected Trash failure without deletion fallback. Owned Trash items are removed
after their recovered contents are checked. See
[the execution QA record](qa/clean-execution-2026-10-07.json).

## Recursive submodule batches

`cleanBatchPreview(includeSubmodules: true)` discovers registered initialized
checkouts from the index and `.gitmodules`. Selected containing folders include
matching children; selected children then include all their initialized descendants.
The low-level API also accepts an exact child-checkout scope. Finder file selection
and nearest-repository resolution still need their native adapter. Uninitialized
or deinitialized directories are skipped. Symlinked checkouts and a checkout whose
Git top-level resolves elsewhere are refused. Discovery and shared submodule path
reads now accept owned cancellation.

The parent preview is first, followed by child paths in deterministic order. Each
child gets its own whole-working-tree preview. Entries already covered by an
ancestor’s unmanaged-directory removal are omitted to avoid executing against a
checkout just removed by its parent. Each entry exposes required checkout, Git-dir
and common-dir locations for future native access-grant checks; exposing these
locations does not establish signed sandbox access.

Batch execution rechecks all registered/initialized roots, administrative locations
and candidate contents before its first removal. It then uses each repository’s
existing accepted-plan executor. Later failure reports completed repository results
and any current partial result, including recoverable Trash URLs. Locks are per
repository, not a transaction across the whole tree; completed work remains when
a later child fails. Native callers must retain every required access lease.

The real submodule fixture uses local submodule add/update, Git files, initialized
grandchildren, a deinitialized checkout, Unicode/newline checkout names and mixed
tracked index/working changes. Tests cover scope exclusion, administrative locations,
exact index/config/HEAD/working preservation, changed child/topology refusal before
parent removal, symlink refusal, actual parent Trash recovery after a locked child,
and removal of a former submodule without duplicate execution. See
[the submodule QA record](qa/clean-submodules-2026-10-07.json).

## Native implementation

`CleanWindow.swift` preserves the radio/checkbox order from `IDD_CLEAN`, with macOS
Trash wording, native radio controls and OK/Cancel/Help. Only cleanup type and
directory removal are saved per root on OK. Dry run, Submodules and unmanaged
repositories reset; Trash reads the shared `RevertWithRecycleBin` preference.
Disabling directory removal clears and disables the extra force checkbox. Files
map to their containing directories; root selection dominates, and invalid paths
are rejected before adaptation.

A separate owned progress window previews or executes cleanup. A successful dry
run offers Trash and permanent deletion in the selected preference order. Each
post-action takes a fresh plan. Retry repeats the last attempted action. Cancellation
belongs to the current attempt; closing a busy window requests cancellation and
waits for completion. Live output retains Git preview text and completed/partial results,
including recoverable Trash locations. Finished mutations refresh open repository
views. The parent access lease is retained throughout; Store builds refuse cleanup
unless it covers every discovered checkout/Git/common directory. This refusal does
not implement acquiring external grants or prove signed sandbox traversal.

The headless native receiver creates owned hidden windows and private preferences,
then closes them. It checks actual dry-run, permanent deletion, recoverable Trash,
lock/Retry and cancellation behavior, together with unchanged tracked/index/config
bytes. It does not establish displayed light/dark, keyboard or VoiceOver acceptance.

## Finder routing

Clean uses the shared `RepositoryAction.clean` command, original cleanup icon and
pinned shell condition requiring both a folder and a folder inside a working tree.
Its “Clean up…” label follows `resourceshell.rc`, and it follows Revert in the
same source menu group. File-only selections, outside
folders, bare roots and administrative `.git` paths do not expose it. Existing icon
preferences apply. The menu captures the selected folders in a `turtlegit` URL;
the app retains its existing permission gate, discovers the nearest checkout and
passes literal root-relative paths into the native options model. Clean on an
initialized nested checkout stays in that checkout, rather than changing to its
parent as parent-index operations do. Mixed-repository selections retain the
existing rejection. Direct app/file requests still use containing-folder adaptation.

Core tests verify Unicode/newline/punctuation request round-trips and nearest
checkout discovery, and the hidden native receiver passes a decoded Finder request
into the real options model. The actual Finder menu builder is checked against the
independent pinned source order. These checks do not activate Finder or verify a
signed app handoff. See [the Finder routing QA record](qa/clean-finder-2026-10-07.json).

## Live cleanup progress

`CleanProgress` reports the repository root, literal relative path, started/finished
state and completed/total item counts. A directory candidate counts as one item.
Events begin after lock acquisition and accepted-plan revalidation; preflight or
lock failure emits no removal events. Started events precede fingerprint/removal,
and cancellation is checked again after the callback. Finished events count only
successful removals. Recursive batches translate each checkout's count into one
whole-batch total while retaining the original repository and path.

The native model drains an owned asynchronous event stream before ending its busy
lifetime. It updates the current path, determinate progress and completed output
while the operation is running. Cancellation keeps the Cancelling message, and
Retry resets counters for a fresh attempt. Earlier completed removals remain
visible on later failure; no failed item is marked complete. Core callbacks run on
the repository executor; native callers marshal them through the event stream.

Core fixtures verify actual removal boundaries, literal newline/Unicode paths,
failed-item omission, cancellation before the current removal, no events for stale
plans/foreign locks, global recursive counts and retained child files after
cancellation. Native subscriptions verify path/count updates while busy, alongside
real Trash/permanent execution, failure and Retry counts. Displayed progress-bar and
VoiceOver acceptance still require physical UI checks. See
[the progress QA record](qa/clean-progress-2026-10-07.json).

## Remaining work

- Activated Finder URL handoff and signed nearest-repository permission acceptance.
- Native access-grant integration for recursive checkouts and external Git/common
  directories, plus signed traversal acceptance.
- Signed Trash acceptance.
- Displayed light/dark layout, original icons, keyboard/VoiceOver and signed sandbox
  acceptance. The Core checks do not establish native dialog parity.

## Shared progress policy and ordered result actions

The native result now presents the source-order first action and a split menu:
Retry on failure; Move to Trash / Delete permanently after a successful dry run,
ordered by the accepted permanent-delete preference. Original Refresh, Cleanup
and Delete artwork supplies native action icons (the source callback itself has
no explicit icons). The request remains captured, and each removal/Retry still
takes a fresh accepted plan. Duplicate actions, closed results and pending
cancellation prompts cannot submit another attempt.

Dry-run and permanent-delete attempts capture AutoCloseGitProgress at construction:
manual retains results; no-options retains successful dry runs with their two
actions and closes permanent completion; no-errors closes either successful
result. Failures remain open. Trash follows upstream's separate CSysProgressDlg
path and closes on successful completion regardless of this setting; completed
output and recoverable locations are delivered before closing. Its failure stays
open to expose partial recovery, a native improvement over upstream's unchecked
DeleteAllFiles result. The existing Show in Trash control is available on retained
failed results that contain recovered items.

ConfirmKillProcess applies to dry-run/permanent attempts, with native Yes/No and
Yes default. No preserves running work; Yes cancels only the owned attempt and
helpers. Trash keeps direct cancellation, as the source system progress path does.
Automatic close waits for an outstanding confirmation response if execution
finishes meanwhile. Model callbacks verify that race; displayed sheet timing and
focus are still pending.

[Policy QA](qa/clean-progress-policy-2026-10-08.json) records four-Git actual cleanup,
Trash recovery, captured close settings, failure/Retry, cancellation and deferred
close, plus the earlier native cleanup regression. No new screenshots or displayed
app sessions were created for this checkpoint. Physical split-menu selection,
keyboard/default buttons, light/dark layout and signed acceptance remain pending.
