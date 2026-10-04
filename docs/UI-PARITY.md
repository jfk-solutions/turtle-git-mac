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
| Log Messages | LogDlg, GitLogListBase, Show Log manual and LogMessages.png | Three panes, compact graph before list, refs, message, file statistics and basic revision menus verified. Commit revision-selection mode and acceptance/cancel/search guards checked. Actions column, working-tree row, reference chooser, statistics/walk/view controls and remaining menus pending. See LOG-PARITY.md. |
| Commit | CommitDlg, IDD_COMMITDLG, Commit.png, PatchViewDlg | Message above checked file list; independent checkbox/highlight selection; optional three-state staging; native commits exercised in both modes. Attached right-hand patch window with native line/hunk staging and unstaging verified. Native Find, Save As, Escape, saved width and show/hide labels ported. Parent/HEAD amend comparison and native selective amendment verified. Read-only View Patch and saved repository staging/patch preferences implemented; native restoration checks recorded. Second-precision author date/time, override and Reset amendments verified. Saved Message/Changes divider drag, adjustment and minimum-window checks verified. Template/operation-message loading and unchanged-template warning implemented; real Git seed tests pass, native template No and ReCommit reset verified. Recent-message insertion, multiple selection, Delete, double-click, Undo, Cancel Yes/No and corrected native history layout verified; broader history QA pending. Native Pick commit hash/message insertion, Cancel, Undo and selection/search guards verified. File Open/Open With/Finder/Log/clipboard menu commands implemented; clipboard and chooser checks recorded, external handoffs pending. Selected-row contrast corrected and captured. Unsupported file types, remaining options and menus pending. See COMMIT-PARITY.md. |
| Repository status | ChangedDlg, IDD_CHANGEDFILES and GitStatusListCtrl | Standalone branch/list/filter/action layout, six columns, native filter and stage/unstage/diff/export checks. Full context menus, persisted options, cancellation and remote checks pending. See STATUS-PARITY.md. |
| Switch/Checkout | GitSwitchDlg, IDD_GITSWITCH, SwitchCommand and CChooseVersion | Native Branch/Tag/Commit rows and option controls; native branch creation and return preserve index/worktree patches. Full chooser, progress and broader UI QA pending. See SWITCH-PARITY.md. |
| New Branch/Tag | CreateBranchTagDlg, IDD_NEW_BRANCH_TAG, BranchCommand, TagCommand and CAppUtils | Native name/revision/options/description or message layout; native branch, annotated tag and optional checkout preserve index/worktree contents. Full choosers, signing UI and broader QA pending. See BRANCH-TAG-PARITY.md. |
| Push | PushDlg, IDD_PUSH, PushCommand and CAppUtils | Native reference/destination/options arrangement; branch/upstream and tag-scoped handoff verified with unchanged index/worktree patches. Basic Manage and cached ref browsers; full choosers/settings, progress, cancellation and authentication pending. See PUSH-PARITY.md. |
| Fetch | PullFetchDlg, IDD_PULLFETCH, FetchCommand and CAppUtils | Native control arrangement and three-state Tags/Prune; URL branch browse/fetch and configured named-remote fetch verified with unchanged HEAD/index/worktree. Fetch → Rebase plan verified; full settings, progress and broader QA pending. See FETCH-PARITY.md. |
| Pull | PullFetchDlg, IDD_PULLFETCH, PullCommand and CAppUtils | Shared native remote/options window; fast-forward pull preserves unrelated mixed changes, flag enablement and error → Working Tree verified. Configured Pull → Rebase auto-start verified; progress and full recovery pending. See PULL-PARITY.md. |
| Rebase | RebaseDlg, IDD_REBASE, RebaseCommand, GitLogListBase and official manual | Native branch/action/list/lower-tabs arrangement, original icons and light/dark captures. Real Start/Skip and recovered Edit/Amend verified; Fetch/Pull handoffs verified; full recovery QA and advanced controls pending. See REBASE-PARITY.md. |
| Merge | MergeDlg, IDD_MERGE, MergeCommand and AppUtils::DoMerge | Native revision/options/message arrangement, conditional enablement, No Commit merge and staging Commit completion verified; strategy tests pass. Full history/choosers/progress/recovery pending. See MERGE-PARITY.md. |
| Stash Save | StashSave, IDD_STASH, AppUtils::StashSave and official manual | Optional message, mutually exclusive untracked/all controls and Abort/Continue warning verified natively; tracked/index/untracked/ignored effects tested. Progress/post-actions, suppression persistence after Continue and broader appearance/resize QA pending. See STASH-PARITY.md. |
| Stash Apply/Pop | AppUtils::StashApply/StashPop, StashCommand and official manual | Immediate operation, native progress/result prompts and Yes → Working Tree verified for success/conflict; Git retains failed/conflicted stash. Selected UI, full recovery, preference relaunch and signed Finder QA pending. See STASH-PARITY.md. |
| RefLog / Stash List | RefLogDlg, refloglist, IDD_REFLOG and RefLogCommand | Full-width Ref selector and upstream five-column order, native Search, selected Apply, inspection and Delete/Clear Abort verified. Real Git stale snapshot and multi-drop tests pass. Full menus, persistence, sorting, deletion execution and dark/resize QA pending. See REFLOG-PARITY.md. |
| Clone | CloneDlg, IDD_CLONE, CloneCommand and CloneProgressCommand | Native upstream option groups and conditional enablement; shallow selected branch/custom origin, SVN-unavailable error → Retry and Show Log verified. Five core tests cover bare/no-checkout/recursive effects, validation and literal SSH key arguments. Native picker/Cancel, authentication, real SVN, progress and signed sandbox QA pending. See CLONE-PARITY.md. |
| Create Repository | CreateRepoDlg, IDD_CREATEREPO and CreateRepositoryCommand | Native Bare/text/OK/Cancel/Help arrangement, .git default and destination warnings; normal/bare creation, Cancel, occupied-bare Abort and bare workspace/Log verified. Picker confirmation, adoption/recent behavior, signed Finder and broader QA pending. See INIT-PARITY.md. |
| Rename | RenameDlg, IDD_RENAME, RenameCommand and MenuInfo | Native six-control arrangement, original icon and Commit/Working Tree/Finder entry points. Native collision → correction, two mixed-file renames and menu handoffs verified; browse, post-close restoration, signed Finder and broader QA pending. See RENAME-PARITY.md. |
| Delete / keep local | RemoveCommand, shell resources and warning/result strings (no dedicated IDD) | Native confirmation and successful two-path keep-local removal verified; retained-copy commit/amend behavior tested. Native confirmation Abort, Ignore/Abort continuation and checked-deletion Commit handoff verified. Full appearance/keyboard QA, submodules and signed Finder pending. See REMOVE-PARITY.md. |
| Ignore | IgnoreDlg, IDD_IGNORE, IgnoreCommand, AppUtils and shell/status-list menus | All ten controls mapped to native groups/radios/buttons; native Cancel, per-folder recursive rules, dark Delete-and-ignore keep-local extension rules and Commit/Working Tree menu handoffs verified. Full menus, recovery, permissions and broader QA pending. See IGNORE-PARITY.md. |
| Delete/modify conflict | DeleteConflictDlg, IDD_RESOLVE_CONFLICT and CAppUtils::ConflictEdit | Native path/reference/status/buttons arrangement, light/dark captures, conditional comparison, incoming-side Log and Modified effects verified. Full comparison editor, Created/rebase/Delete/error/native parent QA remain pending; see DELETE-CONFLICT-PARITY.md. |
| Resolve | ResolveDlg, IDD_RESOLVE, ResolveCommand and shared conflict actions | Native six-control checked list, current/mine/theirs, original icon and app/Finder dispatch; checked-current/Cancel and submodule Reset/resume verified. Full conflict editor, submodule chooser, progress, signed Finder and broader QA pending; see RESOLVE-PARITY.md. |
| Reset | ResetDlg, IDD_RESET, CChooseVersion and CAppUtils::GitReset | Native nineteen-control mapping, light/dark captures, Mixed and submodule Soft/resolution effects verified. Full ref/log/diff-list, progress, Hard warning/recovery, parent restoration and signed QA pending; see RESET-PARITY.md. |
| Diff / text merge | TortoiseMerge, CAppUtils::ConflictEdit and TortoiseUDiff | Native three-pane UTF-8 conflict editor, line numbers, block choices and guarded Save/Mark as resolved. Core tests and initial native block/Find checks pass; full aligned diff views, menus and native acceptance remain partial. See TEXT-MERGE-PARITY.md. Partial staging remains available in the Commit patch window. |
| Settings / Merge General | SetMainPage, IDD_SETMAINPAGE, MainFrm width bounds and BaseView defaults | Native Appearance and Merge Editor tabs. Use spaces, Smart tab char and Tab size saved with Apply/Cancel; invalid zero, live clean-pane updates and relaunch verified. Other General/Colors controls, EditorConfig and full settings behavior pending. See TEXT-MERGE-PARITY.md. |
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

