# Bisect parity

The repository engine now implements Bisect Start, Good, Bad, Skip and Reset.
The repository sidebar now opens a native Bisect window. The start view follows
upstream's two-row Good/Bad layout; the same window expands to show Git output
and continuation controls. Finder commands and Log revision commands now use the
native workflow. Log also displays a working-tree row with current-commit
classification and Reset; its wider working-file/menu parity remains incomplete.
This does not establish complete Bisect or application parity.

## Upstream contract

The audit uses TortoiseGit commit
`7338078f8ddd924b8cddee35f512f2286072136d`:

- `BisectStartDlg.cpp` and `IDD_BISECTSTART` provide two editable revision
  controls, **Last known good** and **First known bad**, each with a Log picker.
  Branches, remote branches and tags populate both choices. Good starts empty;
  Bad defaults to the current branch or HEAD. OK requires both values.
- `CAppUtils::BisectStart` offers **Stash / Abort** for tracked changes, then
  runs `bisect start`, `bisect good`, `bisect bad` in order. Its progress result
  offers Good, Bad, Skip, Reset and, when applicable, Submodule Update.
- `CAppUtils::BisectOperation` retains Reset after a failed active operation.
  Successful operations offer the same continuation controls while the session
  remains active. A located culprit remains a Git session until Reset.
- The shell command uses the active session's custom good/bad terms. Log Start
  takes two selected rows; first visible selection supplies Bad and last Good.
  Log Skip supports multiple selected commits. Other Log classification actions
  use the selected commit; Finder classification uses the current commit.
- Shell `MenuInfo.cpp` rules are ported with original `menubisect`,
  `menubisectreset`, `thumb_up` and `thumb_down` artwork. Log revision rules are
  ported, including current-commit classification and working-tree Reset.

## Implemented engine

`Bisect.swift` resolves all supplied revisions to commit hashes before mutations,
rejects bare repositories and conflicting active operations, and refuses tracked
working-tree or index changes before Start. Untracked files are left for Git's
checkout protection. Start runs the upstream three-command sequence and returns
the complete output, exit code and refreshed state even when Git refuses a
checkout after creating its session.

State is recovered from Git's real `BISECT_START`, `BISECT_TERMS` and
`BISECT_LOG`, using `rev-parse --git-path` for linked worktrees. It includes the
original branch/revision, current HEAD, custom terms and a located first bad
commit when Git has recorded one. Completion records accept both older Git
log wording and Git 2.55’s quoted term format. Good/Bad use those
terms; Skip resolves each supplied commit literally and passes the full
selection to Git. Reset accepts no revision override and asks Git to restore
its recorded original branch. No automatic stash, hard reset, cleanup or
implicit session rollback is performed.

The tests locate a known first bad commit through real checkout/classification,
reopen using a fresh repository actor, and Reset back to the original branch.
They also cover custom terms, batch Skip with an ambiguous result, linked
worktree isolation, invalid Good/Bad input, tracked/index dirtiness, bare and
active-session refusal, and an untracked checkout obstruction whose exact bytes
survive failure and Reset. A failed checkout remains an active recoverable
session; the backend does not report it as a successful search step.

## Native workflow

Both revision fields are editable native combo boxes populated from branch,
remote-branch and tag labels, with a single-selection Log picker beside each.
Good defaults empty; Bad defaults to the current branch or HEAD. The initial
OK button requires both fields. Inputs stay disabled while a session is active.

Starting with tracked changes offers **Abort / Stash**. Abort leaves the tree
and index alone. Stash invokes the existing tracked-only stash workflow after
an explicit response, then revalidates and starts Bisect. Stashes are retained;
untracked files are not included or removed. The helper rejects active merge,
replay and Bisect sessions before stashing. It never auto-applies the stash.

After Start the native window shows Git output and **Bisect good**, **Bisect
bad**, **Bisect skip**, **Bisect reset**, using the unchanged upstream artwork.
A fresh window recovers an external or interrupted session and uses its custom
terms for button captions and commands. A Git failure preserves output/state
and enables Reset while disabling further classification in that result view.
A located culprit is shown with its full hash. Reset restores Git's original
branch and retains output. The window remains available until Close.

After each operation, the model checks the resulting worktree for submodule
configuration, matching upstream's post-command callback. Start, classification
and Reset can check out a revision which adds or removes `.gitmodules`; the
Submodule Update action follows that result rather than the state when the
window opened. Its callback requires a successful result, current configuration
and an idle model. Failure disables it while retaining Reset recovery. A failed
metadata read clears availability rather than retaining an earlier result.

