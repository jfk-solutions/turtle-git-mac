# Working-file Revert parity

The references are the `IDGITLC_REVERT` branch in `GitStatusListCtrl.cpp` and
[RevertProgressCommand.cpp](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/ProgressCommands/RevertProgressCommand.cpp),
pinned by `upstream.json`. The latter source blob was verified as
`8efbc404abacc78e8a1ff0b92d7bbc724e91356e` before implementation. This is working-file
Revert, distinct from reverting a historical commit in Log.

## Native Commit menu

Revert appears for selected versioned rows with the original `menurevert.ico`.
Modified/conflicted selections ask before proceeding; No is the native default.
Added-only selections become unversioned without deleting their working contents.
Successful actions clear selected checks and refresh the list and patch view.
Saved Restore after commit copies remain available independently.

Normal Revert restores HEAD contents to both index and working files. Amend Revert
uses the first parent regardless of the displayed comparison. An unborn repository
can revert staged additions without creating HEAD. Files replaced during Revert
are moved to macOS Trash, adapting the upstream default recycle-bin behavior.
Deleted files are recreated; renamed files return to their original names.
Submodule pointers are reset without changing their checkout or local edits.
Renamed initialized submodules use Git's reverse move to preserve checkout
metadata and update their path in `.gitmodules`, followed by pointer restoration.

The backend rejects mixed unversioned/ignored selections, changed status rows,
unsupported filesystem objects and parent paths escaping the working tree before
working-file changes. It locks the actual index, including linked-worktree indexes, and runs
Git writes against a private copy. The real index is replaced only after all steps
succeed. A checkout/filter error leaves the original index intact and reports
structured Trash locations for recovery. Working-file changes are not a filesystem
transaction: partial Git checkout or submodule moves can still require recovery.
Concurrent external filesystem edits are not fully prevented.

## Verification

Eleven real Git tests cover binary/staged/later working contents, unrelated staged
changes, literal Unicode/newline/pathspec-looking filenames, additions before the
first commit, renames, deletions, parent-based amend, symlinks, escaping parents,
invalid/stale selections, existing index locks, initialized/uninitialized gitlink
conflicts, submodule rename metadata, linked worktrees, text conflicts with an
active merge and a failing required checkout filter.

The focused Revert/Restore/Working Tree suite passed 21 tests. The unsigned Xcode
Debug app build and bundle audit passed, including the embedded Finder extension
and all 59 original icon assets. Native QA used one
disposable application instance: No preserved HEAD and selected/unrelated staged
and working contents; Yes restored only the selected modified file and left its
later working bytes in Trash. Its row disappeared. Added-file Revert preserved
disk bytes, removed its index entry and displayed an unchecked unversioned row.
The process was closed after these checks and process absence verified. A transient
UI observation failure was investigated using the same live process.

## Dedicated native dialog and Finder routing

The pinned `RevertDlg.cpp`, `RevertCommand.cpp` and `IDD_REVERT` were reviewed;
the two source blobs were verified against the inventory. The native window uses
the upstream table above Select/deselect all and OK/Cancel/Help arrangement, with
Path, Extension, Status and added/removed counts, original status/menu artwork,
independent checkboxes and highlighted rows, and a saved window frame.

Scoped folder requests show versioned changes recursively. Directly requested
files and added files start checked; other folder changes await review. Mixed
Select/deselect all clears checks, then an unchecked control selects all. F5
refresh retains reviewed checks; Control-Return and Command-Return accept the
plan. Cancel performs no Revert. The unversioned-items note retains the upstream
default-hidden behavior and uses `Status.UnversionedAsModified`; a settings UI
for that preference is still pending. File drops are restricted to the same
repository and refresh the scope. Double-click/context comparison opens a native
diff sheet; the context menu also provides check/uncheck and scoped Log.

Revert now has an icon-bearing app/Finder action and checked cached eligibility.
Its URL carries literal multi-path selections through repository authorization
to the dedicated window. Selecting a submodule checkout root routes Revert to
its indexed entry in the superproject; independent nested repositories retain
their own owner. Busy Revert windows prevent close and application Quit while
Git/filesystem operations run. Idle Revert controls are disabled while another
window’s application-Quit confirmation is pending.

