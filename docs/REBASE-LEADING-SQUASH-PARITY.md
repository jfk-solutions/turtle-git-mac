# Leading Squash and retained group metadata

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This continues [reached merge-parent selection](REBASE-MAINLINE-PARITY.md).
The supported connected implementation passed the focused grouped checkpoint below.

## Source behavior

`RebaseDlg.cpp::DoRebase` returns for Skip before changing the message accumulator
or first-member metadata (2048–2053). For retained rows it accumulates the original
subject/body and optional cherry-picked attribution, captures first metadata when
a non-Squash row precedes Squash, and chooses `--no-commit` for requested Squash
(2055–2087). This happens before the exact-empty-subject local Edit warning and
the reached merge-parent question. Cancelling that question can therefore leave
the first member's message and metadata prepared even though its patch was not
applied. A subsequent Skip does not clear those prepared values.

The last retained member stops in `Squash_Edit` for message approval
(2373–2385). Approval runs a normal `git commit -F`, not `commit --amend`
(1670–1681). `SquashFirstMetaData` (`RebaseDlg.h:124–177`) emits author/date options
only when set. A leading Squash with no captured leader uses configured commit
identity; it must not acquire the skipped member's author merely from its row
position. Conversely, prepared metadata retained after a reached question must
not be discarded merely because that member is later skipped. The existing
first/latest/current date policy is a separate choice.

This differs from Git interactive-todo grammar, which rejects Squash without a
preceding replay command. Rewriting that row as Pick would introduce an early
commit and change approval and metadata behavior.

Original-empty classification does not automatically suppress every Squash
empty-result question. After the empty-subject warning changes the local mode to
Edit, `DoRebase` adds `--allow-empty` for an originally empty commit but sets
`m_CurrentCommitEmpty` only when the local mode is not Squash (2091–2113).
An originally empty requested Squash with a nonempty subject retains the prior
flag, initially false; a nonempty original commit clears it. Approval at
1650–1667 uses that local/inherited flag before considering the became-empty
Commit/Skip/Cancel question. Original first-parent emptiness, selected-mainline
patch emptiness, exact empty subject and accumulated-group emptiness must remain
distinct; blanket original-empty auto-approval would not match this source.

## Connected native continuation

The implementation represents leading Squash work as an owned no-commit group instead
of feeding an invalid orphan Squash to Git's sequencer. Logical occurrence IDs
and requested actions remain visible while internal markers and physical
placeholders protect the replay plan. The durable group captures the session,
base HEAD, current occurrence, accumulated message, optional original leader
metadata and date policy inputs. `RebaseState.noCommitSquash` exposes group ID,
entry ID, base HEAD, logical step, phase and whether leader author metadata exists.
Its private receipt includes exact group/replay-file bytes and a staged-index
snapshot. Expected-state continuation rejects changed group bytes or index state,
not merely a matching count or HEAD.

The phase model distinguishes waiting, applying, conflicted, approval, committed
and uncertain work. Application publishes its durable intent before running the
patch. Reopening an interrupted applying phase exposes uncertain work and refuses
automatic reapplication. Conflict recovery stages only the accepted paths before
advancing the same group. Approval creates a new commit, with the captured
metadata policy, before the sequencer continues; a completed commit must not be
duplicated by cancellation or reopening during final publication. Completion
records original-to-result rewrite mappings before returning work to Git.
Unchecked staged changes use existing restoration/recovery rather than being
passed through a dirty sequencer continuation.

Durable `allowsEmpty` state follows the source conditional local/inherited flag.
Accepted Commit from an empty-result question is retained across a failed attempt.
A clean failed normal commit uses the existing typed Retry/Ignore receipt: Retry
returns to message review; Ignore advances without repeating the failed commit.
A dirty failure remains an ordinary error rather than an Ignore offer.

Continue, Skip, Abort, reached empty-subject/mainline decisions and supported
pending-action edits operate on the same captured group. Future action writers
retain logical actions and owned placeholders. Skip preserves source-prepared
metadata while removing the current occurrence's accepted work. Abort retains
the existing replay restoration path. Stale session,
HEAD, replay-file, occurrence or owner receipts refuse mutation. Native questions,
message preparation and child workflows retain their existing token, Quit and
actual-detachment ownership. These paths are authored implementation scope;
fixture presence alone does not establish them as verified.

