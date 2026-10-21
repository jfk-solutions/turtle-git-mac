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
alphabetically. Names keep their original Unicode spelling. With case-sensitive grouping,
composed and decomposed spellings remain distinct even when they look the same.
Disabling case sensitivity folds case without normalizing those spellings.
The author slider limits individual series; remaining authors
are grouped as **Others**. If only one author would remain, that author keeps their
name. These settings and the last graph page are remembered when the window closes.

The five original graph icons select pie, stacked line, line, stacked bar and bar.
Hover bars, pie wedges or line points in smaller graphs for the author, value,
unit and percentage. Hovering the average region shows its value. Stacked-area
polygons do not provide individual value tooltips. Zero-value intervals are omitted
from bar graphs; ordinary bars share widths across the populated intervals.
Line styles are unavailable for the author comparison graphs. Stacked bar for
author comparisons shows one colored stack of authors. Ordinary bar and line
graphs include the source average guide. Integer tick labels reflect commit/line
counts. Graph titles and axis units follow the chosen metric and time interval;
the original TortoiseGit palette is shared by all graph styles in light and dark
appearance. Very high author counts retain the source palette's repeated colors.

With a graph selected, choose **File → Save Graph As…**. The save sheet has
**Pictures** and **All Files** filters. The filename selects the encoder: `.pdf`,
`.png`, `.jpg`/`.jpeg`, `.bmp` or `.gif`. Changing the filter preserves your typed
suffix. Pictures adds `.pdf` to an extensionless name; All Files adds `.jpg`.
An unknown suffix also gets `.jpg` appended. The panel confirms the final filename
before overwriting or granting access to it.

PDF is the native replacement for TortoiseGit's Windows metafile export. WMF/EMF
output is unavailable; use PDF for vector output. Pie exports
use the current graph area size, just like the other styles. Date pies share one
horizontal row and shrink to fit; zero-valued intervals leave no empty slot.
All graph styles have a boxed legend on the right. Crowded legends keep the last
group and show dots for omitted middle rows; narrow graphs hide the legend. The text summary cannot be exported
through this command.

This dialog is still being compared with TortoiseGit. Exact displayed label geometry, outlines/shading,
dense history layouts, displayed save-sheet behavior and signed sandbox checks
remain pending; see [the parity record](LOG-STATISTICS-PARITY.md).


Cancel stops gathering file changes and keeps the previous complete summary.
Use Calculate to retry. Closing during calculation first cancels the read, then
closes after Git finishes. The summary page hides graph style and author-limit
controls; those appear when you select a graph. Save Graph As opens an owned
native save sheet; cancelling leaves the graph available for another export.


The author slider's tooltip reports the selected activity cutoff and commit share.
When only one author would be omitted, that author keeps a named entry, matching
TortoiseGit. The graph style buttons identify the selected style.

Save Graph As captures the graph and its current size and appearance when you open
the file panel. Once accepted, the filename, encoder and graph stay fixed while
writing. Controls wait for that write to finish. Closing requests cancellation
and waits for the worker and owned sheets to finish. A forced close retires the
window immediately and releases its ownership after that work drains. Cancellation
before atomic publication preserves an existing destination; a file already
published remains a successful save. Errors stay attached to the Statistics window.

Calculate captures the originating window's Git backend preferences for the whole
read. Cancelling discards partial results and keeps the last complete summary.
After it finishes, Calculate can retry. Quit confirmation invalidates pending form
and export actions, including callbacks retained from an older presentation.


Author identity is retained through totals, activity ranking, interval graphs,
slider selection, legends and graph export. A real author whose name matches the
**Others** caption remains separate from that combined group. Identical-looking
labels can therefore have separate entries and colors; the original names remain
in tooltips and exported text.
