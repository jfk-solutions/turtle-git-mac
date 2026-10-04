# Delete / Delete (keep local) parity

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
`Commands/RemoveCommand.cpp/.h`, `TortoiseShell/MenuInfo.cpp`, shell menu resources
and the removal warning/button/result strings in `TortoiseProcENG.rc`.
Upstream uses message boxes rather than a dedicated IDD dialog.

## Implemented

Delete and Delete (keep local) use the original `menudelete.ico`, copied unchanged
with its provenance/hash recorded. Workspace menus and Finder dispatch open an
owned native window with a confirmation sheet. Single/multiple selection wording
follows upstream. Abort is the default. Normal deletion removes versioned working
files, including modifications; keep local removes them only from the index.
Neither command makes a commit.

Selections are processed individually with separate arguments to
`git rm -r -f [--cached] -- path`. A failed item offers Ignore/Abort, with Abort the
default. Ignore continues with the next item. The final count reports successful
selected items, so a recursively removed directory counts as one item, as upstream.
The repository access lease stays alive through the operation; Store builds require
a matching security scope. Signed sandbox runtime remains unverified.

The backend rejects bare repositories, empty/admin/outside paths, nested repository
contents and stale/unversioned selections before mutation. Selected symlinks are
removed as links. Recursive Git removal retains untracked directory children.
Finder eligibility uses the cached common root and versioned states, excluding roots,
added/untracked/ignored/deleted paths; full upstream submodule eligibility remains pending.

Git reports a retained copy as both an index deletion and an untracked path. The
status model merges these into one identity, retaining the deletion and local-copy
flag. Checkbox Commit uses a separate index for checked retained-copy deletions so
Git cannot silently re-add their working contents. Both HEAD and parent comparison
amendments retain that flag. Unrelated staged files remain in the real index. After
a successful deletion commit the remaining copy appears as untracked. Explicit
Add/Stage can still re-add it. Staging-mode Commit continues to commit the real index.

Upstream GitStatusListCtrl's built-in Delete is a separate filesystem workflow;
its old Git Remove block is commented out. These Git commands are therefore not
substituted for that Commit/Working Tree menu action. Open dialogs refresh after
removal; full selection restoration and local filesystem Delete remain pending.

## Verification

The full Swift suite passes 134 tests. Six removal tests exercise forced removal,
keep-local deletion commits and both amendment baselines, unrelated mixed index/
worktree preservation, literal directory names, symlinks, stale/nested/admin rejection
and cached Finder eligibility. Existing commit/amend/icon tests also pass.

Native QA used `/private/tmp/TurtleGitRemoveQA` through the Debug Finder-request
handler. The two-path keep-local confirmation opened in front, offered Remove/Abort,
and reported `2 files removed.` after Remove. CLI comparison against a saved baseline
proved unchanged HEAD, refs and every working file, with both selected paths absent
from the index. This checks app dispatch, not signed external Finder activation.
Screenshot capture failed with a macOS audio/video recording error; no screenshot
is published for this workflow. Clicking result OK timed out in UI observation; the
app inventory still reported the preview running. Closure/restored selection is not
claimed as verified.

Native normal-Delete confirmation Abort on `/private/tmp/TurtleGitRemoveAbortQA`
left HEAD, index, status and every working file unchanged. In independent three-path
keep-local fixtures, making the second path stale after confirmation exercised the
error prompt: Ignore continued to the third item and reported two successes; Abort
left the third item indexed and reported one. All local files were preserved. The
dark-mode error sheet was inspected directly and its wrapped path/text/buttons were
readable. Saved screenshot capture remains unresolved.

A separate Commit preview opened on the keep-local fixture. The scoped list showed
exactly two checked Deleted rows, one per selected path. Entering a message and
pressing Commit recorded both deletions. CLI inspection verified the exact message,
both paths absent from HEAD, every working file unchanged, and retained copies now
untracked. UI observation reported no available window after Commit; restored
workspace selection remains unverified.

## Remaining parity and QA

Native normal-delete execution, full light/dark resize checks, keyboard traversal,
result closure and parent selection need verification. Full Finder conditions,
submodules/gitmodules handling, cache invalidation, signed sandbox behavior, external
URL activation and live progress/cancellation also remain. This is a partial port.
