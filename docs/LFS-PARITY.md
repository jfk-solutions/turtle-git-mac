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
matching the upstream post-action. Successful completion refreshes the lock
list. A refresh failure clears stale rows and retains the operation results.
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

Working Tree full shared column layout/clipboard, Finder routing, source
availability gates, tri-state select-all, full shared column settings and
locking progress/post-Pull actions remain incomplete. The native list adds an
explicit Refresh button alongside F5. Physical keyboard/menu/pointer behavior,
light/dark appearance, accessibility, fresh real screenshots, signed Finder
deployment and provider acceptance remain pending. This is partial LFS parity
and does not establish whole-application or App Store readiness.
