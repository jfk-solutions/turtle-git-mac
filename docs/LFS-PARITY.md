# Git LFS locking parity

TurtleGit has a native **LFS Locks…** command in its app menu for the current
working repository. It opens a resizable list with checkboxes, Path, Extension
and LFS Lock owner columns. Select/deselect all, Force, Unlock, Cancel, Help and
Refresh/F5 follow the upstream Locks dialog's main workflow. Highlighting and
checked targets are separate. Sorting the list retains checked lock IDs.

Unlock opens an owned AppKit progress sheet with per-file paths, results and output.
The controller explicitly attaches and closes its child window; SwiftUI renders
the sheet contents.
Individual failures do not prevent subsequent files from being processed. A
failed unlock offers Force unlock with the captured original target paths,
matching the upstream post-action. Closing the result dialog refreshes the lock
list, including after cancellation or a failed operation. A refresh failure clears stale rows and retains the operation results.
Force is explicit; it is never enabled automatically after failure.

Busy and Quit confirmation block target/force changes and duplicate actions.
Closing a busy window requests cancellation and waits for completion; app Quit
is refused while a request or result sheet is active. Cancellation retains
completed results and does not imply that remote changes were rolled back.

The repository actor uses literal argument arrays for `git lfs locks --json`,
`git lfs lock -- <path>` and `git lfs unlock [--force] -- <path>`. Every batch
target is checked before the first LFS request; folders, escaping paths and
repository administration paths are rejected. Individual command errors are
returned with the corresponding file. Query parsing expects the CLI's JSON
array, skips empty IDs and reports malformed records rather than interpreting
the HTTP API envelope as CLI output. The common Git administration directory
is used for the local LFS marker, including linked worktrees.

