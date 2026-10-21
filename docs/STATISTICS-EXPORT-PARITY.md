# Statistics save and calculation family — October 21, 2026

This continues the [Statistics review](LOG-STATISTICS-PARITY.md), using pinned
TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`, dialog `IDD_STATGRAPH`.

## Source contract and native adaptation

`src/TortoiseProc/StatGraphDlg.cpp` initializes the six metrics, four options,
five source graph buttons and remembered graph page in `OnInitDialog`
(lines 140–307). `ShowLabels` (310–365) separates summary and graph controls.
Those controls, chart styles, source palette, author slider and preference keys
already exist in the native dialog and are retained in this batch.

`OnFileSavestatgraphas` (1445–1466) uses Pictures and All Files, with `.wmf` as
the extensionless Pictures default. `SaveGraph` (1469–1535) renders the current
graph viewport and chooses PNG/JPEG/BMP/GIF by the filename, appending `.jpg` for
unknown extensions. `src/Resources/TortoiseProcENG.rc`, `IDS_STATPICFILEFILTER`,
defines the two source filter groups.

The native sheet uses Pictures and All Files. Supported typed suffixes select
WMF/EMF/PDF/PNG/JPEG/BMP/GIF regardless of the filter. Changing filters preserves
the filename. Pictures supplies `.wmf` when there is no extension; All Files
supplies `.jpg`. Unknown suffixes get `.jpg` appended.

The source `.wmf` branch actually calls `CreateEnhanced`, rather than writing a
classic Windows metafile. TurtleGit now follows that convention: both `.wmf` and
the explicit `.emf` alias contain enhanced EMF bytes. PDF remains an additional
native vector choice. A separate classic-WMF graph writer is not implemented.
The original bounded enhanced-metafile writer is independent of the comparison
decoder; placing a graph screenshot inside a metafile is not its export route.

The panel normalizes the filename before platform overwrite confirmation and file
access authorization. Acceptance validates the exact final URL and refuses an
unnormalized URL rather than exporting to a different sibling. Core destination
resolution preserves literal spelling, including composed/decomposed names.

## Shared Statistics drawing scene

`StatisticsVectorScene.swift` now builds one immutable `GraphVectorScene` for
`StatisticsVectorNativeView` and `StatisticsGraphExport`. Native presentation,
PDF, raster encoders and enhanced-metafile writing all consume that scene at the
same captured viewport and appearance. This replaces the earlier Swift Charts
and separate Canvas rendering; exports do not reconstruct an approximate chart.

The scene includes the metric title, source palette, integer axes and ticks,
grouped/stacked bars, ordinary lines with positive-value symbols, stacked-area
polygons and pies. Ordinary bars and lines retain the source average guide.
Zero-to-zero line segments are skipped, and a single-interval stacked area is a
narrow filled bar. Author and synthetic Others identities remain numeric group
positions, including canonically equivalent names and duplicate captions.

Pies occupy one centered horizontal row in the visible viewport. Zero-total
series are omitted without reserving slots. The source legend fitting/elision
and final-group policy remain; narrow views hide the legend. Legend width is
bounded to preserve a usable plot, with complete raw labels available through
hover and accessibility. Display-only control characters are made single-line;
the original label bytes remain in point descriptions.

Bar, pie and smaller-line hit regions are derived from the same geometry.
Average tooltips take priority at their guide. Stacked areas retain their source
absence of individual hover regions, while every point, including zero values
and dense lines, has a native accessibility label. Physical VoiceOver acceptance
is still pending.

`GraphVectorRenderer.swift` draws the scene through Core Graphics. PDF retains
native text. EMF resolves shaped CoreText runs, including fallback fonts, into
vector glyph outlines; text is therefore not generally editable/searchable in
that format. A font glyph which cannot supply a path uses a bounded label-local
RGBA image. This fallback never replaces the whole graph with a bitmap. Path,
clip, color and drawing order remain shared across native and exported views.

## Captured workflow and lifetime

Save Graph captures the graph, metric, style, viewport and appearance before
opening its owned sheet. The accepted filename and encoder are frozen in the
single accepted reply. Old, duplicate, closed-owner and Quit-invalidated replies
cannot launch another export. Sheet reply processing waits for actual detachment
before rendering or publishing an error. An export error is another owned sheet,
with the same detachment accounting.

Interactive writing holds the exact destination's scope, coordinates replacement,
stages bytes in a same-volume Foundation replacement workspace, checks
cancellation during writing and immediately before atomic publication, and cleans
its workspace on every exit. An existing destination survives cancellation before
publication. Once publication succeeds, a later cancellation does not report a
failed save. Signed destination-only grants still require installed acceptance.

Ordinary close during calculation/writing requests cancellation and waits. Forced
close retires UI and dismisses owned sheets while retaining the controller, access
lease and Quit accounting through actual worker/sheet drainage. A closing or
retired Statistics controller cannot be reused by Log; an old close callback
cannot clear a replacement controller.

Calculate captures the originating preferences' diff backend once for its whole
read. Partial cancelled results are discarded. The previous complete summary is
retained; retry is available after the worker finishes. Form actions carry the
current revision, including Cancel and Close. Quit confirmation invalidates those
receipts and cancels outstanding work.

## Earlier save-lifetime validation

The [dated grouped checkpoint](qa/statistics-export-family-2026-10-21.json)
records 23 focused Core methods, the Debug app build and ten native case/engine
pairs passing across the recorded repairs. The six new export cases cover both
Git engines; the existing calculation/ownership and author-identity families add
two pairs each. The first app build required explicit Swift capture references;
new and older fixture repairs retain the behavioral assertions and accommodate
actual sheet drainage. Only affected native workflows were repeated after those
fixture repairs; Core and the successful new export group were not rerun.

All twelve receivers, including failed attempts, were reaped and independently
absent. No new screenshots were taken; earlier chart captures do not prove physical
save-panel behavior. Help and localization resources were regenerated, and the
site rendered with its two documentation/link checks passing. Earlier Statistics
checkpoints cover their recorded sources and do not prove these new filter,
atomic writer and ownership rules.

## Current shared-scene checkpoint and limits

The [shared-scene/metafile checkpoint](qa/graph-metafile-family-2026-10-21.json)
records 31 distinct Core methods and 24 native case/engine combinations across
both graph families passing after focused repairs. Statistics covers all five
styles in light/dark, seven actual encodings, PDF labels, decoded source palettes,
pie placement, dense/narrow legends, exact author identities, captured viewport
and save ownership. Header/vector records and real metafile decoding are checked.
Two full-window chart captures were reviewed and updated on the website. All 25
receiver attempts, including the failed Revision attempt, are independently absent.
Historical checks above do not independently certify the new renderer.

Statistics currently bounds every export canvas to 16,384 pixels per dimension
and 32 million pixels of area. The metafile writer also enforces bounded records,
path/glyph work and a 64 MiB output limit. These limits can explicitly refuse an
oversized graph; there is no silent whole-page raster substitute. Native font
metrics, glyph rasterization and pixel rounding remain macOS adaptations, not a
claim of Windows pixel identity.

Still open: physical save/overwrite and modifier
behavior, VoiceOver, exact Windows font/geometry/shading identity, large-repository
performance, installed signed sandbox replacement on deployment volumes, current
complete hosted integration and whole-dialog acceptance. This family does not
certify the complete Statistics dialog or application.
