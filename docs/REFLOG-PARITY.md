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
inspection and Copy to clipboard using the original icons. Delete also applies
to HEAD and ordinary full-reference logs. Selected Apply passes the displayed commit
hash to the native restore controller, preventing a later stash-index change from
redirecting that selection. Unified inspection now uses the shared read-only
diff viewer and source parent/two-revision choices, as recorded below. General reflog entries also offer Browse repository, Create Branch/Tag and
Export at the selected revision, plus the three two-entry Log ranges. These use the original command icons and the
existing native dialogs; other revision actions remain pending.

Deletion and Clear prompt with Delete/Abort. Selected Delete defaults to Delete;
Clear stash defaults to Abort, matching their distinct source calls. Before executing either, the core
reloads the complete relevant reflog and compares it with the displayed snapshot.
An out-of-date view is rejected and reloaded. Multiple deletions run from oldest
to newest to preserve the selected positional indices, matching upstream's
safety check and reverse deletion order. Ordinary entries use `git reflog delete`
without moving their reference; stash entries use `git stash drop`. This check is not a cross-process lock
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

- Complete revision/ref context menus and physical non-stash deletion acceptance;
  the new general deletion path is recorded below.
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

## General reflog deletion

Delete now appears for HEAD and other reference logs as well as stash. Singular
confirmation names the selected positional selector and uses the source's permanent
deletion warning; multiple selection names the count. Delete/Abort buttons retain
the source defaults: Delete for selected entries, Abort for Clear stash. Clear is
still only available for the stash log. Revision choosers suppress deletion.

Acceptance captures the reference, selectors and full displayed snapshot. A
changed reference/view while confirmation is pending is rejected. Core reloads
and compares every entry immediately before transport, rejecting shifted, altered
or stale logs; canonical HEAD/full-ref validation and membership checks prevent
cross-log or malformed selectors. This full comparison is stronger than upstream's
count/endpoint check. Entries delete from oldest to newest so original indices
remain valid. Ordinary logs use `git reflog delete -- <full selector>` without
`--updateref`; deleting their final entry leaves the ref/HEAD intact. The stash
path retains `stash drop` and Clear retains `stash clear`, with their stack/ref
semantics. Errors retain the dialog and reload; successful deletion refreshes
repository views. The preflight comparison is not a cross-process lock, and
partial command failure is not rolled back. The native batch now continues after
command failures, with per-failure acknowledgement and partial-result refresh,
as recorded below.

[Deletion receiver](qa/reflog-deletion-native-2026-10-08.swift) and
[QA record](qa/reflog-deletion-2026-10-08.json) cover source confirmation text,
Abort retention, actual HEAD/branch-log deletion, stale-after-prompt and changed-ref
rejection, whole-log removal without moving the ref, stash Drop/Clear regression,
chooser guards, hidden native default-button alerts and HEAD/index/config/worktree
preservation for general deletion. Six Core reflog tests also cover invalid refs,
cross-log selection and stale snapshots. These checks do not exercise displayed
prompt clicks or menu routing. Physical deletion/recovery, command failure presentation, concurrent external
writers, signed sandbox execution and full RefLog
revision-menu parity remain pending.

## Deletion command failures and continuation

The selected-entry batch now follows `ID_REFLOG_DEL`'s error loop: attempt every
selected positional entry from oldest to newest, report each command failure and
continue after acknowledgement. The shared Core path applies to ordinary reflogs
and stash Drop; Clear stash remains one command. The entire snapshot/reference/
selection validation still precedes the first command and prevents execution on
preflight failure. Source command order preserves younger original indices when
an older command fails. Concurrent external writers can still invalidate those
positions while an error is being acknowledged; this is not a cross-process lock.

Core records completed selectors, accumulated successful output and every failed
selector with its diagnostic. It throws a structured partial-result failure only
after all attempts. An optional async failure handler lets the native controller
show each error sheet before starting the next command. The dialog keeps its
repository access and busy state while acknowledging errors. The final batch
refreshes the list and repository views even when every command fails. A native
caption retains the aggregate result without repeating individual errors in a
second modal prompt; headless callers without a presenter receive the summary
error. Retry uses the newly loaded snapshot and clears the prior report. Completed
deletions are not rolled back. Delete now precedes Stash apply in the context menu,
matching the upstream ordering of those entries.