Successful progress exposes the existing Submodule Update dialog through a
callback. A hidden native receiver checks the actual checkout transitions and
callback guards with an injected callback; activated dialog handoff still needs
native acceptance. Root-model callbacks refresh repository, status, commit and
Log views after state changes. Repeated activation reuses one window per
repository. Close and Quit are refused during Git operations or attached sheets.

This adapts upstream's separate start/progress windows to a native start window
that expands for progress. It retains the two-field start layout and operation
choices; displayed sizing and appearance are not yet verified.

## Finder commands

Finder now projects the five upstream Bisect commands in their own source menu
group between Stash and conflict/removal commands. **Bisect start…** requires a
single repository folder and excludes active Bisect and Merge. **Bisect good**,
**Bisect bad**, **Bisect skip** and **Bisect reset** require one repository folder
with an active Bisect session. Bare repositories, individual files and multiple
folders do not offer these commands. Original icons follow Finder's icon setting.

The shared URL request retains the folder selected when the menu was built.
The request grants no filesystem permission; normal repository authorization
still applies. Finder does not execute Git. The foreground app loads fresh
session state before dispatching a continuation command. Good/Bad/Skip classify
the current checked-out commit, and custom terms are recovered before command
execution. Reset uses Git's original branch. A stale Start request is refused
if another session or merge has begun; a stale classification request is
refused if its session has ended. Reused windows retain the same fresh guards.

The source condition fixture now projects 38 command rules. Finder-related core
tests and the actual native menu-builder receiver cover the pinned order,
inactive/active conditions, icons, selector, captured folder and URL round-trip.
The native Bisect receiver also checks load-then-dispatch, current-commit Good,
Reset, and stale active Start/ended-session Bad refusal against real Git state.
These receivers do not activate the Finder extension or exercise real URL opening.

## Remaining work

The working-tree row now supports current-commit classification and Reset.
Its Cleanup command, advanced working-file actions, preference persistence and
navigation acceptance remain incomplete. Stash, Pull, Fetch and Submodule Update
now have repository dialog handoffs as described below. Activated Finder URL opening and signed handoff are
also unverified. So do activated Log pickers, native alert interaction,
Submodule Update handoff acceptance, progress cancellation, displayed light/dark verification, keyboard
and accessibility checks, screenshots and signed sandbox acceptance. Broader Git
session variants need additional acceptance alongside the normal checkout
workflow. Full TortoiseGit and App Store parity remain incomplete.

## Log revision commands

The revision context menu follows `GitLogListBase.cpp` and
`GitLogListAction.cpp` at the pinned upstream commit. Two selected rows offer
**Bisect start…** when a working tree exists and neither Merge nor Bisect is
active. A stash row at the first selected position excludes Start. Selection
order follows the displayed list: first supplies Bad, last Good. Each preset
uses the row's first reference, otherwise its commit hash. If that reference
has moved, a fresh resolution falls back to the selected hash.

An active session offers **Bisect good**, **Bisect bad** and **Bisect skip**
for one selected revision, unless that row has a `refs/bisect/` reference.
Multiple selection offers only Skip, with the same exclusion on the first
selected row. Skip passes every selected hash literally in displayed order;
it does not expand a revision range. Original artwork and native menu selectors
dispatch all four commands. Busy operations, note editing and unavailable
handoffs disable execution.

Before handoff, the Log checks fresh repository/session state. It refuses Start
if another session or Merge has begun, continuation if the session has ended,
and classification if another caller has marked the first selected commit.
A changed selection or invalidated Log drops the pending handoff. The native
Bisect window revalidates again before execution and recovers custom terms.
Repository callbacks configure normal Log windows and the existing Merge,
Rebase and Stash Log pickers; completed operations refresh normal repository Logs.
Picker handoffs also register their model with the reused Bisect window. The
window keeps weak, deduplicated observers and reloads participating picker Logs
after stash, successful/failed Git results and recovery. Their normal reload
guards apply. Closing a picker invalidates its model and removes it from later
notifications; observing it does not keep the model or its security grant alive.

