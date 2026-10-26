# Reached Cherry Pick merge-parent selection

This records a bounded continuation at pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, not complete Rebase parity.

## Source ordering

`RebaseDlg.cpp::DoRebase` (2048–2133) returns immediately for Skip. It calculates
requested-action Squash accumulation, first metadata and no-commit behavior before
checking the exact empty subject. An empty subject warns and changes the local
execution mode to Edit (2091–2094). Only then, when an advanced Cherry Pick merge
row is reached, does it ask which parent to pick (2115–2133), adding `-m` to the
actual cherry-pick. Cancel stops before applying that occurrence. Ordinary
preserve-merges replay follows its separate parent-rewrite path.

`GetCommitTitle` (2017–2031) supplies the parent subject/short hash. The pinned
question exposes Parent 1, Parent 2 and Cancel. The native question retains all
supported actual parents in their immutable order; it does not discard later
parents of an octopus merge. This is an explicit Mac extension of that dialog.
The source's `IsCommitEmpty` (2001–2014) compares the original tree to its first
parent before the question. Original empty subject, source empty classification
and the selected-mainline patch becoming empty are separate concerns.

## Connected native execution

The native pre-start sweep of all missing mainlines is replaced by a durable
checkpoint before each reached, retained merge occurrence in advanced Cherry
Pick. Earlier commits can therefore run before a later question, and an earlier
conflict does not ask about unreached merges. Skip generates no parent question.
An empty-subject merge retains its earlier warning and mandatory message review;
requested Pick/Edit/Squash remains separate from effective execution mode.

The question loads immutable parent summaries under the owning operation token.
It preserves the selected occurrence and Progress view, offers every captured
parent plus Cancel, and defaults to Cancel. The parent window/access lease and
Quit ownership remain held through metadata reads, the owned sheet's detachment
and continuation. Cancel leaves the reached occurrence unapplied and resumable;
reopening recovers that pending question. Forced retirement settles its owned
continuation and refuses late replies.

Core `RebaseMainlineDecision` identifies the original commit, requested action,
occurrence ID, logical step, pre-application HEAD, exact parent list, session
identity and captured replay files. `selectRebaseMainline` revalidates the session,
HEAD and unchanged replay state, reads the original object again, and validates
the selected parent number. No hash-only choice is shared between repeated rows.
Existing explicitly supplied valid mainlines remain supported.

Git validates the entire interactive todo before reaching a checkpoint. An
unchosen merge therefore has an owned physical `drop` placeholder behind that
checkpoint, not an invalid raw `pick` of the merge object. The requested logical
action and original occurrence remain in metadata and native progress. Ordinary
Squash rows dependent on that unresolved group also remain physical placeholders;
otherwise a first merge followed by Squash would fail Git's predecessor rule
before its parent question could appear. Accepted selection atomically restores
the executable merge action and its dependent ordinary Squash chain, preserving
Skip gaps and stopping at the next unresolved merge. Skip releases the dependent
rows rather than silently dropping their requested work. Pending/adopted action
writers and remaining-row projections retain this physical/logical distinction.

The native backend preserves its existing immutable one-parent execution-object
adaptation: that object's tree and chosen parent encode the merge-to-mainline
patch, while raw original message bytes, author/date, attribution option and
original occurrence mapping remain attached to the logical row. Preparing this
object changes no reference, index or working file. Acceptance journals the todo,
original-to-execution mapping, occurrence mainline and message configuration before
Git resumes. Cancellation after acceptance can therefore reopen the durable
selection without asking again or applying a different parent. Interrupted
metadata publication uses the existing replay-edit journal recovery.

Continue, Skip, empty-subject approval, conflict recovery and live logical
progress recognize the owned checkpoint rather than displaying its internal exec
as another commit. Editing future rows at an existing supported Edit,
file-recovery or Squash pause creates deferred parent choices without asking
about those future rows immediately. This does not add action editing at the
parent-choice pause itself. Changed HEAD, parents, replay files, occurrence,
owner, semantic replay intent, plan generation, Quit state or cancellation refuses
stale acceptance. Existing Edit/Split/Squash/Abort recovery remains distinct from
choosing a parent.

## Boundaries and validation

The next [leading-Squash continuation](REBASE-LEADING-SQUASH-PARITY.md) addresses
the earlier stopped-plan boundary when Skip removes the first retained group
leader. It preserves source no-commit approval and optional retained metadata
rather than inventing a leading Pick. Its [separate checkpoint](qa/pull-leading-squash-2026-10-26.json) records 35 affected Core methods passing cumulatively, a Debug build and paired native Git engines; the earlier mainline checkpoint below retains its original scope.

This supersedes the preflight-parent adaptation documented in the October 16
[Add preparation checkpoint](REBASE-ADD-PARITY.md#owned-add-and-merge-parent-preparation--october-16-2026).
Add still uses cancellable atomic picker insertion; this continuation does not
change its order, duplicate-row or incomplete-reference draft behavior.

The [grouped checkpoint](qa/rebase-mainline-2026-10-25.json) records the actual
production Git-prevalidation repair and earlier failures. The affected Core scope
passes cumulatively: fourteen methods passed the grouped run, then the remaining
cancellation fixture was corrected to assert the actual Git child-cancellation
receipt and passed alone with every durable recovery assertion retained. The
Debug build and both native Add/reached-parent cases pass with system and bundled
Git; both owned offscreen receivers were reaped and independently absent. Checks
cover parent-specific trees and original metadata, repeated occurrences, Skip,
empty-subject ordering, accepted-parent cancellation/reopening, stale replies,
existing recovery and owned sheet cleanup. Installed build 9 predates this source.

No claim follows for every octopus topology, arbitrary externally authored replay
scripts, hooks/filter combinations, physical parent selection or VoiceOver,
signed Finder/App Store execution, minimum-version/Intel execution, whole-dialog
visual parity or the complete hosted CI suite. The native one-parent execution
object remains an adaptation rather than the exact upstream `cherry-pick -m`
process sequence.


The authored [no-commit Split continuation](REBASE-LEADING-SQUASH-PARITY.md#split-continuation--october-26-2026)
adds final-approval child commits with captured group ownership and Cancel/reopen
recovery. Its [dedicated checkpoint](qa/rebase-no-commit-split-2026-10-26.json)
records the affected Core and native checks; preserve-merges orphan topology is
not extended by that continuation.


## Preserve-merges orphan Squash — October 26, 2026

The authored [structural no-commit continuation](REBASE-LEADING-SQUASH-PARITY.md#preserve-merges-orphan-continuation--october-26-2026)
supersedes the earlier preserve-merges orphan boundary for supported
single-parent groups. It preserves final DAG labels, deferred skipped-row
label/update-ref controls, checked-restoration/Split cursors and original-to-final
notes mappings. Unsafe Skip is refused before resetting the group when a future
merge would lose its first parent, an earlier refusal than the source fatal error.
Collapsed/reset-only merges record their actual reached result through an
exactly-once owned checkpoint, with anchored Continue/Abort recovery after a
refusal. Literal-first/merge-row Squash, repeated structural occurrences and
missing first merge parents remain refused. [Validation](qa/rebase-structural-no-commit-2026-10-26.json)
records the grouped focused checks; earlier checkpoints do not certify this new family.
