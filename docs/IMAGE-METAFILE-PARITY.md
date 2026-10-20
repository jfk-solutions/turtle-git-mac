# Windows metafile image comparison

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
`TortoiseIDiff/MainWindow.cpp:1255` offers WMF/EMF; shared
`Utils/MiscUI/Picture.cpp::Load` uses Windows GDI+ Bitmap decoding. This family
adds a bundled macOS decoder for captured WMF, EMF and EMF+ image bytes. Original
repository bytes remain the comparison/conflict/save inputs; rasterization creates
only a private display representation.

## Renderer and source changes

The renderer is MIT-licensed WmfEmfViewer, pinned to
`4e0d6d6807349ebfc8f8c681009c14f9e57621ff`. Its source and license accompany the
packaged runtime. `patches/metafile-renderer.patch` applies to that exact source;
no network or Node/npm runtime is used during conversion. A separate helper uses
system JavaScriptCore and receives only captured bytes over stdin. Native adapters
provide CoreText font measurement, code-page decoding and bounded ImageIO bitmap
conversion. It has no document-derived filesystem or network APIs.

The adaptation implements EMF+ world/page transforms, prepend/append matrices,
indexed graphics Save/Restore, containers, clipping rectangle/path/reset/offset
and all six clip-combine operations. Clips are captured in device coordinates;
a later matrix change cannot move them. SVG groups retain affine geometry for
paths, ellipses, text and bitmap parallelograms. Multi-subpath fills retain every
subpath. Bounded continued objects assemble before decoding.

Font objects retain original family names instead of replacing them with generic
serif/sans/monospace. Native CoreText measurement replaces the upstream fixed
0.6-em estimate. Formatted StringFormat layouts use native shaped outlines for alignment,
wrapping, direction, tabs, spacing, trimming and decorations; exact scope and
remaining text refusals are listed in [formatted text parity](METAFILE-TEXT-PARITY.md). Solid pen caps, joins,
units and dash patterns retain their source data. Raw 24-bit BGR, 32-bit BGRX,
BGRA and premultiplied BGRA bitmap objects use bounded native conversion.
Compressed image signatures determine PNG/JPEG decoding, and actual decoded
metadata determines dimensions. Source rectangles and three-point destinations
retain cropping and affine mapping. Ordinary WMF clip rectangles and EMF two-color
rectangle gradients are implemented. Nested clipping intersects existing clips. EMF+ Header selects EMF+ playback and
suppresses classic fallback drawing; only an explicit GetDC interval enables
classic records until the next EMF+ record. The dual fixture deliberately gives
the fallback a different color to detect the wrong representation or double paint.
Matrix Append/Prepend follows GDI+ row-vector order, separately checked with
noncommuting scale/translation records against Microsoft's documented order.

The [painting interoperability extension](METAFILE-PAINTING-PARITY.md) tracks
ImageAttributes, destination point encodings and gradient-brush support against
Microsoft specifications and the independent layout2vector writer. Its current
batch validation is separate from the earlier grouped evidence. Native CoreSVG
painting limitations require intrinsic-resolution gradient PNGs clipped by the
original vector geometry, explicit visible bitmap tiles and separate color
opacity. Semantic gradient definitions alone are not the display paint; this
subset does not provide unlimited-resolution gradient zoom. Tile markup reserves
a bounded aggregate serialized size before expansion, and poorly conditioned
large-offset radial boundaries are refused rather than approximated.

Known unsupported painting returns an error instead of guessed coordinate geometry,
a grey bitmap placeholder or a successful blank image. Record-chain preflight
requires bounded, aligned outer records, complete declared lengths/counts and EOF;
EMF+ comments receive their own framing checks. Decoder failures, malformed output,
external image references, scripts and DTDs are refused. Parent-owned helper timeout,
output limits and cancellation retire the process group before returning.

## Intrinsic size and metadata

EMF follows GDI+ physical frame/device metadata, rather than treating its ink
`bounds` as the image's pixel dimensions. Device pixels/millimetres establish DPI;
frame extents in 0.01 mm establish rounded raster dimensions at that DPI. The frame
origin is mapped to the display origin without rewriting captured records. The
separate `physical-frame.emf` fixture deliberately distinguishes ink bounds from
physical dimensions. This follows GDI+ behavior, also visible in Wine's
`GdipGetMetafileHeaderFromEmf` implementation.

Placeable WMF retains logical raster extent and the header's Inch resolution, as
GDI+ `GdipCreateMetafileFromWmf` does. Standard WMF lacks physical dimensions; the
native renderer uses an explicit window extent and 96 dpi fallback. It refuses
inputs without a usable extent instead of inventing a default 800×600 viewport.

The [region and pattern extension](METAFILE-REGION-PATTERN-PARITY.md) adds bounded
region trees, region fill/clip records, all 53 hatch styles and bitmap texture
brushes. Its own evidence separates newly accepted behavior from this older
checkpoint. The [compressed-path extension](METAFILE-PATH-PARITY.md) adds relative/RLE region
paths and shares validation with drawing, clipping, custom caps and accepted
gradient boundaries. Negative region rectangle extents, singular
region fill transforms and nested-metafile textures remain explicit refusals.

