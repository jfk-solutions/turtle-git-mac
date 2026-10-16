# Rename parity

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`, `RenameDlg.cpp/.h`,
`Commands/RenameCommand.cpp/.h`, all six `IDD_RENAME` controls and the Rename
conditions in `TortoiseShell/MenuInfo.cpp`. Original `menurename.ico` is copied
unchanged, with its source path/hash and GPL alternative recorded in provenance.

## Implemented

The native window has the upstream source-name information row, New name field,
browse button, OK and Cancel, with horizontal resizing and saved geometry. Errors
retain the entered name for correction. New names are trimmed like upstream and
resolved relative to the source's containing directory; relative moves within the
same working tree are supported. Windows filename restrictions are adapted to macOS:
Unicode, embedded newlines, wildcard punctuation and leading dashes remain literal.

Rename is available from Commit and Working Tree single-versioned-file menus, the
workspace context/command menus and Finder dispatch. The workspace enables Rename
only for a suitable single selection. Bare repositories disable it. Finder uses its
cached snapshot to exclude multi-selection, repository roots, unknown/untracked
files and selections outside monitored roots; directory eligibility includes
versioned descendants. This is initial Rename eligibility, not full shell parity.

The backend uses separate `git mv [case-only -f] -- source destination` arguments.
It validates root/admin-directory containment, symlink parents, versioned source,
unchanged name, existing destinations and destination repository before mutation.
A case-insensitive volume's alias spelling is allowed for a case-only rename; a
separately listed destination is rejected. Tracked symlinks move as links rather than
following external targets. Directory moves retain untracked children. Git stages
the rename while preserving the previous index blob and current working contents.
Open Commit/Working Tree models remap checks, selection and scoped paths before
reload; native post-close observation of that remapping remains unverified.

The browse button uses a native destination panel and checks that its directory
belongs to the same working tree. The repository access lease is retained for the
whole dialog/operation; signed sandbox behavior remains unverified.

## Verification

Five tests exercise real file/directory/case-only/symlink renames, mixed staged and
unstaged contents, unrelated staged files, literal names, parent-relative moves,
occupied/dangling-link destinations, nested repositories and external symlink-parent
rejection, plus cached Finder eligibility. The full suite passes 128 tests.

Native QA used `/private/tmp/TurtleGitRenameQA`. A Debug preview dispatched an actual
FinderRequest through the app handler. The window opened in front of the workspace.
An existing `StatusBadge.swift` target showed a collision error without changing
source/destination files or index. Dismissing it and retrying as
`RepositoryRenamed.swift` succeeded. CLI inspection verified separate index/worktree
bytes, unchanged HEAD/refs and unrelated files, and absence of the original path.
Commit's file menu opened Rename for that path; renaming it again to
`RepositoryFinal.swift` preserved both versions. Working Tree's file menu then opened
Rename for the final path. Cancel was attempted there and CLI inspection showed
unchanged HEAD/index/status/worktree. The observation handle timed out after dialog
closure; closure and restored parent selection are not claimed as native verification.
`site/assets/rename.png` is the actual 1040 × 364 light-mode native window capture.

Native testing exposed mismatched `/private/tmp` versus `/tmp` root spelling in
Finder dispatch. Root discovery and selection normalization now agree. A regression
test covers existing roots and missing/deleted nested leaves. Selected leaf symlinks
remain literal. Finder handoffs also leave dedicated dialogs in front; only unified
Diff raises the workspace output.

## Remaining parity and QA

Native browse/Cancel confirmation, parent-window selection/check restoration,
geometry relaunch, dark rendering and keyboard traversal still require verification.
The current directory picker issue is tracked in INIT-PARITY.md. Signed Finder
activation, external URL delivery, sandbox grants and symlink selections, submodule
moves/gitmodules updates and multi-repository handoffs need broader end-to-end QA.
Reference rename retains upstream's separate inline Browse References editor.
Move/Copy and Finder clipboard consumers have their own connected family records;
autocomplete, Windows error balloons and physical drag integration remain open.
The native Commit list was verified to display index renames as Renamed even if a
low-similarity HEAD comparison reports an added file. The workspace now shares the
existing upstream status-color palette; its broader native visual QA remains.
No full upstream or App Store parity is claimed.

The native multi-file Move and Move/Rename adaptation is tracked separately in
[File Move parity](FILE-MOVE-PARITY.md). Finder clipboard consumers are implemented
in the transfer family; physical drag acceptance remains open.


## Connected file/reference workflow — October 14, 2026

File/folder Rename now shares the guarded Move plan and cancellable literal Git mv
backend. Input errors retain the native source/name/browse/OK/Cancel window. Browse
owns its panel and destination validation token; same-worktree parent-relative names
remain supported. Retired replies cannot change a later input or start mutation.
Actual execution streams bounded output; cancellation/failure retains a progress
result with Back and the entered name. Success delivers captured path remapping and
refresh before closing. Operation counters/leases cover preparation, commands and
pending reads even after forced closure. The progress window is a macOS adaptation
of upstream's blocking Git call; input layout remains horizontally resizable.

Reference renaming retains BrowseRefsDlg's inline editor rather than replacing it
with CRenameDlg. The branch SHA is captured when label editing begins and checked
before nonforcing Git branch -m. Owned streamed output, cancellation, final snapshot
refresh and lifetime counters now cover the command. Changed references are refused
rather than renamed under stale metadata. Git remains authoritative for collisions,
invalid labels and checked-out branch/worktree constraints.

Shared Move/Copy collision dialogs have separate family records. Autocomplete,
Windows balloon focus behavior, full physical input/picker/theme acceptance,
submodule/gitmodules variants and signed Finder/sandbox integration remain open.
Batch results follow grouped validation; no full Rename/source or port claim.

The expanded grouped checkpoint passed 36 Core tests and fourteen native cases
across system and bundled Git. Initial compilation and fixture failures, scoped
repairs, actual process cleanup and acceptance limits are recorded in
[the batch evidence](qa/rename-reference-management-2026-10-14.json).


The shared [path-entry family](PATH-ENTRY-PARITY.md) now supplies native filesystem
completion for Rename, Clone, New Worktree and Export, including full-field text
boundaries, captured directory reads and retired/changed input guards. Earlier
autocomplete-pending entries above describe the preceding implementation. Physical
completion/focus/IME and signed access remain open.
