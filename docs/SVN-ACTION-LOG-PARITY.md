# SVN progress Action log

Source: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`ProgressDlg.cpp:610–697`, `Commands/SVNFetchCommand.cpp:54–95`,
`Commands/SVNRebaseCommand.cpp:97–140`, `Commands/SVNIgnoreCommand.cpp:29–59`
and `AppUtils.cpp:3195–3202`.

The source CProgressDlg writes its displayed bounded output when dismissed by
OK, Cancel or a post-command action. Each instance has its own entry, including
SVN Rebase's intermediate Fetch and fast-forward reset. Stash Apply/Pop and the
pre-DCommit stash use CSysProgressDlg; interactive Rebase uses RebaseDlg. Those
presentations do not gain invented CProgressDlg Action log entries.

Native SVN Fetch, DCommit and both Ignore destinations now retain an independent
command record, preserving command identity, bounded UTF-8 output and its terminal
completion. Normal Close, automatic Close, Compare/Log and Retry request the
record exactly once. Retry records the previous attempt before replacing it.
Successful Rebase Fetch/reset stages record before the next workflow handoff;
DCommit with a created stash records before asking to restore that stash. Options
and failed runtime/upstream preflight do not create progress records.

A forced owner close requests logging immediately but does not write an
unfinished snapshot. Each command retains its own output parser until the actual
worker and pipes drain, then records remaining bytes and cancellation once.
Retired UI callbacks stay fenced. Closing an already completed window does not
retroactively cancel its successful record. Failed writes do not change the Git
result, its recovery actions or worker accounting. Existing private local storage,
retention limits, Show/Clear and disabled logging remain authoritative.

The native SVN controller combines several upstream dialogs in one window. The
log preserves individual source command stages while the window can show their
combined output; this is an explicit native presentation adaptation. Source
icons, existing result controls and their operation ownership are retained.

The [October 28 checkpoint](qa/svn-action-log-2026-10-28.json) records the unsigned
Debug build and four successful native engine/case pairs: the new Action log
receiver and the existing source-form receiver, each with system and bundled
Git. The initial cancellation-footer failure and source-based repair are retained.
The new receiver uses private repositories/preferences/pasteboard/storage and no
presented windows. It covers retained Fetch, duplicate post-action/close,
DCommit options and command identity, failed Ignore Retry, distinct Rebase stages,
forced retirement with a live owned process, UTF-8 output budgets, exact persisted
output and one appended cancellation suffix. All five attempted receiver processes
were reaped and independently confirmed absent. No Core implementation changed,
so its suite was not rerun. This is not a full hosted CI, physical SVN server,
signed sandbox or complete-dialog parity claim.
