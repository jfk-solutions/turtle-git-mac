# Log Revert parity

Pinned source: `7338078f8ddd924b8cddee35f512f2286072136d`.

## Upstream mapping

`GitLogListBase.cpp` offers **Revert change by this commit** for one non-root,
ordinary revision with a working tree and no active merge. Merge commits get a
submenu for every parent. Parent titles contain the 1-based number, subject
truncated at 20 UTF-16 units and an eight-digit hash; a failed metadata read falls
back to number/hash. Root, bare, active-merge and stash/index-parent cases omit the
command. The native menu now maps these rules and original `menurevert.ico`.

Parent subjects load using the Log detail reader's owned cancellation token.
Selection replacement/reload/close cancel the reads and prevent stale metadata
publication. Failed individual subjects retain hash-only labels; the menu can use
those labels while metadata loads. Cached immutable metadata is pruned on reload.
AppKit needs no Windows accelerator escaping, so ampersands remain literal.

`GitLogListAction.cpp::RevertSelectedCommits` asks **Revert the selected commit(s)?**
with Yes/No and No as the default. The native parent-window alert retains that
question and default, with the selected parent label in its supplementary text.
The captured revision and mainline are not taken from a later table selection.
No does not invoke Git. `Git.cpp::GitRevert` uses `--no-edit --no-commit` and the
selected mainline; core revalidates the actual commit and parent range and checks
bare/active-merge state before mutation.

Success presents **Revision(s) reverted. All changes are integrated into your
working tree now.** with OK/Commit. Commit routes to the existing native Commit
workflow with the original repository grant. Status/Commit views and workspace
state refresh after successful or failed mutations; Log reloads after the result.
Git conflicts remain in index/worktree for resolution, with an error reported.
No automatic commit or conflict rollback is introduced.

## Evidence and remaining work

[The verification record](qa/log-revert-2026-10-06.json) records focused real Git
and headless native checks. Tests exercise both merge mainlines, ordinary commits,
root/invalid/active-merge rejection, unrelated staged/working preservation,
conflicts and unchanged HEAD. The bundled App Store Git audit also exercises both
mainlines. Parent metadata tests cover labels, fallback, owned cancellation,
child reaping and independent reading.

Displayed submenu, confirmation default/focus/keyboard, result prompt/Commit
handoff, progress and light/dark acceptance remain pending. Multi-revision Revert,
Skip/Abort continuation, detailed conflict/continue/abort flows, linked-worktree
acceptance and signed sandbox checks remain partial. Cherry Pick still needs its
upstream Rebase-dialog workflow; this change does not provide merge Cherry Pick.
The complete Log/application port remains unfinished.

## Shared history workflow implementation (October 11, deferred validation)

Log and the nested Merge, Switch and Fetch revision pickers now route captured
single/multiple selections through `HistoryRevertWindowController`. Merge-parent
choices retain their captured mainline. Multiple selection retains displayed row
order, skips the working-tree placeholder and uses the shared Skip/Abort error
choice, aggregated MERGE_MSG and completion Commit handoff. The original direct
model route remains available to consumers without a native workflow factory.
The child inherits its owner's appearance and opacity; owner close ends pending
questions and cancels the owned operation.

This integration is source-reviewed implementation, **not new execution evidence**.
The earlier shared Sync checks in
[the history workflow batch record](qa/history-workflow-batch-2026-10-11.json)
do not validate these new Log consumers. Builds, native launches and tests remain
deferred until the larger history section is ready. Forced close, Skip/Abort,
keyboard/focus and signed sandbox acceptance remain open for that pass.

The continuation also retains operation ownership after a forced window close:
Quit remains blocked until the cancelled Git worker returns. Successful Revert
messages are accumulated back into MERGE_MSG after each applied revision, so
cancellation of a later revision cannot discard earlier message text. These
lifecycle changes await the same deferred verification pass.


## Connected selected-history Revert/Combine family — October 14, 2026

Selected Revert now streams each actual command into the shared native styled
output with original copy icons, parsed current work/percentage, CR replacement,
split UTF-8 and a bounded whole-batch log. Original command results and diagnostics
remain in repository callbacks rather than being replaced by the display limit.
Validation failures without streamed bytes still append their diagnostic. The
attempt counter advances before each row, including failed/placeholder rows, as
the source progress does. Initial No, multi-failure Skip/Abort and final OK/Commit
remain separate questions; Commit closes the result before dispatch exactly once.

Successful messages are written back to MERGE_MSG before the next attempt,
including when a later command is cancelled. Partial index/worktree changes are
retained; no automatic commit or rollback is introduced. The controller's ordinary
busy close routes through Cancel. Forced closure settles owned questions, cancels
Git and fences late output/result/Commit handoffs. Operation accounting and captured
scope remain alive until the worker and output drain return. The shared Combine
family additionally owns preparation, Commit, replay and rollback, described in
[Combine commits](HISTORY-COMBINE.md).

The native output UI adapts the source system progress window; no Git-progress
auto-close/kill-confirmation policy is imposed on that different source workflow.
Physical submenu/question/default/Commit-button handling, linked-worktree/error
variants, screenshots/themes/VoiceOver and signed scopes remain open. Earlier
October 11 deferred notes are historical; dated evidence below covers the new
connected implementation and its actual limited verification scope.


The Debug build, five affected Core tests and two native engine cases passed on
the first validation attempt. Core checks cover a real combined middle range with
replayed descendants, unchanged final tree/branch, mismatched interior-row refusal,
dirty preparation, cancelled hard/soft recovery and both merge Revert mainlines.
The native family covers preserved messages, Skip/Commit ordering, actual Commit
presets/Git amendment/replay, forced pending-child rollback and retired Log/Sync
reads. Both receivers were reaped. See [batch evidence](qa/history-workflows-2026-10-14.json).
No full Core or legacy Sync suite was repeated. Actual Commit-button and all
physical/nested-menu interactions remain outside this evidence.
