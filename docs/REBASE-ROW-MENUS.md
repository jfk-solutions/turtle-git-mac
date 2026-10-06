# Rebase row menus

The Rebase and Cherry Pick row menus now reuse native Log commands and original
TortoiseGit icons. This remains a partial port of the upstream Log menu.

The source comparison uses `RebaseDlg.cpp` and `GitLogListBase.cpp` at upstream
commit `7338078f8ddd924b8cddee35f512f2286072136d`. Rebase excludes upstream
checkout, reset, revert, merge, recursive Rebase/Cherry Pick, combine and rollup
commands. Pick/Skip/Edit/Squash remain available only while editing the plan.

Available inspection commands include comparison with the working tree or parent,
two-revision comparison, unified diff, Show Log, repository browsing, Branch,
Tag, Push, Notes and Format Patch. A clipboard submenu provides details with or
without paths, hashes, authors, names, emails, subjects and full messages.
Every command and clipboard item uses an original menu icon.

Selection uses stable row occurrence IDs. Repeated Add entries retain their own
selection while comparisons and clipboard output use real commit hashes. Format
Patch follows Log's single/two-row selection rules and requires contiguous rows
for larger selections. Busy, stale selection and bare-repository guards apply.
Inspection remains available at a paused Edit; changing plan actions is disabled.

Notes reuse the native Log editor and refresh open Log views after saving.
Exact UTF-8 note text is written as a blob and reused by Git notes, preserving
blank lines, spaces, literal comment characters and empty notes even with Git
2.37, which lacks the newer `--no-stripspace` option.

## Verification and remaining work

The headless native receiver hosts the actual Rebase view and invokes its actual
menu dispatcher. It checks original icon resources, single/root/merge/two/repeated
selections, busy/stale/bare guards, real unified-diff data, clipboard contents,
notes saving without HEAD/index changes, and paused Edit inspection/Abort.
Dialog and viewer handoffs are injected; clipboard checks use a private pasteboard.

This does not establish displayed menu positioning, keyboard accessibility,
modal focus, signed sandbox execution or visual parity. Advanced upstream Log
commands and further post-operation controls remain pending. Completed rows in
custom sessions now remain visible and recover on reopening; see
[replay rows](REBASE-PROGRESS-ROWS.md). See the dated QA record for test versions and build results.

Successful Rebase now exposes upstream completion commands through a native
split control. [Completion actions](REBASE-COMPLETION-ACTIONS.md) records direct
and after-Fetch behavior, mail/export adaptation and remaining acceptance.
