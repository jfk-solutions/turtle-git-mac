# Rebase parity

References: `RebaseDlg.cpp`, `IDD_REBASE`, RebaseCommand and GitLogListBase at
`upstream.json`'s pinned commit; [official Rebase manual and screenshot](https://tortoisegit.org/docs/tortoisegit/tgit-dug-rebase.html).
The app's Rebase command now opens a separate native window. This is a partial
port; Fetch/Pull now hand off their selected fetched commit to this window.

## Native layout and controls

The branch/reverse/upstream/browse/onto row sits above the commit action list.
Commits display newest first and replay oldest first, as upstream documents.
Pick, Skip, Edit and Squash use the original upstream artwork in action rows and
context menus and the all/unselected action menu. Up/Down reorder selected commits
while preserving their order; Shift moves the selection to the top/bottom. A
one-step move does nothing if any selected row touches that destination boundary.
The all/unselected action
menu, Force Rebase and Preserve Merges sit below the list. Add opens a native multiple-selection Log picker even before branch/upstream
fields are complete; draft entries remain editable while Start stays disabled.
It is disabled during replay and with Preserve Merges. See [Add audit](REBASE-ADD-PARITY.md).
Changed Files, Commit Message and Progress tabs occupy the resizable lower pane,
followed by progress, status and Start/Continue, Abort/Cancel and Help controls.

Custom active sessions recover the full original list, including completed,
stopped and pending occurrences, from persistent replay metadata. They expose Working Tree, Refresh State, Skip, a message editor and
phase-specific Commit/Continue/Amend and Abort controls. The Conflict Files tab
now routes resolution through the native conflict editors and Resolve workflow,
retaining resolved changes until the step advances. Start, Skip and Abort have
confirmations. Selecting commits
loads their files/message without invalidating a concurrently loading plan.

Branch/upstream fields are currently editable native combo boxes rather than
upstream's dropdown-only controls. Browse is a filtered reference list, not the
complete reference/log browser. Edit now uses a multiline message tab and Continue
applies it. Split opens full Commit selection dialogs, with durable part recovery.
See [Edit/Split workflow](REBASE-SPLIT.md) and
[Conflict Files](REBASE-CONFLICT-FILES.md). Pick/Edit conflict Continue now
commits checked files and preserves unchecked changes through a recoverable
native amend loop. Squash checkbox interaction, advanced group/reference recovery, full
row menus, completed-row display and post-operation controls still need porting
and comparison.

When the commit list has focus, P/S/Q/E choose Pick/Skip/Squash/Edit. Space cycles
each selected row Pick → Skip → Edit → Squash → Pick, bypassing Squash for the
oldest ordinary commit (and the oldest Cherry Pick row), as the pinned upstream
implementation does. U/D move the selection; Shift+U/D move it to the top/bottom.
Command, Control and Option combinations retain normal macOS handling. Other
fields, tables and windows do not receive these action shortcuts. Busy, active,
finished, picker and Preserve Merges states disable plan editing.

The whole-native receiver checks contiguous/noncontiguous moves, boundary no-ops,
stable end moves, per-row action cycles and actual focus-scoped key routing with
system and packaged Git. It also verifies selection identity after SwiftUI's row
reconciliation and pass-through for text fields, other windows and modifiers.
Events are injected into the actual receiver; displayed key gestures, focus
appearance and accessibility acceptance remain unverified. Evidence:
`qa/rebase-list-interaction-2026-10-06.json`.

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
The engine supports amending an Edit stop. Squash now pauses for a native multiline
message editor and captures the upstream first/latest/current author-date setting.
See [Squash workflow](REBASE-SQUASH.md). Autostash is disabled; dirty starts leave
staged contents intact and report Git's error.

## Evidence

Ten Rebase tests cover the headless editor, pick/skip/reorder, squash, Edit/amend/
Continue, true conflict recovery after reopening, Abort, Skip, onto/stale/invalid
plans, preserved merge parents, linked worktrees, dirty rejection, disposition/
fast-forward branch identity and stopped/pending commit metadata. The initial historical checkpoint recorded 78 full-suite tests; that count is not
a claim about the current source. The Cherry Pick audit records the newer focused
replay checks.