## Boundaries and validation

This supersedes the earlier deliberate stopped-plan boundary when skipping the
first retained leader leaves following requested Squash work. The earlier
mainline checkpoint remains historical evidence for that narrower implementation.
The new continuation has its own [grouped checkpoint](qa/pull-leading-squash-2026-10-26.json).

The source enables Split in both Edit and Squash_Edit (`RebaseDlg.cpp:1902–1904`).
The earlier checkpoint above excluded active no-commit groups from Split. The
[new Split continuation](#split-continuation--october-26-2026) addresses that gap;
its validation is separate from the earlier passing results.

That checkpoint covered ordinary/advanced Cherry Pick no-commit groups. Its
preserve-merges orphan boundary is superseded by the authored
[structural continuation](#preserve-merges-orphan-continuation--october-26-2026),
whose validation is separate.

The grouped checkpoint records 35 affected Core methods passing cumulatively:
34 passed initially, then the repaired empty-intermediate method passed both
original and regenerated pending-action paths. A Debug build and offscreen native
Add/reopen/Abort/conflict execution passed with system and bundled Git. The first
native conflict setup used identical add/add bytes and did not create a conflict;
the fixture now writes different destination bytes and retains the original
checked-file recovery assertions. All owned receivers were reaped.

The checks retain tree/index/HEAD and author/message witnesses, reached parent
Cancel then Skip, selected conflict staging without premature commits, empty
reviews, clean commit-failure recovery, stale/interrupted state, pending edits and
reopen. No complete hosted CI, physical keyboard/VoiceOver, signed installed
execution, arbitrary hook/filter combination, all structural topologies or
whole-dialog layout acceptance is claimed here.


## Split continuation — October 26, 2026

The source Commit-dialog loop (1568–1605) runs only when there is no following
retained Squash. `CheckNextCommitIsSquash` (1753–1784) ignores intervening Skip
rows. The checkbox itself only changes the dialog option; it does not create a
commit or reset HEAD. A middle empty-subject review with another Squash pending
does not meet this Split-loop gate.

For Squash_Edit the first child receives the current message and opens a normal
Commit, not Amend. It covers the whole project, selects files, disables
post-actions and detached-HEAD warnings, and uses captured first author/date
metadata where available. Explicit Split disables Amend-Diff-to-Last-Commit.
After first success, later children are normal commits without the initial
message or leader metadata seed. Configured identity/current time remains the
native policy when no leader metadata exists; source's unset metadata/time-zero
call does not establish an original author/date.

Remaining tracked changes force another Commit child. Only a clean tracked tree
offers Add another commit; Yes opens another normal child, No resumes replay.
Untracked files alone do not force the loop. Cancelling a child stops the sequence
without advancing the original occurrence: successful earlier parts remain and
must not be amended or repeated. Final completion records grouped originals
against the final replacement HEAD and returns to Progress. Abort retains the
original replay restoration. Commit errors and empty-result decisions belong to
the actual child Commit workflow rather than the parent direct-approval command.

The authored native adaptation embeds `RebaseSplitState` in the group;
`noCommitGroupID` and `isNewCommit` distinguish it from an applied Edit amendment.
Beginning Split does not reset HEAD or discard the staged accumulator. The first
child installs editable author/date presets when a leader exists, otherwise
configured identity/current time; explicit user options remain authoritative.
All parts are normal commits, and Message Only uses the child Commit workflow.

Receipts capture exact group and immutable replay-plan bytes, occurrence, session
and expected HEAD. They deliberately permit the child's Stage/Unstage operations;
the mutable index is not an immutable Split receipt. Before running a part, the
group publishes applying intent. Success journals the new HEAD/part count even
when cancellation arrives before native delivery. An unchanged failed attempt
restores the exact prior group bytes for explicit child retry. An interrupted or
unexpectedly advanced attempt remains uncertain rather than guessing whether to
repeat a commit. Parent Retry/Ignore is not manufactured for child failures.

The parent refreshes its full session receipt after each child, and waits for the
actual child to detach and drain before another question or child. Cancel before
the first part restores approval with the checkbox/draft retained; later Cancel
preserves accepted parts and allows reopening. Clean completion maps originals to
the final HEAD and restores deferred index policy; dirty remaining work cannot
be skipped through a destructive reset. Supported pending edits preserve the
embedded group identity. When a later Squash is added, continuation preserves
earlier accepted parts and reopens accumulation from the last part's parent.

The [checkpoint evidence](qa/rebase-no-commit-split-2026-10-26.json) records 26
affected Core methods passing cumulatively, the Debug build, Help/localization
checks and the native Add family with system and bundled Git. The initial build
needed explicit closure captures; one new Core and native author-date assertion
needed exact-instant comparison across timezone formatting. Only the affected
checks were repeated, without production behavior changes. Preserve-merges orphan groups
remain outside this continuation; earlier Split and leading-Squash checkpoints do
not certify this new path.

## Preserve-merges orphan continuation — October 26, 2026

The next connected continuation extends no-commit execution to a leading retained
single-parent Squash in a preserve-merges plan, including a group exposed by
skipping its earlier leader. The [structural checkpoint record](qa/rebase-structural-no-commit-2026-10-26.json)
records its actual focused validation and repairs.
The earlier ordinary/advanced Cherry Pick and Split results above do not certify
this topology.

### Source parent and group ordering

The source action controls protect the literal oldest row, not the first retained
row: selected/unselected Squash guards use the final list index
(`GitLogListAction.cpp:1307,1332`), and bulk Squash uses the same literal oldest
entry (`RebaseDlg.cpp:367`). Skipping that oldest row can therefore leave a
later requested single-parent Squash as the first retained work. Native Start
must not introduce a stronger first-retained prohibition while its row-action
controls continue to protect the literal first execution entry.

Preserve-merges `DoRebase` (2140–2265) carries an ordered rewritten-parent map.
Before the next retained occurrence, previous pending originals are mapped to
current HEAD. Dropped-parent entries are expanded recursively in original order;
resolved rewritten IDs are deduplicated. An empty rewritten first parent of a
merge is an explicit error; other empty rewritten mappings fall back to current
HEAD. The source's already-included commit filtering constructs dropped-parent
entries during setup (600–677); user Skip is not automatically identical to that
filtering step.

A retained single-parent requested Squash skips the checkout of its rewritten
parent and accumulates changes at current HEAD. A non-Squash row checks out its
resolved first parent. Squashing a merge commit itself is explicitly rejected
(2199–2205). An unchanged merge can reuse its original commit; a changed merge
checks out its first resolved parent and rebuilds against the other resolved
parents. Native structural labels therefore must reference the final committed
group result, not an internal drop placeholder or an unapproved staged tree.

Squash conflict Continue (1349–1368) verifies resolution/conflict hints, then
returns the final member to Squash_Edit approval or advances an intermediate
member without a standalone commit. Normal approval and Split completion map all
pending group originals to final HEAD (1617–1620, 1722–1726). First metadata and
message accumulation still precede exact-empty-subject review; Skip retains the
source-prepared values described above.

`FinishRebase` calls `RewriteNotes` only for ordinary Rebase, before final branch
restoration (1130–1145). `RewriteNotes` (1193–1234) feeds nonempty old/new map
entries to `git notes copy --for-rewrite=rebase`. Group mappings must therefore
settle after approval or the last replacement part, rather than exposing an
intermediate no-commit tree. Native Git sequencer labels, rewrite files and note
handling are an execution adaptation, not the exact upstream command sequence.

### Supported adaptation and limits

The authored implementation supports initial earlier-Skip→single-parent Squash,
reached empty-subject leader Skip with prepared metadata retained, selected
conflict staging without a premature commit, normal approval, Split, reopen,
Skip/Abort and supported future action regrouping. Native Start protects the
literal oldest entry, and the shared group executor retains logical actions and
structural parent/label dependencies. Session/group/plan/HEAD guards and actual
rewritten-label receipts refuse stale mutation; uncertain application or commit
publication refuses blind repetition.

Skipping current B restores its saved pre-B tree and retains earlier applied A.
If that Skip would leave a later retained merge's first parent unreplayed, it is
refused before resetting the current group. This is a safe timing adaptation of
the source's later fatal topology error. The user can edit the future merge to
Skip at a supported pause, then retry the current Skip. No guessed first parent
or automatic merge-parent substitution is introduced.

Owned skipped-row label/update-ref controls are held until the group's final
label. Their original base targets are captured, while return controls refer to
the final runtime label rather than a guessed future hash. The cursor survives
checked restoration, ordinary Split and cancellation return. A journaled optional
message-configuration archive preserves prior cursors after group retirement, so
later pending-action regeneration normalizes those control blocks too.

Collapsed/reset-only merge results use an owned structural-result checkpoint
after their actual label/Edit result. It records original merge→reached HEAD for
rewrite/notes consumers, validates that label's actual HEAD, then journals a
completed comment and removes the exact rescheduled owned exec. This makes
automatic continuation once-only, including unchanged mappings. A later Git
refusal exposes a pure Continue/Abort checkpoint anchored to that HEAD; Skip,
message editing, file recovery and Split do not mutate that metadata-only phase.

Literal-first Squash, Squash of a merge/root row, repeated structural occurrences
and a missing first merge parent remain refused. Arbitrary octopus/cousin
topology, externally authored todo scripts and every notes/hook/filter
configuration are not inferred supported. The linked structural checkpoint
records 49 Core methods passing cumulatively, Debug builds and the normal native
workflow with both Git engines. A real duplication of rescheduled owned markers
was repaired with only the affected Core case repeated; the native fixture also
needed to select its target row before requesting its menu. Physical/signed/VoiceOver, minimum-version/Intel execution,
whole-dialog layout and complete hosted CI acceptance remain separate.


### Rescheduled owned checkpoints across Git versions — October 26, 2026

Hosted run40335643582 exposed a Git-version difference before structural group
approval, before the test injected its transport failure. With
`rebase.rescheduleFailedExec=true`, older Git can append the preceding instruction
to `done` again while putting the failed owned exec first in todo. Newer Git
retains the reached exec without that duplicate predecessor. Inspecting only the
last physical done line lost the logical approval checkpoint.

Read-only state, current-row and progress projection now recognize the exact
owned source-Squash, empty-message, applied-empty, mainline and structural-result
receipt. Reading does not rewrite replay files. Before a mutation retires the
legacy duplicate, the executor reconstructs and compares the complete owned plan,
including structural cursors, reference updates and completed result markers,
and rechecks file witnesses under the existing action-edit lock. The existing
journal publishes done and todo together. An altered predecessor, pending marker
or unrelated instruction is refused; arbitrary user exec commands are not adopted.

This recovery is shared by group approval, pending action edits, reached message
and parent decisions, Continue, Split and Abort ownership. The native structural
fixture now enables failed-exec rescheduling for the full Split/reopen/Abort
workflows with both Git engines. The new [checkpoint](qa/rebase-rescheduled-checkpoints-2026-10-26.json)
records actual grouped results and remaining boundaries; the earlier normal-path
checkpoint does not certify this Git-version recovery.

The checkpoint records 54 distinct relevant Core methods passing cumulatively
across recorded fixture repairs, the original hosted regression passing, and
two native structural case/engine pairs passing. The older receipt is injected
at a genuine failed-exec boundary; local native engines are Git 2.54 and 2.55.
Debug returned exit zero with contradictory generic compiler diagnostics retained
in the record. All native receivers are absent. Complete hosted integration and
signed/physical acceptance remain open.

### Owned instruction framing — October 27, 2026

An actual Git 2.39.5 reproduction of hosted run40428318167 found a second
connected defect after regroup approval. The owned `done` publisher joined
consumed instructions without a final newline. Git appended the next label
directly to the preceding Drop subject. Label and rewrite witnesses were still
valid, but complete-plan validation correctly rejected the damaged stream before
the intended transport refusal. The earlier injected legacy receipt checks did
not exercise this actual append behavior.

Newly reconstructed nonempty instruction text now ends at a line boundary across
no-commit approval, Split, checkpoint normalization, pending-action changes,
failed-Pick recovery and adopted todo publication. Existing comments and blank
lines are retained; empty instruction streams stay empty. Raw before-images,
untouched files, session witnesses and action-edit journals remain exact. This
does not infer permission to repair arbitrary already-damaged replay files or
weaken the full-plan comparison.

The [framing checkpoint](qa/replay-instruction-framing-2026-10-27.json) records the
actual older-Git reproduction, original diagnostic capture repair and grouped
validation separately. Installed build16 predates this continuation. Full hosted,
signed/physical, minimum-version/Intel and complete upstream acceptance remain
open.