[Partial-failure receiver](qa/reflog-partial-failure-native-2026-10-08.swift) and
[QA record](qa/reflog-partial-failure-2026-10-08.json) inject a real Git command
failure in the middle of HEAD and stash batches, verify later deletions and their
remaining rows, pause in async failure acknowledgement to verify no next command
has started, check all-failed refresh and retry/report reset, preserve Unicode
diagnostics and verify ordinary HEAD/index/config/worktree preservation. The
existing general deletion receiver and eight Core tests retain snapshot/selector
validation, confirmations, Drop/Clear and chooser guards. Actual error sheets,
caption/menu rendering, native retry gestures, external writers and signed sandbox
execution remain unverified. Full RefLog/application parity remains incomplete.

The partial-failure retry fixture exposed Git reflog-walk fallback: after the final
HEAD entry is deleted, `git reflog show HEAD` can return branch-log entries as HEAD
selectors. The native reader now reads the exact `logs/<reference>` file, following
the source libgit2/gitdll backends, instead of inheriting another log. Git's
`rev-parse --git-path` resolves regular, bare and linked-worktree administrative
locations; HEAD/full-reference validation prevents revision expressions and path
traversal. Missing or empty logs return no entries, while access failures remain
errors. Raw new-object IDs, epoch/offset and UTF-8 messages are retained in reverse
file order. Eight Core tests include empty HEAD with an intact branch log and
independent linked-worktree HEAD deletion. Broader malformed records, object types,
encoding and signed administrative-directory access remain pending.

## Browser, Branch, Tag and Export revision actions

The four context commands pass exactly one current row's immutable hash to the
repository owner. Browser opens the repository tree at that revision; Branch and
Tag preset their revision chooser without creating a reference; Export presets
the whole-project revision without writing an archive. Empty, stale or multiple
selections, loading and absent callbacks suppress dispatch. Revision choosers
suppress Branch/Tag creation. The source `IsOnStash` gate excludes the current
`refs/stash` tip and its adjacent index-parent row when that tip has two parents.
Older stash revisions remain eligible, matching the source's exact ref mapping.

Browser and Export reuse now require matching repository/runtime, revision and
scope, no active operation or sheet, and no edited Export destination/result.
Edited or busy windows retain their own ownership while a new request opens a
correctly preset window. Browser reuse additionally requires the requested tree
at its root. Physical factory reuse/independent close and busy Branch/Tag handoff
remain acceptance work.

[Revision handoff receiver](qa/reflog-revision-handoffs-native-2026-10-08.swift)
and [QA record](qa/reflog-revision-handoffs-2026-10-08.json) check all four callbacks
against actual older-revision Browser/Branch/Tag/Export models, the old blob ID,
exact selection and chooser gates, current/older stash and adjacent index-parent
gates, original icon mapping and reuse predicates. HEAD, refs, index, config and
working file remain unchanged by those reads. These checks display no UI; physical
menu/icon rendering, complete upstream context order and actions, edited/busy
window routing, light/dark layouts and signed sandbox execution remain pending.

## Working-tree and selected-revision comparisons

Compare with working tree passes one current entry's immutable revision and the
working tree to the native Changed Files dialog. It is disabled for bare repositories.
Compare revisions accepts exactly two current rows, including a non-adjacent pair,
or a continuous selection of more than two rows. It compares the last displayed
selected row as the base and the first as the destination, following `DiffCommit`
and preserving older-to-newer patch direction. Distinct selectors with equal
hashes remain valid and produce an empty comparison. Empty, stale, noncontinuous
larger selections, busy models and absent callbacks do not dispatch.

Comparison controls precede single-revision Log/Browser commands; multi-revision
Compare follows Delete/Apply before clipboard commands. The existing unified-diff
inspection action now precedes Log. Full upstream context menus/order remain pending; merge-parent and two-revision
unified actions are now recorded below. Read-only
revision choosers may compare when their caller supplies a callback; current
choosers without it leave the command disabled.

Changed Files reuse requires matching repository/runtime and both revision fields,
no active operation/sheet, and no busy or dirty owned child comparison. An edited
or busy comparison retains its ownership while the requested comparison opens
separately. Reopening a matching idle comparison reloads its snapshot, including
current working content. Physical factory routing and independent close remain
unverified.

[Comparison receiver](qa/reflog-comparisons-native-2026-10-08.swift) and
[QA record](qa/reflog-comparisons-2026-10-08.json) load actual Changed Files models
for arbitrary pairs, continuous selections, repeated hashes, revision-to-working
and bare revision pairs. Added/deleted paths and patch direction are checked;
working bytes override staged bytes. Ordinary HEAD/refs/index/config/worktree
remain byte-exact unchanged. No windows are displayed, so menu/icon rendering,
physical comparison activation/reuse, light/dark layout and signed access remain
pending. Full application parity remains incomplete.

