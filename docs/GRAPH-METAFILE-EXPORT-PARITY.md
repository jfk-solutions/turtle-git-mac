# Shared graph drawing and enhanced-metafile export

This continuation covers Statistics and Revision Graph drawing, file encoders
and captured Save ownership. It does not certify either complete dialog.

## Pinned source contract

TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d` writes enhanced EMF
under the `.wmf` suffix using `CreateEnhanced` in
`src/TortoiseProc/StatGraphDlg.cpp:1472–1483` and
`src/TortoiseProc/RevisionGraph/RevisionGraphWnd.cpp:814–831`. Statistics renders
its current graph viewport. Revision Graph temporarily uses default zoom, draws
its graph and restores zoom. A separate classic WMF encoder is not required by
these source branches. TurtleGit accepts both `.wmf` and explicit `.emf` as aliases
for enhanced EMF. Statistics restores the source `.wmf` extensionless Pictures
default; Revision Graph retains `.svg` for Pictures and `.gv` for Graphs.

The user-provided layout2vector repository, pinned at
`2e0a96b9f87f2a8c0ff649963a67dfccd73bf5bb`, provided a separate writer reference.
The native implementation uses an original shared display list and Core writer;
it does not rasterize an entire graph or execute foreign renderer code.

## Shared native scenes

`GraphVectorScene` carries ordered paths, fills, strokes, clips, text and explicit
local bitmaps in top-left coordinates. Native drawing, PDF, SVG, enhanced EMF and
raster exports consume this scene. Graphviz remains topology serialization.

Revision Graph retains row colors, rounded clipping, edge directions, both
selection markers, Base captions and configured native fonts. Vector exports use
unit zoom and raster exports use current zoom. Statistics retains the five graph
styles, summary/metric options, source palette, axes, averages, author identities,
legend and viewport rules. Native chart hover regions and accessibility labels
are derived with the chart geometry, including zero-valued data points.

CoreText shapes each label with actual fallback fonts. SVG/EMF encode glyph paths
rather than depending on fonts installed on another computer. Color-font and
bitmap-only labels retain native appearance using bounded label-local RGBA images;
other geometry stays vector. SVG labels consequently are not editable text;
escaped descriptive metadata preserves raw label spelling. This differs from
upstream SVG text elements. PDF retains native text. None of these choices proves
identical Windows font metrics, antialiasing or GDI pixels.

The enhanced-EMF writer uses a real header, 32-bit paths, cubic curves, fill rules,
saved clips and geometric pens. Dynamic system edge colors are resolved over
the captured canvas background before encoding opaque vector pens; native and
export share the resulting paint. It preserves fractional positions through a
1/64 logical-unit world transform. Local images use premultiplied alpha records.
It refuses unresolved text, nonopaque vector paints, invalid/unbalanced state,
nonfinite geometry and oversized inputs rather than silently flattening a graph.
The limits include one-million-unit page/coordinate bounds, 100,000 commands,
500,000 path segments, 64 MiB output and sixteen megapixels of local bitmap data.
Raster exports retain separate bounded allocation limits.

## Captured save and cancellation

Both owners capture immutable graph content, size, appearance and settings before
showing Save. Acceptance freezes the final URL, encoder and writer exactly once.
Actual panel detachment precedes rendering/writing. The shared staged writer uses
a same-volume replacement workspace and checks cancellation during work and
before publication. A cancelled unpublished save preserves an existing file.

Forced close retires the UI and cancels work; actual workers and child sheets
remain accounted for until they drain. Quit observes that ownership. Duplicate,
late and retired panel replies cannot publish another file. Hidden Revision
Graph command output retains its existing scoped prepared-file publication.

## Validation and remaining work

The [dated grouped checkpoint](qa/graph-metafile-family-2026-10-21.json) records
31 distinct Core methods and 24 native case/engine combinations passing across
recorded focused repairs. Actual output headers/records and decoded geometry,
Unicode label ink, source palettes, five Statistics styles in both appearances,
Revision Graph markers/arrows and native save/close/Quit ownership were checked.
All 25 receiver attempts, including the failed attempt, are independently absent.
Two complete Statistics chart captures were reviewed and updated on the website.
Earlier save and metafile-reader checkpoints do not independently certify this
new graph writer or renderer.

Physical keyboard/VoiceOver behavior, Windows pixel/font identity, very large
repository performance, signed sandbox grants and replacement on deployment
volumes, minimum-OS/Intel acceptance, current complete hosted CI and complete
upstream dialog parity remain open.
