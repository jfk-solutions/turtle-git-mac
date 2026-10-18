# Reset execution, recovery and native follow-ups

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This is a focused `IDD_RESET` and its progress/child workflow comparison. It does
not establish full visual parity or completion of the whole port.

## Source mapping

| Pinned source | Native and Core behavior |
| --- | --- |
| `ResetDlg.cpp:58–102`, `IDD_RESET` | Current branch; Branch/Tag/Commit selectors and full reference/Log browsing; Soft/Mixed/Hard radio descriptions; initial selected-mode focus; horizontal resize and saved geometry remain. Bare repositories select Soft and disable Mixed/Hard. |
| `ResetDlg.cpp:124–140` | OK captures revision and mode. Modified Files compares HEAD with the working tree independently of the proposed reset target. |
| `AppUtils.cpp:1544–1609` | Actual reset uses captured target/mode. Failure offers Retry with the original plan; native final HEAD/current-reference checks refuse stale plans. Cancellation remains attached to the actual Git process. |
| `AppUtils.cpp:1610–1638` | Successful Hard reset offers Submodule Update when `.gitmodules` exists; active bisect offers Good/Bad/Skip/Reset in that order; Hard reset offers Clean last. Existing source icons and progress policy remain. |
| `AppUtils.cpp:1655–1664` | The options dialog, progress result and selected continuation form one ownership chain. Native follow-ups wait for actual sheet release rather than the earlier EndSheet request. |

## Canonical object and reference responses

Reset preparation and its final execution recheck consume stdout for
`rev-parse --verify` and `symbolic-ref --quiet HEAD`. Only the single protocol LF
is removed. Stderr remains diagnostic text, including successful ambiguity
warnings; it must never become part of an object identity or current reference.
Combined Git command text is still displayed for the actual Reset result.
Detached HEAD still produces a nil symbolic reference. Existing bare-repository,
invalid-target, changed-HEAD/reference and cancellation protections remain.

The regression uses a real Git branch and tag with the same short name pointing
to different commits. A second real-repository case injects successful stderr
around actual Git plumbing and covers preparation, final recheck, Mixed effects
and detached HEAD. Neither substitutes a fabricated ResetPlan for Git parsing.

## Native acceptance and recovery

Every form binding carries its owner, form generation and captured draft.
Disabled/inactive controls, old picker bindings, held Hard confirmations and a
Quit roundtrip cannot revive a previous form event. Preparation captures revision,
mode and draft before awaiting Git. Hard Reset keeps its existing explicit
warning about tracked changes and obstructing untracked files; declining it
performs no reset. A delayed confirmation is one-use and verifies its captured
form generation and draft before applying the plan.

Reference, Log and Modified Files child ownership remains held until the native
sheet is actually detached. Hard and cancellation alerts inherit the actual
owner's appearance and alpha; so does progress. A cancellation reply is applied
only after its alert sheet releases the progress owner. Close/Quit cannot escape
a held confirmation or open a second child. Forced closure cancels work and
suppresses late window callbacks, while the actual-operation counter and captured
repository lease survive until Git and any owned helper process drain.

Retry keeps the original plan and does not quietly resolve a moved branch again.
The final Core HEAD/reference check still protects the user if another operation
changed the repository. Successful non-Retry continuations are one-shot. They
run after both the progress sheet and its options sheet release their native
parents. Existing `onChanged`, successful `onReset`, and `onPostAction` contracts
remain; originating preferences are retained for descendants by the root router.

## Validation scope and remaining gaps

Added `ResetOperationTests` and the private native receiver
`docs/qa/reset-operation-native-2026-10-18.swift`
(`ResetOperationVerification.verify()`). The native case exercises real ambiguous
revision execution, stale native binding/Quit receipts, actual invisible Hard
and cancellation alerts, ordered/icon-preserving Clean continuation after actual
nested sheet detach, owned helper No/Yes cancellation, Retry, forced close and
actual operation/Quit/process drain. Its repositories, preferences and helper
processes are private. Directly affected retained Reset progress, picker,
Modified Files and workflow assertions remain; the existing actual workflow
receiver now stays invisible and waits for the complete native detach.

The Debug app build, 23 selected Reset/Bisect Core cases and the new Reset native
operation case with both Git engines pass. The
[grouped checkpoint](qa/switch-reset-bisect-workflows-2026-10-18.json) records
retained coverage, actual failures, affected rechecks and process cleanup.
Physical Light/Dark acceptance at every
size, VoiceOver/keyboard acceptance beyond the focused receivers, signed sandbox
permissions, hosted CI and real Finder invocation remain separate acceptance
work. No source Reset control or postaction is knowingly omitted by this focused
comparison; that does not mark every shared chooser/progress control audited.
