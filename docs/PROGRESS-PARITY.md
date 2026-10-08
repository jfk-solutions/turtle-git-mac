# Git command progress parity

Reference: pinned ProgressDlg.cpp/.h, SetDialogs2.cpp and TortoiseProcENG.rc.

## Automatic close policy

Settings → Dialogs now exposes Autoclose Git progress dialog with the original
three choices: Close manually (0), Auto-close if no further options are available
(1), and Auto-close if no errors (2). The preference is AutoCloseGitProgress.
Absent/invalid values use manual close; reading an invalid value does not rewrite
it. Settings save immediately on macOS rather than waiting for Windows Apply.

Native Commit, Fetch, merge Pull, Merge, Abort Merge, Stash Save and express Switch
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

Streaming command output, complete progress-window controls/layout, physical
Close/Escape/titlebar/nested-sheet/default/accessibility/theme behavior,
remaining progress replacements (including Push and other command dialogs),
command-line closeonend override and libgit2 progress variants remain pending.
Native retries that reuse a sheet retain its captured policy; upstream callbacks
may create a new progress instance. Rebase split cancellation and signed sandbox/
Finder/App Store acceptance remain pending. Headless checks and unsigned bundle
audits do not establish full progress, application or distribution parity.
Existing screenshots predate this setting and policy behavior.
