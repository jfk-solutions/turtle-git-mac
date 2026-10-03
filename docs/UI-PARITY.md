# UI comparison requirements

Every ported window and context menu must be compared with the pinned TortoiseGit
source, resource layout and behavior. Native macOS controls replace Windows APIs;
the port must retain the arrangement, command hierarchy, selection semantics,
information density and interaction order. Generic dialogs remain temporary.

The complete resource inventory is `upstream-dialogs.csv` (129 dialogs). A native
replacement remains partial until its controls, enablement, context actions,
keyboard behavior, resizing and Git effects have been verified. The file audit in
`upstream-files.csv` records the source implementation separately from artwork.

## Current comparison

| Native window | Upstream reference | Evidence and remaining differences |
| --- | --- | --- |
| Log Messages | LogDlg, GitLogListBase, Show Log manual and LogMessages.png | Three panes, compact graph before list, refs, message, file statistics and basic revision menus verified. Actions column, working-tree row, reference chooser, statistics/walk/view controls and remaining menus pending. See LOG-PARITY.md. |
| Commit | CommitDlg, IDD_COMMITDLG, Commit.png, PatchViewDlg | Message above checked file list; independent checkbox/highlight selection; optional three-state staging; native commits exercised in both modes. Attached right-hand patch window with native line/hunk staging and unstaging verified. Native Find, Save As, Escape, saved width and show/hide labels ported. Unsupported file types, remaining options and menus pending. See COMMIT-PARITY.md. |
| Repository status | RepoStatusDlg and GitStatusListCtrl | Current main-window sidebar/output layout differs from upstream standalone status dialog. It needs its native dialog, full columns/groups, context menus and upstream controls. |
| Operation confirmation | Per-command dialog sources/resources | Current generic one-field dialog differs from upstream Fetch, Pull, Push, Branch/Tag, Switch, Merge, Rebase, Stash and Clone dialogs. Each needs its own native replacement and workflow/options audit. |
| Diff | TortoiseMerge and TortoiseUDiff | Monospaced unified patches are available. Side-by-side editor, navigation, syntax/line rendering, binary handling and full editor behavior remain pending. Partial staging is available in the Commit patch window. |
| Finder menu | ShellExt.cpp, resource shell menu, cache states | Original icons and full path selection dispatch implemented. Menu conditions, command coverage, separators, configuration and signed native appearance still need comparison/QA. Finder placement follows macOS extension rules. |

## Verification procedure for each replacement

1. Find the upstream resource and its dialog implementation; capture every control
   and context command, including hidden conditional states and split buttons.
2. Compare the native window with the upstream reference at ordinary and minimum
   sizes, light/dark appearances and common data sizes. Check graph/column placement,
   file groups, message ordering, icons, command names and enabled states.
3. Exercise empty repositories, file/folder requests, multiple selection, renames,
   binary files, staged/unstaged combinations, conflicts and relevant Git states.
4. Verify keyboard actions, double-click, right-click targeting and resizing using
   the running native app. Check resulting Git state with real integration tests.
5. Record remaining differences explicitly; update the corresponding parity document
   and inventory. Do not treat compilation or a screenshot as complete UI parity.

Screenshots must use disposable repositories. A native UI interaction failure must
be diagnosed or recorded as unverified, never replaced with an invented mockup.
