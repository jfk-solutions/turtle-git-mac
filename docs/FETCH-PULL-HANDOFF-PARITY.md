# Fetch/Pull completion and Rebase handoffs

This October 18, 2026 batch compares native completion with
`src/TortoiseProc/PullFetchDlg.cpp` and `AppUtils.cpp::DoFetch`/`DoPull` at upstream
`7338078f8ddd924b8cddee35f512f2286072136d`. It extends the partial
[Fetch](FETCH-PARITY.md) and [Pull](PULL-PARITY.md) audits.

## Operation and native completion

The source executes post-commands after its modal progress dialog returns. Native
Fetch and Pull now retain a completion receipt until AppKit has detached the actual
progress sheet. They then finish the outer options window and dispatch the selected
follow-up once. Pull comparison and history retain the original before/after HEAD
hashes, and Fetch retains its selected destination and result. Deferred Rebase uses
the same native completion path. Previously a close request could dispatch the next
window while the old sheet still owned the options window, leaving that owner open.

Actual-operation counters cover transport, result/recovery inspection and accepted
asynchronous Rebase callbacks, including after forced owner closure. Permission leases
stay alive through the pending work. Independent native release receipts retain the
closed child until actual sheet detachment; application Quit refuses both pending
work and pending release. Fetch/Pull form receipts and completed progress actions
also refuse dispatch while another document's deferred Quit is unresolved. Native
children and progress questions inherit their owner's alpha and appearance before
presentation, keeping automated receivers invisible and light/dark behavior coherent.

## Failed Rebase handoff recovery

An accepted Fetch followed by an owned Rebase opening can fail independently of
transport. The error now remains in the Fetch log with its existing Rebase action.
That action retries the immutable fetched commit and automatic/preserve-merges flags
without fetching again. A remote advancing between attempts cannot change the
accepted target. Success closes normally; duplicate activation and retired owners
cannot repeat or publish the handoff.

Sync suspends two sheets before awaiting Rebase. Fetch records that presentation
chain before handoff and, after an opening error, restores options and progress only
after their actual previous sheet ownership has drained. The existing Sync callback
clears its previous error before each attempt, so a successful retry is not reported
as the earlier failure. This is native error/ownership adaptation; no additional
pre/post Fetch or Pull client hooks were invented. Those source operation paths do
not invoke such hooks. Existing Rebase and Git-native merge hooks retain their own
operation owners.

## Verification scope and remaining gaps

`qa/fetch-pull-handoff-native-2026-10-18.swift`, entry
`FetchPullHandoffVerification.verify()`, uses private preferences and a local-only
source repository. It covers actual hidden Fetch/Pull sheets, source post-action
order, deferred-Quit refusal, close-before-dispatch and once-only callbacks, immutable
Pull endpoints, a suspended two-sheet Rebase error/recovery chain, retry without
transport, and forced retirement of a noncooperative asynchronous handoff. Success,
failure and timeout cleanup close owned windows and wait for operation/release
counters. Fixture presence is not a passing result; grouped outcomes are recorded by
the parent validation checkpoint. No Core algorithm changed, so this batch needs no
repeated Core suite.

Credential-bearing network transports, physical popup/focus/VoiceOver acceptance,
all source controls at every locale, complete pixel/layout comparison, signed
sandbox/Finder and older macOS/Intel deployment remain open. Existing broader Fetch
and Pull gaps remain in the linked family audits. This batch changes no literal UI
labels or source icon mappings and does not establish whole-dialog or whole-app
completion.