Command semantics were checked against the official
[locks](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-locks.adoc),
[lock](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-lock.adoc) and
[unlock](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-unlock.adoc)
documentation. Port mapping uses pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`:
TGitPath.cpp, LFSLocksDlg.cpp/.h, Commands/LFSCommands.cpp/.h and
ProgressCommands/LFSSetLockedProgressCommand.cpp/.h. Original lock/unlock
artwork is reused; native owned sheets replace Windows modal progress.

## Verification and remaining work

[LFS QA record](qa/lfs-locks-2026-10-08.json) records private Core command fixtures,
native window/table/sheet checks and build results. Core fixtures launch a
private command wrapper that logs exact arguments and delegates ordinary Git
commands to real Git. The wrapper supplies LFS responses; no server is
contacted. Native workflow checks inject server replies and mixed results,
verify force retry, cancellation, owner and operation guards, and preserve real
repository HEAD/index/working contents. They do not verify a real Git LFS
helper, authenticated remote or physical input.

The packaged Git engine includes Git LFS 3.8.0. `Configuration/GitLFSRuntime.json`
pins both official publisher archives, the complete source archive, Go notices
and all 28 external module archives/notices. Preparation verifies publisher
SHA-256 checksums and Go module sums; auditing compares executable code/data
and loader commands with publisher binaries even after replacement signatures.
App Store embedding requires this helper and has no external Git fallback.

A real bundled-client loopback fixture verifies LFS pointer conversion, JSON
lock listing, literal unusual filenames, ownership failures, continued per-file
unlock and explicit force. It preserves HEAD, staged entries and working bytes.
This complements the injected native dialog tests above. It does not establish
authenticated provider or signed sandbox acceptance. See the
[runtime QA record](qa/git-lfs-runtime-2026-10-08.json).

Commit and Working Tree now offer original-icon LFS Lock/Unlock context actions
when the repository has a common-directory LFS marker and the selection contains
files without conflicts. With the owner column hidden, both actions match upstream
AppendLocksMenuItems. Their captured selections run in a native sheet attached to
the originating dialog; the owner stays busy through result review. Cancellation
retains completed changes, failed unlock offers explicit Force retry against the
original paths, and closing results refreshes the owner. No remote locks query is
made to build this hidden-owner-column menu or refresh its local file rows.
The standalone Locks window continues to refresh remote lock ownership.
Working Tree joins the global Quit-confirmation guard; Commit and Working Tree
refuse new LFS actions while busy or deciding whether to quit. The hidden native
receiver checks these methods, actual sheet attachment, captured Force retry and
original-icon availability with injected LFS responses against Apple Git and the
bundled engine. See [status-action QA](qa/lfs-status-actions-2026-10-08.json).
Physical menu/pointer/keyboard input is not established by these checks.

Commit now adds an optional **LFS Lock** owner column to its saved header layout.
It is offered only with the common-directory LFS marker, and stays hidden by
default. Showing it refreshes ownership; hidden columns do not request locks.
The owner participates in case-insensitive sorting, path ties, autosizing and
visible-column clipboard output. Lock state is independent of a nonempty owner
name. Known uniformly locked selections offer Unlock, uniformly unlocked ones
offer Lock, and mixed selections offer neither. A query failure or cancelled
reply clears ownership instead of presenting unknown files as unlocked; Cancel
interrupts an in-flight owner query. Existing visibility/order/width preferences
migrate additively. See [owner-column QA](qa/lfs-owner-column-2026-10-08.json).

Working Tree now offers a saved **LFS Lock** visibility choice in its native
header menu. Its default six columns stay visible. The seventh physical column
is hidden by default and unavailable without an LFS marker. Showing it queries
ownership; known locked/unlocked/mixed and unknown menu rules share Commit’s
policy. Owner sorting uses the shared case-insensitive comparison and path tie;
all seven headers retain native ascending/reverse bindings and one sort column.
Closing during an owner query cancels it and does not publish a late response.
LFS batches capture paths in the displayed sort order. See
[Working Tree owner QA](qa/working-tree-lfs-owner-2026-10-08.json).

Finder routing, source availability gates, locking progress/post-Pull actions remain incomplete. The native list adds an
explicit Refresh button alongside F5. Physical keyboard/menu/pointer behavior,
light/dark appearance, accessibility, fresh real screenshots, signed Finder
deployment and provider acceptance remain pending. This is partial LFS parity
and does not establish whole-application or App Store readiness.

The Locks dialog now uses a native three-state Select/deselect all checkbox:
none, all and partial selection are visible as off, checked and mixed. Clicking
an off checkbox selects all; clicking checked or mixed clears all, following
upstream OnBnClickedSelectall. The target reads the current valid checked-ID
count, preserving correctness between rapid activations before SwiftUI redraw.
Busy, Quit-confirmation and empty-list states disable the control; highlighting
remains independent. Add, Revert and Submodule Update supply live counts to the
same shared native helper. Resolve now reuses it too, including the disabled
busy state. Its native checkbox is checked against a private repository with
two real merge conflicts; checkbox changes leave the index untouched. See [three-state QA](qa/lfs-tristate-2026-10-08.json).

Working Tree’s owner column now participates in the shared native saved layout,
adjusted widths, fitting, confirmed reset and visible-column clipboard output.
Filename and File size are optional too; the six default visible columns and
LFS availability gate remain. Existing owner visibility migrates additively. See
[Working Tree column QA](qa/working-tree-columns-2026-10-09.json). Physical/signed/provider acceptance remains pending for both lists.

## Standalone Locks columns and clipboard

The native Locks table now shares saved column visibility, order, adjusted widths,
automatic/content fitting and confirmed reset with Commit and Working Tree.
Its available columns match LFSLocksDlg Init: Path, Filename, Extension, Last
modified, File size and LFS Lock. Path, Extension and LFS owner are visible by
default, alongside the independent checkbox column. Path stays visible; the
checkbox stays first. Preferences use LFSLocks.FileColumns independently of the
other dialogs. Reset No keeps the layout; Yes restores the source default.

All six text headers support ascending/reverse sorting with path ties. Owner
uses case-insensitive text comparison; paths/names use numeric comparison and
byte ties. Size/date come from local filesystem metadata once per lock refresh;
remote files missing locally remain listed with unavailable metadata. Sorting
retains server lock IDs, checked targets and highlighted rows independently.
Busy, Quit confirmation and progress review block layout/sort changes.

Original-icon Copy to Clipboard offers full/relative paths, names and all visible
information. Output uses displayed row and visible-column order with headings
for multiple columns and native LF. The shared native interaction also routes
keyboard copy, checkbox Space and clicked-column copy using server IDs, without
manufacturing Git status records. Shift-copy includes source-style Unknown
status because remote lock records contain no Git working-tree action.

See [Locks column QA](qa/lfs-columns-2026-10-09.json) for native table/header,
layout reopening, fitting/reset, sorting, copy text and operation checks.
Physical gestures/keyboard/context menus, actual reset alert buttons, light/dark
appearance, accessibility, fresh screenshots, authenticated providers and signed
Finder/sandbox deployment remain unverified. Full Locks workflow parity remains
partial.

Other shared-list context commands and source enablement remain pending; the
column checks do not establish full menu parity.

A completed LFS batch now stops accepting queued per-file progress callbacks
before publishing its final results. Previously a refresh yielding to another
actor could append delayed callbacks to those results a second time. The native
receiver preserves the exact per-file result count/order and cancellation checks;
the failed diagnostic log records the duplicate rows before the fix.

## Source context targets and copy masks

The standalone Locks context menu now uses the shared ownership policy: Lock and
Unlock are both offered when the owner column is hidden; visible locked rows
offer Unlock. The common-directory LFS marker, nonempty valid selection and
non-directory gates match AppendLocksMenuItems. Context batches capture
highlighted server IDs in displayed order, independently of checked targets.
They start without Force, even when the dialog’s Force checkbox is checked.
The main Unlock button captures checked paths and its Force setting instead.
Explicit Force retry keeps the captured Unlock targets; failed Lock cannot be
retried as Force Unlock. Owned progress titles and original artwork reflect the
chosen operation. Closing standalone batch results refreshes the lock list.

The shared clipboard formatter now retains Copy all headings when only one
column is visible, following the source’s multi-column command mask. Explicit
single-column and full/relative/name copies still omit headings. Commit/Log
Core formatting, Working Tree and Locks use the same heading rule.

[Menu/copy QA](qa/lfs-menu-copy-2026-10-09.json) records focused Core assertions
and native operation/sheet/selection/Force checks with injected responses.
Physical context-menu activation, full source command coverage, real providers
and signed deployment remain pending.

## Refresh choices and list position

Locks remembers checkbox choices by repository path across refreshes, including
removed paths that later return with a different server lock ID. New paths are
checked by default. Select all updates each current path's remembered choice.
Context Lock/Unlock clears the remembered choices only for its captured targets;
the checked Unlock button retains them. This follows the pinned status list's
checked-path map and LFS context handlers.

With RememberFileListPosition enabled (the source default), refresh restores the
scroll origin, first highlighted row index and focus mark index after the native
table has adopted the new rows. Additional highlighted rows are not restored.
The native implementation also restores row zero; the source's integer truth
check skips that row. Disabling the preference resets scrolling and highlighting
without changing checked targets. Pending restoration is invalidated by a newer
refresh or table teardown.

[Refresh QA](qa/lfs-refresh-2026-10-09.json) records the checks and their limits.

## Progress review and refresh order

The standalone Locks window now follows OnBnClickedUnLock and the status-list
LFS context handlers: the server operation completes, the user reviews results
(and may retry Force Unlock), then Close dismisses the owned sheet and refreshes
the lock list. No query runs during review or between Force retries. Checked
choices, highlighting and the existing lock rows remain intact until dismissal;
context-target checkbox memory resets when the results close.

Close reserves the model's busy state before detaching the sheet, so a new batch,
Refresh or duplicate Close cannot overlap the single follow-up query. That query
uses a fresh cancellation token, including after a cancelled operation. Failed
refresh clears the list and preserves exact per-file results and the operation
summary. Commit and Working Tree continue to refresh their owner on closing
results; their shared operation model does not query remote locks independently.

[Review/refresh QA](qa/lfs-review-refresh-2026-10-09.json) records query counts,
actual sheet detachment, blocked overlapping commands, Force target retention,
cancellation and failed-refresh result preservation. Physical input, full
progress-dialog fidelity and authenticated provider acceptance remain pending.
