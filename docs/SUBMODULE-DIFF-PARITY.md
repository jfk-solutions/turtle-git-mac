# Submodule comparison parity

The references are pinned to `7338078f8ddd924b8cddee35f512f2286072136d`:
[GitDiff.cpp](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/GitDiff.cpp),
[SubmoduleDiffDlg.cpp](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/SubmoduleDiffDlg.cpp)
and `.h`, `IDD_DIFFSUBMODULE`, and the successful post-command callback in
`RevertProgressCommand.cpp`. All three source blobs were verified against the
file inventory. This is the ordinary submodule comparison, separate from the
existing three-side conflict dialog.

## Comparison backend

`SubmoduleComparison.swift` resolves the superproject's From gitlink and either
its historical To gitlink or the actual initialized child checkout's HEAD.
An uninitialized working checkout retains the indexed gitlink as its displayed
revision. It reports subjects, metadata availability, dirty state and the
upstream change categories: identical, addition, deletion, fast-forward,
rewind, or newer/older/equal commit time for divergent histories. Missing child
objects and uninitialized checkouts produce Unknown with unavailable Log sides.
An absent side has no Log revision. Historical comparisons ignore current
checkout dirtiness. Working comparisons include staged, unstaged and untracked
changes, while ignored files do not make the checkout dirty.

Paths and revisions are literal arguments. Tree records use NUL delimiters and
exact path matches, preserving Unicode, commas, newlines and pathspec-looking
names. Child checkout roots are verified before metadata access; external
checkout symlinks and escaping parents are rejected. A conflicted index is
routed to the existing conflict workflow rather than presenting stage zero as
resolved. Reads do not publish index updates or change HEAD/working contents.

Successful Revert results now retain the exact resolved superproject comparison
revision and restored submodule names. A later superproject commit cannot change
that captured baseline; renamed submodules use their restored original names.
This data prepares the Handle submodules action. The native post-action button
and comparison window are not yet connected.

## Verification and remaining work

Seven real-Git comparison tests cover working/historical comparisons, child HEAD
independence from the superproject, ignored and dirty files, binary index
preservation in both repositories, all divergent time categories, uninitialized
checkouts, missing commits, additions/deletions, empty-tree comparisons,
unsupported and escaping paths, conflicted indexes and a Revert baseline after a
later superproject commit. Existing Revert tests additionally check initialized
and uninitialized result paths and restored submodule rename paths. All 18 focused comparison/Revert tests
passed with zero failures. The unsigned Xcode Debug build and app/Finder
extension/license/59-icon audit passed. No QA app was opened for this backend-only
change.

The reviewed native dialog must still provide the From and To groups, revision
and subject rows, original change-type colors, dirty revision indicator, two Log
buttons, conditional Diff/Compare menu, Update handoff, F5, frame persistence and
post-Revert multi-submodule dispatch. The native Submodule Update
options window is implemented separately; its full progress handling and the
comparison window handoff remain pending. See SUBMODULE-UPDATE-PARITY.md. General comparison views, native light/
dark acceptance and signed sandbox access are unverified. Source and dialog
coverage remain partial; no completed native port is claimed for this dialog.
