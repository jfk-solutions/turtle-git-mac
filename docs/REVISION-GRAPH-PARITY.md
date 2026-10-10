# Revision Graph port

The repository data, graph reduction and pinned OGDF layout adapter are ported.
A native AppKit Revision Graph window and Filter sheet are now implemented locally;
focused native interaction checks passed with system and bundled Git. Neither dialog has complete upstream parity. The complete TortoiseGit port and App Store acceptance remain open.

## Source baseline

TortoiseGit commit `7338078f8ddd924b8cddee35f512f2286072136d`:

- [FetchRevisionData](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/RevisionGraph/RevisionGraphDlgFunc.cpp): decoration-simplified unlimited history, range scopes, ordered child-map rewrite, terminal missing-parent nodes.
- [RevisionGraphWnd](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/RevisionGraph/RevisionGraphWnd.cpp): layout configuration and native interaction.
- [GetLogCmd and GetSubmodulePointer](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/Git/Git.cpp): Git options and superproject index pointers.
- [Dialog and menu resources](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/Resources/TortoiseProcENG.rc): Filter's From/To, reference browsers, current/local branch checkboxes and Reset; Revision Graph's File/View/Git/Help menu structure.

The [official manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-revgraph.html)
describes the overview, hover information, two-revision comparison and Show Log.
Source inspection, rather than the manual screenshot alone, determines the
additional controls and graph reduction rules.

## Ported repository behavior

`Sources/TurtleGitCore/RevisionGraph.swift` provides a separate repository query.
It does not inherit Log's row limit or file filters. The default scope uses
`--all`; local branches use `--branches`; current branch uses HEAD; explicit To
and From can contain multiple whitespace-separated revisions. From exclusions
apply in every scope. Local branches take precedence over current branch if an
API caller sets both flags, matching upstream; the native filter enforces mutually exclusive checkboxes and
disables the To field and its browser while either branch scope is selected.

Revision text resolves to commit hashes using `--end-of-options`, then enters the
history command as individual arguments. Text such as `--all` cannot inject a
Git option. The query uses `log --topo-order --parents --simplify-by-decoration`,
adding `--sparse` when branchings and merges are requested.

The ordered reduction preserves roots, branch points, merges, immediate parents
of merges and non-tag references. Hiding tags removes intermediate nodes that
have only tag labels; tag labels on retained branch/merge nodes remain available.
Superproject stage-zero pointers and conflicted Mine/Theirs pointers keep their
nodes; the conflict's common ancestor does not receive this retention exemption.
Disabling superproject pointers removes that exemption.

Excluded parents referenced by retained nodes become terminal boundary nodes.
They do not recursively expand excluded ancestry. Edges describe the simplified
graph, not the original parent list of the commit object. Reference identities
use the existing ordinal Git reference model, including current branch and
annotated-tag kinds. HEAD is also recorded independently for detached checkouts.

Reads suppress optional Git locks. Disposable checks verify unchanged raw index,
config, references and working-file bytes, including the parent index when
reading submodule pointers. Cancellation passes through every Git operation and
the ordered graph rewrite.

## Layout dependency and remaining work

The pinned TortoiseGit gitlink selects OGDF commit
`17f045b131851f5d32af184d5a7a864cec2bfc27`. Its source was fetched and the exact
pin and clean checkout verified. It offers GPL version 2 or 3 in `LICENSE.txt`.
The universal macOS 13 adapter and Swift geometry bridge now reuse this engine,
including COIN, with corresponding source and license packaging. Build and
embed verification is scoped separately in
[the layout runtime record](GRAPH-LAYOUT-RUNTIME.md); signed distribution
acceptance remains outstanding.

Upstream uses SugiyamaLayout with OptimalRanking, MedianHeuristic and
FastHierarchyLayout, with layer distance 30 and node distance 25. The native
adapter reuses these algorithms with caller-supplied dimensions. The native
canvas must measure its reference labels and use the returned coordinates and
clipped bend paths rather than substitute Log's lanes for this graph.

## Native implementation

`RevisionGraphWindow.swift` measures reference labels for the OGDF helper, draws
colored branch/tag rows and clipped arrow paths, and supplies scrolling, zoom,
fit height/width/graph, overview navigation, tooltips and two-node selection.
The app and Finder action route to a reusable controller per repository and Git
executable. Original `menurevisiongraph.ico` is packaged with its provenance.
Node commands route to existing Log, repository browser, comparison, local branch
switch and remote/tag checkout workflows. Reference deletion reuses the shared
CAppUtils::DeleteRef adaptation with fresh object checks. Unified diff resolves selected references before
reading a patch. The native exporter now supports SVG, Graphviz, PNG, JPEG, BMP, GIF and PDF; PDF replaces Windows enhanced metafiles.

`RevisionGraphFilter.swift` provides From/To fields, owned reference browsers,
mutually exclusive current/local branch scopes, OK, Cancel and immediate Reset.
Owned sheets block parent close. Active graph reads cancel and reap before closing;
closed models reject further loads and stale publications.

Remaining requirements include:

