# Git command progress parity

Reference: pinned ProgressDlg.cpp/.h, SetDialogs2.cpp and TortoiseProcENG.rc.

## Automatic close policy

Settings → Dialogs now exposes Autoclose Git progress dialog with the original
three choices: Close manually (0), Auto-close if no further options are available
(1), and Auto-close if no errors (2). The preference is AutoCloseGitProgress.
Absent/invalid values use manual close; reading an invalid value does not rewrite
it. Settings save immediately on macOS rather than waiting for Windows Apply.

Native Clone, Commit, Push, Fetch, merge Pull, Merge, Reset, Clean dry-run/permanent deletion, Format Patch, Export, Abort Merge, Stash Save and Switch/Checkout (regular options and express)
progress now apply this policy after success and after building their post-actions.
Mode 1 retains a result that offers actions. Mode 2 closes successful results even
when they offer actions, without selecting any of them. Failures remain open in
all modes. An instance captures its preference on construction; Abort Merge reads
it when starting its progress phase. Existing explicit success-close paths, such
as footer ReCommit/Commit & Push and Fetch's fast-forward Merge, retain precedence.
Existing accepted-cancellation behavior also remains independent of this setting.

[Native QA](qa/progress-auto-close-2026-10-08.json) records real repository checks
across the three policies: Merge/tag, Reset/Merge Abort and no-change Stash with no
post-actions, results offering actions, ordinary Commit acknowledgement and
hook rejection, retained transport/merge/switch failures, and preference
snapshot/reopening. A hidden settings host uses a private preference domain; it
does not prove displayed picker interaction.

## Invocation-owned completion policy — October 28, 2026

The source constructors `CProgressDlg::CProgressDlg` (`ProgressDlg.cpp:58–73`)
and `CGitProgressDlg::CGitProgressDlg` (`GitProgressDlg.cpp:32–47`) first read
`AutoCloseGitProgress`, then override it when the current command contains
`/closeonend`. Values 1 and 2 select the existing no-options and no-errors
policies; every other numeric value selects manual close. The source automation
manual documents 0, 1 and 2. Its obsolete 3/4 descriptions are commented out and
are not additional active modes.

Native command parsing now carries an optional typed `progressAutoClose` value
with the invocation. An absent option remains absent, so it can inherit the
owner's persistent preference. Explicit manual remains an actual override,
including `/closeonend`, `/closeonend:` and `--closeonend=0`. Both legacy
`/closeonend:2` and native `--closeonend=2` / `--closeonend 2` are accepted. The
option is global command metadata: a command without a progress result can
accept it without creating a progress window.

`CCmdLineParser::GetLongVal` (`CmdLineParser.cpp:202–209`) uses `_wtol`, rather
than strict integer/enum validation. The native carrier retains its observable
policy mapping: leading C whitespace, an optional sign and a decimal numeric
prefix are consumed. Thus `+02suffix` selects no-errors, `1.5` selects
no-options, and empty, nonnumeric, negative, other-mode and overflowing values
select manual. Huge decimal values cannot wrap into an active policy on a
64-bit host. Microsoft's [CRT conversion reference](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/atol-atol-l-wtol-wtol-l)
documents decimal-prefix conversion, zero when no conversion starts and bounded
out-of-range returns. Existing duplicate-option, NUL and unrelated unsupported-option
refusals remain unchanged. Path-file resolution and per-root transport splitting
preserve the captured override; neither operation grants repository access.

The native handoff and progress consumers must keep that override with their
request and captured child/Retry lifetime. It is not a write to the stored
`AutoCloseGitProgress` setting and cannot retarget another open owner's policy.
The existing success/post-action, failure, accepted cancellation and explicit
continuation rules still decide whether a result can close. Core parsing alone
does not establish those native handoffs. The parent records their grouped
implementation and validation in the command-progress checkpoint; authored Core
fixtures and this source comparison do not establish a full hosted or signed
application pass.

### Native ownership and source-local precedence

A typed immutable command scope carries this policy independently of
`UserDefaults`. Options/progress owners retain it; deferred Start, Retry and
post-close callbacks restore it before creating another owner. Controller caches
separate explicit invocations, retain ordinary window reuse, broadcast repository
refreshes to all owners, and keep repository mutation guards across scopes.

The connected consumers include transport, Commit, patch creation/mail/export,
local history/replay/Stash, Add/Resolve/Revert/Clean/Reset/Switch/Bisect,
Worktrees/Submodules/Daemon, SVN progress and LFS lock/unlock. LFS dismisses only
its completed result sheet; its Locks list remains available. SVN Fetch retains
Compare/Log under no-options when fetched revisions changed.

