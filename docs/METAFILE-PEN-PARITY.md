# EMF+ pen strokes

TortoiseIDiff delegates metafile playback to Windows GDI+. TurtleGit renders
captured WMF/EMF bytes through its private helper and displays the result in the
same native image panes. This extension supplies the connected EMF+ pen object
and stroke family; it does not change original repository bytes or conflict-side
selection.

## Source contracts

The binary layout follows Microsoft's [EmfPlusPen object](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/7af4bee7-b3e0-47c5-9678-ffcbb234e378),
[PenData](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/33d8ced5-7768-47aa-a082-a14e5dfabc96),
[compound line array](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/9b1387ba-6008-435b-9d13-878323083130)
and [embedded brush](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/79c653fb-bf01-4f87-8bd2-eac1de71e140).
The brush contains its own GraphicsVersion before its brush type and payload,
as shown in Microsoft's [pen record example](https://learn.microsoft.com/is-is/openspecs/windows_protocols/ms-emfplus/5de09d5b-25ad-491d-a7cb-b53ca49a309e).
The older synthetic alpha-pen fixture omitted this nested version; its framing is
corrected while retaining its alpha/color expectations.

[Pen::SetTransform](https://learn.microsoft.com/en-us/windows/win32/api/gdipluspen/nf-gdipluspen-pen-settransform)
transforms the pen nib independently of the centerline and ignores translation.
[SetCompoundArray](https://learn.microsoft.com/en-us/windows/win32/api/gdipluspen/nf-gdipluspen-pen-setcompoundarray)
requires an ordered positive even array of fractions between zero and one.
[SetAlignment](https://learn.microsoft.com/en-us/windows/win32/api/gdipluspen/nf-gdipluspen-pen-setalignment)
disallows inset compound strokes and inset triangular dash caps. The
[LineJoin enumeration](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusenums/ne-gdiplusenums-linejoin)
distinguishes Miter (limit clipping) from MiterClipped (bevel fallback); their
names must not be mapped directly to CoreGraphics' single miter style.

The user-provided [layout2vector writer](https://github.com/node-projects/layout2vector)
provides an independent object writer reference. The
[BaseHmiTypes renderer](https://github.com/jfk-solutions/BaseHmiTypes/blob/f491a9514f935d64b54bc62ec70606db19f9105a/typescript/base-hmi-types/src/images/converters/metafile-to-svg-renderer.ts)
remains the reference for the previously adapted classic clipping lifecycle,
whose retained license and source pin accompany the helper. Neither package is
installed as a runtime dependency. The pen geometry implementation uses system
CoreGraphics and bounded local geometry construction.

## Implementation and acceptance

`src/turtleGitPens.js` in the reconstruction patch parses the complete pen
header and embedded brush, retaining linear nib transforms, independent standard
start/end caps and anchors, four joins, miter limits, predefined/custom dashes,
dash offsets and flat/round/triangular dash caps. Center/inset positioning and
ordered compound bands feed the same native outline bridge. Custom dash patterns
may have odd counts; their repeated pattern retains alternating on/off lengths.
World-unit width stays in world coordinates; physical/pixel units are converted
to the current page units before applying the outer page/world transform.

All nine stroke record families use this bridge: DrawLines, DrawRectangles,
DrawEllipse, DrawPie, DrawArc, DrawPath, DrawClosedCurve, DrawCurve and DrawBeziers.
Compressed coordinates are decoded where defined. DrawLines, DrawBeziers and
DrawClosedCurve also accept relative integer coordinates; closed curves require
at least three points. DrawCurve honors its starting offset and
segment count while retaining neighboring points for cardinal-spline tangents.
Arc/Pie sweep is bounded to a full turn while preserving the original start
angle. Legal alignment padding is ignored.

Pen brush painting reuses the existing solid, gradient, hatch and texture
pipeline, using actual outline bounds. The stroke receipt is cleared after each
record, including exceptions, so a later classic GDI stroke cannot inherit an
EMF+ pen. World/page transforms and captured clipping belong to the record
playback lifecycle; a pen transform must not apply either a second time or move
the centerline.

`NativeStrokeGeometry` receives only generated path commands and the captured
pen options. Nonzero widths transform the centerline into nib space, construct
stroke outlines and transform those outlines back; zero-width hairlines are
constructed at one device pixel. Curves use bounded adaptive flattening, including
collinear backtracking, before offset strips, joins, caps and compound bands are
constructed. CoreGraphics normalizes the union of these primitives. Closed inset
strokes intersect widened outlines with the original closed figure, while dash
spacing continues to use the original width. Open inset paths remain centered.
The target flattening error is 0.05 device pixel under the captured affine scale.

Native construction is limited across each conversion to 1,048,576 flattened
points, 32,768 primitive polygons, 131,072 outline points before normalization
and 32 MiB of outline markup. Each native input path is limited to 2 MiB and
262,144 generated commands; each normalized result to 131,072 serialized points.
Arcs permit at most 65,536 subdivisions and cubic recursion stops at depth 24.
The native 2 MiB path limit is stricter than the JavaScript bridge's 8 MiB guard.
These limits bound construction before native Boolean normalization.

Binary construction limits include 64 object slots, 65,536 points per record,
4,096 rectangles per record, 1,048,576 aggregate stroke points, 1,024 custom dash
entries and 1,024 compound fractions. Pen width and converted width cannot exceed
65,536; miter limits are between one and 65,536. The JavaScript bridge bounds individual native output paths to 32 MiB,
with finite bounds no larger than
1,000,000,000 coordinate units. These limits reject oversized input explicitly;
they do not silently simplify a drawing.

## Verification

The [batch checkpoint](qa/metafile-pen-2026-10-19.json) records 89 accepted and
55 refused fixtures, seven new Core methods, all executed attempts and their
limits. The pixel oracles examine every pixel away from independently defined
antialias boundaries, using signed-distance shapes and separate brush-fill
controls. They include transformed and reversed bands, miter clipping, ordinary
and dash caps, inset dash spacing, world/physical units, device hairlines,
compressed/relative records, cardinal segment selection and backtracking cubics.
A thin-band fixture was strengthened to keep real interior pixels after its
antialias exclusion; assertions were retained.

The initial 50-method metafile group exposed compound-corner gap overpainting and
a stationary-tangent curve subdivision failure. Offset-intersection trimming and
analytic derivative-root splitting repair those cases. Only the two affected
methods were repeated after the repair, and both passed; the other 48 initial
passes are retained. The checkpoint separates this local arm64 corpus from the
universal validator's generic WMF conversion/rejection checks on both slices.

The Debug app build and both system/bundled-Git native consumer runs passed.
The consumer group uses 39 representative images, including six new pen samples,
through actual image panes and retains original bytes, explicit Merge routing,
preview/reload, conflict-stage selection and cancellation/late-result ownership
checks. Both owned receiver processes were reaped and independently absent.
These unbundled Debug receivers use the development helper; the prepared,
packaged and current helper source identities were separately checked for equality.
This is distinct from signed-parent execution or physical Finder acceptance.

## Remaining compatibility

Custom line-cap objects remain a separate object family. The file-format-only
Left, Outset and Right alignments are explicitly unsupported; the public GDI+
Pen API exposes Center and Inset. Unknown enums and malformed optional arrays
are refused. Inset with compound bands or triangular dash caps is refused as an
invalid API combination. This extension does not
finish classic EMF/WMF extended pen variants, unsupported raster operations,
driver/glyph text, alternate record formats or Windows font substitution. The
existing anti-alias, pixel-offset and compositing-quality records do not select
GDI+ rasterization quality or its pixel grid. Standard anchor dimensions are
compared with the [Wine GDI+ implementation](https://github.com/wine-mirror/wine/blob/master/dlls/gdiplus/graphics.c) policy; a Windows capture oracle is still
needed to certify their exact metrics. Windows
pixel certification, every pathological self-intersection, platform edge
antialiasing, minimum-OS execution, physical Finder acceptance and signed release
acceptance require their own evidence. Successful source parsing or SVG emission
alone does not establish correct native painting or complete TortoiseGit parity.
