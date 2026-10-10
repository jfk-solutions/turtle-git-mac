# Revision Graph

Revision Graph shows the repository's branch and tag topology in a separate
native macOS window. Open **Revision Graph** from the repository's action list.
The Finder extension also has a Revision Graph command when its integration is
available; signed activation and complete Finder acceptance remain pending.

Each node contains colored reference rows. Current branches, other local
branches, remote branches and tags retain distinct TortoiseGit color roles.
Nodes without references display an abbreviated commit hash. Hover over a node
for its full hash, author, author date and message.

Click a node to select it. Command-click or Control-click another node to select
a second revision. The first selection has an I marker and becomes the Base
when two nodes are selected; the second has a red II marker. Right-click a node
for Log, repository browsing, comparison and revision commands. Some upstream
context commands are still missing; see the parity record below.

Use the toolbar or **View** menu to zoom, return to 100%, fit width or height,
or fit the whole graph. **Show Overview** displays a miniature graph; click or
drag within it to navigate. The overview is suppressed above 10,000 displayed
nodes. **Refresh** or F5 reads the repository again.

**View → Filter…** opens a revision range sheet. **From** excludes history
reachable from the entered revision; **To** restricts the included history.
Both fields accept whitespace-separated revisions. **RefBrowser** opens the
native reference chooser. **Only Current Branch** and **Only Local Branches**
are mutually exclusive and disable To and its reference browser. **Cancel**
discards the sheet's changes. **Reset filter** clears the range and branch
scopes and immediately refreshes the graph.

**Show all tags**, **Show branchings and merges**, and **Arrows point towards
merges** are separate View commands. These affect the graph's reduction or arrow
direction, independently of the range filter.

**File → Save graph as…** opens a native format chooser, defaulting to SVG.
Choose SVG, Graphviz (`.gv`), PNG, JPEG, BMP, GIF or PDF. SVG and PDF export
at 100% and include at least the graph and viewport extent; raster images export
the full graph at the current zoom. Graphviz stores topology and colored
reference rows for an external Graphviz renderer. PDF is the native replacement
for Windows metafiles. Very large raster exports report an error; reduce the
zoom or select a vector format. This is a partial port, not a full parity claim.

The [parity record](REVISION-GRAPH-PARITY.md) documents source mappings,
verification and remaining work. The [upstream manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-revgraph.html)
is a reference for the Windows application; platform-specific details can differ.

Example exports from a disposable test repository: [SVG](site/assets/revision-graph-export.svg)
and [Graphviz](site/assets/revision-graph-export.gv). The fixture includes a tag
with XML metacharacters to verify that reference text remains readable.
