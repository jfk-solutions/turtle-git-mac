# Classic EMF path construction and manipulation

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
Pinned renderer: WmfEmfViewer `4e0d6d6807349ebfc8f8c681009c14f9e57621ff`.

Status: connected implementation passed the focused universal-helper, Core,
Debug-app and native-consumer checkpoint on2026-11-23. No Windows pixel
certification or whole-metafile compatibility claim follows from these controls. The independent
HQ6/7 affine interpolation arithmetic remains an open, separate family.

## Concrete missing behavior

The pinned renderer's `emfDrawer.js:872–892` interpreted PolyDraw16 point types
incorrectly: it used the close bit as MoveTo, looked for another close bit and
turned cubic control points into lines. The 32-bit handler recognized the basic
types but did not reject malformed cubic groups or update current position.
At lines2634–2643, FlattenPath and WidenPath were logging-only handlers. Those
records could silently leave the original geometry selected, so a later FillPath
or SelectClipPath displayed the wrong shape. Earlier EMF+ compressed-path or
classic clipping support did not implement these classic record semantics.

## Typed construction and selected-path lifecycle

The original `turtleGitClassicPaths.js` module in the tracked renderer patch
implements `EMR_POLYDRAW` (`0x38`) and `EMR_POLYDRAW16` (`0x5C`) through one decoder.
The [Point enumeration](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/01b63e3f-19d6-437c-8fc6-2758884bc08d)
distinguishes MoveTo6, LineTo2, BezierTo4 and CloseFigure1. Cubics require three
consecutive controls/endpoints; closure belongs only to a line endpoint or the
last cubic point. Unknown flags, malformed triples, count/array mismatches and
invalid coordinate transforms refuse the complete conversion. The
[compact record layout](https://learn.microsoft.com/windows/win32/api/wingdi/ns-wingdi-emrpolydraw16)
uses signed16-bit POINTS followed by type bytes; record alignment padding has no
geometry meaning. The wide form retains signed32-bit coordinates.

The decoder validates the complete packet and charges its budgets before it
changes geometry. Within BeginPath/EndPath, it appends disjoint figures, lines and
real cubics without painting or clearing earlier figures. Outside a path bracket,
it draws the requested lines with the selected pen. Implicit starting position,
closing-line return position and following LineTo/BezierTo operations retain the
accepted logical current position; device geometry is captured under the mapping
active at construction time.

The [path-bracket records](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/b930b989-30ec-4954-a889-1dc60ce0b689)
have empty bodies. BeginPath replaces an older selected path; nested BeginPath
records refuse the whole image, as required by the EMF wire contract. EndPath selects completed geometry. AbortPath discards it.
FillPath, StrokePath, StrokeAndFillPath and SelectClipPath require a completed
path, use their existing brush/pen/clip/ROP consumers, then release its geometry.
A replacement operation itself never produces ink.

SaveDC copies open or completed geometry together with its path state and
logical current position. RestoreDC restores that captured copy, independently
of subsequent additions, AbortPath or replacement. This follows the path-copy
ownership visible in Wine's
[PATH_SavePath/PATH_RestorePath](https://github.com/wine-mirror/wine/blob/master/dlls/win32u/path.c)
without copying its implementation. The existing selected-object/mapping/clip
snapshot remains in the shared GDI state machinery; objects created after a save
are not discarded by restoring path state.

## Flattening and widening

[FlattenPath](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-flattenpath)
replaces selected curves with lines. TurtleGit reuses its original native path
reader and adaptive cubic subdivision in captured device coordinates, with a
bounded1/256-device-pixel geometric tolerance. It serializes only MoveTo,
LineTo and explicit CloseFigure commands. Coincident endpoints do not create an
implicit close; a later cap/join decision must still distinguish them. Repeated
FlattenPath retains a completed path for later consumers.

[WidenPath](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-widenpath)
turns the selected pen's stroke area into the selected path. The native outline
bridge already handles bounded geometric nibs, caps, joins, miter limits and
dash arrays. The new geometry-only classic-pen adapter reuses that receipt with
the pen and transform selected at WidenPath time, then flattens the returned
outline. It preserves captured device positions when the world mapping changes
after path construction. The result is retained geometry: later FillPath uses
its current brush, rather than painting the earlier pen's color during WidenPath.
The same result can subsequently be stroked, clipped, saved, restored or aborted.

Widening accepts geometric ExtCreatePen and ordinary CreatePen, including thin
and zero-width pens, stock pens and null pens. An unset selected pen uses a local
implicit BLACK_PEN descriptor; it does not mutate the object selection. Pen paint visibility does not
suppress this geometry-only operation. Zero-width, stock and null selections
supply a one-device-pixel solid outline. Positive ordinary widths retain their
transformed nib and a minimum device hairline; the minimum outline uses the same
original-space dash subdivision, so it does not paint across dash gaps. A wide
ordinary CreatePen normalizes built-in dash styles to solid, as its creation
contract requires. ExtCreatePen cosmetic pens refuse the whole image, matching
the native API failure observed in the bounded eligibility witness.

The [API remarks](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-widenpath)
describe a narrower ordinary-pen eligibility condition than current Windows
actually accepts. A finite native GDI witness on the existing Windows11 VM
recorded18 eligibility outcomes and14 full GetPath device-geometry observations,
covering identity, enlargement, shrinkage, anisotropy and shear without rendering
expected pixels. Compiler/source/runtime hashes and original observations remain
in the [compact native witness](qa/metafile-classic-paths-reference-2026-11-23/README.md).
TurtleGit's generic minimum-width geometry retains
legitimate playback; exact Windows integer vertices, cap quantization and
per-device raster identity remain unverified. No fixture-specific shape table
or output-based expected pixels are used.

## Work bounds and original bytes

Each PolyDraw packet allows at most131072 points, with1048576 aggregate classic
path points. Selected generated path text is limited to2MiB. Wire/replacement
markup has a64MiB aggregate budget, and saved path copies have an independent
64MiB budget. Selected text is checked again at EndPath and before every consumer, including
paths built by legacy LineTo/PolylineTo records. An independent64MiB cumulative
path-scan budget is charged before joining or parsing retained segments, bounding
repeated small PolyDraw scans. These counters are shared with nested metafile playback. Existing
native cumulative subdivision/outline/serialization limits still apply, so
repeated replacements or saves cannot create an unbounded retained path graph.
Malformed records or failed native geometry refuse the complete image, including
any earlier painted prefix. Original input remains the comparison, Save and
conflict-resolution bytes.

## Prepared controls and validation scope

`scripts/build-classic-path-fixtures.py` authors94 additional files (91EMFs and
3independent SVG controls) and a hashed
manifest under `Tests/TurtleGitCoreTests/Fixtures/Metafile/ClassicPaths`.
Twenty-eight subject/control pairs use independent record constructions. The
source header has inclusive0…64 bounds, producing65×65 native pixels; verification
uses that allocation without resampling. They include
compact/wide cubics, disjoint figures, closure/current position, active and
completed SaveDC copies, flattening, geometric pen caps/joins/dashes, current-pen
changes, captured world mapping, clipping and no-early-ink/Abort behavior.
Twenty-eight malformed or unsupported controls retain a painted prefix before the
invalid operation. No renderer output is used as an expectation. The original cubic subject and
upstream fixture bytes are untouched. The generator refuses differing existing files.

`MetafileClassicPathTests` checks source hashes, full-frame paired constructions,
explicit interior fill/clip colors and whole-image refusals. The dedicated
`scripts/test-metafile-classic-paths.py` receiver prepares actual native image
comparisons, genuine three-stage conflict input, reload/drop, original index/file
preservation and cancelled-decoder/Close/Quit drainage. Its default covers the
connected family with system and bundled Git; `--only consumers` or
`--only ownership` allows an affected repair to avoid repeating passed scopes.
It uses private repositories/preferences and invisible/offscreen owners and
closes every owned window before success or failure is reported.

The existing classic clip-path, extended-pen and positioned-text path fixtures
were exercised as eight relevant regression methods, together with seven new
Core methods (15distinct methods cumulatively after focused fixture repairs).
These controls do not prove every possible input record sequence. Independent
Windows pixel references, signed-parent consumption, physical image
window/accessibility acceptance, every pathological path and full hosted CI
remain separate gates. WMF has no corresponding classic path-bracket records;
this implementation does not invent WMF WidenPath semantics.


## Flatten reference and completed checkpoint

The complete-frame Flatten control is an independently authored Bernstein
polyline, serialized as SVG so the unrelated legacy two-decimal EMF formatter
does not quantize its device vertices. Its subdivision count is derived from
the authored cubic's endpoint second derivatives: the maximum vector norm is240,
and uniform chord error is at most `M/(8*N*N)`. The first power of two meeting
`1/256` device pixel is128. No returned renderer points or pixels select that
count. The original cubic, rounded Bernstein EMF and oversampled256-line SVG
remain separate positive/diagnostic inputs. Pixel comparisons retain tolerance2.
The actual returned path is also checked for explicit open M/L geometry,
endpoints, extents, following current position and exact subcurve control-hull
error bounds against the authored cubic.

The initial fixture incorrectly expected64pixels from inclusive0…64 header
bounds. Later controls exposed logical-current-position restoration and
rasterizer sensitivity to different line subdivisions; all attempts remain in
the private checkpoint logs. The final receipt distinguishes those control
repairs from product changes: the production helper/app bytes did not change
after their successful builds, and passed native scopes were not repeated.

[The QA receipt](qa/metafile-classic-paths-2026-11-23.json) records exact source
hashes, cumulative checks and failures. The runtime configuration's prepared/
pending sentence was frozen before validation to preserve its input/provenance
hash; it does not override this completed focused receipt. The next runtime
candidate can replace that sentence when its inputs are rebuilt. Exact Windows
integer outline/raster parity and unrelated HQ interpolation remain outside this
checkpoint.
