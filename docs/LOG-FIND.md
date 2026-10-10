# Finding revisions in Log Messages

Press **Command-F** in a Log Messages window to open Find. Pressing it again
focuses the same Find window. Find is modeless, so the Log stays available while
you enter a query. Closing the Log also closes its Find window.

## Full text search

Enter text in **Search for**, then press Return or click **Find**. The result is
selected and scrolled into view. Find searches the displayed rows, independently
of the Log's history filter. It includes subjects and message bodies, authors and
committers, both email addresses, revision hashes, notes, configured issue IDs,
reference names, annotated-tag details and changed paths.

The working-tree row can also match its message or changed paths. Uncached commit
paths include root commits and changes against every merge parent. Cached file
lists retain both the new and old names for renames.

**Match case** controls case-sensitive matching. **Regular Expression** uses the
same bundled ECMAScript UTF-16 matcher as the other history searches. Plain-text
queries retain TortoiseGit's quoted terms, exclusions and alternatives.

Each Find starts after the parent's retained numeric row position and stops as
soon as it finds a match. A new Log starts with position zero, so its first text
search starts at the second displayed row. Successful text or reference searches
update that position even when Shift preserves selection. Closing and reopening
Find, changing its query or reloading the displayed history retains the numeric
position. Ordinary selection does not change it; opening a revision context menu
sets it to the selected row, matching TortoiseGit's selection-mark route.
The search wraps once through the displayed rows and excludes the retained row. A status message reports wrapping or no
further match. **Shift-Return**, or Shift while clicking Find, scrolls to the next
match without changing the selected revision. Search text and the two checkbox
preferences are shared with Revision Graph Find.

## Reference navigation

The reference list uses full reference names and the original colored tag,
local-branch and remote-branch icons. Enter a literal, case-sensitive name fragment
in **Filter** to narrow the list. The filter applies after a short typing pause.
Click a reference to resolve its peeled commit and navigate to that displayed
row. References outside the displayed history produce a no-match status.

Find waits for its initial reference read before enabling search. A failed read
or resolution opens a critical sheet. Acknowledge it with **OK** or Return before
continuing. **Cancel** closes Find; it does not change the history filter.

## Port status

This adapts the shared upstream `IDD_FIND` / `CFindDlg` and
`GitLogListBase::OnFindDialogMessage`, rather than replacing the history filter.
The source full-text corpus is defined by `LogDlgFilter::operator()` with
`LOGFILTER_ALL`; the uncached path list follows `GitRevLoglist::SafeGetSimpleList`.
The native window shares the existing Revision Graph Find layout and reference
artwork. See [Revision Graph parity](REVISION-GRAPH-PARITY.md) for those source
controls and the [Log parity audit](LOG-PARITY.md) for remaining Log work.

Physical keyboard/mouse, accessibility, localization, very large histories,
reference-list refresh after all Log mutation commands, metadata changes during
a search and signed sandbox acceptance still require verification. This does not
certify complete Log dialog parity.

Local verification is recorded in [the Find evidence](qa/log-find-2026-10-10.json).

The numeric owner follows `GitLogListBase.h`'s `m_nSearchIndex = 0`,
`GitLogListBase::OnContextMenu` and `OnFindDialogMessage` at the pinned upstream
commit. Revision Graph uses the same ownership, starting value and successful
match update from `RevisionGraphDlg.h/.cpp`. If a reload leaves the retained
index outside the new rows, the native search scans the displayed rows once
instead of entering the source's potentially unbounded wrap loop.

The added cursor lifecycle and context-menu checks are recorded in
[Find position evidence](qa/find-position-2026-10-10.json).
