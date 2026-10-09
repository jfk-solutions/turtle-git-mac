# Submodule Sync parity

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
`SubmoduleCommand.cpp/.h` Sync branch, `ProgressDlg::RunCmdList`, shell
`MenuInfo.cpp` SubmoduleSync clause and `src/Resources/menusync.ico`.
This is local submodule URL synchronization, separate from the unported broader
SyncDlg transport window. No SSH agent or network connection is required.

The application action and Finder menu use the unchanged original colored Sync
icon. Finder requires a folder in Git with submodule configuration, as in source;
bare metadata denies the action. Selecting an initialized indexed submodule root
resolves its superproject. Cached parent metadata participates in Finder grant
selection; the app revalidates the actual repository before dispatch.

Source has no options dialog and does not pass `--recursive`. The native action
opens a progress window immediately. For each selected directory, in selection
order, it runs `git submodule sync -- <scope>`; selecting the project root runs
`git submodule sync`. Ordinary files are skipped. The application menu without a
selection synchronizes the whole current project. Ordinary Git exit errors do
not prevent later directories; aggregate status is bitwise OR, matching source
RunCmdList. Cancellation and launch/validation errors stop later commands.
Earlier successful config changes are retained; there is no rollback.

Arguments remain literal arrays, including newline/quoted/Unicode paths. Native
validation rejects missing/outside-tree scopes and directory symlinks, validates
configured module paths and rechecks before each command. This is stricter than
source's directory probes. Git updates registered submodule URLs and initialized
child remotes, not `.gitmodules`, HEAD, worktree files or the index. Uninitialized
modules remain uninitialized. Nested module URLs are not recursively synchronized.

Native progress captures scope, repository lease, output limit and auto-close
policy at submission. It parses live bytes/CR/UTF-8, displays commands and output,
and retains the result on errors. Manual mode keeps success open; no-options and
no-errors close successful Sync with no additional actions. ConfirmKillProcess
uses source Yes/No with Yes default. No retains the process, Yes cancels its owned
group, and duplicate/late responses cannot cancel completed work or repeat close.
Completion while the question is pending waits for its answer before auto-close.
Close during a running operation invokes cancellation; forced controller closure
cancels and fences late output/results. Quit is blocked during operation/question;
idle progress freezes during another document's Quit question. Action-log writes
use the existing app-installed store; headless receivers use no standard store.

## Verification and remaining work

[Verification record](qa/submodule-sync-2026-10-09.json) separates real-Git Core
coverage, hidden native ownership checks and unsigned build/bundle evidence.
Fixtures allow local file transport only at their construction invocations and
then synchronize dummy SSH URLs without connecting to a server. The original
icon's blob/SHA-256 and AppKit decode are checked, and Submodule Add's shared Add
artwork is explicitly allowed by the icon regression test.

Still partial: displayed progress/window/sheet/keyboard/VoiceOver/light-dark
acceptance, complete source progress geometry/elapsed-time/scrolling/taskbar/Save
and context menus, action-log physical acceptance, signed parent/child Git-dir
scope inheritance and Finder activation/dispatch, all path/config/race variants,
and broader SyncDlg. No new screenshot or App Store readiness is claimed. Other
submodule workflows retain their own partial mappings.
