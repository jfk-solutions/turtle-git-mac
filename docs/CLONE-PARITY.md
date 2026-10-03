# Clone dialog parity

The generic Clone prompt is replaced by a dedicated native window. Baseline:
`7338078f8ddd924b8cddee35f512f2286072136d`, `CloneDlg.cpp/.h`, `IDD_CLONE`,
`Commands/CloneCommand.cpp/.h` and `ProgressCommands/CloneProgressCommand.cpp/.h`.
References: [TortoiseGit Clone manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-clone.html)
and [Git clone documentation](https://git-scm.com/docs/git-clone).

## Implemented

Clone Existing Repository contains URL/history/browse, Directory/browse, then
Depth, Recursive, Clone into Bare Repo, No Checkout, Branch and Origin Name.
An SSH-key/history/browse row precedes From SVN Repository, containing Trunk,
Tags, Branch, From revision and Username. OK/Cancel/Help follow these groups.
The File menu opens Clone with Command-Shift-C; Finder Clone requests supply the
selected destination folder. Original Log artwork appears on the Show Log action.

Depth starts at 1 and From revision at 0; SVN layout fields start at trunk/tags/branches.
Fields follow their checkboxes. Bare excludes recursive, no-checkout and custom
origin; recursive/no-checkout/custom origin disable Bare. Selecting SVN clears and
disables incompatible Git flags, and checks the three layout fields unless the URL
ends in trunk. Disabled SVN values are not sent to a normal Git clone.

URL edits derive the destination name and remove a final .git suffix. Subsequent
URL edits replace the automatically generated component while preserving a manually
changed directory. Browse uses native directory/key panels. Successful clones save
URL/key histories, parent directory and recursive preference; Cancel saves none.

Git arguments are separate process arguments, with source/destination after `--`.
Option combinations, depth/revision, NULs, branch and origin names are validated.
Execution uses an existing destination or its closest existing ancestor; failed
destinations are not deleted. Errors retain the entered controls and offer Retry.
Success shows captured output plus Show Log, Show in Finder and Close. Normal
clones become the active repository when the workspace is idle. Bare clones use
their own Log/Finder actions; opening bare repositories in the workspace remains
pending and bare clones are not added to its recent-working-tree list.

The Windows Pageant/Putty key row is adapted to an OpenSSH private key. Git uses
`GIT_SSH_COMMAND` during clone and stores a shell-quoted `core.sshCommand` for later
operations. Folder/source/key access leases remain held during execution. The app
retains the selected key lease and saves a security-scoped bookmark per cloned
repository, renewing it on reopen. These paths require signed sandbox verification;
encrypted keys, agent prompts and external SSH helpers remain incomplete.

SVN controls build the pinned `git svn clone` arguments, including an optional empty
origin prefix and local-source file URL conversion. Execution preflights `git svn
--version`. The current system Git has no SVN command; this produces an error
without creating the destination. SVN execution is not verified or bundled.

## Verification

Five real-Git tests cover shallow selected-branch cloning with a custom origin,
literal Unicode/quoted directory names, bare versus no-checkout index/worktree
semantics, recursive submodule initialization, occupied-directory preservation,
pre-mutation validation, stored SSH commands and SVN argument construction. A
disposable wrapper grants file transport only for the submodule fixture. A shell
argument check confirms that a key filename containing quotes and shell-like text
remains one literal argument and does not execute its contents. No SSH server or
real private key is involved. The full suite passes 117 tests.

Native QA used `/private/tmp/TurtleGitCloneQA` and a separate
`/private/tmp/TurtleGitCloneResultQA` destination. Command-Shift-C opened the native
window; URL autofill and Depth/Branch/Origin enablement were exercised. SVN selection
enabled layout controls and cleared incompatible Git flags. OK showed the missing
Git-SVN error; CLI inspection confirmed no destination was created. Switching back
to Git and Retry cloned feature/status-badges at depth 1 with remote upstream.
CLI inspection confirmed matching HEAD, shallow history, clean index/worktree and
unchanged source HEAD/refs/status/index/worktree, including its mixed staged edits.
Show Log opened that clone with its selected branch and remote reference.
`site/assets/clone.png` is the actual 1640 × 948 native options-window capture.

The initial File-menu accessibility binding became stale; keyboard invocation
worked in the updated preview. After closing Log, the computer-use connection
timed out. Cancel, picker interaction and further native checks remain unverified.

## Still partial

- Native Cancel/close preservation, URL/key history relaunch, manual-directory
  changes, SSH protocol enablement, browse panels, bare/no-checkout/recursive UI
  execution, Show in Finder, minimum-width and dark appearance QA.
- Live progress, cancellation, detailed transfer rows and full upstream retry and
  post-operation behavior; output is currently shown after execution finishes.
- Authentication, encrypted-key/agent UI, key use after restart, signed multi-folder
  sandbox grants, out-of-scope submodules and independent helper permissions.
- Git-SVN runtime/dependencies and real SVN cloning, LFS capability/runtime handling,
  clipboard defaults, URL-handler/exact-path input and complete saved preferences.
- Bare workspace reopening, saved geometry and upstream libgit2 progress callbacks.

No complete Clone parity or App Store readiness is claimed.