The hidden native receiver checks real menu images, targets and enabled state,
two-row preset order, moved-reference fallback, selection changes, cached
busy/bare/Merge guards, fresh active Start refusal and marked-row exclusion.
It routes injected handoffs into the actual Bisect controller, executes selected
Good/Bad and multi-Skip against real Git, then verifies stale mark and ended
session refusal. An unborn repository Log also loads with no Bisect state.
An actual hidden picker also refreshes HEAD and Good/Bad/Skip references after
classification without manual reload. Reset clears active state and markers
in the source Log. A closed retained picker stays invalidated, and a released
model is not retained by observation. These checks use injected root handoff;
they do not establish activated menus, complete working-file parity or
displayed/signed acceptance.

## Working-tree row data foundation

Upstream `GitLogListBase.h/.cpp` represents the row with an empty commit hash
and the actual HEAD as its parent. It prepends the row to Log, reads working-tree
changes and keeps unversioned files separately for the display option. This
contract now has a core reader in `WorkingTreeHistory.swift`; it is now
inserted into normal native Logs and routed through basic comparison and Bisect menus.

The reader returns the synthetic row, versioned changes and a separate
unversioned list. Its parent is actual HEAD, independent of a displayed range.
Combined HEAD/worktree diff supplies rename paths, binary-aware line statistics
and gitlink modes. Porcelain status retains index changes even when the working
bytes have returned to HEAD. Index mode data preserves submodule typing in that
case. Conflicts retain their status; ignored files are excluded. A cached removal
with a surviving local copy appears in both the versioned and unversioned lists.

Reads disable optional Git index writes, external diff and text conversion, use
NUL-delimited literal paths and accept cancellation. Bare repositories return no
row. An unborn repository has no parent; staged/unversioned statuses are available
without inventing commit statistics. Reading does not create an empty-tree object
or change HEAD, index, working files or conflict stages.

Four real-Git tests cover clean and changed rows, staged plus unstaged text,
binary statistics, Unicode/newline/pathspec-looking names, renames, net-HEAD-clean
index differences, ignored/unversioned files, conflicts, cached removal copies,
unborn/bare repositories, cancellation and submodule pointer/index differences.
They compare index bytes, HEAD, working bytes and unmerged stages where relevant.
A graph check confirms the synthetic row links to the actual HEAD row.

Normal Logs prepend the row by default; revision pickers omit it. Show Working
Tree Changes toggles the row, and Show Unversioned Files toggles its separate
file list. Literal path scopes filter tracked and unversioned files. Cached
removal copies share a path identity with the deletion row and are currently
shown once; separate upstream-style list grouping still requires implementation.
The row has its own message, Commit callback and whole/file comparison with HEAD.
Selecting it together with one commit compares that commit with the working tree.
Unified whole-tree diff is available when a HEAD/base exists. Selected versioned
working files also support unified diff against current HEAD, in list order,
including rename paths and the alternate viewer handoff. Unversioned selections
and repositories without HEAD are excluded; unborn whole-tree unified diff
remains pending. File Log
uses the current repository; historical-only file actions stay unavailable.

An active session offers Good/Bad/Skip/Reset with original icons. Pure-row
classification passes no revision, so Git acts on current HEAD; Reset restores
its original branch. Mixed row/commit selection offers Skip with only the selected
commit hashes. Commit-only actions exclude the synthetic empty hash.

The hidden native receiver checks row/head linkage, unversioned and tracked
details, whole/mixed/file comparison callbacks, actual Git unified patch bytes,
Commit dispatch, empty-hash exclusion, current-commit Skip/Good/Bad and Reset,
busy refusal and row show/hide. Handoffs are injected. Displayed graph/layout,
keyboard/accessibility, activated menus and signed sandbox remain unverified.
The wider working-file menu audit and displayed/signed acceptance remain pending.

Selected-file patch checks preserve raw non-UTF-8 bytes, literal Unicode/newline
paths, rename pairs and selection order; they validate the patch against a
separate index and leave the real index, HEAD and working bytes unchanged.
External diff/textconv filters are suppressed. The hidden native receiver checks
actual selected-file patch bytes, alternate handoff and unversioned refusal;
it does not establish displayed viewer or keyboard acceptance.

Working-file Open, Open With and alternative editor now hand off the actual disk
URL rather than a historical temporary copy. Save As and Export copy current disk
bytes, including unversioned files, through the shared working-file copy engine.
Export preserves relative paths and excludes deleted entries and submodules.
Open validates current file existence/type before dispatch; the new routes refuse
busy or invalidated models. Store builds validate repository and file access,
and copies retain the chosen destination's security scope for the operation.
Displayed panels, external application launches and exact-file sandbox grants
for atomic Save As remain unverified.

