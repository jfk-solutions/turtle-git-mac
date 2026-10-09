# Submodule Add parity

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
`SubmoduleAddDlg.cpp/.h`, `IDD_SUBMODULE_ADD`, `SubmoduleCommand.cpp/.h` Add
branch and `MenuInfo.cpp` SubmoduleAdd clause. The full application port remains
incomplete; this dialog's source mapping is partial.

The native window follows the source groups: **Submodule of Project**, Repository
and Path history/browse rows, Branch with an initially hidden field, Force,
Auto-load SSH key/history/browse, then OK/Cancel/Help. The key control adapts
PuTTY/Pageant to OpenSSH and is gated by helper availability. Source's initial
key history is shared with Clone. Blank key selection performs ordinary Git Add.
Repository end-edit derives a final component, strips `.git` and prefixes the
invoking directory. Path Browse appends that component to the selected folder.
Read-only key grants use the private identity store. Native source/path/key
pickers are owned sheets; late selections after closure are refused.

Add is available in the application's action menu and Finder's one-folder-in-Git
clause with the original Add icon. Bare repository metadata denies this action.
Finder selection is an input request, not a permission grant; existing app routing
acquires the containing repository's lease before opening its native window.

Core uses literal arguments after `--`, accepts relative or contained absolute
paths, rejects traversal, `.git`, outside-tree paths and unsafe final entries,
and rechecks destination containment after suspended key loading. Force replaces
the branch arguments, matching pinned SubmoduleCommand; even with Force, an
explicit empty branch remains invalid. Git controls occupied paths, existing
module reuse and ignore/force errors. Failures retain all existing/partial files.

An explicit selected key loads into an operation-owned private agent before
`submodule add`, without reading a nonexistent child remote. Success saves
`remote.origin.turtlegitsshkeyfile` in the child before publishing completion.
Windows PuTTY config and `core.sshCommand` are not set. Config write failure
reports failure and retains the added module, matching source's failed key-save
result. Native URL/path/key histories are saved at accepted submission; Cancel
before submission does not save drafts. A remembered key grant is independent of
draft histories and persists after dialog cancellation, as in Manage Remotes.

Accepted OK validates/saves histories, creates a progress model with captured
options and repository/source/key grants, and closes the options window. Root
owns a separate progress controller for each submission; closing options releases
its draft grants without cancelling the captured operation. The progress window
owns SSH passphrase presentation and uses the shared ProgressDlg geometry.
The native operation captures options/grants, prevents a second submission,
uses bounded byte/CR/UTF-8 progress parsing and a fresh coordinator on Retry.
A Git failure retains the bounded stream and reports its exit status instead of
repeating the full captured command output. The shared native progress output
now exposes parsed current work/percentage, source Copy/separator/Copy All menu
with original icons, selectable text, completed URL/email links and source
warning/error prefix colors in light/dark appearances. Completion reports Success,
User cancelled, Git exit code or native Operation failed, reaches 100 percent,
and appends source-style elapsed milliseconds/local timestamp unless
ShowGitexeTimings is disabled. Retry clears the previous terminal range and
progress before starting; forced-close fencing suppresses the completion footer
as well as output. The shared UTF-8 display cap remains in force.
Close is the default button and is disabled while running or answering a
question. Abort/Escape and closing a running window use the captured operation's
cancellation token and the current ConfirmKillProcess preference; Yes accepts,
No leaves the operation running, duplicate answers are ignored. Successful
completion waits for an outstanding question before applying captured
AutoCloseGitProgress policy. Add has no successful post-actions; failures stay
open with a native Retry adaptation. Completed attempts write the shared action
log, and Retry starts a new attempt. Cancellation stops its owned token; forced
closure cancels and rejects late output,
errors and completion callbacks. Quit is refused during operation/picker/sheet
ownership. A dirty-document Quit question freezes the idle Add window as well.
Signed mutations require repository and local-source grants.

## Verification and remaining work

[Verification record](qa/submodule-add-2026-10-09.json) records the current Core,
hidden native receiver, builds, inventory and bundle checks. Fixtures generate
private keys and use invocation-only local file permissions/URL rewrites. They
verify local Git effects and the private-agent channel, not a real SSH server.
No main app is launched and no user keys or login agent are inspected.

Still partial: clipboard URL defaults, physical picker/history/branch/end-edit
and focus/keyboard/VoiceOver/light/dark acceptance, complete source progress
animation/Dock/sound and physical question/keyboard behavior, real SSH/reuse/ignored/path
edge cases, signed source/key/helper scopes, Finder dispatch acceptance, real
screenshots, and adversarial filesystem/config races. Native Add now uses
a separate progress window; this does not prove displayed parity. Bundled
OpenSSH agent/add and App Store SSH authentication are not ready. Existing Update
and Sync workflows retain their own partial source and verification records.


The progress styling continuation is recorded in
[the Add progress verification record](qa/submodule-add-progress-styling-2026-10-09.json).
Hidden native integration checks exercise successful Add with a private encrypted
fixture key, bounded Git failure, retry after failure with timings disabled,
key-preparation cancellation and retry followed by forced closure. These checks
do not prove a displayed dialog matches the Windows layout. The following
separate-window continuation replaces the earlier embedded progress implementation.

[Separate-window verification](qa/submodule-add-progress-window-2026-10-09.json)
records captured options/grants and distinct hidden controllers, options closure,
progress Quit refusal, Yes/No/duplicate cancellation answers, retry/forced-close
fences, completion behind a pending question, private action-log deduplication
and captured no-options/no-errors automatic-close policy with real local
Git effects. No main app or physically displayed window is involved; Root routing
is inspected/compiled rather than instantiated in the receiver.
