# Synchronization, Add and Resolve progress family

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
This batch addresses the main Synchronization command surface and the related
Add/Resolve notification-list progress, including their post-action lifetimes.
It does not certify the whole dialogs or application.

## Two upstream progress forms

`SyncDlg.cpp::ShowProgressCtrl/ShowInputCtrl` replaces branch/remote inputs with
animation, phase and progress while a main command runs. `OnProgressUpdateUI`
records actual command completion, percentage 100, elapsed milliseconds, finish
date and the colored success/exit-code footer before post-actions. Successful
command completion clears taskbar progress; failed command completion retains its
error state. Follow-up metadata is not part of the subprocess elapsed time.

`GitProgressList.cpp` and `ProgressCommands/AddProgressCommand.cpp` /
`ResolveProgressCommand.cpp` use a different Action/Path notification list.
The list adds a Finished row with Success/Failed, elapsed time and finish date;
it hides its running bar on completion. These rows are not a plain CLI transcript.
The source list saves its action log. Main Sync does not call that persistent
list-log writer, so this batch does not invent main Sync action-log persistence.
Both source completion forms always include timing, even when other command
presentation timing preferences are disabled.

## Native workflow and ownership

The main Sync command keeps byte-oriented streaming, phase and percentage, source
running-header replacement and completion styling. A typed Core command receipt
captures success/cancellation/exit status, finish date and monotonic elapsed time
immediately after the requested Git invocation settles. Validation does not
publish a completion receipt; later ref/rebase/conflict queries cannot rewrite a
successful command into a failed Git footer. Independent workflow ownership
continues through those queries and actual producer release. Main command
completion and the existing complete-workflow state remain distinct.

Add and Resolve use native multi-select Action/Path tables with the original
background artwork. File rows offer Show Log, Open, Open With and Finder reveal
where applicable; double-click opens a file or reveals a directory. Context Copy
uses the source Path text, while keyboard Copy includes Action and Path. Menus
capture their producing attempt and row identities. A new attempt, busy/retired
owner or deferred Quit cannot dispatch a stale row action. File/application scopes
and owned Open With sheets remain live through their actual completion.

Add captures progress settings, automatic-close and kill-confirmation policy.
Both Add/Resolve retain source notification results and complete action-log text.
Commit post-actions capture repository, grant, preferences and appearance, then
wait for the old frame, sheets and workers to close before opening Commit once.
They retain the current workspace repository. Late or duplicate callbacks,
retirement and deferred Quit suppress a new child. Rebase-owned Add uses the
same preferences and release contract without a nested Commit action.

The application Quit gate counts command workers and controller/sheet release
even after a forced close removes a visible window. These counts describe actual
ownership; cancellation does not falsely imply that a noncooperative worker has
already ended.

## Validation and remaining work

Four focused Core methods, the Debug app and ten distinct native case/engine
pairs passed. The [dated evidence](qa/sync-add-resolve-progress-2026-10-19.json)
retains the initial target-membership build error, actual timing-consumer repair,
and retained-fixture readiness/index-cache failures. Only failed or affected
checks were repeated; passing new cases were not rerun for fixture-only changes.
Every owned receiver was reaped. Optional hidden content captures omitted SwiftUI
compositing layers and were rejected for site/visual-parity publication.

Add's existing atomic index transaction publishes Added rows after acceptance;
it does not publish speculative per-file success while that transaction is still
pending. This native adaptation remains distinct from upstream's incremental
status engine notifications.

Complete original layout/input/VoiceOver acceptance, physical Dock behavior,
installed signed repository/application grants, all source status engines and
current complete hosted/App Store acceptance remain separate requirements.
