# Finder path and selection conditions

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This extends the repository metadata audit with path/status/selection clauses.
Full Explorer-to-Finder parity remains incomplete.

`FinderShellRules` retains the four alternative required/excluded flag pairs for
39 implemented root entries from `MenuInfo.cpp` (blob
`aee7f91ad1111fe03ab85b390855885ca940a27f`). An empty pair does not match;
otherwise all required bits must be present and all excluded bits absent,
following `ContextMenu.cpp`'s `ShouldEnableMenu`. The independent source fixture is
[upstream-shell-menu-conditions.json](upstream-shell-menu-conditions.json).

The extension's repository entries now consume these clauses. Single tracked
files retain file actions, but folder operations such as Fetch, Branch, Reflog
and Repository Browser are hidden. Added files exclude Log and removal; unchanged
files exclude Revert. Two-file selections admit Diff while excluding commands
requiring a single selection. Folder and working-tree-root alternatives remain
separate, including Pull's root alternative without an only-one requirement.
Ignore headers also apply source clauses alongside backend eligibility guards.
Comparison marking retains its single-file rule. Administrative `.git` paths
suppress the menu even when mixed with other selected paths.

An untracked folder inside a cached worktree now retains `folderInGit` separately
from its versioned-file state, as in `TGitPath.cpp`'s administrative mask. Its
ordinary creation entries are hidden; Shift exposes Clone/Create when not
versioned. Targetless toolbar creation remains the native adaptation described
in [the creation audit](FINDER-CREATION-PARITY.md).

Classification reads cached statuses/repository facts and filesystem directory
metadata without executing Git in Finder. Legacy snapshots retain earlier
stash/submodule-container visibility until refreshed; this is compatibility
behavior, not proof that these repository facts exist. Folder operations still
require a cached repository. Backend permission, rename/remove/resolve/revert
and supported-target guards remain in force after the source visibility rules.

## Verification and remaining work

Three new core tests compare every clause and flag against the source fixture,
exercise explicit file/folder/count/status rules, and classify real temporary
paths with cached statuses. The existing creation test now requires no ordinary
creation entries for an untracked folder inside a cached root. The actual
extension menu builder receiver verifies exact command sets for unchanged,
added and two-file targets, worktree-folder creation, mixed administrative
exclusion, source ordering, captured paths, metadata and icon preferences.
It constructs no Finder controller or extension and displays no menus/windows.
The final full core regression passes 474 tests with zero failures; Debug and
unsigned AppStore builds, both bundle audits and site generation pass.

These checks do not prove full source classification. Complete submodule-root cache coverage
(see [refreshed-root progress](FINDER-SUBMODULE-ROOT-PARITY.md)), git-svn, inaccessible paths, background/container bit combinations,
heterogeneous selections across repositories, complete ignored ancestry,
configuration/placement, omitted commands and fresh background status remain
pending. The subsequent [two-file Diff handoff](FINDER-TWO-FILE-DIFF-PARITY.md) adds
standalone direct comparisons, including unrelated files. Its signed/native
activation remains pending. Multiple-folder creation remains
pending. Signed extension activation, native menu gestures and screenshots
remain unverified.

Build and regression evidence is recorded in
[the verification record](qa/finder-path-conditions-2026-10-06.json).

Clean up requires a folder inside a working tree, matching the pinned Cleanup
clause. It is absent for file-only selections and bare roots. Its captured request
passes through the app permission gate to the nearest checkout and native Clean
options; [Clean parity](CLEAN-PARITY.md) records activation and sandbox gaps.
