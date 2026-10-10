# Log commit ordering

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
The source audit found the four-control `IDD_LOGORDERING` dialog missing at
checkpoint `1769e2c738e9b078e6c377205f5124b23bd010db`. A native replacement is
now implemented with Core and native interaction checks. Full parity remains
under review.
See [the source audit](qa/log-ordering-audit-2026-10-10.json).

Clicking a Log revision-table column header while the source is idle schedules a
10 ms timer and opens a compact modal **Log commit ordering** dialog. This chooses
the Git walk order; it does not sort the displayed rows independently. Its label,
combo box, OK and Cancel are the four resource controls.

| Choice | Persisted value | Git argument |
| --- | --- | --- |
| Chronological reversed (git default) | 0 | No order argument |
| --topo-order (TortoiseGit default) | 1 | `--topo-order` |
| --date-order | 2 | `--date-order` |
| --author-date-order | 3 | `--author-date-order` |

Despite its label, the first choice does **not** add `--reverse`. The source
stores `LogOrderBy`, defaults to topology and writes only on OK. OK refreshes Log;
Cancel preserves its preference and contents. Consumers that force topology must
retain that override.

At the audited checkpoint, native `HistoryOptions` lacks ordering and `GitRepository.history`
hardcodes topology. The table has a column-visibility context menu but no ordering
dialog on header click. The next implementation needs a native draft picker and
owned Log route, persistence and cancel behavior, then actual ordering comparisons
against Git on a DAG with distinct author/committer dates. Graph lanes, selection,
filters, pagination and path/range walks must use the selected walk order.
Physical and signed acceptance remain separate requirements.

## Native implementation

`HistoryOrdering` retains the source’s four persisted integer values and maps
them to Git walk arguments. `HistoryOptions.ordering` defaults to topology;
`LogWindowModel.reload` loads the global app preference for each Log walk. The
separate Revision Graph reader continues to force topology. There is no
independent table-row sorting.

The compact native sheet keeps Commit Ordering, the four choices, OK and Cancel.
Selection is a draft until OK; Cancel, Escape and owned forced closure do not save
it. A revision-header click defers presentation by 10 ms, checks owner activity,
and opens the sheet. Its parent controls, ordinary close and Quit are fenced;
forced parent close ends and closes the child without triggering another reload.
OK saves the selected value and reloads Log, retaining selections by commit hash.

Three real-repository tests pass with system Git, Git 2.39.5 and packaged Git.
The fixture uses a merge and skewed author/committer dates, distinguishes at least
three actual orders and compares every mode to direct Git output. Checks also
cover limits, path walks, search, ranges, graph projection input, invalid preference
fallback and unchanged HEAD/index/config/working bytes. The hidden native receiver passes with system and packaged Git, dispatching the
actual table-header delegate, Cancel/OK actions and Return key route, then comparing
all four Log walks with Git. It checks retained selection, Escape cancellation,
busy/close/Quit fences and forced parent close. Actual native content captures are
inspected in light and dark appearance; window chrome is excluded. AppKit clears
the OK button’s explicit Return string when attaching a sheet, so the receiver
checks its default button cell and an actual window key dispatch. Physical input,
VoiceOver, localization and signed sandbox acceptance remain pending.

Native source checkpoint: `900aaf82550e616fa4a79bfd876e2740696f487f`.
The modal reference-child guard was checked using an already-open child and an
already-created menu action. While the ordering sheet is attached, the child menu
is empty and its stale action cannot dispatch. Forced parent closure closes both
children without saving an ordering draft. Broader history/Revision Graph
regression passes 62 tests. See [the verification record](qa/log-ordering-2026-10-10.json)
for build, capture and remaining acceptance scope.