- Verify the native window and owned reference-browser handoffs against upstream.
- Verify full save-panel interactions, arbitrary-extension fallback and signed file grants. Windows enhanced-metafile encoding is replaced by native PDF.
- Verify rendering, zoom, overview dragging, pointer labels and hover date formatting.
- Physical and signed node-menu/File/View/Git/Help acceptance, alternative-tool
  modifier routing, and complete external handoffs.
- App and Finder launch routing, native screenshots, physical keyboard/mouse,
  accessibility, signed sandbox and distribution verification.
- Configured Log ordering beyond the current default topo order, superproject
  pointer labels/rebase wording, unusual nested tags, shallow/missing objects,
  large-repository responsiveness and source-state persistence.

## Verification

Run the focused suite with the system Git, then the bundled engine:

```sh
swift test --filter 'RevisionGraphTests|HistoryRangeTests'
TURTLEGIT_GROUP_TEST_GIT="$PWD/build/git-runtime/Git/bin/git" \
  swift test --filter 'RevisionGraphTests|HistoryRangeTests'
```

The graph tests cover ordered chain reduction, roots, merge parents, branch
points, non-tag labels, annotated/lightweight tags, branch/range precedence,
terminal endpoints, argument safety, unborn/detached and bare repositories,
superproject conflict pointers, cancellation and repository invariants. An
artificial empty-tree root is omitted by Git's decoration simplification;
detached behavior is checked against the actual Git query instead of assuming
every HEAD necessarily creates a visible graph node.

Local test/build results are recorded in
[the checkpoint evidence](qa/revision-graph-data-2026-10-10.json). These checks
cannot establish native window parity, activated Finder behavior, current
hosted CI or App Store readiness.

The native-window checkpoint is recorded in
[revision-graph-window-2026-10-10.json](qa/revision-graph-window-2026-10-10.json).
`python3 scripts/test-revision-graph-window.py --git /usr/bin/git --git build/git-runtime/Git/bin/git`
exercises the actual AppKit window without app activation. It verifies selection,
route callbacks, tooltip metadata, zoom, scope enablement, Cancel, Reset, busy
close cancellation and unchanged repository state. Both focused 25-test runs,
unsigned Debug/AppStore builds and bundle audits passed locally. Full visual,
signed and hosted-CI acceptance remain pending.

## Reference-box rendering

The native graph uses `RevisionGraphDlgDraw.cpp`'s solid `COLORLINE` fills rather
than a gradient. Labels use the source's 20-point horizontal and 5-point vertical
margins, a native 12-point font, and an eight-character minimum hash width.
Text contrast uses the graph's linear sRGB luminance threshold of 0.5 rather
than the separate Log-label formula. Bisect Skip deliberately shares Bisect Bad's
color in this graph, matching upstream. `Graph.RevGraphUseLocalForCur` selects the
local-branch color for the current branch. A superproject pointer uses the source
pink RGB 246/153/253; native dark/high-contrast conversion follows the shared
macOS palette. Unlabelled nodes use the source's red-tinted window background.

Selection marks distinguish the first node with the native highlight and an I
marker, and the second node with source RGB 136/0/21 and an II marker. With two
nodes selected, the first also receives `(Base)`. Native accessibility and
physical gesture acceptance remain outstanding.

Actual native content-view captures are available in the [local site gallery](site/index.html)
and the [rendering checkpoint](qa/revision-graph-rendering-2026-10-10.json).
Both native engine runs and unsigned Debug/AppStore builds and bundle audits
passed. Capture mode takes the window out of the visible ordering before using
alpha one to render native controls, then restores alpha zero. All owned windows
and fixtures are closed/removed. These captures do not prove physical input,
VoiceOver, signed activation or publication.

## Export implementation

`RevisionGraphExport.swift` adapts `RevisionGraphWnd.cpp::SaveGraphAs`,
`Utils/MiscUI/SVG.cpp` and `Utils/Graphviz.cpp`. Native SVG output contains paths,
reference rows and text, not an embedded bitmap. Graphviz preserves `rankdir=BT`,
parent-to-child edges and colored HTML table rows. It uses full hash IDs to avoid
abbreviated-ID collisions and escapes reference labels as XML/HTML. Text uses
the graph's readable contrast in native vector outputs. AppKit's private system
font family falls back to portable Helvetica in SVG/Graphviz; using the private
family name caused a serif fallback in actual Quick Look rendering.

The native format accessory defaults to SVG and updates its extension and allowed
content type together. SVG/PDF use 100% geometry and union the graph with the
viewport; raster outputs use the whole graph at the current zoom. The native
10-point canvas inset is retained in export extents. Export never changes the
model's zoom, selection or canvas frame. PNG/JPEG/BMP/GIF use ImageIO encoders;
PDF uses Core Graphics. Oversized raster allocations fail explicitly, while
vector choices remain available. The save callback writes atomically and leaves
an encoding or filesystem error visible in the status field.

Upstream's WMF enhanced-metafile output is intentionally replaced by PDF on macOS.
Arbitrary unsupported-extension JPEG fallback, complete file-panel gestures,
signed grants, very large graphs and external Graphviz rendering remain pending.

