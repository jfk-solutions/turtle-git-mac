# Switch execution, recovery and completion

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This is a connected `IDD_GITSWITCH` / `CGitSwitchDlg` operation-family extension to
[Switch parity](SWITCH-PARITY.md). It does not certify every picker, progress
resource or complete upstream dialog.

## Source mapping

| Source | Native behavior |
| --- | --- |
| `GitSwitchDlg.cpp:135–169`, OnBnClickedOk | Branch validity/existence and cross-name tag warnings retain the validated immutable options. The native warning is an owned hidden/appearance-inheriting sheet; Abort preserves the draft and Continue revalidates the captured options. Retired/duplicate answers cannot approve a different warning. |
| `GitSwitchDlg.cpp:173–223`, SetDefaultName | Existing local/remote/tag/commit default names, remote symbolic target suggestions, exact suffix tracking behavior, eight-character commit name, tri-state tracking and SwitchToTagNewBranch/SwitchToCommitNewBranch choices remain. |
| `AppUtils.cpp:1266–1335`, Switch/PerformSwitch | Keeps attaching local branches, detached revisions, branch creation/override, force, merge and tracking effects through existing Core Checkout validation and Git operations. No new identity requirement or Merge-only active-replay restriction is added. |
| `AppUtils.cpp:1336–1387`, progress callbacks | Successful Submodule Update, Merge previous branch, Pull and Commit retain source order/icons and conditional gates. Failed checkout retains Stash/Retry/Switch with Merge; failed merge checkout with conflicts retains Resolve/Retry. Source Resolve intentionally opens Commit, as the existing root mapping does. |
| `AppUtils.cpp:1371–1385`, post-exec conflict detection | A successful Git process that leaves merge conflicts is still presented as failure with “Has merge conflict”. Fresh status inspection after cancellation remains owned and cancellable through actual return. |

## Native form and picker ownership

Switch's form and progress models expose `confirmingQuit`. A transition rotates
form identity, disables captured form inputs and refuses browse/checkout/retry or
post-actions during deferred Quit. Accepted picker returns require the captured
options/target draft and the owner's availability. Root propagates the flag in
both document confirmation and asynchronous background-watch shutdown branches.

Initial catalog, reference return, checkout validation/execution and fallback
history reads retain `SwitchWindowModel.activeReads` until their actual provider
returns, including forced closure. Validation cannot start progress after owner
retirement or deferred Quit. The existing full Reference Browser and single-choice
Log remain the normal picker routes. Their pending result already waits for actual
sheet detachment; forced picker retirement now also owns that transition rather
than dropping its last controller reference before AppKit returns.

The source tag-name question now uses a native owned alert in application Switch
windows. The old model-only/SwiftUI path remains available for existing consumers.
The accepted warning snapshot is independent of later direct model mutation.
Immediate injected decisions wait for validation's busy state to settle. Deferred
Quit decisions are retained once rather than launching Git under another dialog's
termination review.

## Execution, recovery and actual closure

`SwitchProgressWindowModel.activeOperations` covers execution, metadata and fresh
conflict inspection, preserving the repository lease until return. Closing a
running owner cancels it; late output or success cannot revive retired UI.
`checkoutOperation` is the existing real Core operation behind a narrow injectable
provider used to verify noncooperative cancellation ownership without launching an
unowned process.

Owned progress, cancellation and tag-name sheets receive parent alpha and
appearance before presentation. Cancellation replies run after their actual sheet
release. Normal completion and post-actions drain the progress sheet, close the
progress/controller owner exactly once, and only then dispatch to the next
workflow. The close route also handles a controller whose window was never ordered,
using one guarded retirement callback once it is detached and invisible.

A selected post-action is consumed before closure. Source Stash/Resolve after a
failed checkout closes the obsolete Switch options owner as well, so the next
workflow does not appear alongside an actionable old Switch form. A failed result
closed without a follow-up can still return to the editable native options draft,
retaining the existing native adaptation. Retry and Switch with Merge stay in the
same progress owner and preserve captured options while changing only the intended
merge attempt flag.

Root follow-ups receive the actual originating preferences for Submodule Update,
Merge, Pull, Commit, Stash and express branch/ref/history entry points. The selected
previous branch is captured before the attempt and remains canonical when passed
to Merge. Preference inheritance does not grant access to a different repository.

## Grouped verification

The Debug app build and new Switch native operation case pass with both Git
engines. The [grouped checkpoint](qa/switch-reset-bisect-workflows-2026-10-18.json)
records the sheet-completion repair, retained coverage, affected rechecks and
process cleanup. No Switch Core behavior changed or additional Core suite ran.

`qa/switch-operation-native-2026-10-18.swift`,
`SwitchOperationVerification.verify()`, uses private repositories/preferences and
hidden native owners. It covers actual native tag warning/captured options,
normal source actions and once-only follow-up after progress/options close,
failed checkout followed by a real merge conflict and Resolve, deferred Quit and
stale controls, actual Cancel No/Yes, held backend ownership, and a late initial
catalog after forced closure. Held providers resume and all owned windows drain
on success/failure; this receiver creates no helper process, network request,
user clipboard entry or standard preference write.

Retained Switch progress, picker, reference-owned Switch and RefLog express checks
retain their existing assertions. Reference-owned forced nested picker closure
now waits for the actual release before asserting retirement. Picker/reference
owners explicitly use alpha zero; RefLog models receive their existing private
preference suite. These adjustments preserve behavioral checks rather than
removing asynchronous lifetime assertions.

## Remaining behavior and acceptance

Physical accessibility, every light/dark control/locale/font layout and signed
Finder/App Store integration remain separate acceptance. The full Reference Browser
and Log have their own outstanding family coverage. The source's Win32 dialog and
system integration are represented by native ownership; this is not a claim of
pixel identity. Git cancellation may retain completed ref/index/worktree changes;
no rollback is promised. This family retains the existing extra validation and
native draft-recovery behavior documented above rather than claiming wholesale
Windows error-path identity.