## Explicit remaining format behavior

The [formatted text extension](METAFILE-TEXT-PARITY.md) adds native shaped glyph outlines for DrawString layouts, including direction, tabs, tracking, wrapping and trimming.
The separate [positioned text family](METAFILE-POSITIONED-TEXT-PARITY.md)
connects driver strings, font-specific glyph indices and classic W text advances
to native outlines, with its own checkpoint and font/record limits. This is
useful three-format support, not complete GDI compatibility. Remaining
unsupported features include DisplayFormatControl, locale-specific digit substitution and measured-character-range queries, gradients outside the
[accepted painting subset](METAFILE-PAINTING-PARITY.md),
file-format-only Left/Outset/Right pen alignment, alternate-format/terminal-server
records and source-copy compositing. The [pen extension](METAFILE-PEN-PARITY.md)
adds transformed nibs, compound bands, standard caps, joins, dash styles and
Center/Inset positioning across the nine EMF+ stroke record families.
The [indexed/16-bit bitmap extension](METAFILE-BITMAP-FORMATS-PARITY.md) covers
1/4/8-bit indexed palettes and RGB555/RGB565/ARGB1555 for images and texture
brushes. Extended grayscale and 48/64-bit formats, nested WMF images and uncommon
embedded compressed formats remain open. EMF invert/mask/parallelogram/SetDIBitsToDevice
records, framed regions and triangle gradients are refused. The
[classic clipping extension](METAFILE-CLASSIC-CLIP-PARITY.md) covers all five
GDI region combinations, path clips, rectangle clips, offsets and metaregions. WMF region/flood fill remains open. The connected
[classic Boolean raster extension](METAFILE-RASTER-PARITY.md) covers ROP2 and
ROP3 evaluation with bounded destination/source/pattern playback; unsupported
transfer records, masks and geometry remain explicit refusals. Its grouped
validation is pending independently of earlier metafile checkpoints.
Windows-only fonts can substitute through CoreText. Exact GDI glyph metrics,
text shaping, pen dash/cap combinations, every classic record variant and pixel
identity across all Windows metafiles have not been certified.

The original synthetic corpus is in `Tests/TurtleGitCoreTests/Fixtures/Metafile`;
`MetafileImageTests` covers actual color pixels, transforms/clips, bitmaps, physical
metadata, text preservation, malformed/unsupported outcomes, SVG policy and owned
helper cancellation/deadline cleanup. The [grouped evidence](qa/metafile-workflows-2026-10-18.json)
records actual build/Core/native executions, failed attempts and retained limits.
No complete Finder/signed deployment, physical
image-window acceptance or whole-application parity is implied.

## Independent writer reference

The user-provided [layout2vector](https://github.com/node-projects/layout2vector)
was inspected at `2e0a96b9f87f2a8c0ff649963a67dfccd73bf5bb` (MIT). Its
`src/writers/emf-writer.ts` and `src/writers/emfplus-writer.ts` implement export
writers; no WMF writer or metafile import renderer was found in that revision.
The synthetic writer tests and paint probes provide an independent reference for
font/string-format objects, image source rectangles, clipping and gradients.
They are not shipped as TurtleGit's decoder. Default ImageAttributes objects and
EMF+ gradient brushes exposed the concrete interoperability cases addressed by the
[painting extension](METAFILE-PAINTING-PARITY.md). That document distinguishes the
accepted subset, explicit refusals and pending validation. Existing web-derived
output files have not been copied into the application or fixtures.


## Selected signed-parent acceptance, October 19

[Actual signed runtime evidence](qa/signed-metafile-2026-10-19.json) now covers
the packaged inherited-sandbox helper and native image loader in a disposable
Apple Development AppStore parent. Eight WMF/EMF/EMF+ samples check vector, text,
bitmap, gradient, region, hatch, indexed4 and RGB565 texture output. Malformed
refusal, an actual post-launch deadline, source-byte preservation, private
request-directory removal and owned-process drainage pass. No shipping GUI or
installed Finder workflow was launched. This selected corpus does not establish
all-record graphics fidelity or App Store distribution acceptance.

## Independent decoder reference

The user-provided [BaseHmiTypes renderer](https://github.com/jfk-solutions/BaseHmiTypes/blob/f491a9514f935d64b54bc62ec70606db19f9105a/typescript/base-hmi-types/src/images/converters/metafile-to-svg-renderer.ts)
was inspected at `f491a9514f935d64b54bc62ec70606db19f9105a` (MIT,
copyright 2026 JFK Solutions). Its classic clip masks and metaregion/offset
lifecycle informed the classic clipping extension; its original license is
retained and bundled. It is a self-contained decoder reference, whereas
layout2vector supplies independent export writers. TurtleGit retains its own
framing checks, explicit unsupported-record errors, budgets, native text/bitmap
bridges and affine playback. BaseHmiTypes' EMF+ object reader covers paths and
images; TurtleGit retains its own bounded pen and custom-cap implementation.
