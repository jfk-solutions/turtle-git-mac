# Client Hook Scripts — implementation in progress

Source: Utils/Hooks.cpp/.h, ProjectProperties::FetchHookString,
Settings/SetHooks.cpp, SetHooksAdv.cpp and the two Hook Scripts resources at the
pinned revision in PORTING.md. GPL-2.0-or-later.

The Core layer now represents all six client hook types, the five-line global
format, shared `hook.<type>.cmdline/wait/show` values and source nearest-path
selection (global then local at each ancestor, wildcard last). Local approval is
bound to repository/type/exact command and must remain in per-user storage.
Saving local hooks updates the eighteen recognized `.tgitconfig` keys and
preserves unrelated configuration/includes. It rejects bare repository saving.
Writes use Git's individual configuration locks, not a cross-key transaction.

Owned invocation plans create private UTF-8 path/message/error files and retain
them through execution/readback. Commit hooks receive path file, message file and
working tree; post-commit receives working tree/amend flag; Push receives error
file/working tree; Rebase receives upstream/branch/error file/working tree.
Success reads back the mutable UTF-8 message; failure retains the original.
Newline-containing path-list entries are explicitly unsupported by this source
file protocol and must be reported by the caller.

The execution API launches a literal POSIX command line in the working tree and
owns its process group. `%root%` is substituted within parsed arguments, preserving
roots containing spaces/quotes. Explicit `/bin/sh -c` is supported through normal
arguments; Windows commands need macOS equivalents. Launch acknowledgment and
completion are separate so the caller can implement the source non-wait option
while retaining cleanup/cancellation ownership. Output is file-backed and display
is capped at one MiB per stream. Child processes are stopped when execution is
cancelled or its leader exits. The source show/hide setting will control native
output presentation; it cannot control arbitrary script-created GUI windows.

The native Hook Scripts list/configuration dialogs, shared Apply/Cancel, per-user
approval decisions and Commit/Push/Rebase hook boundaries are now connected.
Enabling/disabling a local hook stores a per-user decision; it does not add a
non-upstream `enabled` key to the shared repository. Enabling a previously denied
hook clears denial so execution asks again. Changing its exact command also
requires a fresh decision. Global hooks are pre-approved, as in source.

Non-waiting scripts are retained by a shared owned pool; File → Cancel Running
Hook Scripts provides cancellation, and Quit waits for completion. Visible hook
progress windows close on completion. Show/Hide does not govern script-created
GUI windows. Pre-operation failures offer Abort/Continue; successful Git
operations remain successful when a post-hook fails, with a retained error.
Post-push also runs after failed non-cancelled transport attempts. Pre-rebase is
connected to native Rebase Start, excluding Cherry-pick, with upstream and branch.

App Store builds require the captured repository grant. Script Browse remembers
a security-scoped executable bookmark; execution retains scopes for literal
external file arguments that have matching bookmarks. Complex shell expressions
remain constrained by the sandbox, and signed execution acceptance is pending.

The connected replay identity/boundary review below supersedes the older
pending source-placement notes for Rebase autostash, Merge-created commits and
alternate replay/Sync paths. Remaining acceptance: post-action combinations,
comprehensive success/failure and cancellation combinations,
script-created UI and output presentation, stale/script folder grants, screenshots,
physical keyboard/VoiceOver and signed deployment. This family remains partial.

Passing `ClientHooksTests` cover format and selection, approval identity changes,
literal quoting, all payload layouts, private file modes, message readback and
cleanup, configuration retention/removal and cancellation, real cwd/output/message
mutation and owned leader reaping. The grouped native receiver covers shared
settings drafts and owned child dialogs, per-user decisions and late approval,
actual Commit/Push/Rebase boundaries, post-commit failure with preserved Git
success, non-wait ownership, Cancel All and Quit accounting. Results are recorded
only after the checks have run.


The first native attempt exposed completed-execution disposal cancelling the
caller's token. Execution now marks completion before publishing its result;
disposal and Cancel ignore completed executions. The Core check explicitly
asserts the successful caller token survives disposal. Final focused results and
initial failures are recorded in `qa/client-hooks-native-2026-10-12.json`.


## Start/ReCommit and failure-choice follow-up

Launch and command-preparation errors now use the same Abort/Continue choice as
nonzero script exit codes. Continue preserves the original draft and does not
launch again. Cancellation, retirement and missing security scope remain
non-overridable. Late Continue replies are checked before publishing results.
Aborting Start closes Commit without modifying Git state. ReCommit reloads the
fresh template and runs Start again, matching the two pinned caller sites.

