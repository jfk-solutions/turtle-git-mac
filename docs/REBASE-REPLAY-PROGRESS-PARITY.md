# Rebase replay progress and recovery

Pinned source: `7338078f8ddd924b8cddee35f512f2286072136d`,
`RebaseDlg::OnBnClickedAbort`, replay thread/DoRebase and shared Commit Split.

## Connected implementation

Start, Continue, Skip, Abort, Edit/Amend and Squash now accept an owned cancellation
and mutation-output callback. Synchronous actor scopes retain these inputs through
nested validation/Git helpers, restore previous inputs on return or failure, and
never leak a cancelled token into later recovery reads. Validation/object output
is excluded from progress; replay/commit/reset mutations stream actual bytes.

The native Rebase/Cherry Pick progress tab uses the shared bounded color/output
renderer with carriage-return and split UTF-8 decoding. A running Cancel control
consults ConfirmKillProcess. No keeps the operation running; Yes cancels its owned
process. This stops the current command rather than automatically undoing earlier
replay mutations. The existing explicit Abort remains available after recovery.
Upstream running Abort signals its worker, so this is an explicit macOS process
cancellation adaptation rather than an identical Windows thread mechanism.

An interrupted or failed replay reads the actual coherent session with a fresh
token, retains its recoverable files/message/remaining rows and reports a stopped
or failed result rather than claiming success. Owned counters and repository leases
remain alive until preparation, commands and recovery reads settle; retirement
suppresses later callbacks and follow-on dialogs. Empty-result, conflict-hint,
mainline and another-Split questions now settle once when their owner closes.

Stash Save, Split and checked-conflict commits stream through the same progress
machinery.
Their write/continuation-record phase finishes before observing a queued stop,
so a completed commit cannot lose its durable part count and expected HEAD record.
The Split Commit progress remains noncancellable during this protected phase.
Split metadata/read handoffs retain operation ownership and reject late children.

## Acceptance still open

The batch includes real Git scope/cancellation/Split tests and a native receiver
for running Continue/Abort streaming, confirmation, actual paused-state recovery,
retirement and Quit. Physical sheets, full replay/hook/editor/signing interruption,
all structural/cousin/octet replay variants and signed scopes remain open. No
rollback or filesystem transaction is promised across Git commands. Existing
stash restoration and source completion actions retain their separate audits.
The complete Rebase/Cherry Pick dialog and whole application remain uncertified.
The initial grouped Core run covered 84 cases; its only failure was the new
Split fixture flag. The existing 77 Rebase and four session cases passed. Corrected
replay I/O cases and a queued-cancellation boundary check passed in a four-case
repair, then the affected Skip bookkeeping case passed separately after a compile
repair. The broader Core group was not repeated. Debug compilation and four native
cases across system/bundled Git passed; the native fixture first needed a private
property assertion changed to displayed status. Its final checks also cover a
declined pre-replay Stash retaining the unsaved draft and Start action. Every owned
receiver was reaped. See [batch evidence](qa/rebase-replay-progress-2026-10-14.json).
