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
can revert staged additions without creating HEAD. With the default disposition policy, files replaced during Revert
are moved to macOS Trash, adapting the upstream recycle-bin behavior. The
captured policy described below can disable this recovery copy independently
for ordinary replacements and rename destinations.
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
default-hidden behavior and uses the source `UnversionedAsModified` preference. File drops are restricted to the same
repository and refresh the scope. Double-click/context comparison hands off to the shared native comparison; the
expanded context menu is described in the planning-family continuation below.

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

The planning-family continuation below adds shared file commands, sortable saved
columns, direct clean files and owned drop/read handling. The later saved-file
family adds original background artwork. Full source popup masks, saved frame
reopen and multi-display placement remain pending.
The Finder request test does not prove signed Finder extension activation or
actual Finder menu acceptance.

## Remaining parity

Signed Finder menu activation, remaining upstream progress notifications and
post-command options, post-Revert submodule comparison, copy and
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

## Connected progress/recovery family — October 14, 2026

Revert preparation now passes cancellation through status/branch/index reads.
Actual private-index Git steps stream bounded colored output while retaining the
ordered Action/Path table. Running mutation steps finish before cancellation
prevents the next step or index publication; a confirmation does not kill a
half-completed checkout. Native ConfirmKillProcess prompts retain No/Yes, and
automatic completion waits for an owned question to settle. The counter and
repository permission cover all reads, steps and pending questions after forced
retirement. Retired rows, output, parent callbacks and result actions are suppressed.

Captured AutoCloseGitProgress now applies to dedicated Revert results; no-options
retains the source Handle submodules action, and no-errors may close successful
results with that action. Commit's explicit success-close override still requires
no submodule post-action. Failed/cancelled results retain Retry, recovery and output.
Retry reads the current originally selected paths rather than replaying stale rows;
already completed paths remain eligible only while tracked. Unrelated changes are
not included. All recorded Trash copies survive later attempts. Action logs include
rows, command output and the result; the source submodule comparison handoff remains.

Physical progress, confirmation timing, keyboard/themes, signed Trash/sandbox and
all upstream controls remain open. This family preserves cooperative mutation-step
cancellation and does not claim an atomic filesystem transaction or cancellation
that rolls back completed working-file effects. Grouped evidence follows validation.

Debug, 33 related Core tests and four grouped native cases passed on the first
checkpoint with both Git engines. Receiver cleanup and exact validation limits
are recorded in [the batch evidence](qa/revert-progress-family-2026-10-14.json).


## Revert planning family — October 16, 2026

Source: pinned `RevertDlg.cpp` initialization/read/drop handlers and
`GitStatusListCtrl.cpp` Revert/menu handling. The source enables the shared file
popup except Commit, Restore and changelists, and uses the five-column
Path/Extension/Status/Lines added/Lines removed default.

The native planning window now embeds the shared Working Tree file-action backend
without grouping or its preferences. History/old-name history, Blame, two-file
comparison, Open/Open With/editor, export, Reveal, deletion, Resolve/Ignore,
Rename/Move, index flags and LFS retain original menu artwork and captured paths.
The ordinary comparison handoff and shared unified viewer replace the earlier
plain-string patch sheet. Context Revert uses source Yes-default confirmation for
modified ordinary files and opens the existing recovery/progress controller;
closing that child refreshes the planning table. Related Rename/Move/Ignore/Resolve
completion also refreshes the bound repository; Rename updates direct scope and
checks to the new path.

Status, statistics, metadata, repository identity and menu state publish as one
owned snapshot. Refresh supersedes and cancels its predecessor; cancellation and
forced closure retain worker/access lifetime until drain and reject late results.
Same-repository drops coalesce over the source 200 ms delay and union the invocation
scope. Failed/nested-repository drops retain prior rows/scope. A directly requested
clean tracked file appears checked; root/folder requests omit clean files and
unversioned files. Existing checks/highlights survive successful refresh.

The shared native file-list interaction owns checkbox/Space, keyboard deletion,
clipboard, optional filename/date/size columns, sorting, fitting and confirmed
Reset columns. Layout is stored under `RevertDlg.FileColumns`; Working Tree and
Commit preferences remain independent. F5 and Control/Command-Return are scoped
to the owning active window. File questions, export/application panels and progress
children own close and Quit lifetime, including forced retirement.

