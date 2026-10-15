# Repository titles and file path tooltips

Repository dialogs identify their working tree using its full path by default.
In Settings → Advanced, `DialogTitles = 1` starts the path at the repository
name instead. Other values use the full path. Applying this setting updates
already-open repository windows, including their current scoped path and operation
name. Reset the value by clearing its text in Advanced settings.

Commit uses its selected file, or the common containing directory of multiple
selected paths, while Show Whole Project uses the repository root. Working Tree
and Log retain their scoped location. Revision context in a Log title and operation
changes in Rebase/Bisect remain attached when the presentation setting changes.
Progress windows use the same policy and their owner's preference domain where
one is supplied. Standalone document windows retain document filenames.

`ShowListFullPathTooltip` defaults to true. Path cells in Commit, Working Tree,
Log changed files, Changed Files, Add, Revert, Resolve, Rebase conflicts and LFS
locks show the full local file path. Existing rename/changelist details remain
below that path where applicable. False disables these path tooltips; clearing
the Advanced value restores the default. SwiftUI path cells observe the preference
and Add refreshes its AppKit cells when it changes.

## Pinned source comparison

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
`CAppUtils::FormatWindowTitle` / `SetWindowTitle` in
`src/TortoiseProc/AppUtils.cpp` supplies the source setting modes and its
80-minus-dialog-name buffer budget. `CommitDlg.cpp` and `LogDlg.cpp` supply scoped
locations. `CGitStatusListCtrl::OnLvnGetInfoTip` in
`src/Git/GitStatusListCtrl.cpp`, and the corresponding FileDiff handler, supply
the default-enabled full-path tooltip guard.

The macOS formatter retains the source UTF-16 length budget and uses en-dash
separators. Its middle ellipsis preserves whole Unicode graphemes; it does not
reproduce the Windows `PathCompactPathEx` algorithm or font-dependent rendering.
Repository containment requires a path-component boundary, avoiding an upstream
raw-prefix ambiguity with neighboring repositories. Formatting does not resolve
symlinks or perform Git operations. Native paths replace Windows drive letters.

One shared native binding retains each window's repository, scope, operation and
private preference domain, observes preference changes, and retires on window
close. Bindings hold windows weakly. Advanced Apply refreshes bindings immediately.

## Verification and remaining work

See [the grouped native fixture](qa/repository-presentation-native-2026-10-15.swift)
and [testing instructions](TESTING.md#repository-presentation-family).
[Checkpoint evidence](qa/repository-presentation-2026-10-15.json) records the passing Debug build, nine focused Core checks and one native receiver (PID 40119, reaped and checked absent). The first build failed on a progress-model accessor and was repaired before the native run.

The Core tests cover setting modes, neighboring paths, selected-path scope,
Unicode compaction, tooltips, disabling and reset. Native verification covers
actual dialog construction, live private preference domains, Commit/Working Tree/
Log scope, native Add tooltip cells, reset and close retirement.

Physical hover and accessibility gestures, every list column, dialogs outside the
listed shared consumers, exact Windows compaction/locale differences, full layout
comparison and signed sandbox acceptance remain unverified. This shared batch
does not certify complete parity for any dialog.
