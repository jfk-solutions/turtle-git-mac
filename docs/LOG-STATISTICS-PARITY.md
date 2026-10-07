# Log statistics port

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
The statistics calculation layer is implemented. The native Statistics window,
Log button, charts, graph export and option persistence remain unported.

## Source behavior

`LogDlg.cpp::OnBnClickedStatbutton` passes all currently shown revisions, omitting
the working-copy row. It does not independently walk another revision range.
`StatGraphDlg.cpp::GatherData` sorts that snapshot by the chosen date, groups by
author or committer name and optionally folds case. Defaults are case sensitive,
sort by commit count, author names and commit dates. Empty names become `(unknown)`.

Calculate loads complete commit file changes, regardless of a path filter used to
select the Log revisions. Merge revisions contribute commit counts but zero diff
measurements. New-file lines and deleted-file lines are kept separately from other
added/removed lines; binary statistics contribute file counts and zero line counts.
Authorship is the source's weighted commit/file-change measure, not a blame result:
from newest to oldest, weight is distance-from-end / 2, except distance zero uses 1;
the result is multiplied by file count (or 1 when no files were measured).

The source chooses days for elapsed days below 8, weeks below 15 elapsed weeks,
months below 80 weeks, quarters below 320 weeks, and years thereafter. It creates
occupied intervals rather than filling calendar gaps. Its displayed denominator
is last interval minus first interval, with a minimum of one. Integer averages and
this denominator are preserved, including their surprising results for sparse
history. Consecutive unit keys use the source month/day, week number, month,
quarter or year rules. The source's yearless month/quarter keys can collapse
consecutive sparse observations with the same unit in different years.

## Current implementation

`LogStatistics.swift` analyzes a supplied immutable Log snapshot, exposes commit
and file/line measurements per interval and author, rankings, activity min/max,
integer commit averages and normalized authorship percentages. `changesCalculated`
distinguishes initial lazy statistics from measured totals. An incomplete supplied
measurement cache is rejected instead of presenting missing revisions as zero.
The pure calculation rejects unreadable dates and supports owned cancellation.

`GitRepository.logStatisticsChanges` reads root/ordinary commit changes through the
existing literal-path diff reader, skips merge diffs and returns a complete cache
only after success. Revision hashes/parents must be actual hash-shaped identifiers;
working-copy pseudo rows are rejected. Progress and cancellation belong to the
caller. Failed or cancelled calculation does not publish a partial cache.

macOS Calendar supplies regional week/time-zone behavior rather than porting the
Windows-specific week calculation (which has a documented DST defect). Equal-date
rows use stable input order; upstream `std::sort` does not specify tie stability.
Case folding uses Foundation Unicode lowercasing; cross-platform locale casing
acceptance is still pending. These choices need verification with the native UI.

Core fixtures cover names/date/case/ranking options, unknown authors, authorship
weights, all unit boundaries, empty/malformed/cancelled input, incomplete caches,
actual root/modification/rename/deletion/binary/merge reads, no partial cache after
cancellation and exact tracked/index/config/HEAD preservation. No native app or
Statistics window is launched by these tests. See
[the calculation QA record](qa/log-statistics-2026-10-07.json).

## Remaining work

- Native `IDD_STATGRAPH` layout, all summary fields and Calculate/progress flow.
- Graph type selector: statistics, authorship, commits by author/date and line
  changes including/excluding new/deleted files.
- Bar, stacked bar, line, stacked line and pie controls; author count slider,
  Others grouping, labels and colorful light/dark presentation.
- Remembered checkbox/graph settings, Log snapshot handoff and owned-window close.
- Original graph button artwork, File/Save Graph As export and supported formats.
- Displayed layout, regional/DST/case acceptance, keyboard/VoiceOver and signed
  sandbox/App Store verification. The full application port remains incomplete.
