# Transport and command progress preferences

The source is TortoiseGit commit
`7338078f8ddd924b8cddee35f512f2286072136d`, AppUtils::DoFetch,
SyncDlg::Fetch/ShowProgressCtrl, ProgressDlg::OnProgressUpdateUI and the remote
progress animation helper. Native equivalents use the existing Advanced keys;
no extra checkboxes are added to Fetch/Pull dialogs.

**FetchVerbose** defaults to true. Standalone Fetch captures it when submitted;
Fetch-before-Rebase uses that same captured options value. Synchronization's
Fetch, Fetch and Rebase and Fetch all branches honor it in their command plan.
Disabling it omits verbose output but retains --progress. Merge-based Pull and
Push keep their explicit verbose flags, matching their separate source paths.
Normal transport validation, authentication, cancellation, resulting refs and
post-actions remain independent of this setting. Changing Advanced preferences
while a submitted request is waiting does not rewrite that request.

**DownloadAnimation** defaults to true. Native command-progress owners capture
it alongside their presentation state. Enabled owners use a native spinning
indicator; disabled owners show the original static refresh artwork. The native
adapter replaces the Windows AVI rather than reproducing its animation. Numeric
progress bars, running text, Git output, cancellation and result actions remain.
Synchronization uses a static empty progress bar while progress is unknown and
animation is disabled. Existing owners keep their captured policy; new owners
read the current preference.

The connected consumers include Clone, Push, Fetch, Pull, Merge/Abort Merge,
Commit, Format Patch, Export, submodule Add/Update/Sync, Synchronization and its
owned progress, SVN, daemon, Reset, Switch, Stash Save, Resolve/conflict review,
Revert, Worktree Create/List, Bisect and history Revert/Combine. Metadata-only
load spinners and unrelated workflows are not claimed as command progress.

Clone, Push and the shared visible-output state now use the same captured
**GitOutputLimitinKiB** policy. Its default is 2048 KiB, bounded to 16–102400 KiB.
The value is read as the source's DWORD cast to signed 32-bit int; high-bit values
therefore use the lower bound. Reading does not rewrite the stored preference.
This bounds visible output only. Existing UTF-8-safe truncation, carriage-return
replacement and complete raw command diagnostics remain separate.

**ProgressDlgLinesLimit** remains in the source's 52-row Advanced catalogue, but
has no live runtime reader in the pinned tree. TurtleGit keeps that stored row
without inventing a second line-limit algorithm. The live source bound is the
byte-based GitOutputLimitinKiB setting.

Physical motion/keyboard/VoiceOver, every command's displayed result, live
network timing/authentication, signed scopes and App Store acceptance remain
unverified. Static activity artwork is a macOS adaptation, not AVI equivalence.

The [dated QA record](qa/transport-presentation-2026-10-15.json) records actual
scope, failures and repairs. The 33 affected Core cases passed cumulatively; the
Debug build and new policy plus retained Clone, Push and Fetch/Pull native groups
passed on system and prepared bundled Git. All receivers were reaped. Local
passes do not establish complete hosted or distribution acceptance.


## Ordered command transport workflows

Repeated command-line Fetch/Pull/Push repository selections use one connected
workflow per original root entry. The batch waits through options, operation and
result windows and source-modal follow-up actions. A Retry or Reset does not let
the next repository overtake the first. Separate-process source commands such as
Log remain independent native windows. Existing source icons, editable presets,
progress controls and result actions are retained.

Closing an initiating workspace cancels the owned chain and remaining queue;
closing one ordinary repository workflow continues to the next root. Authority
and Quit accounting outlive cancelled workers and detached sheets. See the
[command-line contract](COMMAND-LINE.md) and
[recorded batch evidence](qa/command-transport-batch-family-2026-10-20.json) for
actual acceptance scope and remaining installed/signed checks.
