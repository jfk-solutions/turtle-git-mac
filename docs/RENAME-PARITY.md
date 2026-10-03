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
The shared upstream Rename dialog's other consumers (reference renaming and drop
move/copy workflows), autocomplete and Windows error balloons are not fully ported.
The native Commit list was verified to display index renames as Renamed even if a
low-similarity HEAD comparison reports an added file. The workspace now shares the
existing upstream status-color palette; its broader native visual QA remains.
No full upstream or App Store parity is claimed.