## Two-entry Log ranges

Exactly two current RefLog rows now offer the three source Log ranges in order:
last-to-first `..`, first-to-last `..`, then last-to-first `...`. The last and
first refer to displayed selection order, not lexical hashes or click order.
Repeated hashes are valid and yield empty ranges. Empty, stale, larger selections
and loading cannot dispatch; callers without the optional range callback disable
the menu commands.

The history reader accepts an explicit range with two endpoints and a difference
or symmetric-difference kind. It resolves both endpoints as commit objects with
`rev-parse --verify --end-of-options` before building the Git walk expression.
The range takes precedence over end-revision/all-branches scope, retaining the
existing limit, search, date and path options. RefLog handoff clears old text/date/
path/end filters, turns off working-tree/all-branches rows and rename following,
and leaves the existing Log graph/list intact. All Branches is disabled for a
range. Ordinary scoped revision handoff clears any previous range.

Range Log windows retain independent ownership. Matching idle windows may be
reused; edited range/scope, active history work, note edits or viewer operations
open a separate owned window. Physical reuse/close acceptance remains pending.

[Range receiver](qa/reflog-ranges-native-2026-10-08.swift) and
[QA record](qa/reflog-ranges-2026-10-08.json) cover actual native Log models with
divergent forward/reverse/symmetric commit sets and graph row counts, filter/scope
reset, dispatch and reuse guards, duplicate hashes and unchanged repository state.
Core tests additionally cover annotated-tag endpoints, path/search/limit behavior,
range precedence and rejection of invalid/option/range-expression endpoints.
No windows are displayed. Rendered labels/icons, physical activation/reuse,
broader merge-base topologies, range-specific follow-renames, signed sandbox
execution and complete RefLog/dialog/application parity remain pending.

## Shared unified-diff viewer and merge choices

The legacy metadata/plain-text patch sheet has been replaced by the shared native
read-only unified-diff viewer. It retains raw Git bytes for Save As, line colors,
Find/zoom/print behavior and the existing external-viewer preference. Ordinary
parent and two-entry actions pass Shift to the preference's alternate choice.
The source's extra-changes action always uses its default viewer choice.

One-parent entries offer Show changes as unified diff. Merge entries offer
**Unified diff with**: All Parents, Only Merged Files, Show extra changes after
merge, then each numbered parent with its subject/hash label. These use the
source's `diff-tree -r -p --stat` parent, `-m`, `-c` and separate `--cc` modes.
Extra changes with no second output line report No extra changes after merge
without opening a viewer. Root commits have no parent action, and bare repositories
hide the source's unified actions. Exactly two rows compare last selected to first
selected; equal hashes yield an empty viewer. Larger or stale selections cannot
run the action.

Parent metadata loads for visible immutable revisions and remains cached across
refreshes while those hashes stay in the list. Diff work is guarded by snapshot
generation, current selectors, repository access, busy state and owned viewer
activity. RefLog close is blocked during viewer work or a viewer sheet; closing
an idle owner closes its owned Find and unified viewer. Actual viewer ownership
and menu/key activation remain physical acceptance work.

[Unified receiver](qa/reflog-unified-diff-native-2026-10-08.swift) and
[QA record](qa/reflog-unified-diff-2026-10-08.json) cover all parent modes, source
Shift exception, two-entry direction/equal hashes, original non-UTF-8 byte handoff
and read-only Patch model export, clean-merge message, metadata refresh retention,
invalid/busy/root/invalidation guards and unchanged HEAD/refs/index/config/worktree.
The receiver intercepts viewer dispatch; it displays no viewer or external app.
Core tests cover actual merge diffs and parent validation, and existing hidden Find
ownership tests cover the RefLog close path. Physical light/dark viewer rendering,
external launch, Save As/print, parent menus, owned viewer lifecycle, bare/signed
invocation and broader octopus/encoding cases remain pending. Full RefLog/dialog/
application parity remains incomplete.

## Compare with previous revision

The source command now opens native Changed Files with the selected commit's
parent as the base and the selected commit as destination. A normal commit uses
its only parent; a merge offers each numbered parent with the existing subject/
hash label, immediately after the unified-diff choices and before Log commands.
Root commits have no command. The original Compare icon is reused.