Three new tests cover real scoped selection defaults, component boundaries,
unversioned exclusion, unchanged index contents, cached Finder eligibility,
literal URL roundtrip and initialized submodule/independent-repository routing.
The final focused selection/Revert/Finder/icon suite passed 20 tests. Native
Finder-style URL QA checked the initial mixed selection, mixed/off/on selection,
F5 preservation, Cancel without Git changes, and selective Control-Return
acceptance with unchecked staged/working contents and HEAD retained. Actual
light/dark captures are `site/assets/revert.png` and `revert-dark.png`; width and
footer sizing were corrected after inspecting the native captures. Each preview
was closed and process absence verified before the next rebuilt preview opened.
The final unsigned Xcode Debug build and app/extension/icon audit passed.

Full file-list context commands, background artwork, sortable columns, unchanged directly requested
files, file-drop runtime acceptance, Command-Return, error/retry and busy-Quit
runtime checks, saved frame reopen and multi-display placement remain pending.
The Finder request test does not prove signed Finder extension activation or
actual Finder menu acceptance.

## Remaining parity

Signed Finder menu activation, remaining upstream progress notifications and
post-command options, recycle-bin preferences, post-Revert submodule comparison, copy and
case-only rename combinations, renamed-but-missing destinations and root-amend
behavior still need audit. Native multi-selection, staged mode, amendment, conflict
and submodule UI acceptance remain to be exercised. Signed sandbox Trash access
and external-volume behavior are unverified. These source inventory entries
remain partial; the app is not yet ready for App Store distribution.

## Native Revert progress and cancellation

The pinned `GitProgressDlg.cpp` and `.h` blobs were verified against the source
inventory. `CGitProgressDlg` uses `IDD_SVNPROGRESS`: an action/path list above
progress, information and OK/Cancel controls. The native Revert progress window
follows that arrangement with original command artwork and colored terminal
states. Accepting the selection closes the planning window before starting this
window. Dedicated Revert keeps its terminal result open; Commit-list Revert
requests successful auto-close unless submodules are selected. Failed/cancelled
Commit-list Revert retains selection checks.

Progress arrives in order through an asynchronous stream. Cancel, Escape or
closing a running progress window requests cooperative cancellation. OK remains
disabled until completion, repeated cancellation is disabled, and application
Quit is blocked while the operation runs. Git batches contain at most 64 paths;
checks between batches and filesystem operations stop subsequent changes. A
running Git command finishes before cancellation takes effect. Cancellation
before index publication preserves the original index, reports structured Trash
URLs, and explicitly explains that completed working-file changes remain.
The final recovery button reveals those copies in Finder.

Five additional integration tests cover pre-cancellation, stopping after the
first Trash operation, stopping before checkout, a 70-file checkout cancelled
between batches, and successful progress with a literal added filename. Together
with the eleven existing Revert tests, all 16 passed. The unsigned Xcode Debug
build and embedded app/extension/59-icon audit passed. The complete Swift test
suite passed 219 tests with zero failures.

One disposable native preview used a delayed checkout filter. Quit was blocked
while busy; Cancel changed the status and disabled itself. After the active
checkout finished, the result showed cancellation with completed rows, enabled
OK and the recovery button. HEAD and indexed contents matched their pre-operation
values; checkout contents and the exact displaced working bytes in Trash were
verified. Status refresh can update index stat metadata; this native check does
not assert byte-identical index serialization. Core cancellation tests assert
byte-identical indexes before any refresh. The real capture is
`site/assets/revert-progress.png`. The finished progress window was closed;
a subsequent accessibility observation timed out, so the same completed test
process was terminated and process absence verified without reopening it.

A second, sequential native run checked successful dedicated Revert: the result
remained open with completed rows, enabled OK and disabled Cancel. Working and
indexed contents matched HEAD; HEAD was unchanged and the exact displaced bytes
were verified in Trash. Normal application Quit exited, and process absence was
verified before any further UI acquisition. The unsigned App Store build and its
app/extension/icons/pinned universal Git runtime audit also passed; this does not
prove signed sandbox acceptance.

Successful Commit-list native auto-close, native failure/retry, Escape/window-close variants,
clipboard/reveal acceptance, dark progress rendering, global auto-close
preferences, post-Revert submodule comparison, background animation and shared
progress for other operations remain pending. These entries are partial.

Post-Revert comparison data now includes the exact resolved baseline revision
and restored submodule names. The read-only classification backend and its tests
are recorded in [SUBMODULE-DIFF-PARITY.md](SUBMODULE-DIFF-PARITY.md); the native
Handle submodules action and comparison/Update windows remain pending.
