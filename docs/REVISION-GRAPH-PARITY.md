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
  pointer signed/worktree acceptance, unusual nested tags, shallow/missing objects,
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


## Saved display choices

The native window now reads and immediately saves the four source
`InitialSetMenu`/`ToggleSetMenu` settings using app-private UserDefaults:

| Source preference | Native command | Default |
| --- | --- | --- |
| `ShowRevGraphOverview` | Show Overview | off |
| `ShowRevGraphBranchesMerges` | Show branchings and merges | off |
| `ShowRevGraphAllTags` | Show all tags | on |
| `ArrowPointToMerges` | Arrows point towards merges | off |

Settings apply globally across repositories, matching the source registry
scope. Each accepted command writes only its own setting, so another window's
other choices cannot be overwritten by an old snapshot. A new model restores
the saved display choices before reading history. Zoom, selection and Filter
From/To/branch scopes remain transient. Busy/closed/owned-sheet command guards
run before any preference write. Existing `DialogGeometry.attach` retains the
native window geometry separately; physical/signed window restoration remains
unverified. Private QA does not install global geometry preferences.

Native source defaults, menu dispatch/checkmarks, new-window restoration and
busy/closed write guards passed with system and bundled Git. Unsigned
Debug/Store builds and both packaging audits passed. See
[preference evidence](qa/revision-graph-preferences-2026-10-10.json). Physical
app relaunch and cross-window acceptance remain pending.


## Submodule pointer identities

`RevisionGraphData` now retains labels per hash as well as the computed pointer
hash set used by graph reduction. This ports `CGit::GetSubmodulePointer` and
`DrawTexts` labels: stage zero is `super-project-pointer`; conflict stage two is
`super-project-head` and stage three is `super-project-merge-head`. With an active
parent rebase, stage two becomes `super-project-rebase-head` and stage three
becomes `super-project-head`. Stage one remains excluded from retention and rows.

Rebase detection resolves the parent's worktree-local admin paths. It recognizes
source `rebase-apply` and `tgitrebase.active` directories plus native Git's
`rebase-merge` backend. It does not use the child's rebase state. Every command
uses optional-lock suppression and the caller's cancellation token. Rendering
measures each pointer row and carries explicit pointer color identity through
the canvas, overview, SVG and Graphviz exporters. A reference with the same text
cannot accidentally acquire pointer color. Multiple pointer labels on the same
hash retain separate rows. The existing Advanced setting
`LogShowSuperProjectSubmodulePointer` is now read with its source true default
before a new graph query; disabling it omits parent pointer reads and rows.

Core fixture checks cover stage-zero, merge and all three rebase-directory
variants with unchanged parent index bytes. Native checks cover label-row/color
identity and a real disposable conflicted submodule graph, measured rows and
SVG output. Physical conflict/rebase gestures, signed parent grants, unusual
submodule layouts and full parity remain pending.

Five Core graph tests and the native receiver passed with each Git engine.
Unsigned Debug/Store builds and both bundle audits passed; see
[pointer-label evidence](qa/revision-graph-pointers-2026-10-10.json). The native
conflict case is a private repository fixture, not signed/physical acceptance.


## Filter reference picking and scope behavior

`RevGraphFilterDlg` invokes `PickRef(false, "", gPickRef_All, true, false)`.
The native Filter now opens the all-reference chooser at HEAD with multiple
selection enabled and no range-choice prompt. The shared browser retains its
single-selection default for all other callers. A single selection returns its
canonical full name; several return displayed-order browser short names joined
by spaces, matching `GetSelectedRef` (local branches omit `refs/heads/`, other
references omit `refs/`). From/To already accept whitespace-separated revisions.

The native chooser is owned by the Filter sheet, inherits its visibility, and
blocks Filter Cancel/Reset/close plus graph close until it finishes. Parent input
focus is released before presentation and restored to the target field after
selection or cancellation. A request identity and the finished flag reject
late callbacks after forced close. Cancelling leaves the field unchanged.

Scope behavior now matches `OnBnClickedCurrentBranch` and
`OnBnClickedLocalBranches`: the active scope disables the other, clears To,
and disables To and its browser. Unchecking re-enables them. Reset still clears
both scopes and revision fields and immediately applies the cleared filter.
Native QA covers actual nested sheets, table multi-selection, chooser callbacks,
field focus, cancellation, scope controls and applying the returned multi-ref
text. Physical/VoiceOver/signed acceptance and all browser command parity remain
pending.


The multi-reference handoff exposed successful Git warning output contaminating
resolved hashes for a same-named branch/tag. Graph protocol parsing now reads
stdout only for hashes, branches, references, history and parent paths. Git
failures retain their diagnostics. A Core regression compares the picker-style
short multi-ref range against explicit canonical refs and checks unchanged
index/config/reference bytes with both engines.

Six Core graph tests, the full native graph receiver and the shared
reference-browser/Reset receiver passed with each Git engine. Unsigned
Debug/Store builds and both packaging audits passed; see
[Filter-picker evidence](qa/revision-graph-filter-picker-2026-10-10.json).
The graph receiver uses actual private nested sheets; the shared-browser
receiver uses injected presentation. Neither proves signed or physical acceptance.


