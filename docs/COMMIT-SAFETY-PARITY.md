# Commit detached HEAD and cancelled-draft recovery

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.

## Detached HEAD decisions

`CommitDlg.cpp:799` invokes `CheckHeadDetach` after optional branch creation.
`CheckHeadDetach` at lines 2957–2979 offers Yes, No and Cancel: Yes opens the full
Create Branch dialog with switching enabled, No continues on detached HEAD and
Cancel returns to Commit. `RebaseDlg.cpp:1594` suppresses the warning for its
owned replay Commit. A detached commit is still a valid explicit choice.

Native Commit checks the current branch during each ordinary commit attempt.
The question belongs to the captured Commit repository and retains its paths,
checkboxes, attribution, message and completion action. Yes opens the existing
native Create Branch workflow with its full reference controls and switching
selected. Cancelling the child abandons that attempt. Successful child completion
is distinguished from partial branch creation followed by cancellation; after
release, Commit reads the actual branch again. Creating without switching does
not silently accept detached HEAD: the question is offered again. No explicitly
allows the current detached attempt. Replay and history-combine amendments retain
their separate ownership and suppress this ordinary safety question.

The inline new branch option uses the existing commit engine's create/switch
transaction; a failure there aborts rather than creating a detached commit. The
question is skipped for that explicit path. Native warning placement precedes
Core's atomic index preparation; upstream prepares its checkbox index before the
question. Cancelling the native question therefore does not stage checked paths.
Client pre-commit hooks can already have run, as in the source. A branch created
and switched by the child remains real repository state if a later commit fails.

Questions and branch children inherit appearance, captured access and the private
preferences transaction. Forced owner closure cancels the operation, rejects late
answers and waits for native child release and pending reads. Quit forwards to
the child and retains pending-work accounting. Ordinary cancellation after a
pending detached preparation drains returns through draft/history and saved-copy
recovery instead of dropping the draft.

## Recover the issue field when cancelling

`CommitDlg.cpp:1567–1572` calls `UpdateLogMsgByBugId(false)` before changed-draft
comparison and history persistence; lines 1617–1643 trim the issue ID, replace
comma-space and space-comma once, expand every `%BUGID%`, then append or prepend
the configured line. Cancellation does not validate numeric IDs, execute regex
matching or suppress a matching issue line already present in the editor.

Native cancellation derives this recovery message without changing the visible
editor or issue field. Rejecting Cancel and asking again cannot accumulate lines.
Accepted cancellation writes the derived message to the existing history store;
an issue-only draft counts as changed. The ordinary template/amend comparison,
non-amend draft preservation, saved-copy recovery and preference ownership remain
in the same cancellation workflow. Invalid issue IDs remain recoverable even
when Commit itself would reject them. Source behavior for a nonempty issue ID
with an empty template is retained as well.

## Validation and remaining acceptance

Eight focused Core methods and six native case/engine runs passed with Apple and
bundled Git across the grouped checkpoint and focused fixture repairs. The native
checks use real detached commits, Create Branch/switch/error retry, unswitched
reoffer and Rebase Split commits. Cancellation/history checks retain exact draft,
issue-line and non-Amend recovery assertions. Late-reader/child drain checks use
injected delayed reads/preparation; they do not prove every live hung Git process.
All eight owned receivers, including failed attempts, were reaped and independently
absent. The Debug app build passed after a native type correction; Core was not
rerun for native-only repairs. Existing compiler/toolchain warnings remain.

[Recorded evidence](qa/commit-safety-family-2026-10-20.json) retains failure and
repair scope, actual checks, source hashes and visually inspected offscreen
light/dark captures. The full Core/native suites and hosted CI were not certified. Physical keyboard/VoiceOver, all conditional layouts, external hook UI,
signed sandbox grants, installed Finder and App Store acceptance remain open.
This family does not certify the whole Commit dialog or full application port.
