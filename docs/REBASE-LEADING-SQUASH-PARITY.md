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

The source enables Split in both Edit and Squash_Edit (`RebaseDlg.cpp:1902–1904`)
and handles normal split commits at 1568–1605. The implementation excludes an
active no-commit group from Split; this remains an explicit source behavior gap. Existing Split in
other supported replay pauses is unaffected.

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
