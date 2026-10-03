# Create Repository parity

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`, `CreateRepoDlg.cpp/.h`,
`Commands/CreateRepositoryCommand.cpp/.h` and all five `IDD_CREATEREPO` controls
in `src/Resources/TortoiseProcENG.rc`. The upstream control order is Bare,
explanatory text, OK, Cancel and Help. The native window follows that arrangement.
Reference: [TortoiseGit Create Repository manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-create.html).

## Implemented

File → Create Repository (Command-Shift-R) selects a destination before opening
Git Init. Finder requests supply the destination; sandbox builds still require
permission. The checkbox uses the upstream label and defaults on for folder names
ending in `.git`. Help opens the upstream manual. The window uses native light and
dark appearance, with an informational success sheet and errors retained for retry.

Special folders are checked before enabling creation. Windows known-folder checks
are adapted to macOS home, Desktop, Documents, system/application folders and volume
roots, resolving symlinks. A nonempty bare destination prompts Abort/Proceed.
Warnings are checked again before Git executes. Abort is the default action.

Git runs `init [--bare] -- destination`, preserving existing contents and honoring
`init.defaultBranch` and `GIT_TEMPLATE_DIR`. No forced branch name or failed-folder
cleanup is applied. After success, the actual repository kind is queried rather
than inferred from the checkbox, and the repository is adopted when the workspace
is idle. Explicit Open/Close supersedes a queued adoption. Recent permissions are
saved for the resolved repository root. Signed bookmark renewal is unverified.

Bare repositories resolve their own absolute Git directory, including when nested
inside a working repository. The workspace labels them explicitly and disables
worktree operations. Log allows history, commit comparisons, branch/tag/push and
soft reset; worktree comparison, checkout, revert and cherry-pick are disabled.
Bare Branch/Tag cannot switch and Fetch cannot hand off to Rebase. Full bare menu
parity, RefLog actions and repository-folder icon customization remain incomplete.

## Verification

Five real-Git tests cover normal creation with a configured default branch and
external template, occupied bare-folder confirmation, file preservation,
reinitialization preserving HEAD/index/worktree/config, nested bare discovery with
Unicode/newline paths, Push/Fetch/history, special-folder symlink classification and
invalid destinations. The local full suite passed 122 tests with zero failures.

Native QA used disposable `/private/tmp/TurtleGitInit*QA` fixtures. Debug previews
opened a fixture, then dispatched a real FinderRequest to the existing app handler;
this does not verify signed Finder-extension activation or external URL delivery.
Normal creation produced a success sheet and preserved `keep.txt` as untracked.
Bare creation produced a success sheet and a bare repository without a `.git`
subdirectory. A `.git` folder started checked. Cancel left its folder empty; Abort
of the occupied-bare warning retained only the original `keep.txt` unchanged.
Window observations timed out after closing those dialogs, so immediate workspace
adoption and recent-menu behavior are not claimed as native verification.

A separate preview opened the newly created bare repository. Its workspace and
empty Log rendered without an error. After a fixture Push, Refresh displayed all
six revisions and the expected main ref/hash. The revision menu visibly disabled
working-tree comparison, checkout, revert and cherry-pick. Source HEAD, refs,
status, index and worktree were preserved. `site/assets/create-repository.png` is
an actual 1200 × 444 native light-mode capture of the options window.

## Remaining verification

The native destination panel renders but its confirmation/New Folder buttons remain
disabled in current QA. Changing modal presentation to asynchronous presentation
did not resolve this; picker confirmation remains unverified. Closing a native
options window also leaves its observation handle timing out, while app inventory
still reports the process running. Neither observation is proof of successful
workspace adoption. Native Proceed in an occupied bare folder, special-folder Abort,
Help navigation, failure/retry, dark-dialog capture and signed sandbox/Finder/recent
workflows still require QA. No full upstream parity or App Store readiness is claimed.
