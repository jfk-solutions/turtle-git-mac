# UI comparison requirements

Every ported window and context menu must be compared with the pinned TortoiseGit
source, resource layout and behavior. Native macOS controls replace Windows APIs;
the port must retain the arrangement, command hierarchy, selection semantics,
information density and interaction order. Generic dialogs remain temporary.

The complete resource inventory is `upstream-dialogs.csv` (129 dialogs).
`upstream-controls.csv` now inventories 1,648 static controls at that same pinned
commit, including hidden controls, IDs, labels and full resource declarations.
Regenerate it with `python3 scripts/inventory-dialog-controls.py`. Pending controls
require native mapping, enablement/layout comparison and operational evidence;
this inventory does not prove those checks have passed. Dynamic menus, histories,
plugin controls and state transitions also require source review. A native
replacement remains partial until its controls, enablement, context actions,
keyboard behavior, resizing and Git effects have been verified. The file audit in
`upstream-files.csv` records the source implementation separately from artwork.

## Current comparison

| Native window | Upstream reference | Evidence and remaining differences |
| --- | --- | --- |
| Log Messages | LogDlg, GitLogListBase, Show Log manual and LogMessages.png | Three panes, compact graph before list, refs, message, file statistics and basic revision menus verified. Actions column, working-tree row, reference chooser, statistics/walk/view controls and remaining menus pending. See LOG-PARITY.md. |
| Commit | CommitDlg, IDD_COMMITDLG, Commit.png, PatchViewDlg | Message above checked file list; independent checkbox/highlight selection; optional three-state staging; native commits exercised in both modes. Attached right-hand patch window with native line/hunk staging and unstaging verified. Native Find, Save As, Escape, saved width and show/hide labels ported. Parent/HEAD amend comparison and native selective amendment verified. Read-only View Patch and saved repository staging/patch preferences implemented; native restoration checks recorded. Second-precision author date/time, override and Reset amendments verified. Saved Message/Changes divider drag, adjustment and minimum-window checks verified. Template/operation-message loading and unchanged-template warning implemented; real Git seed tests pass, native template No and ReCommit reset verified. Recent-message insertion, multiple selection, Delete, double-click, Undo, Cancel Yes/No and corrected native history layout verified; broader history QA pending. Unsupported file types, remaining options and menus pending. See COMMIT-PARITY.md. |
| Repository status | ChangedDlg, IDD_CHANGEDFILES and GitStatusListCtrl | Standalone branch/list/filter/action layout, six columns, native filter and stage/unstage/diff/export checks. Full context menus, persisted options, cancellation and remote checks pending. See STATUS-PARITY.md. |
| Switch/Checkout | GitSwitchDlg, IDD_GITSWITCH, SwitchCommand and CChooseVersion | Native Branch/Tag/Commit rows and option controls; native branch creation and return preserve index/worktree patches. Full chooser, progress and broader UI QA pending. See SWITCH-PARITY.md. |
| New Branch/Tag | CreateBranchTagDlg, IDD_NEW_BRANCH_TAG, BranchCommand, TagCommand and CAppUtils | Native name/revision/options/description or message layout; native branch, annotated tag and optional checkout preserve index/worktree contents. Full choosers, signing UI and broader QA pending. See BRANCH-TAG-PARITY.md. |
| Push | PushDlg, IDD_PUSH, PushCommand and CAppUtils | Native reference/destination/options arrangement; branch/upstream and tag-scoped handoff verified with unchanged index/worktree patches. Basic Manage and cached ref browsers; full choosers/settings, progress, cancellation and authentication pending. See PUSH-PARITY.md. |
| Fetch | PullFetchDlg, IDD_PULLFETCH, FetchCommand and CAppUtils | Native control arrangement and three-state Tags/Prune; URL branch browse/fetch and configured named-remote fetch verified with unchanged HEAD/index/worktree. Fetch → Rebase plan verified; full settings, progress and broader QA pending. See FETCH-PARITY.md. |
| Pull | PullFetchDlg, IDD_PULLFETCH, PullCommand and CAppUtils | Shared native remote/options window; fast-forward pull preserves unrelated mixed changes, flag enablement and error → Working Tree verified. Configured Pull → Rebase auto-start verified; progress and full recovery pending. See PULL-PARITY.md. |
| Rebase | RebaseDlg, IDD_REBASE, RebaseCommand, GitLogListBase and official manual | Native branch/action/list/lower-tabs arrangement, original icons and light/dark captures. Real Start/Skip and recovered Edit/Amend verified; Fetch/Pull handoffs verified; full recovery QA and advanced controls pending. See REBASE-PARITY.md. |
| Operation confirmation | Per-command dialog sources/resources | Current generic prompts differ from upstream Merge, Stash and Clone dialogs. Each needs its own native replacement and workflow/options audit. |
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

## Color and documentation references

Compare with the [official manual’s dialog screenshots](https://tortoisegit.org/docs/)
and pinned resources in both light and dark appearances. Preserve semantic status
colors, colored command artwork, graph lanes and reference labels; see
[APPEARANCE.md](APPEARANCE.md). The future user-facing guide follows the upstream
manual’s organization with Mac-specific screenshots/instructions; see
[MANUAL-PLAN.md](MANUAL-PLAN.md). These references are part of each dialog audit,
not a claim that all existing dialogs have passed visual QA.
