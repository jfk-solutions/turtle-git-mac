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

## Remaining parity

Streaming adoption outside Clone, Push, Fetch, merge-based Pull and Merge, complete progress-window controls/layout, physical
Close/Escape/titlebar/nested-sheet/default/accessibility/theme behavior,
remaining progress replacements for other command dialogs,
command-line closeonend override and libgit2 progress variants remain pending.
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