Submodule conflict: native 26-control resource mapping, checkout Base, colored
types, side choices and rebase stage ordering are partial; see
[SUBMODULE-CONFLICT-PARITY.md](SUBMODULE-CONFLICT-PARITY.md).

Submodule Delete/Abort, recoverable Trash, and file-to-gitlink directory conversion
are implemented with native Abort/Delete effects verified. Registered/multi-item
removal and reverse transitions remain partial. Shared command labels now respect
template tinting for monochrome Log, Help and cherry-pick artwork.

Text conflict editor now has aligned read-only source rows, original source
numbers, and upstream light/dark removed/added/conflicted/empty colors. Both
actual native captures were inspected. The full suite passes 180 tests. Exact
libsvn alignment parity and synchronized scrolling acceptance remain pending;
logical Command-Z and Shift-Command-Z are verified on the QA host; broader keyboard combinations remain pending. See [Text merge parity](TEXT-MERGE-PARITY.md).

Merge source panes now offer Use this whole file. Native Mine, Theirs, Undo/Redo and unsaved-close Cancel were verified; rebase
native combinations remain pending. Reload is visible with original artwork
and successful-load history reset. Its dirty prompt and Cancel were verified;
confirmed reload/reset acceptance remains pending.

Reload now offers Save and Reload, Reload Without Saving and Cancel, matching
the reviewed upstream three-way Save check. Native Save and Reload wrote exact
Mine bytes and preserved unresolved stages; post-reload rendering/history and
the new prompt's other choices remain unverified after observer timeouts.