The native post-commit argument follows `dug_settings_hooks.xml`: `false` for an
ordinary commit, `true` for amend. The pinned Windows caller passes
`amend.IsEmpty()` even though `amend` contains `--amend` when enabled, inverting
that documented meaning. This discrepancy is explicit; scripts relying on that
Windows inversion need adjustment. Native ordinary/amend flags, ReCommit, Start
closure, missing executable/malformed command choices and cancellation/retired
replies passed the focused receiver. No full Windows behavioral certification is
inferred. See `qa/client-hooks-failures-native-2026-10-12.json`.


## Native layout review

Compared the pinned SettingsHooks.png / SettingsHookEdit.png and corresponding
resources with actual native compositor captures in Aqua/Dark Aqua. The five
columns and Remove/Edit/Copy/Add order are retained. The Path header uses the source caption. The earlier configuration capture
displayed the source disabled `local` placeholder; the October 19 draft transition
work below supersedes its value presentation and retains an explicit initial-local
comparison gap. Issue Tracker Config is
now a child of Hook Scripts in the settings tree, matching Settings.cpp. The
original monochrome hook image uses native template tinting for dark contrast.

Six related utility images are published with the capture record. The Hook page
image uses a dedicated private host with shared footer, not the full navigation
tree. Configure controls preserve Enable/type/repository/path/command/Wait/Hide/
OK/Cancel/Help order. Native fonts, rounded fields and alternating table styling
are macOS adaptations. Window resize, physical keyboard/VoiceOver and signed
acceptance are not certified by these images.

## Replay identity repair and actual source hook boundaries — October 18, 2026

The connected review follows pinned `RebaseDlg.cpp::CheckRebaseCondition`,
`AppUtils.cpp::CheckUserData`, `Git.cpp::GetUserName/GetUserEmail/GetCommitterName/
GetCommitterEmail` and `CommitDlg.cpp`'s three Commit client-hook call sites.
The related native resource families are `src/Resources/TortoiseProcENG.rc` /
`IDD_REBASE` and `IDD_SETTINGIT_CONFIG` (the native Git Settings page).

Rebase Start now checks all four explicit author/committer values after the
source's tracked-change stash boundary and before PreRebase. Git's synthesized
login/host identity is not accepted as configured user data. Nonempty environment
values take precedence over author/committer settings, then user settings; empty
overrides fall through. This preflight deliberately preserves the pinned
`GetCommitterEmail` use of `GIT_AUTHOR_EMAIL`, rather than silently changing that
source UI rule to `GIT_COMMITTER_EMAIL`. The Git subprocess environment itself is
unchanged and retains Git's own identity semantics.

Incomplete identity offers Yes/No and an owned Settings sheet beginning on Git.
It retains the replay repository, permission lease and original preferences in
an independent Settings transaction. Returning from Settings does not certify
identity or start the hook: all four values are read again, and the offer repeats
if they remain incomplete. No aborts the pending Start. A stash already created
by the source ordering stays owned and available through the existing restore
flow. Cherry Pick shares identity validation but does not acquire a PreRebase
client hook. Cancellation/owner retirement rejects delayed metadata and Settings
replies; actual read/operation accounting remains owned until return.

Source review also resolved two older pending hook questions without inventing
extra call sites. Automatic merge commits from `git merge` have no Tortoise
Start/Pre/PostCommit client-hook caller; the explicit Commit post-action opens
the existing Commit dialog and its hook workflow. Sync Fetch-and-Rebase and Pull
Rebase handoffs use the same owned Rebase Start boundary, including autostash,
identity repair and PreRebase, while alternate Cherry Pick replay remains excluded.
The existing Sync Push calls retain their separate PrePush/PostPush boundaries.

`ReplayUserIdentityTests` exercises explicit/inherited values, environment and
empty-override precedence, the pinned email rule, missing identity, cancellation
and unchanged configuration/HEAD. The native
[replay fixture](qa/replay-hook-identity-native-2026-10-18.swift) covers actual
stash/identity/hook ordering, repeated incomplete Settings repair, original hook
arguments, failed-hook history preservation, held-read retirement/Quit ownership,
the actual owned Git Settings page and forced parent closure. Parent grouped
validation records outcomes; fixture existence does not prove a pass. Physical
Settings gestures, all replay combinations, signed script/save grants and whole
application parity remain open.

Actual grouped build/check outcomes: [history action batch evidence](qa/history-actions-2026-10-18.json).