Compare Two Files now routes working-row selections through the existing pair
engine in displayed order. A missing disk side reads its pinned HEAD blob;
unversioned files use disk bytes. Submodules are excluded. Mark for Comparison
and Compare with the mark accept working and historical selections in either
direction. Historical sides are pinned before reading; working sides stay live.
Working marks have an explicit Working tree label. Imported Finder marks retain
their file grant when comparing with a working selection, and the root consumes
that stored mark after handing off the viewer.

Core checks cover mixed-side bytes, moving refs, unchanged HEAD/index/working
bytes and invalid paths. Hidden native checks cover list order, missing-side HEAD
fallback, mixed directions and busy/invalidation/deleted/submodule guards through
injected callbacks. Root viewer dispatch and Finder mark consumption are compiled
and source-inspected; displayed/signed handoffs remain unverified. Shift alternate
diff-tool selection still requires implementation.

Working-row Blame now follows upstream's HEAD behavior: GitStatusListCtrl launches
the viewer without a revision and TortoiseGitBlameDoc defaults that request to
HEAD. It annotates committed bytes rather than the current edits. Log checks
current file existence/type and resolves actual HEAD before dispatching a pinned
revision. Added, unversioned, deleted, submodule and unborn selections are
excluded. Busy, selection-change and invalidation guards prevent stale handoffs.
Unversioned working files also exclude Show Log, matching the source menu gate.

The hidden native fixture opens and closes an actual Blame controller and checks
that its snapshot contains HEAD bytes while the file has different disk bytes.
It also checks moved HEAD, stale missing files, historical dispatch and the
selection/class guards. Root handoffs are injected; displayed appearance,
keyboard/accessibility and signed sandbox remain unverified.

Working-row conflict menus now offer single-file Edit Conflict and selected
Resolved/Mine/Theirs with original icons. Primary action on one conflicted file
routes to Edit Conflict; ordinary or multiple-file primary actions retain base
comparison. Mixed selections pass only conflicted paths to resolution, matching
upstream's skip behavior. Fresh index checks reject conflicts that disappeared;
Mine/Theirs also reject changed rebase semantics since the menu was populated.
Busy, bare, changed-selection and invalidated models refuse dispatch.

Root routes reuse the existing text/delete/submodule editors and the quick Resolve
dialog with confirmation. Their completion callbacks now refresh live normal
Logs for the same repository. Repository completion notifications now queue a
refresh while Log is busy and combine repeated notifications into one reload.

The hidden native fixture opens/closes a text editor, executes actual
Current/Mine/Theirs through ResolveWindowModel, and preserves unrelated staged
and working bytes and HEAD. Injected completion refresh removes the resolved
status. A real rebase verifies stage-2 mapping; a fabricated rebase marker checks
stale menu semantics. Root editor subtype dispatch and repository-wide refresh
are compiled/source-inspected, not activated. Text editor inspection is hidden;
delete/submodule routes, confirmation sheets, input events and signed access
still require native acceptance.

## Deferred repository refresh

Repository mutation callbacks and Bisect picker observers request a queued Log
refresh. A busy Log reloads when its current action or history read finishes;
repeated requests before that reload starts are combined. An explicit reload
consumes pending work, and closing the model cancels queued work. A completion
cannot revive a retained, closed Log.

The hidden native fixture holds an injected unified-diff handoff while actual
HEAD advances, then verifies the latest commit appears after release with one
reload. It also checks idle coalescing, manual reload, and closing before a queued
refresh or during the held action. Root callback wiring is compiled and inspected;
displayed interaction and signed sandbox acceptance remain pending.

## Working-tree repository commands

The row now offers Stash Save, Stash Pop, Stash List, Pull, Fetch and Submodule
Update using original icons and the pinned Log menu groups. Save and Pull exclude
an active Merge; Fetch remains available during Merge. Pop/List require a stash;
Submodule Update requires current submodule configuration. A selected stash row
also offers Pop/List, matching the upstream latest-stash commands rather than
applying the selected commit. Cleanup remains unported.

Each request rechecks repository metadata and its captured selection before
handoff. A new Merge refuses Save/Pull, a removed stash refuses Pop/List and
removed configuration refuses Submodule Update. Busy operations or note editing
disable dispatch. Root callbacks retain the Log's repository and access grant,
open the existing native dialogs and refresh open normal Logs for that repository
(including path/revision-scoped Logs) after Stash Save/Pop, Fetch/Pull and
Submodule Update completion. No Git command is executed directly by the menu.

