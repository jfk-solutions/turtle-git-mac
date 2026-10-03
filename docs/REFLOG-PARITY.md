# RefLog and Stash List parity

Reference: pinned `RefLogDlg.cpp/.h`, `refloglist.cpp/.h`, `RefLogCommand.cpp/.h`,
`IDD_REFLOG`, `GitLogListAction.cpp` and the
[official Reference Log manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-reflog.html).
This remains a partial port.

## Native layout and behavior

Stash List opens the RefLog window with `refs/stash`; RefLog opens with `HEAD`.
The top Ref selector spans the available row and lists HEAD and full repository
reference names. The single list uses upstream's column order: Hash, Ref, Action,
Message, Date. A row's identity is its reflog selector rather than its commit hash,
so repeated HEAD positions remain independently selectable.

The lower row keeps Search, conditionally visible Clear stash, OK, Cancel and
Help, with an additional native Refresh button. Search uses a native sheet with
Find Next and Match case. It selects matching rows and wraps instead of filtering
the underlying snapshot. Clear stash is hidden for other refs and disabled when
the stash list is empty. The window and controls disable while repository work
runs, retaining the repository access lease.

Stash context menus provide selected Apply, Delete, unified-diff inspection and
Copy hash using the original icons. Selected Apply passes the displayed commit
hash to the native restore controller, preventing a later stash-index change from
redirecting that selection. Inspection uses the first-parent diff and full commit
metadata. General reflog entries currently offer inspection and hash copying;
the rest of upstream's revision actions remain pending.

Deletion and Clear prompt with Abort/Delete. Before executing either, the core
reloads the complete stash reflog and compares it with the displayed snapshot.
An out-of-date view is rejected and reloaded. Multiple deletions run from oldest
to newest to preserve the selected positional indices, matching upstream's
safety check and reverse deletion order. This check is not a cross-process lock
against further changes between Git subprocesses.

## Evidence

Four core integration tests check selectors, timestamps, Unicode and colon-bearing
subjects, available refs, repeated HEAD history, multi-drop ordering, preservation
of HEAD/index/worktree, stale Drop/Clear rejection, clear-to-empty behavior and
invalid inputs. The full local suite passed 112 tests. The subsequent top-row
AppKit layout adjustment compiled successfully and was exercised natively.

Native QA used `/private/tmp/TurtleGitRefLogQA`, with two real stashes and unrelated
mixed changes. Search for Newer selected the matching entry. Clear then Abort left
the complete stash list unchanged. HEAD selection displayed three independent
entries pointing to the same commit and hid Clear stash. Selected Apply from the
older row's context menu restored `older` to tracked.txt while retaining both
stashes, HEAD, staged local.txt and its later working-tree contents.

The final AppKit selector was checked in `/private/tmp/TurtleGitRefLogLayoutQA`,
a disposable copy. HEAD/stash switching worked. Inspection showed the older stash's
full metadata and `-base/+older` patch. Selected Delete presented a one-entry
confirmation; Abort preserved HEAD, both stashes, index and working-tree diffs.
The full-width selector and five columns were captured in the actual native image
`site/assets/reflog.png` (2000 × 1124).

Some accessibility observations failed transiently during initial context-menu
checks; invoking the menu on a freshly loaded, unselected row succeeded and the
Apply, inspection and Delete Abort checks above were completed.

## Remaining

- Complete revision/ref context menus, deletion for non-stash reflogs and chooser mode.
- Upstream modeless search behavior, F3/F5 shortcuts, no-match presentation and
  broader case/Unicode search QA.
- Native multi-selection Delete execution, Clear execution, clipboard verification
  and stale-view error recovery. Core deletion tests do not prove these UI paths.
- Saved column widths/order, sorting, saved geometry, minimum-size and dark-mode QA.
- Log working-tree/stash menus, selected Pop and branch-from-stash workflows.
- Signed Finder invocation, multi-repository scope QA and sandbox runtime verification.
