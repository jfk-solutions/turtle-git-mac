# Classic WMF/EMF Boolean raster operations

This family extends the private metafile display decoder used by Image Compare
and image-conflict panes. Pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d` loads these formats through Windows
GDI+ in `src/Utils/MiscUI/Picture.cpp::Load`; its renderer has a device context
with existing destination pixels. SVG blend modes do not reproduce GDI's
bytewise Boolean operations. TurtleGit therefore combines captured drawing,
source, brush and independent geometric coverage in a bounded native raster
adapter. Repository bytes remain the comparison and Save inputs.

## Operation contract

The operation evaluator covers every Boolean function of the relevant operands:
16 ROP2 functions of pen/brush and destination, and 256 ROP3 functions of pattern,
source and destination. It does not replace this space with a common-operation
whitelist. The ROP3 truth byte comes from bits 16–23 of the record's operation
code. For each RGB bit the truth-table index is `(P << 2) | (S << 1) | D`.
ROP2 uses the corresponding two-input table for modes 1–16. Operand-dependency
checks distinguish an unused source from a missing required source. A PATBLT
record cannot supply a source rectangle and rejects source-dependent functions.

The canvas starts with a white destination backdrop. A later operation observes
all earlier painting in record order, including ordinary vector/text drawing
between Boolean operations. Coverage is a separate operand: a source's color or
alpha cannot silently replace the rectangle/path and clip that determine where
BLACKNESS, destination inversion or another operation applies. Boolean RGB
calculation is separate from edge coverage. This is intrinsic-resolution playback;
it does not promise vector-resolution zoom after a raster checkpoint or Windows
pixel identity at antialiased boundaries.

Selected brush and ROP2 state follow SaveDC/RestoreDC with mapping and clipping;
created GDI objects retain their lifetime outside a saved state. Captured clipping
and destination transforms constrain the operation. Source crop, signed extents
and supported source mapping are validated together rather than ignoring source
coordinates and stretching a complete bitmap into the destination. A required
source rectangle must fit completely inside the decoded DIB. Source transforms
accept scale and translation; rotation and shear remain refused when a source
operand is required. Unused source transforms do not invalidate a source-independent
operation. Classic CreatePen strokes retain their declared logical width; the
one-pixel ExtCreatePen cosmetic restriction does not apply to these pens.

The connected record scope is WMF DIBBITBLT, DIBSTRETCHBLT, STRETCHDIB and PATBLT,
and EMF BITBLT, STRETCHBLT and STRETCHDIBITS, together with classic SetROP2
painting. Pattern operands cover solid and hollow brushes, six classic GDI
hatches, selected stock brushes and embedded device-independent bitmap patterns.
Hatch phase and brush origins stay in device pixels. Opaque hatch gaps use the
captured background color; transparent gaps retain holes for ROP2 painting. ROP3 transfers retain their
independent rectangular coverage and refuse transparent required pattern pixels;
a hollow brush cannot provide a required pattern operand. Acceptance still depends on valid embedded bitmap data, representable
geometry, supported brush data and available operands. All 256 truth functions in
the evaluator does not mean that every Windows bitmap-transfer record is accepted.

## Bounded native boundary and ownership

`Sources/TurtleGitMetafile/main.swift` rasterizes only renderer-generated SVG
operands after a separate SVG policy check. Documents cannot supply executable
SVG, external image URLs or document-controlled filesystem/network requests.
The helper evaluates RGB bytes and emits an embedded PNG checkpoint for later
painting. Unsupported input returns a conversion error, preserving the existing
image-loader failure path instead of returning a successful partial picture.

The native boundary limits a surface to 32,768 pixels per dimension and
16,777,216 pixels; work to 4,096 calls, 33,554,432 cumulative composite pixels and
67,108,864 cumulative operand-render pixels; an individual SVG operand to 16 MiB
and cumulative operand markup to 64 MiB. A per-operation working-buffer estimate
must fit 256 MiB. Brush storage is bounded by 64 MiB of decoded bitmap
patterns, pattern expansion by 67,108,864 cumulative pixels and generated brush
definitions by 16 MiB. These are rejection limits, not a promise that every input at a
limit succeeds. Existing 64 MiB input, 128 MiB output, helper deadline and private
request-directory rules remain in effect. Cancellation retires and waits for the
owned helper process before releasing captured inputs and grants. The Boolean
adapter adds no independent app, persistent worker or document mutation.

## Explicit limits

Source rotation/shear for bitmap transfers, device-dependent WMF bitmap variants,
unsupported bitmap encodings and unsupported pattern-brush variants remain errors.
The connected classic EMF masked/transparent extension below covers its own
record and operand requirements. The classic DIB path accepts bounded RGB, RLE4/RLE8,
indexed palettes, bitfields and core headers; JPEG/PNG-compressed DIB layouts,
embedded/external bitmap profiles and device-dependent bitmap layouts remain
unsupported. Dynamic DC_BRUSH/DC_PEN color state, monochrome
creation variants and obsolete device-dependent brush records remain unsupported.
In the ROP3 record family, any nonzero high byte in an operation code is refused, including
flags that request operating-system screen capture or alter mirroring. Such flags
are not interchangeable with a Boolean truth byte. MASKBLT's separate ROP4
layout uses that byte as its background truth table, as described below.
The connected [classic region/flood family](METAFILE-CLASSIC-REGION-FLOOD-PARITY.md)
uses this raster boundary for region fills/frames/inversion and destination-aware
border/surface flood coverage; its guide records the separate acceptance scope.
Other separately refused visible record families remain outside this extension.
EMF+ compositing, including SourceCopy, is a
separate graphics model and is not enabled by classic GDI ROP support. Hardware
palette realization and exact Windows edge/font/device behavior remain open.

The [bitmap-format](METAFILE-BITMAP-FORMATS-PARITY.md),
[classic clipping](METAFILE-CLASSIC-CLIP-PARITY.md) and
[painting](METAFILE-PAINTING-PARITY.md) guides retain their own accepted subsets.
This family does not establish complete metafile compatibility, physical image
window acceptance or signed distribution acceptance for the new compositor.

## Primary references and verification boundary

- [Microsoft binary raster operations](https://learn.microsoft.com/en-us/windows/win32/gdi/binary-raster-operations)
  and [SetROP2](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setrop2)
  define the two-operand operation family.
- [Microsoft ternary raster operations](https://learn.microsoft.com/en-us/windows/win32/gdi/ternary-raster-operations)
  defines the source/pattern/destination truth-table family.
- [BitBlt](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-bitblt)
  distinguishes destination clipping, source transforms and transfer flags.
- [CreatePen](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createpen)
  defines classic logical widths and wide dashed-pen fallback to solid.
- [PatBlt](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-patblt)
  excludes operations that require a source rectangle.

The Boolean adapter is original TurtleGit code, based on these documented
semantics and the existing pinned WmfEmfViewer parser; it introduces no copied
third-party implementation. Existing renderer, Wine hatch-table and BaseHmiTypes
clipping notices and pinned hashes remain intact.

The connected native runner is
`scripts/test-metafile-raster.py`, with comparison-consumer and conflict cases
using private inputs and both Git engines. The independent output
check evaluates Boolean predicates against decoded native pixels, including all
truth functions, independent coverage, preceding destination paint, source crop,
state restoration, transformed clipping, malformed/missing operands and owned
cancellation. Serialized SVG or a successful helper exit alone cannot prove the
Boolean pixel result. Earlier metafile and signed-parent evidence does not certify
this new adapter.

The [batch evidence](qa/metafile-raster-family-2026-10-20.json) records actual
execution and repairs; the operation-space counts above are not a port-completion
percentage or evidence of full Windows visual parity.


## Classic EMF masked and transparent transfer family

The extension adds EMR_MASKBLT, EMR_PLGBLT, EMR_TRANSPARENTBLT and EMR_ALPHABLEND
to the existing ordered destination canvas. These are classic EMF records;
ordinary WMF DIB/ROP operations retain their existing contract. Original EMF bytes
remain comparison, conflict and Save inputs.

| Record | Operation |
| --- | --- |
| MASKBLT | A monochrome mask selects the foreground or background ROP3 truth byte; each supports all 256 functions |
| PLGBLT | Source pixels map to the destination parallelogram, with optional monochrome masking |
| TRANSPARENTBLT | Exact RGB color-key pixels retain the previous destination; other pixels copy through the captured geometry |
| ALPHABLEND | Constant and per-pixel premultiplied source-over blending use the captured source and destination |

Mask selection uses source bits rather than palette colors. Coverage and mask
selection remain separate: the selector chooses a Boolean operation, while the
captured geometry/clip determines where it applies. An absent MASKBLT mask uses
its foreground operation. Alpha blending uses its constant factor and per-pixel
alpha without applying geometric edge coverage twice. Transparent color-key
copies and alpha blends have distinct semantics.

For these four records, source and mask operands use bounded device-canvas
planes sampled at pixel centers through the inverse destination mapping. The
source rectangle is validated before nearest sampling; edge samples clamp to
that rectangle. Geometry and the captured DC clip apply through the separate
coverage operand once. This avoids multiplying native SVG image-edge and
rectangle-edge antialiasing, while retaining explicit errors for missing or
unsupported required operands.

The same bounded SVG/native raster boundary, cumulative work and memory limits,
private helper lifetime and original-byte preservation cover these records.
This remains intrinsic-resolution rendering with separately documented Windows
edge/font/device limits. Complete EMF+/GDI compatibility, physical signed
acceptance and every Windows graphics record are not established by this family.

Primary record references are Microsoft's
[MASKBLT](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/e6f715c0-d034-4eb3-952e-f8ee66adb9ed),
[PLGBLT](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/b6c8b39d-42c7-4221-ab70-93f1e09b644e),
[TRANSPARENTBLT](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/aa216051-2dc0-4317-b343-525431cfa103)
and [ALPHABLEND](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/34e07d4f-aee6-4b63-a4bb-96996ad47669).
The AlphaBlend record's BlendFlags field is ignored as specified by MS-EMF;
the blending operation and alpha format retain their defined constraints.
[Batch evidence](qa/metafile-masked-transfers-family-2026-10-20.json) records actual
executed checks and failures. The grouped native entry point is
`scripts/test-metafile-masked-transfers.py`.