## Editable zoom control

The native toolbar now includes an editable percentage combo box adapting
`OnChangeZoom`/`UpdateZoomBox`. It offers the eight source percentages, in the
descending order produced by upstream's repeated insertion at index zero.
Preset selection, Return and native editing completion apply a percentage;
buttons, wheel and fit changes synchronize the display with source-style
integer percentage formatting. A layout/redraw with unchanged zoom does not
replace an in-progress text draft.

Custom positive scales are not capped at the 200% button limit. Native input
validation rejects malformed, zero/negative, non-finite and unrepresentable
geometry values, restoring the last valid display rather than forwarding
source `_wtof` zero/overflow values to AppKit. Busy, closed, Filter/export and
owned-sheet guards reject edits. The combo box is disabled during loading and owned modal interactions.
Native QA exercises preset notification dispatch, typed action dispatch,
Return through the actual field editor, custom fractional and above-200% scales,
invalid values and loading/Filter locks. Physical popup/Tab/localized-decimal
behavior, signed and accessibility acceptance remain pending. See the original
toolbar mapping below for the subsequent artwork port.

The native graph receiver passed with each Git engine, including actual Return
input and modal/loading guards. Unsigned Debug/Store builds, both packaging
audits and local Pages build passed. Refreshed light/dark captures were inspected;
see [zoom-control evidence](qa/revision-graph-zoom-2026-10-10.json). Earlier
screenshot records remain scoped to their original commits.

## Original toolbar artwork and command order

The native toolbar now uses unchanged `src/Resources/revgraphbar.bmp` from the
pinned source. Tiles 0–5 are Zoom in, Zoom out, 100%, Fit height, Fit width and
Fit graph; tile 6 is the upstream combo placeholder; tiles 7 and 8 are Filter
and Overview. The loader crops each 20×20 glyph from the bottom-up BGR strip
and uses the first source pixel as the exact RGB transparency key, matching
`CImageList::Add`. Glyphs retain their original colors in both appearances.
Resource provenance records the original strip hash; bundle audits include it.

The menu row and toolbar occupy separate native rows. Six zoom buttons precede
the editable percentage, then Filter and Overview, with source separator groups.
Refresh is a native additional button for the existing F5 command. Toolbar
actions are disabled during loading and owned modal interactions; Overview
reflects its current state. At this toolbar checkpoint the original Find tile was decoded but not exposed;
the subsequent Find implementation is mapped below. This checkpoint does not certify full toolbar,
physical input, accessibility or signed execution parity.

Pixel checks compare every decoded tile with the pinned BGR resource, including
the transparency mask. Native checks passed with system and bundled Git for
button order/artwork, all six zoom actions, Overview state and loading locks,
plus retained graph/filter/export/reference tests. Light/dark content captures
were inspected and refreshed in the local gallery. See
[toolbar evidence](qa/revision-graph-toolbar-2026-10-10.json).

Unsigned Debug and App Store configuration builds passed. Both bundle audits
verified 118 unchanged upstream icon resources, including the new graph strip;
the local Pages build passed. This is local unsigned evidence, not hosted CI,
publication, signed Finder or App Store approval. All owned native QA receivers
exited and no app/test/compiler instances remained at the checkpoint.

## Find dialog and search

The modeless owned AppKit Find window adapts `TortoiseProc/FindDlg.cpp` and
`TortoiseLoglistCommon.rc2::IDD_FIND`: Full text search with a history combo,
Match case, Regular Expression and right-hand Find/Cancel, plus the full-name
reference list and its case-sensitive, one-second delayed Filter. The toolbar
uses the original Find tile and Command-F opens or focuses the existing window.

Graph metadata now includes author email, committer name and committer email.
Readable excluded-parent nodes load that metadata without expanding ancestry.
Search uses `LogDlgFilter` fields and the existing FilterHelper/ECMAScript UTF-16
port, including inactive-invalid-expression and negation behavior. Search starts
after its last result, wraps once and excludes that previous result. A bounded
loop fixes the upstream first-search/no-match loop without changing the result
order. Reference clicks resolve canonical names with `^{}` and navigate only if
the peeled hash is displayed. Shift preserves graph selection; normal results
replace it and clear the second selection.

Find does not own a modal sheet. The parent retains its child, which inherits
the parent's visibility for private QA. Repository reads and regex matching
run asynchronously with cancellation, captured access leases and stale-result
guards. Parent loading/modal operations disable Find; closing Find or its
parent cancels owned work. Explicit status text replaces source window flashing
and beeps for wraps/no-match. Search history and case/regex preferences are
saved on Find dispatch. At the initial Find checkpoint reference rows reused branch/tag/fetch menu
icons; the subsequent original-strip adaptation is mapped below. Physical focus/keyboard,
accessibility, localization, larger graphs and signed sandbox behavior remain
under review. Full Find/application parity is not certified.

The upstream inventory now includes shared `.rc2` resources. This adds the
previously omitted common Find dialog and its eleven controls: 130 dialogs
and 1,659 static controls at the same source pin. The inventory-pin regression
also checks shared-resource discovery and ignores dirty `.rc2` working copies.
All Find controls are marked partial; dynamic behavior and shared Log consumers
still require their own review. Historical 129-dialog checkpoints are unchanged.

