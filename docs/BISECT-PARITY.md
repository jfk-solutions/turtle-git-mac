# Bisect parity

The repository engine now implements Bisect Start, Good, Bad, Skip and Reset.
The repository sidebar now opens a native Bisect window. The start view follows
upstream's two-row Good/Bad layout; the same window expands to show Git output
and continuation controls. **Log and Finder entry points remain pending.**
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
- Shell `MenuInfo.cpp` and Log menu rules must still be ported with original
  `menubisect`, `menubisectreset`, `thumb_up` and `thumb_down` artwork.

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

When submodule configuration exists, successful progress also exposes the
existing Submodule Update dialog through a callback. This handoff still needs
native acceptance. Root-model callbacks refresh repository, status, commit and
Log views after state changes. Repeated activation reuses one window per
repository. Close and Quit are refused during Git operations or attached sheets.

This adapts upstream's separate start/progress windows to a native start window
that expands for progress. It retains the two-field start layout and operation
choices; displayed sizing and appearance are not yet verified.

## Remaining work

Log/Finder command entry points, selected-revision classification and fresh-state
menu rules remain pending. So do activated Log pickers, native alert interaction,
Submodule Update handoff acceptance, progress cancellation, displayed light/dark verification, keyboard
and accessibility checks, screenshots and signed sandbox acceptance. Broader Git
session variants need additional acceptance alongside the normal checkout
workflow. Full TortoiseGit and App Store parity remain incomplete.
