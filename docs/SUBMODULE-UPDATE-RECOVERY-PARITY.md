# Submodule Update and Sync execution/recovery — October 18, 2026

This is a partial audit of `IDD_SUBMODULE_UPDATE` and connected `IDD_GITPROGRESS` workflows.

Source pin `7338078f8ddd924b8cddee35f512f2286072136d`:
`SubmoduleCommand.cpp:159–171`, `MassiveGitTaskBase.cpp:209–229`, and
`ProgressDlg.cpp::RunCmdList`. This is the execution/recovery part of the related
Stash/Submodule batch. Existing options/list controls, icons and persisted scope,
selection and flags remain in place.

## Implemented execution family

Explicit Update selections are split into ordered argv batches before execution.
The macOS budget counts UTF-8 bytes, NUL terminators and pointer slots, including
Git's fixed arguments, executable and repository path. It derives a conservative
budget from ARG_MAX, the current environment, runtime/environment reserve and a
128 KiB ceiling. A single path too large for the remaining budget fails before
any Update command. Options and `--` are repeated for every batch; selected paths
retain their exact order and Unicode spelling. Later batches recheck path safety.

Unlike upstream's all-selected command omission, every native batch carries the
reviewed explicit selection, including scoped lists where every displayed row is
checked. This intentional adaptation prevents a folder-scoped review from updating
unreviewed submodules elsewhere. Commands are passed without a shell; the quoted
command line in progress output is display text only.

Like source RunCmdList, ordinary nonzero statuses are aggregated with bitwise OR
and later batches still run. Launch/validation failures and cancellation stop the
sequence. `SubmoduleUpdateResult` retains each attempted batch's exact paths,
status and output. `successfulPaths` includes only complete zero-status batches;
it does not infer which paths changed inside a failed batch. `attemptedPaths` is
the conservative refresh/recovery boundary. A failed launch is an attempted
submission, not a guarantee that a process or mutation occurred.
`SubmoduleUpdateExecutionFailure` retains the partial result and underlying error.
The old String-returning `updateSubmodules` keeps its existing error contract.

Sync preserves source ordered-directory commands and ordinary-error continuation.
Its result now retains cancellation and aggregate output; a
`SubmoduleSyncExecutionFailure` carries any completed/interrupted commands when a
later cancellation/validation/launch failure stops execution. The existing
`syncSubmodules` method preserves its throwing cancellation contract. Empty/file-only
Sync still reports source failure status rather than success.

## Native completion and ownership

Update and Sync expose typed `onAttemptCompleted` receipts exactly once when a
command was attempted. Receipts publish partial changes on ordinary failure,
cancellation and forced owner closure, while late progress presentation remains
fenced. Successful workflow callbacks remain separate: Update `onUpdated` and
Sync `onSynced` cannot advance a parent operation on failure or cancellation.
The root workspace uses attempted receipts to refresh repository history, status,
Commit and replay state. The Submodule Diff child forwards the captured mutation
callback even after its presenting owner is retired.

Sync now has an operation drain counter independent of its window lifetime;
Update retains its existing counter. Active command processes and children remain
owned through cancellation and reaping, so forced closure does not allow Quit to
race an in-progress mutation. Existing bounded progress, cancellation policy,
completion footer and action logs remain in use. Native cancellation sheets inherit
owner alpha and appearance before display.

The successful Update Bisect menu retains source Good/Bad/Skip/Reset icons and
eligibility. It owns one captured handoff, closes the progress window, waits for
actual AppKit sheet detachment, releases its owner and then calls the captured
Bisect action once. A release counter covers that interval for Quit. Root routes
follow-up windows with the actual Update/Diff owner's preferences. The previous
Submodule Diff close override is removed so one controller owns native detachment.

## Grouped validation

The complete related implementation froze before one grouped Core/native
checkpoint. The scoped checks passed; actual receiver repairs and remaining
acceptance are recorded in the batch evidence below.

- `SubmoduleUpdateRecoveryTests` adds three Core tests: UTF-8 argv budgeting and
  exact path identity; ordinary-error ordered Update/Sync partial receipts; and
  cancellation in a second command retaining the first receipt, stopping later
  selections and reaping owned wrapper/sleeper processes. Existing Update/Sync
  Core contracts remain covered by their focused classes.
- `SubmoduleUpdateRecoveryVerification.verify()` in
  `qa/submodule-update-recovery-native-2026-10-18.swift` uses private local
  repositories, initialized local submodules, a private preference suite and
  hidden native owners. Its wrapper runs real selected Git Update/Sync commands
  before injected failures/cancellation pauses. It verifies partial refresh versus
  success callbacks, unchecked selection exclusion, parent HEAD/index/gitmodules
  preservation, actual Sync config changes, forced-close result delivery and
  reaping, Quit ownership, and exactly-once Bisect after real sheet detachment.
- The retained `SubmoduleSyncReceiver.run()` partial-error assertion now consumes
  the attempted-result callback and separately asserts zero success callbacks.
  Retained `SubmoduleUpdateProgressReceiver.run()` and
  `SubmoduleHandoffsVerification.verify()` remain applicable: their model-only
  Bisect action is synchronous after its close callback, while actual native
  detachment is covered by the new fixture. No behavioral assertions are removed.

Owned native windows/sheets stay invisible; success/failure cleanup closes owners,
cancels work, drains operation/release counters and waits for owned child reaping.
No credential helper, public server, user pasteboard, Finder operation or signed
application is exercised by these private fixtures.

## Remaining limits

The budget is conservative rather than an exhaustive proof for every macOS
runtime/environment. Validation cannot eliminate an external process changing
configuration between checks and Git execution. Each Git command may partially
modify several submodules; there is no automatic rollback or per-path success
claim within a failed batch. Recursive/network/authentication failures, every
merge/rebase/force combination, physical progress/keyboard/theme review, signed
sandbox acceptance and large real-world repositories require further acceptance.
This family does not certify every upstream Submodule dialog or the whole port.

Grouped execution outcomes and repairs are recorded in
[batch evidence](qa/stash-submodule-workflows-2026-10-18.json).