Native QA verified commit detail selection, Skip and Up/Down, and a real Start
operation: the skipped file was absent, retained commits stayed on the chosen
branch, upstream was an ancestor, and the worktree was clean. A fresh app recovered
an existing Edit pause and native Amend changed the real commit message. Computer
use was interrupted before native Continue could be verified; backend Continue
completed the disposable session. Native Continue/Skip/Abort and full close/reopen
interaction remain QA work. Automation also lost window access after closing an
operation window; a process sample showed the app waiting normally for events.

Actual light/dark screenshots are `site/assets/rebase.png` and `rebase-dark.png`.
These predate the completed-row styling and establish only the pictured layout,
not current visual, behavior or accessibility parity.

## Remaining workflows

- Fetch/Pull handoffs, old-upstream detection, fast-forward choices and config defaults.
- Remaining advanced Cherry Pick options, displayed patch-becomes-empty interaction and custom structural merge plans.
- Remaining reword/author editing and complete conflict/resolution menus and tabs.
- Remaining row targeting/shortcuts and drag reordering, customizable columns and persisted layout. Action and move shortcuts now have headless native coverage; displayed acceptance remains pending.
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

Cherry Pick mode now reuses this window with the upstream disabled reference row,
hidden Force/Preserve controls, attribution checkbox and merge-parent prompts.
See [Cherry Pick parity](CHERRY-PICK-PARITY.md). Existing screenshots above predate
the numbered-row and formatted-date changes and do not establish the current layout.

Pick/Edit empty results now offer Commit/Skip/Cancel, including already-applied
patches and all-unchecked selections. Conflict-message hints offer Ignore/Abort.
See [empty-result workflow](REBASE-EMPTY-RESULTS.md).

Cancelling the first Split dialog after a checked conflict Edit now restores
the applied Edit recovery and message without changing HEAD/index/files. The
transition rejects an externally changed HEAD and supports reopening.
See [Split return QA](qa/rebase-split-return-2026-10-06.json).

Squash conflicts now show the whole group relative to its destination parent.
Native phase captions match the upstream continuation stages, and amendment is
restricted to applied Edit pauses. See [Squash conflicts](REBASE-SQUASH-CONFLICTS.md).

Empty Squash approval now offers Commit/Skip/Cancel. Skip drops the whole group
and retains a durable retry intent after reset failures.
See [empty Squash groups](REBASE-EMPTY-SQUASH.md).

Repeated Squash conflicts retain no-change middle messages in the final draft,
exclude deliberate Skip steps, and preserve the latest source date. Reopening,
empty-group choices and subsequent ancestry are covered by real/headless native
fixtures. See [repeated conflicts](REBASE-SQUASH-CONFLICTS.md#repeated-conflicts-within-a-group).

Configured Git reference updates survive the native custom plan, with group refs
following the final Squash result. Commit-step identity ignores those additional
commands; Cherry Pick keeps source branches unchanged. Linked-worktree empty
Skip recovery is covered. See [reference recovery](REBASE-REFERENCE-RECOVERY.md).

Configured Rebase references remain associated with the original occurrence
after repeated Add and reordering. Automatically omitted patch-equivalent
references follow Git's unchanged-reference behavior, while retained references
update after Edit approval. See [repeated/omitted references](REBASE-REFERENCE-RECOVERY.md#repeated-add-and-omitted-commits).

Row menus now reuse native Log inspection/reference/notes/clipboard commands
with original icons and occurrence-aware selection. Advanced Log commands and
displayed acceptance remain pending. See [row menus](REBASE-ROW-MENUS.md).

Custom replay lists now retain completed occurrences, original action/mainline
metadata, stable numbering and current/completed styling through reopening.
[Replay rows](REBASE-PROGRESS-ROWS.md) records scope and remaining differences.

Successful Rebase now exposes upstream completion commands through a native
split control. [Completion actions](REBASE-COMPLETION-ACTIONS.md) records direct
and after-Fetch behavior, mail/export adaptation and remaining acceptance.