EOF source metadata now preserves missing final newlines for the unchanged final
conflict, including a separator for combined choices. Native combined choice
and Save bytes were verified; CRLF/resolution/Undo native combinations remain
pending. Full upstream EOL/encoding parity is still incomplete.

The text merge result now offers the upstream nine-style line-ending submenu
with reversible conversion. A shared UTF-16 scanner fixes CRLF marker detection
and caret line numbers. Native CRLF → LF, Undo/Redo and unresolved Save warning
were verified; complete EOL/encoding metadata and exotic native combinations
remain partial. See TEXT-MERGE-PARITY.md.

The text merge context menu now includes upstream leading tabs/spaces
conversion and Trim right, with single-step Undo and conditional availability.
Native conversion, Undo and exact Unicode/CRLF Save bytes were verified.
Global tab-width preferences, EditorConfig and locale-specific Unicode trim remain
pending. See TEXT-MERGE-PARITY.md.

The merge editor now has independent 1/2/4/8 tab-width menus in each pane.
Native width changes preserved clean state and Undo history; merged-result
conversion and Save bytes at width eight were verified. Global persistence,
global insertion-mode preferences and EditorConfig remain pending.

Merge pane menus now include Tab/Space and Smart tab char. Native Space
insertion, nearby-tab Smart choice, multiline Tab/Shift-Tab, Undo and exact Save
bytes were verified. Global preferences, EditorConfig, precise partial-column
selection restoration and broader key/view behavior remain pending.
