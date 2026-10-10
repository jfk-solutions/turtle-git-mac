# Revision Graph port

The native Revision Graph window is still missing. This checkpoint ports its
repository data and graph reduction, not its rendering or user interaction.
Both `IDD_REVISIONGRAPH` and `IDD_REVGRAPHFILTER` remain pending in the dialog
inventory. The complete TortoiseGit port and App Store acceptance remain open.

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
API caller sets both flags, matching upstream; the future filter UI must enforce
the source's mutually exclusive checkbox behavior.

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
It has not yet been built or embedded in TurtleGit; no OGDF distribution claim
is made at this checkpoint.

Upstream uses SugiyamaLayout with OptimalRanking, MedianHeuristic and
FastHierarchyLayout, with layer distance 30 and node distance 25. The native
port should reuse these algorithms, with measured native label dimensions,
rather than substitute Log's lanes for the standalone graph.

Remaining requirements include:

- Universal OGDF build, layout bridge, corresponding source and license packaging.
- Native canvas, colored reference boxes, arrows, hit testing, scrolling, zoom,
  overview dragging and hover author/date/message information.
- Source-style Filter dialog and its reference-browser handoffs.
- Refresh, fit height/width/graph, tag and branching toggles, arrow direction,
  overview and export formats.
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
