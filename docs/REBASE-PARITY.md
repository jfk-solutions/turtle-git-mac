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
See [Squash workflow](REBASE-SQUASH.md). Git's implicit autostash stays disabled
in the replay engine; the native dialog explicitly owns Save/Pop and questions
according to `rebase.autostash`, as described in the stash workflow audit.

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

- Complete Fetch/Pull variants, native factory acceptance, hook/network/signed
  execution and remaining configuration parity. Manual Fetch/Rebase decisions
  and old-upstream checks are now adapted; see FETCH-PARITY.md.
- Remaining advanced Cherry Pick options, displayed patch-becomes-empty interaction and custom structural merge plans.
- Remaining reword/author editing and complete conflict/resolution menus and tabs.
- Remaining row targeting/shortcuts and commit drag reordering and physical column-layout acceptance. Customizable metadata columns and persisted layout are implemented in the October 13 batch below. Action and move shortcuts now have headless native coverage; displayed acceptance remains pending.
- Broader hook, signing/editor/authentication, reopened-session stash restoration, streaming progress,
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

Active session context now restores original options and Fetch/Pull completion
origin after reopening. [Session context](REBASE-SESSION-CONTEXT.md) records
versioned metadata, fallback and verification limits.

Manual Fetch/Rebase now asks the upstream up-to-date and unchanged questions,
then offers Merge/Rebase/Abort for an ancestor target. Answers can be remembered.
Configured automatic Pull/Rebase skips those prompts. Actual ff-only Merge and
retained dirty/conflicted failures are recorded in the Fetch decision QA; native
Rebase factory/editor acceptance and full workflow parity remain pending.

