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

This continuation covers ordinary/advanced Cherry Pick no-commit groups. It does
not add orphan-group execution to preserve-merges structural plans; existing
structural Squash constraints and supported recovery remain separate.

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