The actual native identity Settings sheet reproduced a Close/OK/Cancel refusal:
AppKit disabled its title-bar close control despite an idle transaction. The
owned sheet now accepts explicit close actions only through its live transaction
and existing delegate guards. It retains its continuation and question ownership
through actual parent/child sheet detachment, including forced parent retirement.
The invisible fixture exercises Close, real OK/Cancel footer dispatch, held-save
refusal and late-reader drain with both Git engines. This fixes that owned sheet;
it is not a claim about every Settings host or signed platform behavior.

The connected [captured Settings sheet family](SETTINGS-SHEET-PARITY.md) shares
guarded Close/OK/Cancel and actual-detachment ownership across Properties,
Unified Diff and Rebase, preserving their original preferences and pending work.

## Hook Scripts editor and checked-list source comparison — October 19, 2026

The connected editor/list changes follow `Settings/SetHooks.cpp`,
`Settings/SetHooksAdv.cpp`, `Utils/Hooks.h::hookkey/hookcmd` and
`IDD_SETTINGSHOOKS` / `IDD_SETTINGSHOOKCONFIG` at the pinned source revision.
Add starts with no selected type, an empty working-tree scope and Enable off;
Wait and Show remain on. Copy retains the selected hook's type, command and flags
but clears its path, matching the fields copied by `OnBnClickedHookcopybutton`.
These are editor defaults; the public Core model's initializer is unchanged.

The repository-only checkbox disables the scope field without overwriting its
global draft. Acceptance assigns the captured repository root for a local hook;
a global hook requires `*` or an existing absolute directory. A selected hook
type and a nonempty command are required. Script Browse quotes the selected path
for the native POSIX argument parser. Its captured permission is remembered only
if the accepted command still matches that chosen script. Typed commands continue
through the existing argument and sandbox checks at execution.

The native AppKit list retains the source's five columns, checked first column,
raw hook-type names and Wait/Show text. Rebuilt content sizes its columns to the
header and row text; the captured FullRowSelect preference controls the selected
rectangle. Double-clicking a selected row opens Edit from any text column;
checkbox gestures remain checks. Native row navigation and Space checking are
available without adding non-source Delete or Return commands. The earlier
SwiftUI-table styling description is superseded by this native checked list.

Folder/script choosers retain their captured preferences, appearance, permission
leases and editor revision through actual sheet detachment. Duplicate replies,
retired owners and stale drafts cannot publish a selection. Closing an editor
drains its owned chooser before releasing its completion, while settings changes
remain within the existing shared Apply/Cancel transaction. Source table/editor
gestures, signed permission persistence and full visual acceptance remain open;
the grouped batch record reports validation only after it runs.


### Exact identities, grants and decision ownership

Hook identity, selection and draft equality compare original UTF-8 scope and
command bytes. Canonically equivalent Unicode spellings remain separate. The
existing global five-line format and approval Codable fields are unchanged;
ordinary stored decisions remain valid for their actual exact tuple. A different
spelling requires its own decision. Project saving also rejects a hook whose
scope is only canonically equivalent to the actual repository root.

Native script bookmarks use an encoded array rather than String dictionary
identity. Existing ordinary dictionary entries remain readable and migrate on a
new grant write. Once the new store exists it is authoritative. Acquisition
validates the resolved exact URL before starting access, renews a stale bookmark
only after access starts, and balances every earlier grant on partial failure.
Grant decode, start or renewal failures remain non-overridable access failures.
This is a macOS sandbox adaptation, not a Windows hook format change.

Approval and Abort/Continue choices retain the actual native sheet until it
physically detaches. Duplicate replies, cancellation and retired owners cannot
persist approval or launch scripts. Caller Task cancellation reaches the shared
operation token; a pending native question observes token cancellation and closes.
Injected asynchronous approval/read callbacks retain their ownership until their
actual return. Session counters and pending process-start accounting block Quit
through reads, question release and actual producer drain. Non-wait scripts retain
their existing pool ownership. Show/Hide continues to control the native running
window; no claim is made that macOS controls arbitrary script-created GUI windows.

The [connected batch evidence](qa/hook-scripts-family-2026-10-19.json) records
nine focused Core methods, the Debug app and six native case/engine pairs passing.
Initial compile, URL-normalization, picker and fixture failures remain recorded.
The actual default No button action passes; hidden Return event routing did not
work and does not certify physical keyboard input. All owned receivers were
reaped. No new screenshots were produced.

The editor opened from an existing local row currently displays its actual root,
rather than the source's initial disabled `local` value. Exact initial local/global
transition presentation, physical input/VoiceOver, signed script grants and
complete source parity remain open. No dialog is certified complete.