Tracked dirty-tree Stash/Abort, effective `rebase.autostash`, Cherry Pick's manual
question, post-save Pre-rebase hooks, and owned Done/Abort/completion restoration
are now implemented together. See [stash workflow and remaining limits](STASH-PARITY.md#replay-stash-and-applypop-ownership-october-12-2026).

The selected-revision Edit Notes action now uses the shared owned [Input
sheet](INPUT-DIALOG-PARITY.md). The revision context menu is gated while it is
open. Retiring the Rebase owner invalidates its revision model, cancels pending
note reads and closes the sheet without late presentation. Full physical/signed
acceptance remains open.

## Revision metadata and column layout (2026-10-13)

The Rebase/Cherry Pick list now retains source REBASE, right-aligned ID, SHA-1,
Message, Author and Date defaults and offers hidden-by-default Email, Commit Name,
Commit Email and Commit Date columns. Hash cells carry full hashes and truncate
visually to their width. Upstream `RebaseDlg.cpp` uses the shared Rebase column key
and replaces Graph/Actions with REBASE/ID; the native plan's occurrence IDs and
execution order remain separate from column order.

The native header offers checkable column choices and the existing source-style
Yes/No Reset question. Width/order/visibility persist in supplied preferences,
shared by Rebase and Cherry Pick. Unknown/duplicate ordering and invalid widths
are ignored; at least one column remains visible. Header drag tracking prevents
SwiftUI refresh from resetting a drag before its final width/order is stored.
Busy, sheet and retired ownership guard layout commands. Existing SwiftUI row
menus and the owned keyboard/action dispatcher are preserved.

Rebase readers now include raw committer name/email/date, retaining raw author
name/email/date and message text in their original fields. One reader supplies
ordinary plans, Cherry Pick entries and resumed replay metadata; display mailmap
preferences do not become replayed authors. The hosting view supplies the owning
font preferences, and Date/Commit Date use its Log date settings.

The focused Core metadata check, final Debug build and four grouped native
receivers with system/bundled Git passed. Native QA verifies declared/default
columns, saved layout on reopening, the committer email rendered in a native cell
using local Vision OCR, action selection, Reset, busy/closed refusal, and unchanged
HEAD/index/global layout settings. The shared note-editor ownership regression
also passed. The initial native test exposed missing committer metadata and was
repaired. Attempts to inspect hidden SwiftUI text/AX cells could not verify their
values; native cell pixels replaced that assertion without removing it.

All owned receivers were reaped. Conditional columns are implemented in the batch below. Physical header drag/Reset
acceptance, VoiceOver, commit drag ordering and full signed/replay/window parity remain open. A cell render is not an all-dialog visual comparison.
See [batch evidence](qa/rebase-columns-2026-10-13.json).

## Conditional Bug-ID/SVN column family (2026-10-13)

Rebase and Cherry Pick now include the source conditional Bug-ID and SVN Rev
columns after Commit Date. Bug-ID availability uses effective project issue
properties; SVN availability uses worktree/common Git metadata. Available columns
start visible, participate in saved width/order/visibility, retain a hidden choice
while unavailable, and recover contextual defaults through Reset. Configuration
removal hides the checkbox and clears its displayed values.

The model projects values in an owned background read without changing replay
records or authors. Duplicate commit events share one hash-keyed result. One
batched C++ helper invocation extracts issue IDs across the entire projection,
retaining UTF-16 offsets, first capture/two-expression semantics, NUL termination,
source invalid-regex suppression and natural ID sorting. SVN extraction uses its
existing batch and source whole-message anchors. Template-only issue extraction
remains local. Reordering or changing plan actions does not restart unchanged
metadata. Explicit reload rechecks configuration.

Closing/refreshing cancels the owned read, rejects obsolete replies and retains
its repository grant and global Quit accounting until completion. Read state
is separate from replay execution; the UI remains selectable while repository
queries may queue behind the owned read.
Runtime errors are reported by the owning Rebase dialog. SwiftUI column groups
keep all twelve columns within macOS 13-compatible builder expressions.

The batch's evidence is [conditional-column QA](qa/rebase-conditional-2026-10-13.json).
It does not establish complete dialog/VoiceOver/physical/signed parity. Source
Windows versus macOS locale/regex equivalence and all rendered cells remain open.

## Dialog-local commit drag ordering (2026-10-13)

Ordinary Rebase and Cherry Pick now support dragging a contiguous selected block
inside the revision list. The source is `GitLogListBase::OnBeginDrag/OnMouseMove`
and `RebaseDlg::OnCommitsReordered`: move in newest-first display order, preserve
the block's order, and select its occurrences after insertion. The native model
stores the reverse display as execution order, retaining actions, mainlines and
occurrence identities. Source no-op positions inside or immediately after the
selected span are refused; the final row permits insertion after the list.

The owned native list monitor draws an insertion line, requests edge autoscroll,
consumes the active drag's pointer events and supports Escape cancellation. Header
interaction remains owned by the column layout probe. Drop validation retains
owner/generation plus row/action/progress/mainline state; changed plans, busy,
active/finished, note/sheet and retired owners cannot apply an obsolete drag.
Handlers update only the plan, not Git HEAD/index/worktree.

At the drag-only checkpoint, Preserve-merges ordering remained disabled because
the backend rejected edited structural plans. The later structural Pick batch
below implements reordered execution and enables dragging; structural action
editing and broader Source equivalence remain open.

Two focused Core checks, the Debug build and four grouped native receivers across
system/bundled Git passed. Native QA invokes actual insertion/finish handlers,
checks the marker destination, block/selection/execution ordering and refusal
cases, and preserves HEAD/index. Column/committer-cell/layout regression also
passed. All four receivers were reaped. The checks do not synthesize a physical
pointer gesture; full mouse capture, stationary-edge autoscroll, multi-display,
VoiceOver and signed acceptance remain open. See
[batch evidence](qa/rebase-row-drag-2026-10-13.json).

## Reordered structural Pick plans (2026-10-13)

Preserve-merges dragging and movement buttons now accept reordered Pick-only
plans. The unchanged structural plan retains Git's previous default path. A
reordered structural plan uses an interactive label/reset/merge todo compiled
from immutable commit parents. Common merge bases map to Onto; already replayed
parents map to their labels. An unreplayed linear parent uses current HEAD, as
in the source. A merge with an unreplayed first parent is rejected before starting.
Unchanged original merge parents can reuse the original merge; rewritten parents
are deduplicated and merged with the original message/author reference.

The sequence editor places generated update-ref commands after each original
commit's stable label. Structural markers count logical commits rather than
Git's label/reset operations, preserving progress rows, stopped/remaining revision
metadata and Abort through a conflict. The source comparison is
`RebaseDlg.cpp`'s rewritten-parent handling around lines 2137–2270. These changes
supersede the previous blanket structural-ordering restriction.

Five focused Core tests passed with the current built app as sequence editor:
reordered branch/side/merge execution and parent count/tree results, invalid future
first-parent refusal without mutation, conflict logical progress/recovered rows
and Abort, structural update-ref placement, and the unchanged Preserve-merges
path. Debug build and four grouped native checks across system/bundled Git passed;
all four receivers were reaped. Native checks exercise structural drag availability
and conditional metadata ownership, not physical structural replay gestures.

At this checkpoint, structural Skip/Edit/Squash and keyboard actions remained
open; the later action batch below supersedes Skip/ordinary Edit and movement
keyboard restrictions. Broader cousins/octopus/root
and nested merge behavior, real branch-update execution, physical/signed scope
and full Source workflow equivalence remain open. This is a partial structural
port. [Batch evidence](qa/structural-order-2026-10-13.json) records actual results.


## Structural Skip and ordinary Edit actions (2026-10-13)

Preserve-merges plans now support selected and bulk Pick/Skip plus Edit on
ordinary commits, including the Space action cycle and P/S/E/U/D keyboard paths.
Menus keep structural Squash disabled and merge-commit Edit unavailable. The
source permits these remaining actions; this restriction is an implementation
gap, not claimed source parity. Add remains disabled for structural plans.

Any action change selects the custom structural compiler even when ordering is
unchanged. Skip records a logical completion label without applying a patch or
rewriting the source parent map (`RebaseDlg.cpp` around lines 2048–2052). A later
ordinary child uses the current HEAD fallback, while an unreplayed first merge
parent remains a preflight error. Ordinary Edit emits Git's Edit operation before
its completion label, so a pause still identifies the current logical row. After
amend/Continue, the label captures the edited HEAD for descendant parent rewriting.
Recovered rows retain captured actions and completed/current states; Abort
restores the original branch history. All-Skip plans finish at Onto.

Debug compilation passed. Nine focused Core checks passed, including Skip/Edit
recovery and message amendment/Continue, Edit/Abort, all-Skip execution, reordered
merge topology, conflict recovery, invalid first-parent refusal, update-ref
placement and the unchanged structural path. Four native receivers passed across
system/bundled Git and were reaped. They verify actual model selection/cycling,
unsupported Squash refusal, row drag and conditional metadata lifecycle. Keyboard
paths are enabled in the native monitor but physical keystroke acceptance is not
proved by these handler checks. The first Core attempt failed to compile because
the test referenced `editPause` instead of the existing `isEditPause`; the corrected
fixture passed without an app behavior change.

Merge Edit, structural Squash/group rewrite, skipped first-merge-parent workflow
recovery, broader root/cousin/octopus/nested graphs, real update-ref execution and
physical/signed acceptance remain open. See [batch evidence](qa/structural-actions-2026-10-13.json).


## Structural merge Edit and real reference updates (2026-10-13)

Preserve-merges Edit now accepts merge commits from individual/bulk actions,
Space cycling and the existing E keyboard path. The structural compiler emits a
Git `break` after reconstructing or reusing the merge and before its logical
completion label. Recovery recognizes that owned break plus the captured Edit
identity and its next label, supplies the current merge message, retains the
original row identity/action and selects the message tab. Continue amends the
current merge and then records its rewritten label for descendant commits.
Source comparison: `RebaseDlg.cpp` around lines 2195–2270 and 2368–2372, where
merge replay precedes its Edit pause. The source workflow is the target; Git's
sequencer implements the native pause. Retired owners also reject action changes.

The ordinary Split implementation is disabled at a merge Edit pause because its
first-parent reset would discard merge topology. Source-equivalent merge Split
requires a separate implementation and remains a recorded gap. Structural
Squash/group rewrites are also still unavailable. These changes supersede the
previous merge Edit restriction, without certifying the full structural workflow.

Twelve focused Core checks passed, including reopen/message amendment/Continue
with a two-parent merge and rewritten descendant, Abort restoring all references,
and actual `rebase.updateRefs=true` updating a side branch to the merge's rewritten
parent. The prior ordinary Edit/Skip, topology, conflict/progress and invalid-parent
checks passed in the same group. This replaces the earlier placement-only evidence
for that tested reference scenario; all other reference/graph cases remain open.

The Debug build and four native receivers across system/bundled Git passed. The
native fixture resumes a real active merge replay in the Rebase window model,
checks its message tab and Split guard, invokes Continue and verifies the amended
message and parent count. It also retains prior row-drag and metadata assertions.
All receivers were reaped. The first native attempt used the reference runner as
sequence editor; its different bootstrap entry point could not run the editor.
The fixture now uses the current built app executable and the corrected group
passed. Physical gestures/keyboard, VoiceOver, conflict-to-merge-Edit acceptance,
broader graphs and signed sandbox behavior remain unverified.

[Batch evidence](qa/structural-merge-edit-2026-10-13.json) records scope and failures.


## Structural Squash groups and final-parent labels (2026-10-13)

Preserve-merges now accepts Squash for ordinary one-parent commits from individual
and bulk actions, the Q keyboard path and Space cycling. A first applied Squash
and Squash on a merge/root commit are rejected, matching the source's constraints.
Source comparison: `RebaseDlg.cpp` around lines 2048–2094, 2195–2204 and 2368–2387.

A group starts with its Pick/Edit commit and includes following Squash rows,
ignoring skipped rows for grouping. It omits resets between Squash patches and
defers original commit labels until the final result. Applied group members map
to that result for later parent rewrites; skipped rows retain the source fallback.
Generated update-ref commands follow the final labels, including references
attached to the group's starting commit. Logical progress now reads captured
identities from replay commands and completion labels rather than merely counting
labels, so a group message pause identifies its final applied row.

The existing durable message-review protocol gathers the original group messages,
omits skipped messages and requires approval through the native message tab before
Continue. It retains the existing Squash date-policy configuration. Edit followed
by Squash goes through the group's final message review rather than an early Edit
pause. An ordinary child may squash into a merge result while retaining its parents;
the merge itself cannot be marked Squash. Split remains unavailable for structural
Edit/Squash results with multiple parents because the existing Split implementation
would flatten the topology. Source-equivalent merge Split remains open.

Fourteen focused Core checks passed, including a multiple-Squash group with a
skipped row and approved message, a child combined into a two-parent merge and an
actual reference attached to the group's starter updating to the combined result.
The existing structural Edit/Skip/Abort/conflict/topology cases passed in the same
group. Four native receivers across system/bundled Git also passed, including a
real group loaded in the window model, recovered group messages, message approval,
Continue and retained merge topology. All receivers were reaped. A subsequent
review added the merge-result Split guard; its affected checks are recorded in the
batch evidence. Physical keyboard/gesture and signed sandbox acceptance remain
unverified, as do wider graph, conflict/empty-group/date-policy combinations.

This batch supersedes the prior blanket structural Squash restriction, without
certifying the complete Rebase dialog. [Batch evidence](qa/structural-squash-2026-10-13.json).