Constructor overrides do not supersede later source assignments.
`GitStatusListCtrl.cpp:2589–2591` explicitly sets nested Revert to no-options;
`SVNRebaseCommand.cpp:99–100,137–138` forces intermediate progress to no-errors.
Trash cleanup uses `CSysProgressDlg` (`CleanupCommand.cpp:233+`) and preserves its
automatic end. Silent Resolve (`ResolveCommand.cpp:40+`) runs without a Git
progress dialog. These branches remain distinct from generic policy consumers.

The grouped command-progress receiver covers the captured command/window
ownership and delayed handoffs; it does not establish physical native interaction,
a signed installed Finder extension or full upstream UI parity. The [October 28 checkpoint](qa/command-progress-2026-10-28.json) records 57
existing parser tests plus four new policy tests, an unsigned Debug build and six
native receiver passes across system/bundled Git. It also records the initial
fixture/compiler failures and their focused repairs. The receiver exercises
representative real owners with injected private workers; it does not test every
changed dialog or replace signed/physical acceptance.

## Remaining parity

Streaming adoption outside Clone, Push, Fetch, merge-based Pull and Merge, complete progress-window controls/layout, physical
Close/Escape/titlebar/nested-sheet/default/accessibility/theme behavior,
remaining progress replacements for other command dialogs.
The invocation-owned closeonend continuation above supersedes the earlier parser omission;
remaining native consumer and libgit2 progress acceptance retain their recorded scope.
Native retries that reuse a sheet retain its captured policy; upstream callbacks
may create a new progress instance. Rebase split cancellation and signed sandbox/
Finder/App Store acceptance remain pending. Headless checks and unsigned bundle
audits do not establish full progress, application or distribution parity.
Existing screenshots predate this setting and policy behavior.

[Push progress QA](qa/push-progress-2026-10-08.json) records its separate result and close policies.

[Reset progress QA](qa/reset-progress-2026-10-08.json) records mode/action-dependent close policies and Retry.

[Clean progress QA](qa/clean-progress-policy-2026-10-08.json) records ordered actions, branch-specific cancellation and Trash completion.

[Format Patch progress QA](qa/format-patch-progress-2026-10-08.json) records submission-time policy capture and once-only mail acknowledgement.

[Export progress QA](qa/export-progress-2026-10-08.json) records retained Explore results and atomic cancellation.

Switch/Checkout now owns captured full-option progress with source-ordered recovery,
ConfirmKillProcess and deferred completion while confirmation is pending. See
[Switch parity](SWITCH-PARITY.md) and [native QA](qa/switch-progress-2026-10-08.json).

Clone now owns a captured result with ordered Log/Explorer actions, captured Retry
and ConfirmKillProcess. See [Clone parity](CLONE-PARITY.md) and
[native QA](qa/clone-progress-2026-10-08.json).

Clone now streams byte-oriented CLI output through a port of GitCliOutputParser,
with percentage/phase presentation, output limits and automatic end scrolling.
See [live-output QA](qa/clone-stream-2026-10-08.json); physical and signed acceptance
and streaming in other dialogs remain pending.