The hidden native receiver checks icons, targets, enabled state and injected
handoffs; merge conditions, busy/selection changes, fresh stash/config removal
and selected stash-row Pop/List. It fabricates the Merge marker and temporary
configuration in a disposable real repository and removes/restores its test
refs. It does not fetch from a network or pop a stash through these callbacks.
Activated dialogs and root completion refresh still need displayed acceptance.

## Owned cancellation and recovery — 2026-10-13

The native Bisect family now owns a cancellation token for initial repository
queries, Start, Good/Bad/Skip/Reset and the explicitly approved Stash. Closing a
busy window requests cancellation and keeps it open until the owned work settles.
Its footer exposes Cancel and a pending Cancelling state. The original captured
Good/Bad revisions are retained across the stash decision and Start sequence.

A cancelled command can leave Git’s bisect session active. The live window reads
actual state using a fresh owned recovery token and offers Reset; it does not
implicitly reset, apply a stash or claim remote/local changes were undone.
Cancellation during revision resolution stays a cancellation error. Replay
conflicts are checked through cancellable Git metadata paths.

Forced closure retires the model, cancels its child, resolves its stash decision
once, closes an owned revision picker and refuses subsequent UI publications,
callbacks or dispatch. Active operation accounting survives retirement until
children and recovery queries finish, blocking Quit even after the window goes
away. Duplicate pickers and commands behind a picker are refused.

Seven Core tests, two grouped native cases across system and bundled Git, Debug
compilation and two documentation tests passed. All owned test processes were
reaped. See [dated lifecycle QA](qa/bisect-lifecycle-2026-10-13.json).
Physical Cancel/stash/picker keyboard acceptance, full progress presentation,
all Git checkout-hook behavior and signed Finder/App Store execution remain open.


## Connected Bisect start/progress/recovery family — October 14, 2026

This batch compares BisectStartDlg's branch/tag population, remote-prefix input
and single Log picker contract with AppUtils's Start/Stash/operation callbacks
and ProgressDlg's output, kill confirmation, auto-close and Action log behavior.
Good/Bad choices retain branch-first/tag-second ordering and exact reference
identity. Typed `remotes/` values are normalized as the source does. Picker
requests retain their target field and identity; duplicate, changed-target,
retired and unavailable-presentation replies cannot change either revision.
The actual Log receives the typed revision at construction, preventing a first
unfiltered read. Disabled/dismantled native combo delegates refuse edits.

The native window now switches from the compact two-row start layout to an output
result layout; revision inputs no longer occupy the result. This remains one
owned macOS window rather than the source's separate modal window instances.
Back restores the start layout after a failed inactive attempt. Active results
show source-ordered Submodule Update, Good, Bad, Skip and Reset. Interrupted or
failed active results expose only Reset; success after Reset has no classification
actions. Existing custom terms, culprit hash, Log observers and safe explicit
Stash/Abort behavior remain. A declined stash restores options without mutation.

Core Stash/Start/classification/Reset APIs stream only the actual commands;
validation and metadata reads are excluded. All three Start commands drain into
one ordered parser. Stash output remains before Start output after explicit
approval. Presentation is bounded, CR/split-UTF-8 aware, styled and selectable,
with current work/percentage and original-icon Copy/Copy All menus. Repository
callbacks retain complete original results. Full result storage is not bounded.

Kill confirmation responses are once-only. A completed operation waits for an
outstanding question before successful auto-close; late Yes cannot cancel it.
Forced retirement bypasses the question, cancels owned reads/processes, ends
owned sheets and drops late replies. Operation accounting and retained repository
scope span the output drain, result metadata and fresh cancellation recovery.
Recovery reads Git's real session and leaves Reset available without rolling back
completed changes or reapplying a stash. Captured auto-close counts the conditional
Submodule Update and active continuation actions. Closing/Back/new attempts preserve
the displayed Action log result, including cancelled attempts.

Physical window composition, separate-window lifetime equivalence, Return/Escape,
real nested sheets/picker clicks, VoiceOver, screenshots/theme acceptance, signed
sandbox and actual Finder activation remain open. This is partial family progress,
not a claim of full Bisect or application parity.


