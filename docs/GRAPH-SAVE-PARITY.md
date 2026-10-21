# Revision Graph save workflow

This batch connects the native Save Graph As panel and hidden command output to
the same filename rules. It does not certify the complete Revision Graph dialog
or Windows rendering identity.

## Pinned source

TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`:

- `src/Resources/TortoiseProcENG.rc:4143`: Pictures, Graphs and All Files.
- `src/TortoiseProc/RevisionGraph/RevisionGraphDlg.cpp:670–695`: Pictures adds
  `.svg` and Graphs adds `.gv` only when the supplied name has no extension.
- `src/TortoiseProc/RevisionGraph/RevisionGraphWnd.cpp:813–935`: the actual
  suffix selects the encoder; unknown names append `.jpg`. Vector outputs use
  default zoom while raster outputs use the displayed zoom.
- `src/TortoiseProc/Commands/RevisionGraphCommand.cpp`: `/output` starts a hidden
  graph and saves through the same exporter.

## Native behavior

`RevisionGraphExportDestination` preserves literal filename bytes and applies
the source defaults/fallback. The native panel offers the three filter groups,
keeps a custom suffix when switching groups and resolves the final filename
before the platform's save acceptance. A returned URL which still requires a
different filename is refused; accepting one path cannot authorize writing a
sibling path. The filename chooses SVG, GV/DOT, WMF/EMF, PNG, JPEG, BMP, GIF or PDF.

CLI decoding normalizes graph output before requesting its output permission.
Hidden output captures its graph preferences at command handoff, owns its graph
controller and retains repository/output access until rendering, publication and
controller reads drain. Existing staged, directory-relative atomic publication
continues to preserve destinations on failure/cancellation. Interactive export
captures immutable graph scenes before opening its panel, uses the accepted panel
URL and cancellation-aware staged atomic writer, and retains owned save/error
sheet state until it drains. Duplicate and retired responses cannot publish another export. Global
Quit confirmation freezes graph commands and interactions.
Entering Quit also cancels an in-flight hidden command export; cancelling Quit
does not revive that export.

The existing renderer continues to use actual native graph geometry, source
colors, labels, selection markers and arrows. SVG, WMF/EMF, Graphviz and PDF use
vector/default-zoom output;
raster formats use current zoom and retain the existing bounded image size.

## Explicit differences and remaining work

- Upstream's `.wmf` branch actually creates an enhanced metafile. Both `.wmf`
  and `.emf` now write enhanced EMF from shared native drawing commands. See
  [the vector export contract](GRAPH-METAFILE-EXPORT-PARITY.md) for Unicode
  outlines, label-local bitmap fallback and explicit resource limits.
- SVG labels now use shaped outlines rather than editable text. Raw labels remain
  in descriptive metadata; PDF retains native text. This is a documented difference
  from upstream SVG text elements.
- `.dot` and PDF are retained native additions.
- AppKit provides the native panel, overwrite prompt and sandbox grant. Full
  physical keyboard/VoiceOver and signed save-panel access on supported macOS
  versions/volumes remain separate acceptance work.
- Concurrent unrelated writers are not serialized. Complete graph layout,
  every source state, Finder/distribution and full hosted integration remain open.

The earlier save-workflow grouped checkpoint passed 61 distinct Core methods, the Debug app build and
six native case/engine pairs across the recorded focused repairs. Actual native
save/error sheet detachment, output encodings, final-path authorization, captured
settings, cancellation and owned helper drainage were checked. Automated windows
were hidden/offscreen; no complete physical or signed panel acceptance is claimed.

The dated grouped checkpoint is recorded in
[graph-save-2026-10-21.json](qa/graph-save-2026-10-21.json).

The [shared-scene/metafile continuation checkpoint](qa/graph-metafile-family-2026-10-21.json)
now records 31 distinct Core methods and 24 native case/engine combinations
passing across focused repairs, including this save family and the older graph
window family. Earlier results above do not independently certify the new renderer.
