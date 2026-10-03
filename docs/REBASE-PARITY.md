# Rebase parity

Reference: `RebaseDlg.cpp`, `IDD_REBASE` and RebaseCommand at the pinned commit in
`upstream.json`. This is a backend-first port. The existing generic Rebase prompt
still runs its old command; the native plan window and Pull/Fetch handoffs have
not yet been connected to this backend.

## Backend foundation

A captured plan records the selected branch, upstream and optional onto hashes,
plus the ordered commits. Pick, Skip (Git drop), Edit and Squash actions can be
set per commit, and entries can be reordered. Patch-equivalent upstream changes
are initially skipped unless Force Rebase is selected. Invalid/missing/duplicate
entries and a first retained Squash are rejected. Start rejects references that
changed since the plan was loaded. Preserve Merges uses Git's structural rebase
plan and rejects custom actions/order for now.

Git's sequence editor invokes TurtleGit's own executable with a dedicated
headless argument. It copies the generated plan into Git's todo file and exits
before creating windows. The executable path is quoted for Git's editor command;
commit data is written as data, not executable shell text. Per-command environment
overrides are isolated to that Git child process. The temporary source plan is
removed after Git consumes it; Git's own persistent todo remains for recovery.

Start/Continue/Skip/Abort return output, exit status and the current Git rebase
state. State is read through `rev-parse --git-path`, so linked-worktree metadata
is isolated from the main worktree. It includes branch/original head/onto,
current step, pending commands, stopped commit/message and unresolved paths.
A new repository object can read an existing session and continue it. Edit
supports amending the current commit with an explicit message. Git's default
combined squash message is currently accepted without an interactive message UI.
Autostash is disabled for this engine; a dirty start returns Git's error without
creating a rebase session or altering staged contents.

## Evidence

Eight tests cover the editor entry point, actual rebases through the built app's
headless editor, pick/skip/reorder, squash messages, edit/amend/continue, true
conflict state and resolution after reopening, abort restoration, skip after
conflict, onto, stale references/invalid plans, preserved merge parents, linked
worktree isolation and dirty-index rejection. The complete Swift suite has 76
passing tests. These prove the tested backend operations, not native dialog parity.

## Native window and workflow work remaining

- Branch/reverse/upstream/browse/onto controls, action commit list, select-all action
  menu, Up/Down/Add, Force/Preserve options and resizable lower panes.
- Changed Files, Commit Message and progress/output panes, current commit selection,
  editable squash/reword messages, Edit/Split commit and row menus/icons.
- Start/Continue/Skip/Abort confirmations and native conflict-resolution/staging
  actions; reopen/resume QA and complete post-operation commands.
- Fetch → Rebase and configured Pull → Fetch/Rebase, fast-forward choices,
  original upstream tracking/old-upstream detection and preserve-merges behavior.
- Add commits, split commits, custom structural merge plans, cherry-pick mode,
  empty commits and patch-equivalence/Force interactions, submodule behavior.
- Up-to-date/fast-forward/equal reference enablement, stash restoration, hooks,
  signing/editor prompts, streaming progress/cancellation and recovery failures.
- Native screenshots, keyboard/resize/light/dark/accessibility comparison, broader
  Git-version coverage and signed sandbox runtime/editor validation.

The upstream inventory is marked partial backend. No new native Rebase screenshot
or completed UI claim is made until the actual window has been ported and exercised.
