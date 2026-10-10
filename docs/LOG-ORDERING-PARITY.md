# Log commit ordering

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
The four-control `IDD_LOGORDERING` dialog is **not implemented** at native
checkpoint `1769e2c738e9b078e6c377205f5124b23bd010db`.
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

The current native `HistoryOptions` lacks ordering and `GitRepository.history`
hardcodes topology. The table has a column-visibility context menu but no ordering
dialog on header click. The next implementation needs a native draft picker and
owned Log route, persistence and cancel behavior, then actual ordering comparisons
against Git on a DAG with distinct author/committer dates. Graph lanes, selection,
filters, pagination and path/range walks must use the selected walk order.
Physical and signed acceptance remain separate requirements.
