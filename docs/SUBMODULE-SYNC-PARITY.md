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
`git submodule sync`. Ordinary files are skipped. If no commands remain, the result is -1/failure,
matching ProgressDlg rather than reporting an empty success. The application menu without a
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

The submodule progress log now has the source Copy / separator / Copy all
information to clipboard menu with original copy icons, respecting application
menu-icon preferences. Copy All preserves selection and viewport without a
temporary select-all. Live output follows the tail and retains a valid selection;
shortened/truncated text clamps ranges. The pane uses native dynamic text/background
colors and the configured log font. Both progress windows expose parsed percentage
and current work, a progress bar, separate Close/Abort and a native Escape route;
Close remains the Return default, including when Update offers bisect actions.
[Progress control verification](qa/submodule-progress-controls-2026-10-09.json)
records hidden native evidence; physical display/keyboard acceptance remains pending.

Completion now replaces the phase label with Success, the Git exit-code result or
User cancelled and finishes the progress bar. The visible/action-log footer uses
source completion wording and, by default, elapsed milliseconds plus a localized
short date/time. The native dialog settings expose Show Git execution timings and
timestamp; disabling it keeps the completion line without timing. Elapsed time
uses the monotonic process clock. UseSystemLocaleForDates selects native
localized short date/time or the source fixed yyyy-MM-dd HH:mm:ss local format. Native validation/launch failures without a Git
status use Operation failed; forced close still fences late output.

At completion the output styles only exact line-start fatal/error/warning prefixes:
bold red errors and yellow warnings with source light/dark RGB values. StyleGitOutput
(default true) gates those prefixes independently of links and terminal color.
The existing upstream URLFinder port supplies URL/email links; clicks use native
URL handling, while hidden QA injects a private receiver. Success footers use source
blue/cyan unless native increased contrast requests system text color; failures
are red. Stream output stays plain until completion, matching the source callback.
[Styling verification](qa/submodule-progress-styling-2026-10-09.json) distinguishes
attributed-text/color-component checks from unverified displayed appearance.

## Verification and remaining work

[Verification record](qa/submodule-sync-2026-10-09.json) separates real-Git Core
coverage, hidden native ownership checks and unsigned build/bundle evidence.
Fixtures allow local file transport only at their construction invocations and
then synchronize dummy SSH URLs without connecting to a server. The original
icon's blob/SHA-256 and AppKit decode are checked, and Submodule Add's shared Add
artwork is explicitly allowed by the icon regression test.

Still partial: displayed progress/window/sheet/keyboard/VoiceOver/light-dark
acceptance, complete source progress geometry/taskbar and broader controls, action-log physical acceptance, signed parent/child Git-dir
scope inheritance and Finder activation/dispatch, all path/config/race variants,
and broader SyncDlg. No new screenshot or App Store readiness is claimed. Other
submodule workflows retain their own partial mappings.

The shared visible output state now enforces the cumulative byte limit across
streamed batches, rather than allowing a last full batch past the cap. A cut
does not leave an incomplete valid UTF-8 scalar. The source truncation marker
and final completion line remain visible; raw Git recovery output is unchanged.
