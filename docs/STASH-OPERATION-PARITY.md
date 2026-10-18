# Stash preparation, completion and ownership

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This extends the existing Stash audit; `IDD_STASH` and the connected
Save/Pop/Apply/Drop workflows remain partial family mappings, not a whole-port
completion claim.

## Source mapping and preserved behavior

| Pinned source | Native implementation |
| --- | --- |
| `AppUtils.cpp:106–112`, `CAppUtils::StashSave`, `CheckUserData` | User Save prepares the configured author/committer identity before enabling its form; missing data opens an owned Git Settings sheet. Cancel aborts preparation. Accepted Settings rereads effective identity, including source environment precedence. Submission rereads, and Core checks once more immediately before stash push. |
| `StashSave.cpp:39–124`, `IDD_STASH` (`TortoiseProcENG.rc:1812–1827`) | Single-line optional message, include-untracked and --all mutual exclusion, OK/Cancel/Help, horizontal resize and Continue-only warning suppression remain. Controls capture form identity and reject writes from retired, disabled or deferred-Quit presentations. |
| `AppUtils.cpp:114–156`, Save command and completion | Keeps `stash push`, enabled flags, unchanged message bytes through `-m`, and old/new refs detection. Pull and Merge precede created-only Pop/Apply, with existing source icons and follow-up values. Successful no-change Save can still offer Pull/Merge. |
| `AppUtils.cpp:161–207`, `StashApply` | Selected entries remain hash-pinned; Apply keeps the stash. Success/conflict questions and quiet notices retain source showChanges behavior. |
| `AppUtils.cpp:210–258`, `StashPop` | Latest-stash Pop, independent remembered clean/conflict answers, showChanges modes and conflict-retained stash behavior remain. |
| `RefLogDlg.cpp`, stash deletion; Core `ReferenceLog.swift` | Existing explicit Drop/Clear confirmation, positional-stack snapshot validation, oldest-first deletion and per-item failure handling remain intact. This batch adds no new Drop identity requirement. |

## Identity and operation contract

`StashSaveOptions.requireIdentity` defaults false. Source user Save sets it true;
internal Rebase/Bisect saves keep Git's existing requirements. Core refusal uses
`StashFailure.identity` before the mutating command. No Merge-only active-replay
restriction is imposed: upstream Stash Save does not call IsTGitRebaseActive.

Preparation owns its cancellation token, repository grant and static
`StashWindowModel.activePreparations` count until the read/Settings workflow
actually returns, even after forced owner closure. A late or noncooperative read
cannot enable a retired form or launch Git. Closing a pending preparation cancels
its token and retires the Settings sheet, then closes the owner after return.
Submission captures the options and follow-up request. The Core command has its
own final identity recheck; an earlier accepted Settings result is not an authority
to mutate later.

Save progress consumes a chosen post-action once and drains its actual AppKit
sheet before closing progress/options and dispatching the follow-up. A retained
button or duplicate reply cannot dispatch a second operation. Restore similarly
drains the result question and closes the Restore window before View Changes.
Ordinary result Close and forced closure also retain actual detach ownership.
`StashWindowController.activeChildReleases` includes both Save and Restore child
transitions; the shared release helper is retained until AppKit reports the child
is detached.

Owned include-untracked, process cancellation and result sheets pass the parent's
alpha and appearance before presentation. A result that arrives while a Cancel
question remains attached drains the old question before presenting the result.
Forced closure retires replies and queued presentations. Settings retains its
existing owned sheet release implementation. No automated child should appear
visibly when its owner is hidden.

Save, Save Progress and Restore expose `confirmingQuit`. Deferred Quit refuses new
form/command/post-action transitions. Root Quit checks include preparations,
pending warnings/Settings, progress/result prompts and child-release counters;
actual Git execution retains `LocalGitCommandProgress`/Restore operation counts.
An accepted Restore answer already delivered during deferred Quit waits for that
state to end, then is consumed once.

## Grouped verification

Implementation completed before the grouped checkpoint. The related Core and
native cases passed; actual failures, focused repairs and remaining limits are
recorded in the batch evidence below.

- `StashOperationTests` uses private real repositories for final user identity
  refusal before index/worktree/stash mutation, preserved default internal Git
  behavior and cancellation. Explicit process identity overrides may skip the
  missing-identity assertion, matching the source precedence.
- `qa/stash-operation-native-2026-10-18.swift`,
  `StashOperationVerification.verify()` exercises actual hidden Settings
  cancel/accept and identity reread, stale form controls and option exclusions,
  the native warning Abort/Continue, Quit ownership, real Save/captured options,
  ordered post-actions and duplicate dispatch, actual sheet-drained follow-up and
  Apply View Changes, retained stash and noncooperative preflight retirement.
- Retained `qa/stash-save-progress-native-2026-10-08.swift` now awaits initial and
  submission identity preparation before inspecting progress. Its existing real
  Git snapshots, options, no-change actions, warning, cancellation and failure
  assertions remain. The retained Restore receiver still verifies remembered
  choices, conflict behavior, cancellation and failure handling.

The new receiver owns private preferences and repositories, keeps all windows and
sheets hidden, closes every owned controller and drains held operations on success
and failure. It does not invoke network, Keychain, a credential helper, or the user
pasteboard.

## Remaining acceptance and limits

Physical light/dark layout and keyboard/accessibility review of every upstream
control, signed/App Store folder grants, installed helper behavior and complete
Finder integration remain separate acceptance work. Existing Git cancellation can
retain mutations already completed; no rollback is promised. Windows message-box
and system-progress presentation uses native sheets/windows while preserving its
result choices. Drop/Clear behavior is retained from its existing family audit;
this batch does not certify every Reflog menu or every stash/replay combination.

Grouped execution outcomes and repairs are recorded in
[batch evidence](qa/stash-submodule-workflows-2026-10-18.json).