Seven focused Core graph tests passed with each Git engine. Native receivers
passed with both engines for modeless single-window ownership, searchable body/
case/email/ECMAScript fields, annotated reference peeling, selection-preserving
navigation, actual reference-table action dispatch, actual field-editor delayed
filter input, saved history/options, loading/modal locks and close cancellation.
Closing the parent closed its Find child. Control-frame checks and light/dark
right-button alignment checks passed; the inspected final captures were added
to the local gallery. The initial action-only run exposed a collapsed group
layout during capture inspection; constraints and independent frame checks
were repaired before the final acceptance run. Physical Shift/focus/keyboard
and signed execution remain pending. See
[Find evidence](qa/revision-graph-find-2026-10-10.json).

The final unsigned Debug and App Store configuration builds passed, as did
both bundle audits (118 upstream icon resources) and the local Pages build.
All owned receivers exited; no app/test/compiler processes remained. The
App Store/sandbox/Finder signing and current hosted CI/publication gates remain
open. The checked-in Find evidence is a feature checkpoint, not full parity.

## Find reference artwork, errors and keyboard routes

Find reference rows now use unchanged `src/Resources/reftype.bmp`, retaining
the source's 16-pixel tag/local/remote tiles and explicit white RGB mask. Unknown
reference namespaces have no type glyph, matching `nImage = -1`. The original
strip and SHA-256 provenance are bundled; the existing toolbar and new reference
strips share a BGR/color-key decoder. Independent pixel checks retain all RGB
values and verify the exact alpha mask.

Failures reading references or resolving a clicked reference now present a
critical sheet owned by Find with the source failure caption, Git details and
OK acknowledgment. Runtime matching failures use the same native error route.
Concurrent failures queue behind the current sheet. Find, root toolbar/menus,
canvas selection/pan/wheel and overview navigation are guarded while a Find
error is pending. Root/child user-close is blocked until acknowledgment; forced
owner cleanup ends and closes owned sheets, clears queued failures and cancels
work. Deferred repository refresh remains blocked through acknowledgment.

Command-F retains the single Find-window route, Cancel uses guarded native
close, and Shift-Return commits the current query and navigates without changing
selection. The source Shift-on-Find behavior is also retained for ordinary
button/reference events. Synthetic native key dispatch is a scoped check;
physical keyboard/mouse, VoiceOver/localization, complete shared Log consumer
parity and signed App Store/Finder acceptance remain unproven.

All three icon tests passed, including an independent source-pixel oracle for
the three reference tiles and retained toolbar pixel checks. The native graph
receiver passed with both Git engines for rendered-row glyph equality, Command-F
opening/Cancel closing, field-editor Shift-Return navigation, source reference
failure captions and actual owned-sheet OK acknowledgment. It also checked
root/child close and toolbar/menu/canvas locks, unchanged selection on failure,
failed reference-list loading and forced owned-sheet cleanup. Light/dark Find
captures were inspected and refreshed. See
[Find details evidence](qa/revision-graph-find-details-2026-10-10.json).

The reference bitmap also matches the pinned Git blob byte-for-byte. Unsigned
Debug/App Store builds, both bundle audits (119 icon resources) and local Pages
build passed. Plain Return, physical input/accessibility, concurrent reference-
load/search completion ordering, error-sheet appearance/key variants and signed
acceptance remain pending. No owned app/test/compiler processes remained at
checkpoint. Hosted CI and publication are not established by these local checks.

## Find initialization ordering and Return

The source completes `RefreshList()` inside `OnInitDialog` before the Find
dialog can accept searches. The native asynchronous adaptation now tracks
reference loading explicitly: query/options/list/filter controls are disabled
and forced text/reference dispatch is rejected until the initial read ends.
The waiting status explains the state; Cancel and parent close can still cancel
the owned read. Reference-read failure transitions directly into its owned
critical sheet, without enabling search between loading and acknowledgment.
This excludes reference-load/search overlap at initialization.

Native QA adds startup control locks and unchanged history/selection assertions,
cancel-before-load completion, plain Return through the actual combo field
editor, and Return through the critical sheet's default OK button. Results are
scoped to native event injection; physical keyboard/focus and complete
application/signed parity still require acceptance.

The final receiver passed with system and bundled Git for these startup and
Return paths, plus retained graph/Find/error/filter/export/reference/pointer
checks. The first startup test caught a missing forced-dispatch guard despite
disabled controls; the search entry point was repaired before the passing run.
No Core matcher or artwork changes were required. See
[startup/Return evidence](qa/revision-graph-find-startup-2026-10-10.json).

Final unsigned Debug/App Store builds and both bundle audits passed (119
upstream icon resources). Normal gallery captures from the prior checkpoint
remain current; loading/error-sheet appearance is not newly certified. All
owned receivers exited, with no remaining app/test/compiler instances.
Physical input, shared Log Find, signed execution and full port parity remain
open; local builds do not establish current hosted CI or publication.