Exactly one current selector, loaded parent metadata, a valid parent number and
a supplied comparison callback are required. Empty/stale/multiple selections,
loading, missing callbacks and a closed model cannot dispatch. This read-only
command remains available in bare repositories, matching the source's separate
eligibility from unified diffs. Revision choosers may compare when their caller
supplies the callback. Changed Files keeps the existing matching idle-window
reuse and edited/busy-window ownership rules.

[Parent comparison receiver](qa/reflog-parent-comparisons-native-2026-10-08.swift)
and [QA record](qa/reflog-parent-comparisons-2026-10-08.json) load actual Changed
Files models for a normal commit and both merge parents, verify base/destination
and raw non-UTF-8 patch direction, selection/parent/callback/busy/invalidation
rejection, chooser dispatch and a bare merge comparison. Ordinary HEAD/refs/index/
config/working bytes remain unchanged by reads. No windows are displayed. Physical
menu/parent/icon rendering, activation and window ownership, octopus/missing-parent
variants and signed sandbox access remain pending. Full RefLog/dialog/application
parity remains incomplete.

## Switch/Checkout and Reset handoffs

RefLog now offers Reset active branch and Switch/Checkout to this revision after
Browse repository and before branch/tag creation. Both require exactly one current
entry, a working tree, a resolved HEAD and a supplied callback. They exclude the
current stash tip and the adjacent two-parent stash index row. Reset accepts HEAD;
Switch/Checkout requires another revision. Older stash commits retain source
eligibility. Revision choosers suppress these commands. Bare/unborn repositories,
empty/stale/multiple selections, loading and closed models cannot dispatch.

The selected revision presets the existing native Switch or Reset dialog
without applying an operation. Reset uses the immutable hash; Switch prefers a
matching remote ref as described below. Explicit revision requests open independently owned
windows, preserving existing draft targets/options and operations. Generic menu
requests retain their existing window behavior. Switch's explicit initial revision
also survives a model reload; Switch has no automatic appearance-load callback.
Successful Switch/Reset callbacks refresh RefLog metadata and repository views.
Reset refuses close while its confirmation sheet is attached, and Switch refuses
close during an operation/reference chooser/tag-conflict sheet. Actual dialog
ownership and close routing remain acceptance work.

[History-action receiver](qa/reflog-history-actions-native-2026-10-08.swift) and
[QA record](qa/reflog-history-actions-2026-10-08.json) load actual Switch/Reset
models at an older hash and check target/type and reload retention without execution.
HEAD checkout/reset distinction, current/older stash, selection/callback/busy/
chooser/bare/unborn/invalidation guards and original icons are checked. Ordinary
HEAD/refs/index/config/working bytes remain unchanged by those reads. No windows
are displayed. Physical menu/title/icon rendering, independently owned windows,
confirmation/operation/close acceptance, adjacent stash index history-action gates,
detached captions, express branch switching,
broader Switch/Reset parity and signed access remain pending.
Full RefLog/dialog/application parity remains incomplete.

## Remote defaults for Switch/Checkout

RefLog Switch/Checkout now consults a sorted hash-to-reference map, as the pinned
source does when no ref label was clicked. The first matching `refs/remotes/` name
presets the native Branch target, Create New Branch, a suggested local branch name
and automatic tracking. Local branches and tags do not override that remote guess.
An entry without a matching remote still presets its immutable commit hash. Reset
continues to use the hash. Refresh rebuilds this map, including annotated tags and
symbolic remote names; bare/unborn handling retains the existing eligibility gates.

A valid explicit symbolic remote preset (such as `refs/remotes/alpha/HEAD`) stays
visible in the native picker. Its resolved remote target supplies the local branch
suggestion, avoiding the invalid local name `HEAD`. Ordinary branch lists still
omit unselected symbolic references. This is a native usability adaptation around
upstream's symbolic-reference mapping and its backend-dependent branch lists.

The [receiver](qa/reflog-remote-defaults-native-2026-10-08.swift) loads actual native
models and checks sorted remote selection, hash fallback, reload retention, moved
remote refs, symbolic presets and ordinary read-only repository state. A separate
fixture operation creates the correctly tracked local branch through Core. No
window or preferences are written. The [QA record](qa/reflog-remote-defaults-2026-10-08.json)
records runtime/build coverage. Physical picker/menu rendering, signed access,
complete express branch progress/post-actions and full application parity remain
pending.
