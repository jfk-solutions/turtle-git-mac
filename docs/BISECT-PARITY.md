# Bisect parity

The repository engine now implements Bisect Start, Good, Bad, Skip and Reset.
The repository sidebar now opens a native Bisect window. The start view follows
upstream's two-row Good/Bad layout; the same window expands to show Git output
and continuation controls. Finder commands and Log revision commands now use the
native workflow. The Log working-tree row and its Reset menu remain pending.
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
  ported; working-tree row rules remain pending.

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

The Log working-tree row, including its current-commit classification and Reset
menu, remains pending. Activated Finder URL opening and signed handoff are
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
Automatic refresh of those modal picker Logs after a Bisect handoff remains
pending; their action preflight still uses fresh Git state.

The hidden native receiver checks real menu images, targets and enabled state,
two-row preset order, moved-reference fallback, selection changes, cached
busy/bare/Merge guards, fresh active Start refusal and marked-row exclusion.
It routes injected handoffs into the actual Bisect controller, executes selected
Good/Bad and multi-Skip against real Git, then verifies stale mark and ended
session refusal. An unborn repository Log also loads with no Bisect state.
These checks do not establish activated menus, working-tree row support or
displayed/signed acceptance.
