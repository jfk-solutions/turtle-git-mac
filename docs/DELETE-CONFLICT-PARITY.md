# Delete/modify conflict parity

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`, DeleteConflictDlg.cpp/.h,
all fourteen IDD_RESOLVE_CONFLICT controls, CAppUtils::ConflictEdit and its
GetConflictTitles/DescribeConflictFile helpers.

## Native window

The native Conflict window retains the Delete/modify merge conflict group, path,
two reference/status rows, Show log for each available side, conditional Show
changes beside the surviving side, Modified (or Created), Delete, Abort and Help.
Abort is the default Return action; Escape also aborts. Deleted and Modified use
the upstream file-status colors. Show log keeps its visible label while carrying
a distinct accessibility label for each reference. The original menuconflict.ico
is copied unchanged with hash/GPL provenance for Edit conflict. Actual light/dark
captures are site/assets/delete-conflict.png and delete-conflict-dark.png, both
1520 × 562 pixels.

Edit conflict appears for one ordinary DU/UD/AU/UA file in Commit, Working Tree
and workspace context menus. Commit/Working Tree double-clicks and Resolve's
single missing-side double-click open the same window. Submodules are excluded;
UTF-8 text merging and the Base/Mine/Theirs submodule chooser now have separate
partial native editors (TEXT-MERGE-PARITY.md and SUBMODULE-CONFLICT-PARITY.md). The Finder shell Edit conflict menu is not exposed until the
full editor dispatch is available. Debug Finder-style URLs exercise scoped app
routing but do not prove signed Finder activation.

With a base version, the keep button is Modified and Show changes is visible only
on the surviving side. With no base it is Created and both comparison buttons
are hidden. Normal merges display stage 2 then stage 3. Rebase displays stage 3
(the commit being replayed) first and stage 2 (the branch being rebased onto)
second, matching upstream's reversal while retaining actual index stage numbers.
HEAD, MERGE_HEAD, CHERRY_PICK_HEAD, REVERT_HEAD and REBASE_HEAD supply side commit
identity; merge refs are described from matching branches when available.

## Operations and history

Modified/Created stages the current working contents with ordinary git add,
not a forced checkout of the surviving blob. Delete uses ordinary git rm,
allowing Git's refusal/errors rather than forcing removal. The captured conflict
stages and selected path/parent ownership are validated before mutation through
the shared Resolve checks. Stale conflicts, text merges and submodule conflicts
cannot be deleted through this dialog. No action commits or continues a merge,
rebase or cherry-pick. The access lease stays alive; Store builds require covering
repository scope.

Show changes displays the stage-1-to-working-contents unified diff. Upstream opens
its external side-by-side diff tool; that full editor remains unported. No adjacent
.LOCAL/.REMOTE/.BASE temporary files are produced or blindly removed.

Show log opens a distinct Log window scoped to the path and exact side commit.
History verifies the commit and walks that commit's ancestors, rather than HEAD
or unrelated branches. The target is captured as a full hash and shown in the
window title. All Branches is disabled for an explicitly bounded history.
Full reference/rename-aware history and upstream chooser behavior remain pending.

## Verification

The full suite passed 158 tests. Five DeleteConflict tests cover both deletion
orientations, reviewed current contents, base comparison, exact ordinary deletion,
unchanged unrelated index/working changes and refs, MERGE_HEAD retention, stale
snapshots, unsupported editor types, rebase reversal, bounded incoming history,
option-as-revision rejection and a real file/directory conflict with no base and
the Created choice. Ten existing Resolve tests and icon decoding also pass.
The accessibility labels and bounded-history checkbox enablement compiled after
the full suite.

Native /private/tmp/TurtleGitDeleteConflictQA showed the expected two statuses,
reference identities, conditional Show changes and blue default Abort. Show
changes displayed the exact base-to-reviewed README patch. After distinct
accessibility labels were added, the incoming Show log opened its exact commit,
selected it and showed only README history. These inspections preserved the
captured HEAD, refs, index, status and every working file. Sending Return to the
Abort preview also left the complete baseline unchanged.

Native Modified staged Reviewed README to keep, removed its unmerged entries and
preserved HEAD/refs/all working files/all unrelated index entries and MERGE_HEAD.
Observations after closing Log or the conflict window timed out or reported no
window while inventory still showed the original preview running. Git effects
are proven; parent restoration is not claimed. Pre-label-adjustment Show log
interaction was ambiguous, and is not counted as a successful handoff.

## Remaining parity

Native Created, both orientations/rebase/cherry-pick/revert, Delete execution,
stale/error retry, Help, Escape/keyboard focus and parent refresh/selection need
broader QA. Full side-by-side comparison, merge editor, temporary artifact ownership,
submodule conflict chooser, Finder menu coverage and signed sandbox runtime remain
pending. All dialog/control workflow records remain partial.
