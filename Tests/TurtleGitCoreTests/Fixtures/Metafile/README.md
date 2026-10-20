# Original synthetic Windows metafiles

These fixtures and `generate.py` are original TurtleGit test data, licensed under
MIT. They contain no copied image/font payloads. The generator follows Microsoft
[MS-EMF](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/),
[MS-EMFPLUS](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/)
and [MS-WMF](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wmf/)
record structures, independently of renderer output. No runtime conversion is
needed to regenerate the corpus.

Successful inputs:

- `classic-vector.emf`: red rectangle and blue filled path, 96×64 at 96 dpi.
- `classic-bitmap.emf`: top-down 2×2 red/green/blue/white DIB stretched to 32×32.
- `physical-frame.emf`: same device-coordinate drawing, 96×64 ink bounds but
  physical frame twice as large; GDI+ dimensions are 192×128 at 96 dpi.
- `plus-transform.emf`: indexed graphics Save/Restore, translation and device-fixed
  clip; a later blue rectangle must not inherit the red rectangle's transform.
- `plus-path-container.emf`: filled path under container mapping and restored state.
- `plus-continued-bitmap.emf`: two flagged image fragments assemble before decoding.
- `plus-matrix-order.emf`: noncommuting scale/translation distinguish Append and Prepend.
- `plus-dual-getdc.emf`: red EMF+ versus green fallback, then explicit blue GetDC drawing.
- `plus-bitmap-text.emf`: raw BGRA image and original Helvetica face/text.
- `plus-compressed-crop.emf`: compressed PNG with zero ignored bitmap dimensions,
  source crop and a three-point destination parallelogram.
- `clip-vector.wmf`: placeable WMF, red brush and intersection clip, 96×64/96 dpi.
- `clip-144dpi.wmf`: same logical raster extent with 144 dpi physical metadata.

`unsupported-region.emf` and `unsupported-rop.emf` intentionally request unsupported
painting. They must fail explicitly, not produce a successful empty/approximate image.

Painting and image placement corpus (original deterministic data):

- `plus-gradient-transform.emf`: red/green/blue preset stops with a separate brush
  rotation/scale/translation and world translation. The painted rectangle lands
  at x48–72/y8–56; normalized horizontal-axis fractions independently determine
  red near (70,10), green at (60,32), blue near (49,54), and white at (44,30).
- `plus-gradient-wrap.emf`: Tile and TileFlipX in separate world-translated bands.
  At the same second-period fraction, (24,20) restarts red and (24,52) reflects
  blue. These expected colors are derived from stop order, not renderer output.
- `plus-image-attributes.emf`: a real ImageAttributes object ID3 in the default
  layout2vector writer form, applied to an original 2×2 RGBA PNG.
- `plus-image-clamp.emf`: magenta ClampColor outside both source-image sides;
  original red and green source-pixel centers remain unchanged inside.
- `plus-image-wrap.emf`: Tile and TileFlipX across negative and positive source
  bounds. Pixel centers at x8+16n independently determine the repeat/flip order.
- `plus-image-relative.emf`: P=0x0800, with C deliberately also set (ignored when
  P is set). Cumulative deltas (160,8), (-128,0), (128,32) exercise signed 7- and
  15-bit coordinates and a world matrix. Red/green/blue pixel centers land at
  (68,20), (36,20), (68,36).
- `plus-image-int16.emf`: C=0x4000 without P, signed absolute points including an
  initial x=-16; translation gives independent red/green/blue sample centers.

The optional image-attributes sentinel in old and new fixtures is `0xffffffff`.
An ID0 reference would incorrectly point at our image object rather than optional
attributes. This corpus corrects that previously permissive synthetic encoding.

