# Local command progress family

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`, ProgressDlg's
UpdateCmdOutput/UpdateProgressFromLine, RichEdit copy/style handlers, and the
Reset, Switch and Stash AppUtils progress routes.

Reset, Switch/Checkout, Stash Save and Stash Apply/Pop now consume command output
while Git is running. A shared producer/consumer drains the existing thread-safe
CLI parser, retains carriage-return replacement and split UTF-8 behavior, and
flushes pending bytes before result handling. Current work and percentages appear
when Git reports them; commands without a percentage retain indeterminate progress.
Silent commands use their completed result as a display fallback.

Display output follows GitOutputLimitinKiB and uses the same ANSI cleanup,
truncation marker and UTF-8 boundary behavior as the existing submodule progress
family. This bounds the visible log; the original command result remains available
to repository/status callbacks. Original stdout/stderr result data is not replaced
by the normalized display text, and the result is not appended a second time after
streaming. The existing result storage is not claimed to be memory-bounded.

All four views use the native read-only progress output renderer with source
error/warning colors, links, text selection, Copy and Copy all information menus,
and original copy artwork. StyleGitOutput and the supplied icon/font preferences
remain effective. Apply/Pop now has an expandable native progress window with the
output above its existing running/cancel row; its completion/questions, remembered
choices and close-before-Working-Tree handoff remain unchanged.

Operation accounting spans command execution and post-result inspection, including
failure, normal cancellation and forced window retirement. Removing a window
cancels its owned process and prevents late output/result/post-action callbacks;
Quit stays blocked until the child and consumer settle. Reset's progress task now
retains the original access lease independently of its removed options owner.
Existing security-scope preflight and Git cancellation retain completed changes
rather than claiming rollback.

Stash Save now shares the source ConfirmKillProcess question with Reset and Switch.
Responses are once-only and late responses cannot kill a completed command. A
successful command waits for an outstanding kill question before applying its
captured auto-close policy. Forced close ends owned confirmation sheets. Reset and
Switch retry tokens, conditional post-actions, Apply/Pop question modes and each
operation's existing auto-close decisions remain intact.

The existing Reset/Switch/Stash Save/auto-close receivers now join the common
app-object compilation cache. Their old script entry points delegate to the owned
bounded runner. CI executes them once in its existing grouped native step, instead
of compiling/running each full app a second time. Tests and assertions are retained.

The Debug build and 27 affected Core tests passed. Ten grouped native cases
(five families with system and bundled Git) passed; all owned receivers were
reaped. Initial driver/fixture failures and the focused repairs are retained in
[the QA record](qa/local-command-progress-2026-10-14.json). Core tests were not
repeated for fixture-only repairs. Complete physical
scrolling/Return/Escape/copy/VoiceOver, pixel/color/theme acceptance, other remaining
progress consumers, command-line close overrides, signed scopes/Finder/App Store
execution and the whole application port remain open.

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
