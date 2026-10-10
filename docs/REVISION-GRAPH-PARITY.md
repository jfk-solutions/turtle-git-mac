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
Node commands route to existing Log, repository browser, comparison, checkout,
branch/tag and reset workflows. Unified diff resolves selected references before
reading a patch. The current graph export supports PDF only.

`RevisionGraphFilter.swift` provides From/To fields, owned reference browsers,
mutually exclusive current/local branch scopes, OK, Cancel and immediate Reset.
Owned sheets block parent close. Active graph reads cancel and reap before closing;
closed models reject further loads and stale publications.

Remaining requirements include:

- Verify the native window and owned reference-browser handoffs against upstream.
- Match source export formats beyond the currently implemented PDF export.
- Verify rendering, zoom, overview dragging, pointer labels and hover date formatting.
- Complete node context menus and File/View/Git/Help menus, original icons,
  two-node selection, comparisons, unified diff and Show Log routing.
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
