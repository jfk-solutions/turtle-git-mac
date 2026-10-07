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
Working-file conflict actions
still require their upstream-specific implementation and acceptance.

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