Export acceptance is scoped in [revision-graph-export-2026-10-10.json](qa/revision-graph-export-2026-10-10.json).
Both native Git-engine runs passed the encoding, format-control and view-state
checks. Unsigned Debug/AppStore builds and bundle audits passed. Actual exported
PNG and native Quick Look SVG rendering were inspected; external Graphviz
rendering and signed save-panel grants remain unproven.

## Reference menus and deletion

The native node menu follows `RevisionGraphWnd.cpp::OnContextMenu`: Show Log,
Browse, branch-specific Switch or remote/tag Switch/Checkout, Copy ref names,
reference-specific Delete/All, HEAD/unified/working-tree comparisons. Two-node
menus contain Show Log, Compare revisions and Unified diff. Original icons
remain attached to native menu items. Single-reference choices stay direct;
multiple local branches and deletable references form submenus. Extra generic
Create branch/tag, Reset and Copy hash items have been removed from this graph
menu to retain the source hierarchy.

The exclusion follows `GetFriendRefNames`' current short-name comparison for
all reference kinds, including a same-named tag. Annotated tags retain `^{}` in
copied names, friendly revision values and delete-menu labels, while the native
Git reference model keeps normalized names for mutation. Copy on a node with no
refs returns the full hash. Show Log uses raw hashes and the ordered first-to-
second difference range from `LogCommand.cpp`.

Typed menu payloads retain the node hash and reference identities. A retained
menu cannot act on another node. Deletion resolves the current commit before
showing confirmation; the shared deletion API rechecks its object/stash snapshot
after confirmation. All presents each reference separately and stops on Abort.
Remote/stash choices and failure reporting retain the shared source behavior.
Security scope, cancellation and a private SSH coordinator cover repository
operations; actual remote-network deletion remains unverified.

NSAlert clears customized button equivalents during presentation. The native
controller sets the Abort Return shortcut and default cell after beginning the
sheet; the real Return event was checked without activating the app. Owned
sheets block parent close and Quit. Repository refresh requests defer while the
graph is busy, filtering, exporting or presenting a sheet, then run when ready.
Physical branch checkout, remote/stash confirmation variants, alternative tools,
VoiceOver, unusual-reference ordering and signed Finder acceptance remain pending.

The [menu checkpoint](qa/revision-graph-menus-2026-10-10.json) records both native
engine runs, 17 focused core tests per engine, unsigned builds and bundle audits.
The deletion checks use disposable repositories only and keep ordinary read-only
invariants separate from intentionally destructive fixture actions. Current
hosted CI, physical gestures, signed activation and complete parity remain open.


## Mouse navigation implementation

The canvas now separates explicit selection used by command routing from user
clicks. Plain clicks toggle the first selected node and clear the second;
Command/Control clicks toggle nodes, promote the second when the first is
removed, and replace the second when a third is added. Modifier clicks on blank
space preserve the selected pair. Context clicks on a third node reject the
menu while keeping the pair, matching `UpdateSelectedEntry` upstream.

Dragging blank space pans the native clip view using successive pointer deltas.
Mouse-up ends the gesture. Clip bounds constrain both panning and overview
navigation. Command/Control-wheel zoom uses the source 0.9 step and 0.01–2
limits. Ordinary scrolling keeps AppKit's native behavior; Shift-wheel swaps
axes for discrete wheel events, while precise trackpad events retain AppKit's
phase and acceleration handling. Closed or loading graph models reject these
interactions. The native receiver covers synthetic event dispatch; physical
mouse/trackpad acceptance, accessibility and signed execution remain pending.

Focused synthetic navigation checks and the retained native graph suite passed
with system and bundled Git. Unsigned Debug/Store builds and both packaging
audits passed; see [navigation evidence](qa/revision-graph-navigation-2026-10-10.json).
This does not certify physical gestures or complete upstream parity.


## Adaptive overview

`BuildPreview` in the pinned `RevisionGraphDlgFunc.cpp` uses maximum bounds
of at least 100 × 200 or a quarter of the viewport, whichever is larger. It
fits the graph without magnifying above 100% and keeps each result dimension
at least 30. The native overview now follows these rules with a four-point
stroke inset. `DrawGraph` positions it at the lower right despite the source
comment saying top right. Native placement uses the clip viewport so the
miniature does not cover the scrollbars, and updates after window resizing.

The miniature reuses the graph labels and selection markers at preview scale.
A shaded viewport rectangle and border replace the old outline-only marker.
The marker is clipped to the miniature. Overview clicks/drags navigate without
changing the selected node pair; drags outside its bounds do not navigate,
matching upstream's overview hit guard. Clip constraints retain valid scroll
origins. Native content captures are refreshed with this layout. Physical
pointer/trackpad gestures, large-repository performance and signed execution
remain pending.

Both Git engines passed the focused native receiver. Unsigned Debug/Store
builds, both packaging audits and the local Pages build passed. Refreshed
light/dark captures were inspected; see [overview evidence](qa/revision-graph-overview-2026-10-10.json).
Earlier rendering records describe their original checkpoint captures.
