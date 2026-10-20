# EMF+ painting interoperability

This is the painting extension to the [metafile decoder](IMAGE-METAFILE-PARITY.md),
with TortoiseGit pinned at `7338078f8ddd924b8cddee35f512f2286072136d`.
It addresses reusable image attributes, image placement encodings and gradient
brushes within the existing IDiff image panes. It introduces no new image dialog
or repository conversion. Original bytes remain authoritative.

Implementation and validation are separate: the first Core checkpoint exposed
painting failures, followed by focused renderer diagnostics and production
repairs. The final source-pinned runtime and Debug app built successfully; all
18 metafile Core methods and the native consumer group with both Git engines
passed. [Grouped QA evidence](qa/metafile-painting-2026-10-18.json) retains all
failed attempts and the exact scoped results. Earlier [metafile evidence](qa/metafile-workflows-2026-10-18.json)
predates this extension and cannot establish these painting results.

## Independent writer comparison

The user-provided [layout2vector](https://github.com/node-projects/layout2vector/tree/2e0a96b9f87f2a8c0ff649963a67dfccd73bf5bb)
was inspected at `2e0a96b9f87f2a8c0ff649963a67dfccd73bf5bb` under MIT.
It exports EMF and EMF+; it is neither TurtleGit's decoder nor a WMF implementation.
No generated browser/Paint output from that project is adopted as an original
TurtleGit fixture or proof of Windows acceptance.

Its [EMF+ writer](https://github.com/node-projects/layout2vector/blob/2e0a96b9f87f2a8c0ff649963a67dfccd73bf5bb/src/writers/emfplus-writer.ts)
provides concrete interoperability cases:

| Writer implementation | Captured record behavior | Decoder consequence |
| --- | --- | --- |
| Constructor, `buildImageAttributesObject` | A reusable type-8 object in slot 5 contains Clamp wrapping, transparent clamp color and RectClamp. | Defining default attributes must not reject an otherwise renderable image. Drawing must resolve the referenced object and preserve its edge semantics. |
| `emitDrawImagePoints` | Pixel source rectangle, exactly three floating-point destination corners, and an ImageAttributes object reference. | Object references, source cropping, affine destination placement and current graphics transform must work together. |
| `buildLinearGradientBrush` | Linear brush with transform, unit-width rectangle, endpoint colors, Tile wrapping and optional preset stops. | The brush's coordinate system and preset colors must survive parsing and painting. |
| `buildRadialGradientBrush` | Path brush with Clamp wrapping, transformed elliptical Bezier boundary, center color, one surround color and optional preset stops. | A radial approximation cannot silently claim arbitrary path-gradient support; the accepted boundary subset must be explicit. |
| `emitConicGradientFill` | Conic painting is emitted as many colored path wedges. | This is ordinary solid path painting, not a native EMF+ conic-brush format. |

The [classic EMF writer](https://github.com/node-projects/layout2vector/blob/2e0a96b9f87f2a8c0ff649963a67dfccd73bf5bb/src/writers/emf-writer.ts)
and its `scripts/generate-paint-emf-probes.mjs` additionally distinguish
STRETCHDIBITS plus world transforms, clipping, text and compound path fills.
The probe README requests manual Paint observations; its existence alone is not
a successful Paint result.

## Format contracts

Microsoft's [ImageAttributes object specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/9f73a2af-8c9c-4d05-98ab-19a485064364)
defines wrapping, clamp color and rectangle/bitmap clamping. Supporting the
writer's default object does not imply color matrices, gamma adjustment or every
image effect. Reserved fields must not become invented drawing options.

[DrawImage](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/778bfc49-e058-4fb2-b19d-9f801f8e458a)
uses either integer or floating-point destination rectangles.
[DrawImagePoints](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/9bad3867-71b0-46fb-9b90-f7d8fb37ff76)
adds compressed/relative point encodings and maps its three corners to a
parallelogram. Relative points are not interchangeable with fixed-width signed
16-bit coordinates. Source units remain pixels. Record flags must be interpreted
before selecting the point layout; truncation must fail rather than shift the
remaining fields into plausible coordinates.

[Linear gradient data](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/55bba6b0-bb57-4545-93f1-4c64f02b0a80)
and [path gradient data](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/cfe9439a-f2b6-4663-9032-67ce8feea5aa)
have different boundary and optional-data layouts. The
[BrushData flags](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/1ab04f60-1c58-410f-a29e-d725f5eb9b0f)
select transforms, preset colors, blend factors and focus/gamma behavior.
Path-gradient preset/factor positions follow the GDI+ playback API:
[SetInterpolationColors](https://learn.microsoft.com/en-us/windows/win32/api/gdipluspath/nf-gdipluspath-pathgradientbrush-setinterpolationcolors)
and [SetBlend](https://learn.microsoft.com/en-us/windows/win32/api/gdipluspath/nf-gdipluspath-pathgradientbrush-setblend)
run from boundary position 0 to center position 1. SVG radial stops run the other
way, requiring reversal. The generic wire-structure description alone is not
used to invert actual GDI+ playback behavior. This also means accepting a writer's
records does not certify that writer's intended CSS appearance.

## Image attributes and placement subset

The batch implements referenced type-8 ImageAttributes with RectClamp (0).
Wrap values 0–3 emit explicit visible image copies with the correct negative
and reflected tile phase; native SVG pattern tiling is not used. Inverse current
world-transform bounds limit copies to the actual viewport, with caps of 16,384
tiles per record and 65,536 per conversion. Before concatenation, tile markup
reserves `count * (escapedPNGhref.length + 4096)` bytes against an aggregate
64 MiB budget; count limits alone would allow a small bitmap to expand into
multi-gigabyte inline SVG. Clamp (4) paints the requested
ARGB color only outside the source image extent before placing the original
image. Keeping the clamp area separate avoids painting an opaque backing under
translucent source pixels. BitmapClamp (1) remains refused. The absent-attributes
sentinel is `0xffffffff`; an explicit table index must be 0–63 and name a present
ImageAttributes object, rather than an unrelated object type.

Both image records validate pixel source units, bounded nonzero source extents,
record lengths and referenced images. DrawImage supports floating-point and
signed 16-bit destination rectangles. DrawImagePoints supports floating-point,
signed 16-bit and relative signed 7/15-bit point encodings before applying the
current graphics transform and source crop. The relative flag is `0x0800`;
`0x2000` denotes an image-effect route and is refused. Relative image placement
does not imply support for the separate relative path encoding. Source-copy
compositing and image effects remain explicit refusals. Attributes applied to
nested EMF images are refused; the pre-existing nested-EMF route is retained only
with absent attributes. Up to three wire-alignment bytes are ignored, without
treating additional bytes as an extended attributes structure.

## Gradient subset

The local `turtleGitPaint.js` renderer module adds linear and a restricted path
brush through existing shape/text fill resolution. Linear gradients accept
endpoint colors, preset color stops or horizontal blend factors, plus independent
nonsingular affine brush transforms. The gradient axis is horizontal in brush
coordinates; the brush matrix and current graphics transform compose separately.
Wrap values 0/2 repeat, 1/3 reflect, and 4 pad. Vertical factor arrays are bounded
and consumed but do not change painting, matching Microsoft's
[documented Windows GDI+ behavior](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/55111093-ff77-4fb7-9065-c246a07e42c6).
The supported subset requires both reserved endpoint-color fields to duplicate
their corresponding endpoint colors. Microsoft's general structure text says
these fields should be ignored, but its Windows product notes document empty
rendering when **both** duplicates mismatch. The stricter rejection of a single
mismatch is a conservative unsupported-case policy; it is not a claim that
Windows necessarily paints nothing for a single mismatch.

Path gradients are accepted only for a centered, affine image of the canonical
four-cubic ellipse: a 13-point Float32 boundary with the expected point types,
a matching bounded-tolerance center, and uniform boundary ARGB colors. Float32
coordinate precision and canonical-shape tolerance must each fit within 100 parts
per million of the conservative minimum ellipse axis
(`abs(det(U,V)) / hypot(Ux,Uy,Vx,Vy)`); otherwise the brush is refused. The bound
also rejects excessively ill-conditioned axis ratios.
This prevents a huge coordinate offset from admitting visibly noncanonical or
off-center geometry after a later world translation/scale. They
support Clamp wrapping, optional affine brush transform, preset colors and
horizontal blend factors. Positions/factors retain boundary-to-center semantics;
the paint evaluator reverses their sampling orientation. Painting beyond the boundary remains
transparent rather than extending the boundary color across the filled shape.

Stop arrays contain 2–4096 ordered finite positions with endpoints 0 and 1;
duplicate positions remain valid hard transitions. Invalid factors/counts,
conflicting preset/factor flags, singular matrices, unsupported versions and
unexpected object bytes fail. General paths/point boundaries, off-center radial
brushes, poorly conditioned huge-offset ellipse coordinates, nonuniform surround
colors, focus scales, gamma correction and radial tiling remain unsupported. This accepted ellipse subset covers a concrete writer
encoding without approximating arbitrary path-gradient geometry.

## Native display representation and failure repairs

Focused native raster diagnostics demonstrated that CoreSVG ignored gradient
repeat/reflect, shifted gradient colors on PNG round-trip, and tiled bitmap SVG
patterns incorrectly. Those observations required production painting changes;
they were not resolved by removing pixel assertions. A separate native SVG
alpha issue interpreted `rgba(...,1)` as byte alpha 1/255.

Gradient objects retain semantic SVG gradient definitions as metadata, but actual
brush color is evaluated analytically into a bounded PNG through the existing
native `__turtleBitmap` adapter. The original fill geometry remains a vector
clip. Gradient text uses white text in a luminance mask because native SVG clip
text was not honored. Conservative path-control-hull/rectangle/ellipse-arc
bounds receive one pixel of padding; text falls back to the viewport bounds.
Brush/current-matrix/crop caching avoids repeating an identical paint raster.

Each paint raster is limited to 16,777,216 pixels and 64 MiB of raw color data;
generated gradient rasters together are limited to 67,108,864 pixels per
conversion. Wrapped linear gradients use twofold sampling when the per-raster
budget allows it to reduce native upsampling seams. Global alpha is applied to
the placed image. This is an intrinsic-output-resolution display raster, not a
resolution-independent vector gradient or a claim of exact rendering at unlimited
zoom. Reopening/decoding original metafile bytes remains separate from preview
zoom. Solid geometry/text and clipping retain their existing vector route.

The final SVG color pass emits RGB color and explicit opacity instead of relying
on CoreSVG's ambiguous RGBA alpha handling. Clamp color likewise uses separate
opacity. This preserves opaque and translucent source fills/strokes without
changing captured metafile bytes. Unsupported operations continue to fail rather
than presenting a successful incomplete picture.

## Authored verification scope

The original MIT synthetic generator has produced seventeen new EMF files for the
following cases. The generator was rerun for focused fixture corrections after
the failed checkpoint; all eighteen focused Core methods subsequently passed. A subsequent
native clamp-color assertion required the pixel-inspection helper to use an
explicit sRGB byte buffer: `NSBitmapImageRep.colorAt` did not preserve the PNG
profile in that comparison. Color thresholds were retained. This fixture-helper
correction is separate from the production rendering repairs. These
fixtures contain original data rather than copied writer output, images, fonts
or SVGs. Eighteen focused Core methods and two added native consumer samples
are the final focused verification scope:

| Case | Intended assertion |
| --- | --- |
| `plus-gradient-transform.emf` | Three preset colors, independent brush transform and current world transform retain direction and placement. |
| `plus-gradient-wrap.emf` | Tile and TileFlipX preserve distinct stop order across repeated bands. |
| `plus-gradient-radial.emf` | Canonical elliptical path, centered uniform boundary, preset boundary/midpoint/center colors, and independent brush/world translations. |
| `plus-gradient-blend.emf` | Horizontal blend-factor plateaus preserve endpoint colors with a distinct middle blend. |
| `plus-image-attributes.emf` | A real default type-8 object resolves through its referenced table slot. |
| `plus-image-clamp.emf` | Out-of-image clamp color appears while interior image pixels stay unchanged. |
| `plus-image-wrap.emf` | Tile and FlipX differ at negative and positive source boundaries. |
| `plus-image-relative.emf` | Relative `0x0800` points use mixed signed 7/15-bit cumulative deltas, even when the compressed bit is also set. |
| `plus-image-int16.emf` | Signed absolute 16-bit destinations preserve negative coordinates. |
| `plus-alpha-pen.emf` | A real opaque red pen and half-alpha inline red brush retain separate SVG color/opacity and the expected pixel contrast. |
| `unsupported-image-effect.emf`, `unsupported-image-attributes.emf`, `unsupported-image-wrap.emf`, `unsupported-image-attribute-type.emf` | Image effects, BitmapClamp, invalid wrap value and wrong object type fail explicitly. |
| `unsupported-gradient-stops.emf` | Invalid preset data cannot become a successful plausible gradient. |
| `unsupported-image-tile-budget.emf` | A count-valid repeated bitmap must fail its projected serialized-byte budget before constructing excessive SVG. |
| `unsupported-gradient-precision.emf` | Coordinates with excessive Float32/canonical tolerance relative to the ellipse axis must not approximate arbitrary boundaries. |

## Scope and remaining work

The subsets above passed this batch's source reconstruction, focused Core pixel
checks and native consumer checks. These results establish only the recorded
subset and workflows; they do not certify complete Windows graphics parity.

The later [region and pattern extension](METAFILE-REGION-PATTERN-PARITY.md)
addresses region painting and hatch/bitmap texture brushes with separate evidence.
Later [formatted text](METAFILE-TEXT-PARITY.md),
[indexed/16-bit bitmap](METAFILE-BITMAP-FORMATS-PARITY.md) and
[pen stroke](METAFILE-PEN-PARITY.md) and [custom-cap](METAFILE-CUSTOM-CAP-PARITY.md)
extensions have separate evidence. Explicit gaps remain for driver/glyph strings, other raw bitmap
formats, uncommon classic raster operations and Windows font/antialiasing identity. Any newly accepted gradient subset must retain explicit refusals for
its remaining optional fields, malformed boundaries and unsupported painting.
Three older image fixtures now use the explicit `0xffffffff` absent-attributes
sentinel; this preserves their original crop/text/bitmap purpose while separate
fixtures exercise real attributes. Native consumers add transformed gradients
and default attributes to the retained WMF/classic EMF/EMF+ samples.

All helper input/output limits, cancellation, timeouts and native ownership
rules continue to apply; no painting feature grants filesystem or network access.

The [compressed-path continuation](METAFILE-PATH-PARITY.md) now shares the wire
reader for that same accepted ellipse boundary. Short/relative encoding does
not relax the thirteen-point geometry, center or tolerance rules above.