Additional intentional refusal cases cover E=0x2000 (image effects, not relative
points), BitmapClamp1, invalid wrap5, wrong-type attributes, and malformed preset
stop order. They must not be rendered as successful approximate/blank images.
The wire flag definitions and integer encoding come from independent Microsoft
[DrawImagePoints](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/9bad3867-71b0-46fb-9b90-f7d8fb37ff76),
[PointR](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/c861a0d4-39f0-4f6c-bad9-e3f7bf63205e),
[Integer7](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/c2b45b77-c9ce-4b2e-8ede-ff5e90ec7f1b),
[Integer15](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/c5478039-f448-422e-ba0b-ff5eddcada8e),
and [LinearGradientBrushData](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/55bba6b0-bb57-4545-93f1-4c64f02b0a80)
structures. The author-provided layout2vector repository informed producer shape
compatibility; no generated vector/image outputs were copied into these fixtures.

- `plus-gradient-radial.emf`: a canonical four-Bezier elliptical boundary with
  separate brush/world translations, uniform boundary color, and three preset
  colors with explicit endpoint plateaus (blue through boundary fraction0.1,
  red from0.9 to center1). GDI+ preset positions run boundary0 to center1.
  Device center(54.5,38.5) aligns with pixel(54,38), which is pure red;
  pixel(66,38) samples half-radius green, and pixel(76,38) lies in the blue
  plateau. This avoids near-stop interpolation/color-space assumptions. It follows
  [SetInterpolationColors](https://learn.microsoft.com/en-us/windows/win32/api/gdipluspath/nf-gdipluspath-pathgradientbrush-setinterpolationcolors),
  independently of the producer's CSS-style stop ordering.

- `plus-gradient-blend.emf`: horizontal blend factors (ending-color weights),
  retaining pure red/blue plateaus and a symmetric red/blue midpoint. This tests
  the distinct BlendFactorsH representation rather than only preset colors.

- `plus-alpha-pen.emf`: real type2 Pen object with an opaque red width4 line,
  followed by an inline half-alpha red rectangle on white. Pixel and SVG checks
  require an opaque pen plus visible source-alpha blending, preserving separate
  `stroke-opacity`/`fill-opacity` rather than CoreSVG's ambiguous rgba alpha.

- `unsupported-image-tile-budget.emf`: deterministic original noisy128×128 RGBA
  PNG, tiled100×100 (10000tiles, below the count limit) over a source rectangle
  mapped to96×64. Duplicated serialized image payload exceeds64MiB and must be
  rejected before concatenating the oversized SVG.
- `unsupported-gradient-precision.emf`: an ellipse near coordinate900000000,
  radius1024, with one Bezier control shifted256 units. A world scale of0.03
  makes that distortion7.68pixels; accepting it with a coordinate-magnitude
  tolerance would visibly misrender it. Float32 precision relative to the small
  ellipse axis must instead force an explicit unsupported result.

Core color samples normalize the actual CGImage into a named sRGB8-bit buffer.
This avoids NSBitmapImageRep.colorAt's generic-calibrated NSColor interpretation
changing pure tagged-sRGB magenta. All original pixel thresholds remain intact.

Raw bitmap batch (original generator inputs, no upstream picture bytes):

- `plus-raw-indexed{1,4,8}-{positive,negative}.emf` use odd widths, deliberately
  nonzero unused bits/nibbles and row padding, and distinct top/bottom rows.
  One-bit values are MSB-first; four-bit values use the high nibble first.
  Eight-bit uses index200 in a201-entry palette; padding255 must be ignored.
- `plus-raw-indexed-alpha{,-unflagged}.emf` retain half/zero-alpha ARGB entries
  with and without HasAlpha metadata. GrayScale2 and Halftone4 have separate
  valid fixtures. GrayScale on non-gray colors is explicitly refused.
- `plus-raw-{rgb555,rgb565,argb1555}-{positive,negative}.emf` use little-endian
  packed channels and padded rows. RGB555 deliberately sets its ignored top bit;
  ARGB1555 distinguishes transparent and opaque colors. `*-mid.emf` samples
  nonendpoint channel values independently of the implementation.
- `plus-raw-rgb24-*` retain sufficient unaligned stride9, and `rgb32-*` ignore
  their unused high bytes. Straight `argb32-*` and premultiplied `pargb32-*`
  encode the same half-alpha red and transparent/opaque controls in both orders.
- `plus-raw-texture-*` paint the same source pixels through native texture
  brushes with a single clamped tile, making the image/texture paths comparable.
- `unsupported-raw-*` have complete outer record chains and isolate unknown
  palette flags, bad grayscale metadata/counts/indices, truncated palette or
  pixels, insufficient/unaligned/extreme stride, extra payload and huge dimensions.
  Representative malformed indexed/16-bit objects also appear in texture brushes.

Primary specifications: [EmfPlusBitmap](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/112a5e2c-6bb3-4daf-8ee3-0f3d3984410f),
[BitmapData](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/c236db12-fc5d-4e5b-8266-0468881cd940),
[PixelFormat](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/47cbe48e-d13c-450b-8a23-6aa95488428e),
[PaletteStyle flags](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/fbdf8835-4deb-481e-b246-15cebbb18710),
and Microsoft's [signed image stride explanation](https://learn.microsoft.com/en-us/windows/win32/medfound/image-stride).

The six `*-plateau.emf` alpha companions use uniform8×8 source texels. Original
mixed fixtures remain intact. Their emitted embedded PNG first texel is checked
as straight RGBA255/0/0/128. Plateau interiors are compared within1/255 to an
independent plainCSS SVG white background plus red fill-opacity128/255, containing
no metafile or bitmap. Initial mixed-cell interpolation suspicion was disproved:
uniform bitmap and plainCSS both produced255/147/141 on this Mac. Native SVG
color handling makes literal displayed sRGB0.5 an invalid oracle for that alpha;
the exact decoded alpha and independent native source-over comparison cover both
stages without loosening their expected color/alpha relationship.


## Formatted EMF+ text

`plus-formatted-*` are original Microsoft-record constructions for native glyph
outlines, tabs/first-tab offsets, tracking, mixed Hebrew/numeric bidi, clockwise
vertical Latin, wrapping and line alignment, clipping/LineLimit, trimming,
hotkey markers, underline/strikeout, supplementary Unicode and missing glyphs.
Gradient/world/clip companions retain the independently measured baseline ink
mask; the device clip is captured before the later translation.
`unsupported-formatted-*` isolate bad object arrays, enum/flag values, counts,
nonfinite metrics and unpaired UTF-16. No font/glyph outline or upstream image is
embedded in these input files. Final-pixel assertions are independent of the
native layout bridge and keep platform font limitations explicit. See
[formatted text scope](../../../../docs/METAFILE-TEXT-PARITY.md).

## Classic EMF clipping and metaregions

`classic-clip-*` are original synthetic GDI records for all five
EXTSELECTCLIPRGN and SELECTCLIPPATH combinations, including an independent
384-point final native pixel oracle per image. Overlapping rectangles distinguish
AND, OR, XOR, DIFF and COPY; default/infinite selection, empty regions, zero-area
rectangles and null COPY retain different outcomes. Two disjoint rectangles and
an even-odd path hole prevent bounding-box substitution. The same-oriented
nonzero companion intentionally fills the inner figure.

World/map/shear companions capture clip geometry before resetting the transform;
RGNDATA remains in initial playback device coordinates, including a nonzero
physical frame origin. OFFSETCLIPRGN uses a logical displacement vector (the world
translation must not become part of the vector), moves existing mask clips, and
brings offcanvas path/region geometry back into view. SETMETARGN retains an
independent intersection after resetting or moving the new selected clip.
Save/Restore covers relative negative depth and positive absolute saved levels.
Selected paths survive region/meta/offset operations but are consumed by
SELECTCLIPPATH. Input files contain no copied source implementation or expected
SVG, no font bytes and no Windows-generated image.

`unsupported-classic-clip-*` have valid outer framing and isolate invalid region
headers, lengths, counts, extents, modes, null-versus-empty framing, missing or
consumed paths, short rectangle/offset records and unmatched restore levels.
Conversion must fail instead of publishing a successful partial image. These
fixtures cover this bounded family, not all classic GDI graphics behavior.

The two `classic-clip-getdc-*` companions paint red through a temporary selected
clip or metaregion in the first EMF+ GetDC interval. The next EMF+ record releases
that DC. A second GetDC paints green both inside and outside the former region;
actual color samples prove the clip state does not leak across ownership scopes.

`plus-pen-*` are independently authored EMF+ Pen objects and drawing records.
Every Pen embeds its own complete versioned BrushObject, following
MS-EMFPLUS 2.2.1.7 and the official 3.2.33.1 pen example; layout2vector's writer
independently uses this framing too. The older `plus-alpha-pen.emf` now includes
that previously missing embedded graphics version while retaining the same
opaque-red pen and half-alpha brush pixel assertions. Native pen outlines are
filled paths, so the serialization assertion checks opaque outline fill rather
than requiring the old SVG stroke representation.

Pen tests inspect actual native pixels on a fixed grid against independent
analytic boxes, circles, polygons and signed-distance unions/differences.
A one-pixel band around analytically predicted boundaries is excluded from pure
red/white classification to avoid treating legitimate antialiasing as changed
geometry. Interior ink, complete surrounding white area and explicit acute-join
probes remain required. No generated SVG outline is used as an expected image.

The fixtures cover horizontal/vertical/diagonal strokes, both independent end
caps, anchored ends, arbitrary asymmetric compound bands, reversed direction,
closed compound rings (a 16-unit pen gives each ring a genuine four-pixel
interior for the unchanged antialias-boundary oracle), centered/inset strokes,
pen linear scale/shear with ignored
translation, page/physical pen units and scaled-world device hairlines. Insets
retain original-width dash units and phase. Dash styles, custom odd patterns,
positive/negative offsets and independent round/triangle dash caps keep real
white gaps. Acute V joins in both directions distinguish regular miter clipping
from MiterClipped's bevel fallback using Microsoft's inner-corner/full-width
miter definition. Anchor dimensions use the separately inspected Wine GDI+
implementation policy; this is not certification against Windows pixels.

DrawPath, DrawLines, DrawRects, ellipse/arc, Beziers and cardinal curves exercise
the shared outline path. Equivalent compressed and relative encodings compare
against ordinary records with independently known geometry. Relative closed
curves include C (ignored when P is set) and nonzero alignment bytes. Open curves
retain Offset and NumSegments; unused points must not paint. A collinear cubic
with two backtracking extrema paints outside its endpoint interval and guards
against flattening it to the infinite chord.

Hatch, gradient and texture pen fixtures have independent filled-rectangle
controls using the same captured brush data. Full native pixel comparison,
color-endpoint/texture samples and a mixed pen/fill ownership image verify that
brush mapping and subsequent painting remain separate from outline generation.

`unsupported-pen-*` retain valid outer record chains and isolate malformed or
unsupported pen versions/types/flags/units, nonfinite values, missing/oversized
arrays, invalid cap/join/alignment combinations, missing custom-cap data, embedded brush
framing, invalid brush data and malformed point/curve ranges. They must fail
instead of publishing a successful partial comparison. This corpus does not
establish every GDI+ custom-cap variant, arbitrary Windows font/driver record or
physical Finder/signed distribution behavior.

## EMF+ custom line caps

`plus-pen-custom-*.emf` contains complete versioned default and adjustable-arrow
cap objects. Pens embed each sized cap before their complete brush; the standalone
ObjectType9 fixture is metadata and draws no extra shape. Independent ordinary
FillRects controls for hatch, gradient and texture paint a shaft rectangle
`(20,30,56,4)` and an outward cap rectangle `(76,24,12,16)` without the custom-cap
parser or native stroke-outline bridge.

Default cap fixtures distinguish fill from stroke, both-path stroke precedence,
winding nested figures, cap-local curve decoding, BaseInset and WidthScale,
independent local stroke cap/join styles, ignored hotspots, and empty/inactive attributes. Arrow
fixtures distinguish a triangle, positive notch, negative diamond, invisible
filled arrow, unfilled chevron, ignored unfilled MiddleInset, zero extents and
scaling. Horizontal, vertical, reversed, diagonal and multi-figure paths cover
physical endpoint placement. Closed paths suppress custom caps, compound bands
retain one adornment per endpoint, and dash gaps retain ordinary dash caps.
Captured clipping, world transforms, pen shear and ignored pen translation cover
the common native paint path.

`unsupported-pen-custom-*.emf` preserves valid outer EMF and Pen/Brush framing
while isolating invalid nested cap versions, types, flags, enums, sizes, path
counts/types/cubic sequences, RLE runs and meaningful numeric fields. Positive
BaseInset exceeding the line length is deliberately refused because the native
GDI+ API calls its behavior undefined. Left/Outset/Right alignment remains a
separate explicit refusal pending Windows playback evidence.

These are analytic geometry and independent shape-control fixtures. They are
not Windows-produced pixel captures and do not certify every GDI+ cap variant.

## Shared compressed EMF+ paths

`plus-compressed-path-*.emf` adds 34 original accepted records, all with a
96×64 canvas. Ordinary fill/stroke paths, captured path clips, region paths,
custom-cap paths and the existing canonical ellipse-gradient boundary each have
independent absolute Float32 controls and equivalent signed-short, relative R,
and R|C forms. The R|C pairs prove that C is ignored when R is set. Same-winding
nested rectangles deliberately retain Alternate/even-odd fill for normal and
region paths; marker and dash-mode point metadata do not select winding fill.
Custom caps retain their separate winding consumer semantics.

Independent rectangle/ring bounds check actual native pixels across the full
canvas, excluding only a one-pixel analytic antialias boundary. Cubic t=.5 is
known independently at (28,18), and a second open figure leaves a real gap.
The closed cubic counterpart adds the closing line rather than changing its
control points. The relative coordinates include separately chosen signed
7-/15-bit components, literal hand-authored -16384/+16383 encodings, and signed
7-bit -64/+63 boundaries. A 67-point rectangle exercises a 63+2 type run without
losing collinear vertices. Nonzero optional alignment bytes are ignored.

The representative consumer pairs are `fill-relative`/`fill-float`,
`region-relative`/`region-float`, and `cap-relative`/`cap-float`. The first two
paint the red outer rectangle (8,8)–(88,56), with the white hole
(24,20)–(72,44). The cap pair paints the red shaft (20,30)–(76,34) and outward
box (76,24)–(88,40). All pair members have identical intended native pixels.

`unsupported-compressed-path-*.emf` contains 41 independently framed refusals:
bad versions/reserved flags, count overflow and budgets, truncated float/short/
PointR/type data, invalid or mismatched RLE headers/run totals, unsupported point
types, interrupted or prematurely closed cubic triples, nonfinite/unbounded
coordinates, unrelated trailing bytes, and the same malformed nested payloads
in regions, caps and gradients. Two individually valid 524,289-point objects
exceed the conversion-wide 1,048,576-point reservation. Another relative path
has individually valid Integer15 deltas whose cumulative coordinate exceeds
the existing coordinate limit. Input bytes must remain unchanged after refusal.

The binary contract follows Microsoft's [EmfPlusPath](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/b539cf16-6232-4705-9f6e-6f914705145f),
[PointR](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/c861a0d4-39f0-4f6c-bad9-e3f7bf63205e)
and [PathPointTypeRLE](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/1acc6ffc-ff99-40fe-925e-b90869b7d02c)
structures. No independent winding flag, arbitrary gradient boundary geometry,
or Windows pixel certification is inferred from a successful compressed decode.

The retained `plus-pen-custom-padding.emf` uses a redundant explicit closing
vertex: its Float32 path occupies 57 meaningful bytes plus three nonzero padding
bytes, for the required DWORD-aligned size60. The earlier fixture appended two
bytes to an already aligned size48 path; that was invalid wire framing rather
than a supported padding variation. Its rectangle and independent pixel oracle
are unchanged, as is the separate outer-cap tail.
