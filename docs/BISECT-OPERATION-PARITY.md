# Bisect progress, guarded review and owned continuations — October 18, 2026

Source pin `7338078f8ddd924b8cddee35f512f2286072136d`:
partial `IDD_BISECTSTART` and shared `IDD_GITPROGRESS` coverage,
`BisectStartDlg.cpp`, `AppUtils.cpp::BisectStart` (3567) and
`BisectOperation` (3647), and `ProgressDlg.cpp` completed progress (311 onward)
and `IDC_PROGRESS_BUTTON1`/post-command list handling (406 onward).

## Implemented connected family

The completed Bisect result now offers the source default action with an adjacent
menu, replacing the separate horizontal classification buttons. When available,
Submodule Update is first, followed by Good, Bad, Skip and Reset with their
original update/thumb/Bisect artwork. A failed/interrupted active operation keeps
only Reset. A successful Reset has no classification actions, while its optional
Submodule Update remains available as in AppUtils. Existing custom good/bad terms,
culprit display, actual Git state and original source command precedence remain.

Each actual progress attempt records elapsed time and completes at 100 with
Success, User cancelled or the failure status. The existing completion formatter
supplies the source-style status/date/elapsed footer, honors ShowGitexeTimings and
the date locale preference, and marks the exact output completion range for native
styling. Live streamed work/percentage remain unchanged. Read-only loading does
not invent a successful command receipt. New attempts clear the old footer;
Action log history retains the completed previous attempt. Forced retirement
keeps the accepted display frozen rather than appending late completion text.

Start-field bindings and picker/Start/split-action callbacks carry a model/form
epoch. Loading, progress transitions, picker ownership, Return to options, Quit
confirmation and retirement invalidate prior controls. Guarding lives in the
model binding so a deferred native combo notification cannot exploit a stale
enabled view. Picker results still capture their original target/string and now
also reject a changed owner epoch. All normal form, picker, cancellation and
continuation dispatch is blocked while confirming application Quit. Root keeps
that flag through both deferred termination paths.

Owned Log pickers, dirty-worktree Stash/Abort questions and kill confirmations
inherit the captured owner's alpha and appearance before presentation. Picker
preferences remain the actual Bisect owner's private/captured preferences. A
Submodule Update continuation is captured once, closes the Bisect owner, waits
for actual AppKit sheet detachment, releases ownership, then invokes the captured
follow-up. The child-release counter blocks Quit during that interval. Root uses
the same preferences for the resulting Update dialog.

## Mutation receipts and compatibility

`startBisectWorkflow`, `bisectWorkflow` and `stashBeforeBisectWorkflow` return
actual results plus typed `BisectMutationResult` receipts. Receipts retain the
kind, attempted commands, statuses, complete original output and cancellation.
An exception after a successful earlier command or during a later command throws
`BisectMutationFailure`, retaining both the receipt and underlying error. The old
Start/classification/Stash APIs preserve their original return/error contracts
by delegating and unwrapping the underlying error. Canonical object queries read
stdout and remove only Git's final LF; successful ambiguity warnings on stderr
cannot enter a subsequent Good/Bad argument. Git-directory queries retain their
existing exact stdout/single-LF path handling. Validation failures before
mutation still return their original failures.

Native `onAttemptCompleted` publishes an attempted receipt once, even if its owner
was force-closed while Git was running. Root uses it to refresh repository history,
Commit, Status and replay state. These refresh facts are distinct from a successful
complete operation: a failed command or post-command metadata read may follow
partial ref/index/working-tree changes. Legacy `onChanged` remains live-only for
existing consumers and observed Logs; it is not a success callback. No late view
or legacy callback is revived after retirement.

Stash retains its existing backend unchanged. Its receipt conservatively covers
the submitted save operation, including internal save/preflight/post-save reads;
it does not claim every thrown save reached Git or created a new stash. A receipt
whose submitted commands exited zero does not prove a subsequent state/metadata
read succeeded. There is no automatic rollback or stash reapply.

## Grouped verification

The Debug app build and 23 selected Reset/Bisect Core cases pass. The new Bisect
native operation case passes with system and bundled Git. The
[grouped checkpoint](qa/switch-reset-bisect-workflows-2026-10-18.json) records
retained coverage, actual failures, affected rechecks and process cleanup.

- `BisectOperationTests` adds three Core cases: real dirty refusal, Stash/Start/Reset
  command/output/state receipts with the stash retained; and owned live cancellation
  during Start's Good command, retaining Start plus interrupted Good and a real
  recoverable session, stopping later Bad, and reaping wrapper/sleeper processes.
  An ambiguous branch/tag case verifies canonical hashes come from stdout alone,
  excluding successful Git warnings from subsequent mutation arguments.
- `BisectOperationVerification.verify()` in
  `qa/bisect-operation-native-2026-10-18.swift` uses private Git repositories,
  preferences and invisible native owners. It covers guarded review and retired
  callback epochs, actual hidden Log picker and Stash/Abort sheets, real Stash/Start/
  Reset, source split action order/icons, timed/untimed completed output and exact
  footer range, Quit refusal, actual Submodule owner sheet release followed by one
  callback, hidden kill confirmation, partial cancellation/forced-close receipts,
  frozen retired presentation and owned process reaping.
- Retained Bisect progress/lifecycle fixtures retain their existing streamed
  output, custom terms, Reset, stale picker, action log, cancellation and retirement
  assertions. The older reusable eligibility loop in the combined native receiver
  installs a model-level handoff adapter so it can inspect successive classifications;
  actual owner closure is covered by the new dedicated native case. Its assertions
  remain intact.

These scoped checks do not establish physical theme/layout/keyboard/VoiceOver
acceptance, every checkout hook, signed Finder/App Store or complete hosted CI.
Owned test windows and children are closed and operation/release counters drained
on success/failure. No user clipboard or public server is used.

## Remaining adaptations and limits

The native review and progress remain one owned window; upstream creates separate
modal instances. Dirty-worktree approval remains at accepted Start rather than
before opening the review. The native backend validates supplied commits before
mutation and stops Start after a nonzero step; upstream's generic command-list
runner can continue after an ordinary error. Existing safety behavior is retained
rather than sending later classification commands after a failed Start.

Custom terms, merge/replay exclusions, tracked-only Stash, untracked checkout
protection, linked-worktree paths and source command precedence are preserved.
An external process can change Git state between queries and mutations. There is
no transaction-wide rollback, automatic stash apply or guarantee of successful
completion merely from displayed controls. Physical split-menu/default-button
behavior, full progress visual parity, real diagnostics/accessibility acceptance,
all partial metadata-read failures and signed deployment remain open. This is a
partial Bisect family replacement, not certification of the entire port.
