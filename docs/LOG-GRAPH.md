# Expanding compressed history

Open **Log Messages**, then choose **Walk Behavior → Compressed Graph**. The list
keeps HEAD, visible branch/tag labels, merges and forks while hiding ordinary
commits between them. The compact graph remains before the revision list.

Right-click one commit and choose **Expand** to reveal its linear history down to
the next label, merge or fork. That boundary keeps its own collapsed state; expand
it separately to continue. Expanding a merge reveals its parent arms. Choose
**Collapse** on an expanded row to hide the segment again. You can also collapse a
row inside an expanded segment. Hollow nodes identify collapsed segments; filled
nodes identify expanded ones.

Expand/Collapse is available only in Compressed Graph with one ordinary commit
selected and no active text search. It is absent for working-tree rows, multiple
selection, normal history and **Show labeled commits only**. An invalid regular
expression leaves the text filter inactive, as in TortoiseGit.

These commands change the displayed graph, not commits, branches, the index or
working files. Rollup choices belong to the current Log window. Closing it resets
those choices. Compression currently applies to the loaded history batch;
cross-page behavior and physical UI acceptance are still being compared with
TortoiseGit. See [Log parity](LOG-PARITY.md#compressed-graph-expandcollapse).

## Double-click comparison

Double-click comparison starts disabled, as in TortoiseGit. Enable **Settings →
Dialogs → Can double-click in log list to compare with previous revision** to use
it. It compares the first selected revision with its first parent. If several rows
are selected, their first visible row supplies the comparison. A root commit
reports **No previous version.** The context-menu comparison and unified-diff
commands remain available without this setting.
