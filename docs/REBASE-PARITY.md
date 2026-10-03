# Rebase parity

References: `RebaseDlg.cpp`, `IDD_REBASE`, RebaseCommand and GitLogListBase at
`upstream.json`'s pinned commit; [official Rebase manual and screenshot](https://tortoisegit.org/docs/tortoisegit/tgit-dug-rebase.html).
The app's Rebase command now opens a separate native window. This is a partial
port; Fetch/Pull now hand off their selected fetched commit to this window.

## Native layout and controls

The branch/reverse/upstream/browse/onto row sits above the commit action list.
Commits display newest first and replay oldest first, as upstream documents.
Pick, Skip, Edit and Squash use the original upstream artwork in action rows and
context menus. Up/Down reorder one selected commit. The all/unselected action
menu, Force Rebase and Preserve Merges sit below the list. Add is visibly disabled.
Changed Files, Commit Message and Progress tabs occupy the resizable lower pane,
followed by progress, status and Start/Continue, Abort/Cancel and Help controls.

Active sessions recover the stopped and pending commits from Git's persistent
metadata. They expose Working Tree, Refresh State, Skip, an amend-message field,
Amend, Continue and Abort. Resolution edits and staging take place in Working Tree
or an external editor. Start, Skip and Abort have confirmations. Selecting commits
loads their files/message without invalidating a concurrently loading plan.

Branch/upstream fields are currently editable native combo boxes rather than
upstream's dropdown-only controls. Browse is a filtered reference list, not the
complete reference/log browser. The amend field is single-line. Full row menus,
keyboard action shortcuts, completed-row display, conflict tabs, Edit/Split and
post-operation controls still need porting and comparison.

## Backend foundation

A captured plan records branch, upstream and optional onto hashes and ordered
commits. Patch-equivalent changes default to Skip unless Force is selected.
Invalid/missing/duplicate entries, a first retained Squash and stale references
are rejected. Equal/up-to-date/fast-forward dispositions drive Start enablement;
Force allows replaying commits on an already current branch. Preserve Merges uses
Git's structural plan and currently disallows custom actions/order.

Git invokes TurtleGit's own executable as a headless sequence editor. The temporary
plan contains data, not executable commit text; the executable path is quoted and
child environment overrides are isolated. Git retains its persistent todo after
the temporary source plan is removed. Continue/Skip/Abort return output, exit status
and state through `rev-parse --git-path`, including linked-worktree isolation.
The engine supports amending an Edit stop. Squash currently accepts Git's combined
message without a native message prompt. Autostash is disabled; dirty starts leave
staged contents intact and report Git's error.

## Evidence

Ten Rebase tests cover the headless editor, pick/skip/reorder, squash, Edit/amend/
Continue, true conflict recovery after reopening, Abort, Skip, onto/stale/invalid
plans, preserved merge parents, linked worktrees, dirty rejection, disposition/
fast-forward branch identity and stopped/pending commit metadata. The full suite
has 78 passing tests.

Native QA verified commit detail selection, Skip and Up/Down, and a real Start
operation: the skipped file was absent, retained commits stayed on the chosen
branch, upstream was an ancestor, and the worktree was clean. A fresh app recovered
an existing Edit pause and native Amend changed the real commit message. Computer
use was interrupted before native Continue could be verified; backend Continue
completed the disposable session. Native Continue/Skip/Abort and full close/reopen
interaction remain QA work. Automation also lost window access after closing an
operation window; a process sample showed the app waiting normally for events.

Actual light/dark screenshots are `site/assets/rebase.png` and `rebase-dark.png`.
These establish the pictured layout, not full behavior or accessibility parity.

## Remaining workflows

- Fetch/Pull handoffs, old-upstream detection, fast-forward choices and config defaults.
- Add/Split, cherry-pick mode, empty commits and custom structural merge plans.
- Native squash/reword message editing, complete conflict/resolution menus and tabs.
- Full row targeting/shortcuts, ID/customizable columns, dates and persisted layout.
- Hooks, signing/editor/authentication prompts, stash restoration, streaming progress,
  cancellation, failures and signed sandbox/editor validation.
- Broader native light/dark/contrast, keyboard, resizing and accessibility QA.

Inventory statuses remain partial native; no completed Rebase parity claim is made.

## Fetch/Pull handoff

Fetch's Launch Rebase After Fetch control is enabled for a non-bare repository
and one selected remote. It enables branch selection and fetches that branch
explicitly, then opens the Rebase plan. A configured rebase Pull locks this control
on and starts the plan automatically, matching upstream AppUtils routing.
Merge-only options are unavailable on this route. `merges`/`preserve` configuration
also selects Preserve Merges. URL destinations can explicitly launch Rebase;
all-remotes destinations cannot select one Rebase target.

The actor fetches and resolves the selected branch's FETCH_HEAD commit before
returning its immutable hash. This supports custom fetch refspecs and prevents a
subsequent Fetch from changing the already opened target. Fetch errors do not
open Rebase. An active Git Rebase rejects this route before fetching.

Real integration tests cover custom refspecs, Unicode branches, immutable targets,
failed fetches, dirty index/worktree preservation, configuration precedence, active
session rejection and replay/Continue. Native QA on an isolated sample repository
verified Fetch → unstarted plan without changing HEAD, Cancel, then configured
Pull → auto-start → Rebase finished. Git verified local history replayed onto the
expected fetched commit, unchanged branch identity and a clean worktree.

Upstream up-to-date/unchanged prompts, explicit fast-forward Merge/Rebase/Abort
choices, post-operation Log/Push/mail actions, comprehensive conflict UI and
native preserve-merges/URL/failure/recovery QA still remain. Pinning the target
currently displays its hash rather than a named remote-tracking ref.