The Debug build passes after the recorded compiler repair. Planning, retained
progress and shared Working Tree file-menu checks pass with system and bundled
Git; the Revert-only queued-refresh repair passes its affected two-engine check.
All ten receiver processes, including the two failed initial runs, are absent.
See [batch evidence](qa/revert-planning-2026-10-16.json) for exact scope and the
AppKit reentrant-table warning. These checks do not certify full source popup-mask, physical keyboard/Finder,
all conflict/gitlink/rename combinations, visual or signed sandbox acceptance.

## Saved comparison, Save As and list artwork — October 16, 2026

`RevertDlg` enables `GITSLC_POPSAVEAS` and `GITSLC_POPPREPAREDIFF`; the pinned
Working Tree, Commit and Resolve initializers explicitly disable them. Revert
now offers the separate **Save As**, **Mark for comparison** and **Compare with…**
actions with original icons. They use the source selection mark, independently
of the highlighted set. A replacement mark or refreshed file snapshot invalidates
an older comparison popup. Local marks retain live working paths; imported Finder
Diff Later marks retain their exact file and repository-access grant and import
only once per saved identity, preserving a later local mark.

Comparison dispatch uses the existing owned prepared-file route. Marked file reads,
source/default alternative-tool choice and Finder mark consumption retain that
route's ownership. The prepared-submodule continuation in [Submodule Diff parity](SUBMODULE-DIFF-PARITY.md)
now handles gitlink marks through Submodule Diff; Save As remains a file action.

Save As owns its NSSavePanel and copy worker through cancellation/retirement,
including a held destination reply and forced owner close. The suggested working
filename uses the source's empty-revision suffix (`name-.ext`). Choosing Cancel
writes nothing. The chosen destination keeps its security scope during the actual
copy, and Core's existing literal-path, regular-file, same-file and Git-metadata
checks remain authoritative. Binary bytes are copied without altering HEAD/index.

The original `RevertBackground.ico` is bundled byte-for-byte with provenance. Its
128-point artwork stays anchored to the native table viewport, below native cells,
without input/accessibility interception. The shared ShowListBackgroundImage
preference controls it. Detachment and forced window closure retire the drawing
layer. Other consumers leave the optional background unset.

The native Copy to Clipboard column item now captures row identities even for
entry-based lists; Revert also captures the displayed column text and rejects the
item after refresh or owner retirement. The existing full/relative/name/all copy
commands and source menus disabled in the other dialog families remain unchanged.

The Debug build, three icon checks and all six grouped native case/engine runs
pass after the recorded fixture correction. All seven receiver processes,
including the initial failed fixture, are absent. Reviewed actual
[light](site/assets/revert.png) / [dark](site/assets/revert-dark.png) captures
show the native five-column layout, status colors and original artwork. See
[batch evidence](qa/revert-file-commands-2026-10-16.json) for scope, repair and the
retained planning-table warning. Full popup-mask/submodule, physical, minimum-OS
and signed sandbox acceptance remain open.

## Native file-list refresh position — October 16, 2026

The planning window now restores native viewport, highlighted files and focus
only after its complete owned snapshot reaches the actual table. Checks retain
their independent lifetime; new scopes reset position, and cancellation or newer
reading intent retires older callbacks. Source preference and file-only Ctrl/Cmd-A
share the [file-list refresh family](FILE-LIST-REFRESH-PARITY.md). Eight grouped case/engine runs pass; physical and signed acceptance remain open.


## Exact planning, checkbox and operation identity

The connected [Add/Revert selection family](ADD-REVERT-IDENTITY-PARITY.md) now
retains exact valid UTF-8 Git names through checked/highlighted rows, marked
menus, refresh and private-index operations. Revert checkboxes apply to the
highlighted files as in the source; Add native menu invocations retain their
original payload and reject stale or retired targets. See the family document
for actual grouped evidence, light/dark captures and remaining physical/signed
acceptance. This supersedes the pending Add/Revert outer-selection migration;
full dialog parity remains partial.

