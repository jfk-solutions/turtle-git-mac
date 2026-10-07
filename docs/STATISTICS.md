# Statistics

Open **Show Log**, then choose **Statistics** below the revision list. The window
uses the revisions currently shown in Log, excluding its working-copy row.
Loading more history or refreshing Log does not change an already open Statistics
window; close and reopen it to use the new list.

Choose a graph type at the top:

- **Statistics** shows totals and activity averages/minimums/maximums.
- **Commits by date** compares commit activity over time.
- **Commits by author** compares commit counts.
- **Percent of authorship** uses TortoiseGit's weighted commit/file-change
  measure. It is different from line ownership shown by Blame.
- **Changed lines including added/deleted files by date** includes those files'
  line totals.
- **Changed lines not including added/deleted files by date** counts changes to other
  files.

The initial summary avoids reading every commit's diff. Choose **Calculate** to
load file/line totals. Authorship and line graphs start this calculation when
selected. Progress appears at the bottom; **Cancel** stops the calculation. Closing
or pressing Escape while it is running requests cancellation first.

The four checkboxes control case-sensitive author grouping, author versus
committer names, commit versus author dates, and sorting by commit count versus
alphabetically. The author slider limits individual series; remaining authors
are grouped as **Others**. If only one author would remain, that author keeps their
name. These settings and the last graph page are remembered when the window closes.

The five original graph icons select pie, stacked line, line, stacked bar and bar.
Line styles are unavailable for the author comparison graphs. Stacked bar for
author comparisons shows one colored stack of authors. Ordinary bar and line
graphs include the source average guide. Integer tick labels reflect commit/line
counts. Graph titles and axis units follow the chosen metric and time interval;
colors follow light or dark appearance.

With a graph selected, choose **File → Save Graph As…**. Select PDF, PNG, JPEG,
BMP or GIF in the save sheet's **Format** field and choose a destination. PDF is
the native replacement for TortoiseGit's Windows metafile export. Pie exports
include all date groups and legends, even when scrolling is needed in the window.
Other exports use the current graph area size. The text summary cannot be exported
through this command.

This dialog is still being compared with TortoiseGit. Exact displayed label geometry, colors,
dense history layouts, displayed save-sheet behavior and signed sandbox checks
remain pending; see [the parity record](LOG-STATISTICS-PARITY.md).
