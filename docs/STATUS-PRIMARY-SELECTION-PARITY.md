# Selected-file Return and clicked-row activation

This connected continuation covers Classic Commit, Working Tree and Revert.
The focused Core check, Debug app build and combined native cohort passed with
system and bundled Git. [The checkpoint record](qa/status-activation-family-2026-11-23.json)
retains the actual scope and earlier failures.
Earlier clicked-row evidence does not prove the new selected-row Return route.

## Pinned behavior

At TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`, the shared
`src/Git/GitStatusListCtrl.cpp:2926–2976` double-click handler activates its
clicked row, ignoring checkbox state-icon double-clicks. Its Return handler at
`3618–3667` confirms the complete selection once and then activates each selected
row in displayed order: conflicts enter ConflictEdit, unversioned/ignored files
enter StartDiffWC, missing added/renamed/copied rows are skipped, and ordinary
rows enter their comparison. `CheckMultipleDiffs:4360–4371` uses NumDiffWarning.
`OnGetDlgCode:3611–3616` keeps Return in the list instead of the default button.

StartDiffWC clears action flags and passes working-copy operands
(`GitStatusListCtrl.cpp:2996–3023`, `GitRev.h:101`, `GitHash.h:138–145`). This is
an actual working-file preview, including the surviving disk copy after an index
deletion; it is not an invented empty-base or tracked-deletion comparison.

## Native input and accepted plan

The shared native primary-action bridge distinguishes a clicked-row receipt
from an ordered selected-row receipt. Return and keypad Enter require the exact
visible report/window/key owner and report first responder. Field editors,
foreign windows and Command/Control/Option combinations keep their own input.
An empty or temporarily mismatched report consumes Return without submitting
Commit/Revert. Group headings are not file IDs. Checkbox pointer exclusions and
Classic clicked-row behavior remain independent from selected Return.

Gui staging uses its existing stage/unstage double-click routes; the Classic
bridge is not its activation handler. Explicit context-menu Compare remains one
comparison request, even when selected files include conflicts.

`StatusListPrimaryActivation` retains ordered exact StatusEntry rows and their
real index/worktree flags, directory/gitlink roles, source window/preferences,
Git backend, alternate-tool choice, merge tools and conflict identity options.
Its source Intent is captured synchronously before busy publication. Initial
cancellable reads resolve the accepted literal HEAD/parent or empty-tree base
before the one selected-count question. Root consumes this immutable plan with
no second warning and never re-reads a replacement HEAD.

The source model's existing operation token/counters retain the request through
its own question and actual Root preparation. Selected records are checked in
O(selected) time; repeated cancellation polling does not rebuild an all-files
map. Source changes, tool/backend changes, Quit and retirement revoke delivery.
Working-file previews use two working sides; ordinary comparisons use the
accepted base; source missing combinations are classified by the shared
StatusEntry comparison eligibility rather than a lossy display caption.

## Closing and refresh

Cancel/close can retire an owned selected-file warning. The source operation
stays owned until both warning sheet links and the actual async handoff drain.
Status and Revert defer forced onClosed completion while that request remains
pending; Commit retains its existing file-work completion contract. Root owns
its child preparation separately and acknowledges after progress-sheet drainage.
Opening a native conflict editor is launch acceptance, not resolution.

Commit queues an ordinary repository refresh requested during primary activation
and services it after drainage. New scope/Whole Project requests retain their
existing admission rules. Status and Revert retain their queued refresh paths.
Read-only primary cancellation does not add a misleading partial-mutation error.

## Prepared verification and remaining scope

The existing clicked-row native cohort and its assertions remain intact. A
connected receiver continuation mounts all three actual reports, injects native
Return/click events through their real bridge, inspects one accepted selection,
and calls the production Root dispatcher on real private conflict/index/working
files. It checks one warning, declined and actual native No responses, literal
base pinning while HEAD moves, stale settings refusal, field/foreign/empty
selection ownership, explicit Compare, retained-copy preview, original bytes,
and forced close/Quit while an actual Root conflict read awaits acknowledgement.
The combined native cohort passed these checks with both Git engines; injected
child presentations keep this separate from physical keyboard, external-tool
and signed-distribution acceptance.

The legacy focused receipt remains available for unconfigured standalone
consumers. Add, Resolve and Synchronization have their separate report contracts;
this continuation does not certify all shared status-list consumers. Physical
keyboard/mouse/VoiceOver interaction, translated bundled presentation, signed
sandbox handoffs, exhaustive mixed-status combinations and complete port parity
remain separate acceptance scopes.
