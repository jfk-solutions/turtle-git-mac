# Compressed raster sources in Windows metafiles

This family extends the existing image, texture and classic transfer consumers;
it does not replace the original metafile bytes or add a viewer command.
Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`
`src/Utils/MiscUI/Picture.cpp` delegates Windows metafile display to GDI+.
The native decoder must interpret the corresponding serialized image records.

## Containers and shared consumers

Microsoft's [EmfPlusCompressedImage object](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/9c00912b-adfa-469e-8baa-82d9d3d8d6ae)
defines EXIF, GIF, JPEG, PNG and TIFF compressed image data. EXIF is JPEG metadata,
not a separate invented raster signature. Ordinary ImageObjects and images inside
texture brushes now share one format detector. Pen brushes use the same texture
reader; they do not have a separate reduced codec list. The native ImageIO
boundary independently restricts the actual decoded container type to these four
raster formats, validates complete input, dimensions and decoded pixel storage,
and emits a private PNG display receipt. Arbitrary ImageIO codecs cannot enter
through this bridge simply by masquerading as a supported signature.

The existing DrawImage/DrawImagePoints path retains its literal source crop,
reflected/affine destination, clip, image attributes and ordered SourceOver or
SourceCopy geometry. Texture wrapping, brush transforms, transparent samples,
pen outlines and native text brush consumers retain the same shared paths as raw
bitmap textures. Alpha belongs to image pixels, independently of geometric
coverage. Decoding does not flatten transparent GIF/TIFF pixels over a background.

The bounded [Windows reference](qa/metafile-compressed-windows-reference-2026-10-24.json)
confirms first-page TIFF and ignored TIFF/JPEG orientation6 metadata. GIFs with
any nonzero graphics-control delay or an explicit NETSCAPE2.0 loop block are
exposed as animation by GDI+, and serialized playback defaults to their first
frame. An untimed GIF without that loop block is a static final composite.
The native adapter classifies those original control records, because ImageIO
clamps zero delays and supplies a default loop count. GIF extension/subblock
bounds are checked; unknown application extensions are ignored rather than
inventing an animation flag. Embedded images do not start a new animation timer.

For static GIFs, ImageIO's final-index decode supplies the complete logical canvas,
including earlier delta rectangles, transparency and disposal. A focused codec
probe independently confirmed full-canvas retention for the original transparent
delta fixture before this implementation was selected. Source bytes, frame count
and alpha are retained independently of those display pixels. Other application
extension conventions and complete Windows codec identity are not certified.

## Classic compressed stretched transfers

[EMR_STRETCHDIBITS](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/89c0d808-0dea-413f-be40-2e9e51fa36ac)
and [META_STRETCHDIB](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wmf/7ebae08d-61ee-4d82-9aa5-9217ba2aa8c1)
permit JPEG/PNG DIB payloads. The [StretchDIBits contract](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-stretchdibits)
requires DIB_RGB_COLORS and SRCCOPY for these compressed operands. The reader
retains those restrictions rather than accepting arbitrary Boolean raster
operations, indexed color usage, top-down compressed DIBs, AlphaBlend masks or compressed pattern brushes.
The header's compression must agree with the encoded payload, bit count must be
zero, and byte counts, offset ranges and decoded dimensions must agree.

Classic compressed transfers use the existing opaque-color decoder: alpha is
removed while retaining the represented RGB samples. They do not perform EMF+
alpha blending. Decoded RGBA bytes feed the existing final-device pixel-center
sampler, so stretched/mirrored/cropped operands remain opaque under independent
coverage and destination clipping. This extends the compressed direct-scanline
family; direct scanline band rules and device-sized placement remain distinct.
No source rotation/shear capability or printer-device pixel identity is claimed.

## Bounds and ownership

Each decoded raster is limited to 32,768 per axis and 16,777,216 pixels, and each
container to 512 frames/pages. Compressed images reserve from the same cumulative
67,108,864-pixel native expansion budget as raw images before decompression.
A static GIF's dependency frames each reserve a full logical canvas before the
final composited decode; TIFF pages and animation frames that are not selected
are not decompressed. GIF subblocks/JPEG markers/PNG chunks and classic TIFF IFD,
strip/tile/Exif ranges have independent bounded envelope validation. Up to three
zero alignment bytes after the container are accepted; arbitrary appended data
and truncated referenced data are refused. BigTIFF is outside this classic TIFF
profile. Existing input, markup, output,
record, recursion, raster compositor and process-deadline limits remain shared.
Malformed containers, mismatched source dimensions and unsupported classic
operations refuse the entire conversion, including earlier painted records.
The helper receives captured bytes, not user-controlled file or network paths;
ImageIO decoding stays inside the existing owned helper process. Cancellation
terminates and drains that process through the existing decoder lifetime.

## Original fixtures and checkpoint

`generate-compressed-raster.py` authors compressed image/texture/pen records,
raw BGRA controls, crop/affine/clip/wrap/attributes and alpha replacement cases,
classic JPEG/PNG stretched/cropped/mirrored transfers, and malformed/budget
refusals. Encoded GIF/TIFF structures and all geometry are original; macOS sips
encodes the original four-color JPEG. Existing 1,334 metafile/PNG payloads remain
unchanged. The native `--only compressed-raster` group reuses the receiver cache
and actual Compare/Open/drop/conflict flows with private repositories,
preferences, original-byte assertions, delayed decoder retirement and owned
window/process cleanup.

The authored corpus contains 110 accepted metafiles, 21 refusals and 14 original
compressed source containers. Twelve focused Core methods and the cached native
`--only compressed-raster` case are prepared for the grouped checkpoint. Windows
reference runs distinguish real container support, Object DataSize alignment,
default frames, alpha, and orientation; classic compressed stretched transfers
were not painted by that Windows display target. Their decoding is an explicit
portable native profile for the documented serialized records, rather than a
claim that every Windows display/printer driver supports JPEG/PNG pass-through.
The universal helper builds and validates on both architectures; the Debug app
build passes. All twelve compressed-raster Core methods pass. Both system/bundled
Git native compressed-raster cases pass, including actual independent Compare
pixels, Open, malformed refusal, preview replacement, three-stage conflict
selection and decoder/grant/late-result/Quit ownership. Receivers 91437 and 91655
were reaped and no owned receiver/metafile helper remained. The first native
attempt (91082, also reaped) exposed a fixture-only legacy filename heuristic
before conflict setup: the new names do not contain “plus.” The focused repair
uses checked, explicit WMF/classic-EMF/EMF+ samples and retains every conflict
assertion. Only those two affected native pairs were repeated; Core/helper/app
checks were not rerun for that fixture repair. The isolated ImageIO capability
probe resolved the static GIF compositor architecture before this grouped
checkpoint; it was not counted as a workflow test. Signed deployment, physical
Finder, complete Windows font/device identity and every metafile record remain
separate acceptance requirements.