[Grouped selection evidence](qa/add-revert-identities-2026-10-17.json).


## Checked acceptance and owned file commands

The connected [file-command flow](ADD-REVERT-FILE-FLOW-PARITY.md) now uses the
source's checked-path ordering and once-only acceptance. Add owns Save/Export/
Open With/editor from its chooser through worker/launch drain; Add and Revert
share a picker identity/release/retirement session. Actual grouped evidence,
compatibility diagnosis and acceptance boundaries are in
[the batch record](qa/add-revert-file-flow-2026-10-17.json).


## Captured working-file disposition policy

Pinned `RevertProgressCommand.cpp:43–55` reads two independent preferences.
`RevertWithRecycleBin` is the master switch and defaults to true.
`RevertRenamedFilesWithRecycleBin` also defaults to true, but affects renamed
entries only. The source excludes added entries from its deletion list; when the
rename switch is false it also excludes replaced/renamed entries. The master
switch then controls whether that list is recycled at all. `SetDialogs2.cpp`
connects the master switch to `IDC_USERECYCLEBIN`; the rename switch is a separate
advanced preference, not another name for the master setting.

The native working-file Revert policy retains that distinction:

| Master switch | Rename switch | Ordinary replacement | Rename destination |
| --- | --- | --- | --- |
| On | On | Trash recovery copy | Trash recovery copy |
| On | Off | Trash recovery copy | No Trash recovery copy |
| Off | Either | No Trash recovery copy | No Trash recovery copy |

Disabling a recovery copy does not turn Revert into a separate Delete command.
Git still restores the selected baseline and reverses selected renames; overwritten
or removed working contents in that part of the operation have no promised Trash
copy. Added-only Revert still removes the index entry while retaining working
contents. Deleted files can be restored without a pre-existing file to recycle.
Gitlink checkout and rename handling retain their existing separate rules.
Old-name obstructions, filesystem types and submodule metadata are validated
even when Trash is disabled; the preference does not bypass path safety checks.

`WorkingFileRevertPolicy(recycle:recycleRenamedFiles:)` defaults both switches
to true. Its preference loader retains those defaults for missing values and
interprets nonzero stored values as enabled. The native operation captures this
policy from its originating preference store before confirmation. Its question
describes the captured disposition rather than
promising recoverability unconditionally. Dedicated Revert, Commit-list Revert,
and the shared Resolve and Rebase conflict-file Revert progress owners use the same
policy, including their custom executors. Retry refreshes
selected-path status while retaining the accepted policy; changing Settings after
an attempt starts does not change that attempt or its retry.

Progress and recovery remain separate facts. A completed Trash step contributes
its actual returned recovery URL; a bypassed Trash step does not fabricate one
or add a recycling row to the progress total. There is no additional permanent
deletion phase: Git performs the baseline restoration and rename cleanup.
Failure or cancellation retains prior recovery receipts and explains that completed
working-file changes remain. The private index is published only after successful
Git steps, so an unchanged index does not imply that earlier filesystem effects
were rolled back. Recovery actions reveal actual recorded copies only.

This continuation closes the working-file preference-consumption gap listed in
the earlier chronological audit. It does not change Reset's independently captured
backend policy or Log's historical commit Revert. The [grouped checkpoint](qa/working-file-revert-disposition-2026-10-26.json)
records 27 distinct Core methods and six native case/Git pairs passing cumulatively
after a fixture API repair and a real ignored staged-deletion metadata correction.
Both Debug builds and localization write/check pass; all seven attempted receivers
were reaped and independently absent. Earlier checkpoints retain their original
scope. Physical signed-sandbox Trash behavior, external volumes and every
rename/submodule combination remain outside those focused claims.


## Source row activation continuation — October 30, 2026

The shared [file-list activation family](STATUS-LIST-ACTIVATION-PARITY.md)
separates a double-clicked row from highlighted multi-selection, preserves its
comparison/conflict and Shift-tool intent, and rejects stale sort/reload/closed
receipts. Checkbox events retain their native action; group rows cannot launch
a different selected file. Explicit multi-file menu commands retain their
existing behavior. Physical keyboard/VoiceOver and full-dialog acceptance remain
separate from the connected native checkpoint.
