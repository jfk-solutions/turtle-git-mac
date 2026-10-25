# Empty-message Rebase and Cherry Pick recovery

This family addresses a confirmed active-source behavior: a retained replay entry
with an empty subject must receive a warning and editable recovery. The connected
implementation is complete and has received bounded source review and focused
Core and grouped native validation. This document does not establish
complete Rebase parity or signed installed acceptance.

## Pinned source contract

References are the pinned TortoiseGit commit
`7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/RebaseDlg.cpp` and
`src/Resources/TortoiseProcENG.rc`.
The shared `IDD_REBASE` dialog also hosts the advanced Cherry Pick mode.

`DoRebase()` at lines 2036–2113 establishes the ordering:

1. A Skip entry is marked done and returns before the warning or replay work.
2. The original action and next non-skipped action determine squash message
   accumulation, first-author/date metadata and `--no-commit` preparation.
3. The action, hash and subject are logged. An exactly empty subject triggers
   `IDS_PROC_REBASE_EMPTYCOMMITMSG`, an OK/exclamation warning: “Found an empty
   commit message. You have to enter one or rebase cannot proceed.”
4. The local effective mode becomes Edit. The stored requested row action is not
   changed. Empty-tree detection, merge-parent choice and actual replay follow.

The condition is `GetSubject().IsEmpty()`, not a trimmed-message check. A subject
containing spaces is not the same condition. The warning concerns a missing
subject, independently of whether applying the commit changes the tree. It is
shown for the reached retained entry, rather than for all empty subjects in an
initial plan. Skip entries and entries never reached must not produce warnings.

The same `DoRebase()` path covers ordinary replay, Cherry Pick and preserved
merges. Successful effective Edit stops execution at lines 2324–2327 or
2368–2371. Conflicts retain their ordinary recovery path; the stored original
requested action is still used by later source continuation logic.

## Squash, authors and recovery

Original and effective actions have distinct roles. Replacing every empty-subject
plan action with Edit before preparing the plan would change the source's squash
boundaries and metadata. In particular, the no-commit decision at lines 2080–2086
precedes the local Edit override. `CheckNextCommitIsSquash()` at lines 1753–1785
skips Skip entries and follows the replay direction.

Edit continuation at lines 1625–1719 rejects a trimmed-empty edited message. Plain
Edit amends the current commit; Squash Edit creates a commit using the retained
first-author/date policy. If the next retained entry is Squash, the source reads
the latest HEAD metadata after the edit and resets the squash base with the user's
edited text. The amended author and message must therefore survive into the
remaining group. The existing native nonempty-message, author, date and
empty-tree recovery rules remain part of the connected workflow.

Split is offered in Edit and Squash Edit at lines 1902–1904. The Commit child
workflow at lines 1568–1613 initially amends except in Squash Edit; subsequent
split parts use ordinary commits. Cancelling the child returns to the retained
replay state. Empty-subject handling must preserve these existing entry points,
checked-file recovery and pending message drafts.

Abort at lines 2584 onward retains the ordinary confirmation and worker-stop
rules. Cherry Pick restores its captured starting revision; ordinary replay
restores its captured branch/HEAD. A warning does not authorize discarding work,
resetting another session or bypassing recovery.

## Connected implementation

The native replay uses Git's sequencer. An owned pre-entry `exec false` checkpoint
stops immediately before each retained empty-subject occurrence. Its persisted
identity distinguishes repeated occurrences and records the original requested
action. Reading a stopped checkpoint produces a warning receipt bound to that
entry, session state and HEAD. Native acknowledgement uses the existing replay
sheet owner, cancellation and progress lifetime; Core revalidates the receipt
before continuing. Skip entries receive no empty-subject checkpoint.

