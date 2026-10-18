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
0.6-em estimate. Simple StringFormat alignment, line alignment and wrapping are
implemented; complex text layouts are refused explicitly. Solid pen caps, joins,
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

## Explicit remaining format behavior

This is useful three-format support, not complete GDI compatibility. Remaining
unsupported features include EMF+ region objects/fills, driver/glyph strings,
vertical/RTL/tab/trimming StringFormat layouts, custom text tracking, relative
compressed path encodings, non-solid brushes, transformed/compound/custom-cap
pens, alternate-format/terminal-server records and source-copy compositing.
Indexed and 16-bit raw EMF+ bitmap formats, nested WMF images and uncommon embedded
compressed formats remain open. EMF invert/mask/parallelogram/SetDIBitsToDevice
records, framed regions, triangle gradients and non-Copy/And region combinations
are refused. WMF region/flood fill and non-copy raster operations remain open.
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
EMF+ gradient brushes expose concrete remaining interoperability work; existing
web-derived output files have not been copied into the application or fixtures.