Push now adopts the shared byte-oriented CLI parser for every remote, branch/tag
phase and optional first-parent count. Its live percentage/phase and captured
output limit preserve full raw result classification after display truncation.
See [Push parity](PUSH-PARITY.md#live-cli-output) and
[live-output QA](qa/push-stream-2026-10-08.json); physical/signed acceptance and
streaming adoption in other dialogs remain pending.


Fetch, its selected-branch Rebase route and merge-based Pull now stream the shared
CLI parser, with captured display limits and complete raw diagnostics. Retry
resets the parser and visible phase. The later Merge adoption section supersedes the original completion-time
output behavior for the ff-only Merge chosen after Fetch. See [Fetch/Pull live-output QA](qa/fetch-pull-stream-2026-10-08.json)
and the individual parity documents; physical/signed acceptance remains pending.


Primary Merge and Fetch's ff-only Merge now adopt the shared source CLI parser
and captured-limit presentation. Merge honors ConfirmKillProcess; Merge result
close, Fetch explicit/automatic close and Rebase handoff defer while a question
is pending. Late answers preserve natural success. See
[Merge live-output QA](qa/merge-stream-2026-10-08.json). Branch-deletion progress
and complete controls/physical/signed acceptance remain pending.

## Persistent Action log

Twelve native progress window implementations now preserve displayed results on
close and before replacing an attempt, using the source retention/cancellation
rules. Settings → Saved Data provides the source Action log group. The
[Action log guide](ACTION-LOG.md) lists coverage and explicit remaining gaps;
headless QA is recorded in [the checkpoint](qa/action-log-2026-10-08.json).

## Abort Merge output adoption, October 11

Abort Merge adopts the shared native output control already used by submodule
progress. The actual controller receiver verifies its icon-bearing Copy/Copy All
menu dispatch, private Unicode clipboard, preserved selection/viewport, completed
fatal prefix and URL attributes and parsed live current-work/percentage values
with system and packaged Git. The standalone shared-control regression also
passes. Current-work and progress appear above the output; the finished bar is
full. New unedited light/dark captures show a real index-lock failure.

This does not complete `IDD_GITPROGRESS`: animation, completion timing/footer,
Dock progress, full options and physical/signed acceptance remain pending for
Abort Merge. The hidden inactive native bar renders gray even though its tint is
set for failure; source-equivalent red error-bar appearance is not proven.
See [Merge parity](MERGE-PARITY.md#abort-merge-progress-output-october-11).

## Abort Merge completion adoption, October 11

The source-style completion helper now also serves Abort Merge: Success or the
Git exit-code status, a single colored footer, optional milliseconds/finish date,
and terminal100. Cancellation uses User cancelled; forced invalidation publishes
no footer. The reset finish timestamp is captured before later metadata reads.
This advances the earlier footer gap; animation, Dock progress and the other
remaining requirements still apply. See the latest Merge completion follow-up.

The connected [local command progress family](LOCAL-COMMAND-PROGRESS-PARITY.md)
adds live Reset/Switch/Stash output, shared native log styling/copy controls,
bounded presentation, independent ownership and once-only kill questions.


The [Worktree progress family](WORKTREE-PARITY.md#connected-worktree-progress-family--october-14-2026)
adds live creation/management output, native copy icons, batch output limits,
kill confirmation, captured auto-close decisions and Action log preservation.


The [Bisect connected family](BISECT-PARITY.md#connected-bisect-startprogressrecovery-family--october-14-2026)
adds streamed Stash/Start/classification/Reset, native copy output, once-only kill
confirmation, captured auto-close, Action log and interrupted-session recovery.

## Captured transport/progress presentation — October 15, 2026

The [connected presentation family](TRANSPORT-PRESENTATION.md) now consumes
FetchVerbose and DownloadAnimation without extra dialog controls. It shares the
source byte-limit interpretation across Clone, Push and common progress. The
pinned ProgressDlgLinesLimit entry remains dormant, with no invented consumer.
Full workflow, physical and signed acceptance remain partial.

[Grouped evidence](qa/transport-presentation-2026-10-15.json) records 33 affected
Core cases, the Debug build and four native groups on both Git engines, including
the argument-recorder setup repair. Complete hosted/physical/signed parity is
not established.


The connected [native Dock progress family](DOCK-PROGRESS.md) now adapts taskbar
normal/indeterminate/waiting/error/completion to the application Dock, with
concurrent operation and retained-window ownership. Physical/signed and full
consumer acceptance remain open. Older Dock-pending entries are historical.


The [Synchronization child progress family](SYNCHRONIZATION-PARITY.md#connected-child-progress-family--october-17-2026)
now adopts parsed live progress, completion details, native Copy menus, Action log
and Dock state across separate Checkout/Merge/tag command children. Forced closure
retains the actual worker lease and parent continuation until drain; source compact
tag waits retain their parent error path. The Debug build and grouped native
progress/tag workflows pass on system and bundled Git; four actual captures were
reviewed. Full source/physical/signed acceptance remains open.


The [Sync failed fast-forward recovery continuation](SYNCHRONIZATION-PARITY.md#failed-fast-forward-recovery-and-commit-handoff--october-17-2026)
adds the source Resolve-to-Commit action after verified index conflicts. Its fresh
inspection preserves the original failure and retains worker/lease/Quit ownership;
late cancellation replies cannot target a replacement stage. Grouped system/bundled
Git native checks and actual light/dark handoff captures pass. Full generic progress
and physical/signed acceptance remain open.


## Connected command diagnostics — October 17, 2026

[Command identity and failure delivery](PROGRESS-DIAGNOSTICS.md) connects local
progress and transport consumers, preserves raw recovery results and keeps
completion diagnostics within the captured output limit. Full progress-dialog
parity and physical/signed acceptance remain open.


The [connected Daemon progress family](DAEMON-PARITY.md#connected-native-progress-family--october-17-2026)
adopts shared native Copy/styling/completion, captured auto-close, once-only kill
questions, Action log and independently owned process/Dock/permission lifetime.
Physical and signed acceptance remain separate.

Format Patch now carries actual command receipts and captured output preferences
through its progress review, with owned question/progress retirement before the
shared Send Mail handoff. [Source comparison](FORMAT-PATCH-PARITY.md#progress-review-and-send-mail-continuation--october-19-2026)
and [batch evidence](qa/format-patch-workflow-2026-10-19.json) retain the exact
implementation and validation scope; installed/live transport acceptance remains
separate.
