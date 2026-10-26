# Pull conflict-result review and handoff

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This is a connected continuation of [Pull progress](PULL-PARITY.md) and
[Fetch/Pull handoff ownership](FETCH-PULL-HANDOFF-PARITY.md), not a new Pull
transport implementation or complete dialog acceptance.

## Exact source result decisions

`AppUtils.cpp::DoPull` (2422–2434) asks `IDS_SEECHANGES` only when progress returns
`IDOK`, Git status is exactly 1, and `progress.m_LogText` contains the literal
`CONFLICT`. The resource caption is “Do you want to see changes?”
(`src/Resources/TortoiseProcENG.rc:4783`). The information question has Yes/No,
default Yes and no saved suppression key. Yes opens `repostatus` for the captured
repository; it does not itself resolve files or commit a merge.

Progress distinguishes terminal intents. `ProgressDlg.cpp::OnBnClickedOk`
(640–649) copies the result control into `m_LogText` then returns OK.
`OnCancel` (665–697), including the completed window's close button, returns
Cancel. Busy cancellation keeps its existing optional process-kill question.
A selected post-action follows `OnBnClickedButton1` (651–656): it writes the log,
executes the accepted action and ends OK, but does not populate `m_LogText`.
The CString member defaults empty (`ProgressDlg.h:106`); `GetLogText` (108)
returns a separate local copy. Therefore an accepted post-action does not also
trigger the final See Changes question.

The prior conflict-information/suppression hint and Resolve/Commit result menu
are separate decisions (`AppUtils.cpp:2326–2349`). Working Tree review must not
replace those actions, nor turn an ordinary failure, cancellation, success or
preflight error into a conflict-result Close.

## Connected native scope

The implementation separates an explicit accepted result Close from Cancel,
window dismissal, automatic cancellation close, selected post-action and forced
owner retirement. It captures the actual result exit status and conflict output
independently of a clipped presentation log. The source's exact status/token test
is retained; reading only current working-tree conflicts is not the close gate.
The full-result token capture avoids losing a real conflict merely because native
presentation truncates earlier output; it is an explicit bounded-log adaptation.

An eligible accepted Close awaits one owned Yes/No sheet. The question, repository
access and Quit ownership survive until the actual answer and sheet detachment.
Yes queues Working Tree with the captured repository/grant; No closes normally.
Neither answer modifies the conflicted index or working files. Repeat Close,
retained answers, forced closure, replacement owner and cancellation cannot
create a second question or late Working Tree. Normal Cancel/window dismissal
and an already accepted explicit post-action bypass this question.

The same result transaction owns existing post-action close-before-dispatch and
actual worker/sheet drain. It must retain successful Pull's immutable Diff/Log
endpoints and existing Stash Pop/Push/Submodule Update flags, and failed Pull's
Resolve/Commit or unrelated-history/retry/Stash/Reset decisions. Working Tree is
an internal accepted-close handoff, not an invented extra result-menu entry.

`PullProgressWindowModel.requestClose(accepted:)` owns the terminal intent and
result identity. `PullProgressWindowController` owns cancellation, conflict-hint
and See Changes sheets through one answer/detachment transaction. Its close
transaction waits for pending operations and sheets before releasing the captured
handoff; a forced window closure invalidates the model and discards that handoff.
The outer Fetch/Pull completion gate and application Quit accounting include the
pending result question. `RepositoryModel` opens Status against the captured
repository and access lease rather than adopting a different workspace root.

## Existing Fetch/Rebase completion boundaries

Configured Pull Rebase still routes through Fetch rather than `git pull --rebase`
(`AppUtils.cpp:2445–2457`). `RebaseAfterFetch` (2465–2518) distinguishes accepted
normal completion, Log, Push, Send Mail, another Rebase and Cancel. Log opens the
captured repository; Send Mail exports the selected upstream-to-branch range
before composing, and failed export does not send a partial batch. These existing
native workflows remain independent of the merge-based Pull conflict Close.
A cancelled Rebase must not become successful Pull review, and its explicit
completion child must not be replaced by Working Tree.

## Verification and remaining boundaries

The [grouped checkpoint](qa/pull-leading-squash-2026-10-26.json) records a
successful Debug build and offscreen native execution with system and bundled Git.
The checks use genuine conflict results, retain the exact exit/output gates,
distinguish Close/Cancel/window dismissal and accepted post-actions, and verify
held answers, actual sheet detachment, owner retirement and once-only captured
Working Tree delivery. The first native run caught dispatch during windowWillClose
before the window was hidden; the scoped visibility repair passed both engines.
Existing Fetch/Rebase/Log/mail behavior remains separate from this focused result
transaction acceptance.

Physical keyboard/VoiceOver, signed installed repository grants, every network
transport/hook combination, minimum-version/Intel execution, whole-dialog source
layout and complete hosted CI remain separate acceptance work. No automatic
conflict resolution, Commit, stash restoration or email transport is introduced.
