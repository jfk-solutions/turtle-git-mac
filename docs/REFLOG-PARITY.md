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
Help, with an additional native Refresh button. Search uses a native modeless Find window with
Find Next and Match case. It selects matching rows and wraps instead of filtering
the underlying snapshot. Clear stash is hidden for other refs and disabled when
the stash list is empty. The window and controls disable while repository work
runs, retaining the repository access lease.

Stash context menus provide Show log, selected Apply, Delete, unified-diff
inspection and Copy to clipboard using the original icons. Selected Apply passes the displayed commit
hash to the native restore controller, preventing a later stash-index change from
redirecting that selection. Inspection uses the first-parent diff and full commit
metadata. General reflog entries currently offer Log navigation, inspection and
the three clipboard formats; other revision actions remain pending.

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

- Complete revision/ref context menus and deletion for non-stash reflogs.
- Physical row activation/chooser double-click and normal stash-mode regression QA;
  headless selection-mode rejection is checked in the actions receiver below.
- Physical modeless Find focus, F3/F5 routing, scroll-to-match and broader
  Unicode search acceptance; the native receiver checks are recorded below.
- Native multi-selection Delete execution, Clear execution, clipboard verification
  and stale-view error recovery. Core deletion tests do not prove these UI paths.
- Saved column widths/order, sorting, saved geometry, minimum-size and dark-mode QA.
- Log working-tree/stash menus, selected Pop and branch-from-stash workflows.
- Signed Finder invocation, multi-repository scope QA and sandbox runtime verification.

## Changed Files revision chooser

RefLog now supports an optional selection callback. In this mode OK accepts exactly
one entry's immutable hash; Cancel returns no entry, and primary row activation
accepts the selection. Stash mutation controls and model methods are disabled while
choosing a revision. The normal window continues to use OK/Cancel to close; its row
activation now opens scoped Log, as recorded below. Its repository access lease remains retained, and reads
require the repository's security scope in App Store builds.

Dark native QA opened the chooser from Changed Files, selected the earlier HEAD
entry, accepted it and verified the destination hash and empty comparison against
the same base. Reopening and cancelling preserved both revision fields. Parent and
child HEAD, the child index and its dirty file were unchanged, and the QA process
was closed. See [comparison evidence](SUBMODULE-DIFF-PARITY.md) for screenshots and
remaining chooser checks. This does not verify all ordinary RefLog workflows in
dark mode.

## Modeless Find and function keys

Search and Command-F now open a separate native Find window, retaining a single
instance per RefLog window. Repeating Search or F3 focuses that existing window
and retains its search text and case option. Cancel or its close gesture releases
it; reopening starts with empty text and Match case off. Closing RefLog closes
its owned Find window. The list remains usable while Find stays open, matching
`CRefLogDlg::OnFind` instead of blocking the list with a sheet.

F3 opens Find and F5 refreshes through the owning native window's key handler;
Command-F/Command-R remain macOS shortcuts. Function keys and Find Next are gated
while the list loads. Refresh retains the Find window and resets its search cursor.
Find starts at the selected row, advances after each match, wraps through the
list and searches the ref, action, full hash and reflog message as newline-separated
fields. Manual selection repositions the cursor. Match case uses native Unicode
matching. A search starting past the last row shows an accessible wrap message;
editing the text or case option clears that message. A no-match search reports
the requested text and retains selection. Windows taskbar/window
flashing is replaced by that message. Commit-message bodies are not loaded by this
reflog reader; the reflog action/message are the available search payload.

[Native receiver](qa/reflog-search-native-2026-10-08.swift) and
[QA record](qa/reflog-search-2026-10-08.json) cover actual hidden Find/RefLog window
ownership, singleton reuse, close/reopen and parent cleanup; direct constructed
function-key inputs; real ref/action/hash/case/cursor search and refresh; chooser
mode search; and byte-exact HEAD/index/config/worktree preservation. No events
are sent to an application and these checks do not establish physical key routing,
Find focus, scroll-to-match, rendered light/dark layout or signed sandbox execution.
The full RefLog/dialog/application port remains incomplete.

## Log navigation and clipboard submenu

Ordinary RefLog row activation now follows `CRefLogList::OnNMDblclkLoglist`: it
opens Log at the first selected row's immutable hash instead of opening a patch.
The Show log context action accepts exactly one current row. The repository
window owner retains/reuses the scoped Log independently of RefLog, so closing
RefLog leaves that explicitly opened Log available. The handoff retains the
repository access lease, sets the end revision and selected revision to that hash,
hides the working-tree row, clears text/date filters and removes file scope.
Selection-mode activation continues to accept exactly one revision; chooser
windows without a Log handoff disable that separate context command.

Copy to clipboard now contains **Full data**, **SHA-1**, **Messages**, in source
order, all using the original Copy icon. Full data exports Revision/Date/Message
for each selected row. Messages uses `* action: message` followed by a blank line;
SHA-1 exports one hash per row, retaining repeated hashes for distinct reflog
selectors. Selection follows the displayed row order. The source CRLF separators
are retained; empty/stale selection and loading leave the clipboard unchanged.
The native Unicode pasteboard preserves non-ASCII messages. The Date column and
Full data share the existing short/long, relative and system-locale Log date
preferences instead of an independent RefLog date style.

[Actions receiver](qa/reflog-actions-native-2026-10-08.swift) and
[QA record](qa/reflog-actions-2026-10-08.json) cover real older-revision Log loading,
selected hash and newer/working-tree exclusion, text/date-filter reset, dispatch
and chooser guards, ordered Unicode/duplicate-hash clipboard formats, a private
pasteboard, fixed date formatting and unchanged HEAD/index/config/worktree. The
receiver never displays windows or modifies the general clipboard. Actual
menu/icon rendering, physical row activation and window handoff/reuse, locale/
relative-time date rendering, chooser Log handoff, full revision actions and
signed sandbox execution remain pending. This is partial RefLog parity.