Non-Squash entries use an effective Edit execution action while retaining their
requested action in replay metadata. Structural merges retain their parent/label
mapping and explicit Edit break. Empty-subject Squash entries retain their group
operation, followed by a separate owned checkpoint so the combined message must
be reviewed before advancing. This distinction avoids applying a squash member
twice or treating a requested Squash as an unrelated Pick. The durable message
review and author/date handling remain part of the existing squash workflow.

These checkpoints cover ordinary and structural replay and Cherry Pick. Stopped
sessions retain their occurrence identity for reload, pending-action editing,
Continue, Split and Abort. The warning is separate from an empty-tree decision or
failed-Pick question. Native recovery selects the reached occurrence, presents
the source warning, and leaves a cancelled acknowledgement recoverable rather
than silently advancing. A mandatory post-application message pause is exposed as
active recovery, rather than as a generic failed command.

Cancellation, window retirement and Abort drain the owned question. A late reply
cannot bypass the captured cancellation or state/HEAD checks. Existing nonempty
edited-message, conflict, checked-file, author and Split controls remain in use.
Structural checkpoint Skip uses the current occurrence’s owned label boundary,
including reset-only merges, and retains later logical entries. Adoption and
pending-action edits validate the owned markers against persisted replay identity
rather than recognizing arbitrary lookalike commands. These branches have bounded
static review and are included in the focused Core checkpoint.

The sequencer checkpoint is a macOS execution adaptation to upstream's MFC worker
loop. Source warning text and reached-entry ordering are retained; exact internal
Git commands and intermediate HEAD/index states are not asserted identical to the
source's precomputed `--no-commit` path. In particular, an effective Edit before a
later Squash and a combined-message review use the native durable recovery model.
Focused actual-repository checks cover resulting message, author, topology and
recovery behavior within the recorded cases. No new user-facing option chooses between these execution
mechanisms.

## Verification and remaining boundaries

The [dated family receipt](qa/rebase-empty-message-2026-10-25.json) records the
bounded checkpoint and its failures. The initial Core group ran 37 methods: 35
passed and two failed. One Split fixture used the wrong default amend contract;
its assertions were retained after correcting that fixture. The other failure
exposed a production defect: a later Squash reused Git's stale first message
section and lost the intermediate approved subject/body. The repair persists the
approved message with its reviewed boundary, uses it only inside that same group,
and appends later original bodies once. Both pending-action writers retain the
approved message.

A focused recheck passed eight methods: the two previously failing methods and
six directly affected retained Squash methods. Together these runs establish 37
distinct Core methods passing cumulatively; the entire initial group was not
repeated. The affected Debug repair build succeeded. This is focused validation,
not a complete Core suite or hosted CI result.

The grouped native checkpoint passed all six distinct case/engine pairs: three
families (`review`, `sequence`, `ownership`) with system and bundled Git. It exercises the real owned warning sheet
and message review, replay-mode/recovery behavior, and cancellation/retirement
ownership within its recorded cases. The source text, one OK button, invisible
sheet ownership, native action dispatch, detachment and progression into Edit
remain asserted.

The first sheet assertion failed because it expected the OK button's Return
`keyEquivalent` to remain set. Diagnostic evidence showed that AppKit had cleared
that property while retaining the actual default button cell. The fixture alone
was corrected to assert default-cell identity and enabled state; the other sheet
and dispatch assertions were retained. No production UI repair was made for that
failure. Final native evidence is recorded in
`build/qa/rebase-empty-message-native-default-cell-repair-2026-10-25.log` and the
linked family receipt. The cumulative result is 37 distinct focused Core methods,
the successful Debug repair build and six native pairs passing, rather than an
unqualified first-attempt or full-suite pass.

Full graph/recovery combinations, physical keyboard and VoiceOver behavior,
supported macOS/Intel execution, signed installed workflows and complete hosted
CI remain separate acceptance boundaries. See [Rebase parity](REBASE-PARITY.md)
and [release blockers](RELEASE-BLOCKERS.md); their dated evidence is not renewed
by this focused checkpoint.
