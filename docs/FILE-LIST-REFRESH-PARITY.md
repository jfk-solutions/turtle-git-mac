# File-list refresh and native reading position

Reference: pinned `GitStatusListCtrl::StoreScrollPos/RestoreScrollPos`,
`RevertDlg::RevertThread` and `ChangedDlg::ChangedStatusThread`/filter handlers.
Source stores the viewport, first selected row and selection mark before list
replacement; RememberFileListPosition defaults on. File checks remain independent.

## Connected native behavior

Commit, Working Tree and Revert now attach their actual native file table to one
owned refresh coordinator. A successful read waits for the matching row identities,
column layout and native layout before restoring the viewport and releasing input.
Commit's full and incremental staging reloads share this lifecycle. Working Tree's
filters and Commit's Unversioned/Whole Project changes also preserve the position.
New invocation scopes reset it. The source preference is captured for that refresh;
switching it off clears highlighted rows/focus and returns to the top without
changing Commit/Revert checks or staged contents.

Native multi-selection follows surviving file identities. When every selected
file disappears, the old row index provides a nearby file fallback; group headers
cannot become that fallback. The focus/selection mark is restored separately.
A newer pointer, scrollbar, wheel or file-table key gesture invalidates a pending
restore so an old callback cannot pull the reader away. Editing another field does
not claim file-list reading intent. Existing header fitting, columns, source
watermark and file-menu behavior remain connected.

Ctrl-A and Command-A select only file rows and preserve checks. Working Tree F5
and Escape require the active owning window, its own event and no modifiers or
attached sheet. Escape cancels an owned read, or closes an idle dialog. Read-only
refresh cancellation is quiet; mutation cancellation retains its existing result
message. Editable fields keep native selection and shortcuts.

Every replacement/cancellation/retirement settles each native wait once. The
model's read token and access lease survive native row publication. Full Commit
reloads now have independent application Quit accounting even after forced window
retirement; an injected read ignoring cancellation cannot publish late rows.
Working Tree collects LFS lock metadata before publishing the complete new file
snapshot, so a failed final read retains the previous table and lock information.

## Validation and limits

[Grouped native evidence](qa/file-list-refresh-2026-10-16.json) records eight
passing case/engine combinations: the new refresh receiver and retained staging,
Working Tree and Revert planning receivers, each on system and packaged Git.
Checks cover actual native scrolling, selections, checkbox separation, filters,
the source preference, gestures and read ownership on private repositories and
preferences. No Core Git algorithms or persistence formats changed; its suite
was not repeated. One Debug build passed, with three exit-zero/no-output compiler
diagnostics recorded. All eleven owned receivers, including failed fixture runs,
were reaped and independently absent. The hidden selection and disabled-button
fixture repairs retained the behavioral assertions. Revert still emits its
previously recorded AppKit reentrant table-delegate warning.

This does not certify all physical gestures, IME/keyboard layouts, minimum-OS or
signed Finder/sandbox behavior. Commit's existing metadata/message/hook pipeline
still publishes individual model fields during reads; this batch adds native
settlement and lifetime, not a transaction across that whole pipeline. Full source
visual/menu and all-dialog acceptance remain open.

## Complete Commit read publication — October 17, 2026

Commit now collects its required full-refresh reads before publishing files,
branch/operation/amend base, metadata, changelists, index flags, three statistics
sets, initial author, provider, preferences and message seed. The owning token is
checked on both sides of each suspension and immediately before publication.
Requested invocation scope/whole-project state and automatic checks are accepted
with that display. Before publication, a failed or cancelled read keeps the
previous accepted fields, scope, checks, selection and LFS ownership. An initial
failed read does not consume preference/template initialization or open a preview.

Optional LFS lookup finishes before publication. Its failure accepts the new
files with empty/unknown ownership and a warning, rather than associating old
locks with new rows. The new snapshot's LFS availability selects this lookup,
including its first load. Retry clears its previous read error only if another
operation has not replaced the error in the meantime.

Initial templates, issue properties and history are prepared together. The start
hook runs after the required reads; its accepted result enters the same
publication. User message/issue edits made during seed/hook preparation win over
that captured result. Failed required reads cannot consume the initialization
flags; successful later refreshes do not repeat the start hook or initial preview.
Existing explicit hook failure/close and template-permission policies remain.
Completions and patch refresh start only after the new display is accepted.

The field publication contains no asynchronous suspension. Native row/viewport
settlement follows with the existing read lifetime and newer-user-intent guards.
Cancellation during that later settlement does not undo an already accepted
snapshot. This is a native publication boundary, not a Git repository transaction
against concurrent external writers. Physical gestures, full source visual/menu
parity and signed acceptance remain open. This supersedes the earlier limitation
about individual Commit metadata fields being published during required reads.

[Batch evidence](qa/commit-refresh-snapshot-2026-10-17.json) records twelve passing
native case/engine combinations on system and bundled Git: complete refresh,
incremental staging, author/date/amend controls, preferences/template access,
issue-provider commits and actual native reading-position restoration. The Debug
build passed with two exit-zero/no-output diagnostics. A new fixture's final-LF
expectation was repaired; application sources did not change after the checkpoint.
All thirteen owned receivers, including the failed fixture attempt, were reaped
and independently absent. Core algorithms were unchanged and not retested.
