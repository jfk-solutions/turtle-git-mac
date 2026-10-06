# Bisect parity

The repository engine now implements Bisect Start, Good, Bad, Skip and Reset.
**These operations are not yet exposed by native dialogs, Log menus or Finder.**
This is the backend prerequisite for porting the upstream Bisect workflow, not
completed application parity.

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

## Remaining work

The native two-row start dialog, editable reference lists, Log pickers and
Stash/Abort prompt are pending. So are progress/continuation UI, custom-term
labels, original icons, Log/Finder entry points and fresh-state menu rules,
Submodule Update handoff, displayed light/dark verification, keyboard and
accessibility checks, screenshots and signed sandbox acceptance. Broader Git
session variants need additional acceptance alongside the normal checkout
workflow. Full TortoiseGit and App Store parity remain incomplete.