Debug compilation and all eight affected Core tests passed. Four grouped native
cases (new connected progress family plus existing lifecycle) passed with system
and bundled Git. Initial fixture-only helper/label failures are retained in the
[batch evidence](qa/bisect-progress-2026-10-14.json); no app rebuild or Core repeat
was required after the native label correction. All five attempted receivers,
including the failed initial case, were reaped. Action log assertions require
actual saved Unicode output and User cancelled, not only a logging callback.


Inactive unborn repositories now return an empty HEAD in the read-only Bisect
state query, allowing RefLog and other metadata consumers to load them normally.
An active Bisect session still requires a resolvable HEAD. Private regression
checks preserve the staged index, symbolic branch, working bytes and active marker;
see [RefLog batch evidence](qa/reflog-native-batch-2026-10-15.json).

## State-driven command entry — October 18, 2026

Source `bisect` entry now captures Start/Good/Bad/Skip/Reset presence, optional
Good/Bad values and the active-operation `ref`. A typed source decision reads
fresh Git state before routing: inactive Start opens review, active commands use
Good/Bad/Skip/Reset precedence, and Reset ignores `ref`. Active Start combined
with an operation follows that operation; active Start alone and inactive
classification report the source error without mutation. Empty Bad uses the
native branch/HEAD default. Common path-file reads preserve the request.

Native loading publishes recovered state even when command eligibility fails,
keeping Reset available for an active session. Initial invalid entry cannot
masquerade as an already-edited Start review; valid reviews retain their inputs
on repeated Start. Existing pickers/operations refuse competing command work.
Workspace progress/picker preferences are captured by the native controller.
Current custom terms are still resolved by the existing Git operation backend;
Start acceptance, dirty Stash/Abort, progress, cancellation, recovery, source
icons and continuation controls remain that workflow.

[Command guide](COMMAND-LINE.md#stateful-bisect-entry) and
[batch evidence](qa/bisect-commands-2026-10-18.json) record source decisions, actual
Git sessions, grouped lifecycle/progress validation and remaining physical/signed
limits. This is not complete Bisect or application acceptance.

A fresh Start command after a completed/Reset progress view restores empty Good
and branch/HEAD Bad defaults; a still-open Start review keeps its edited values.
This distinction prevents a previous search's revisions becoming defaults for a
new source command while preserving user drafts.

## Source form, revision picker and completion ownership — October 21, 2026

The current batch returns to pinned `IDD_BISECTSTART` (ENG.rc1796–1810),
`BisectStartDlg.cpp145–190` and `AppUtils.cpp3647–3698` as one connected family.
The source ComboBoxEx resources specify `CBS_SORT`: the older branch-first/tag-second
native ordering above was incomplete. Good and Bad retain exact reference values
while their displayed choices use sorted ordering. Their native Form commands
preserve the source G/B mnemonics outside text composition, with Command-Option
shortcuts for macOS. The two-row start form remains distinct from the expanded
output state within one owning native window.

Each field's Log picker receives the captured revision as both its ending and
selected revision, matching both SetParams arguments. It keeps the originating
preferences and single selection, omits the working-tree row and rejects stale
or duplicate replies. Picker dismissal and forced owner closure must wait for
actual history reads and sheet release rather than releasing only the visible
sheet. This complements the existing model operation accounting above.

The completion control uses native split-button behavior and original source
artwork. Its ordered choices are optional Submodule Update followed by Good,
Bad, Skip and Reset for successful active results. Failed active results retain
Reset. Captured completion receipts must be consumed once and refuse changed
state, busy work, Quit and retired owners. A deferred Submodule Update must wait
until its originating Bisect work, revision picker and questions have drained.
Repeated classifications and cancellation recovery retain Git's real session;
closing the UI never performs an implicit Reset or reapplies a saved stash.

Six distinct native case/engine pairs pass across the grouped checkpoint and
focused ownership fixture repairs. [Dated evidence](qa/bisect-source-controls-2026-10-21.json)
records the initial compile error, privacy/acknowledgment fixture corrections,
actual Git results, eight reaped receivers and four complete light/dark captures.
Core was unchanged and not rerun. Repository entry refuses a retired same-repository
owner while its work drains, then permits a fresh owner after release. Deferred
Submodule Update also inherits the originating window presentation and preferences.
The [user guide](BISECT.md) explains the native workflow.
Physical keyboard/pickers/VoiceOver, signed Finder and minimum-version acceptance,
complete source state/layout parity and full hosted integration remain open.
