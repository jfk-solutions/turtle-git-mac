# Original synthetic Windows metafiles

These fixtures and `generate.py` are original TurtleGit test data, licensed under
MIT. They contain no copied image/font payloads. The generator follows Microsoft
[MS-EMF](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/),
[MS-EMFPLUS](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/)
and [MS-WMF](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wmf/)
record structures, independently of renderer output. No runtime conversion is
needed to regenerate the handwritten corpus. The `windows-formatted-*` files are
original Windows GDI+ recordings retained byte-for-byte from the pinned reference
run; regenerate those with its C++ utility, not `generate.py`.

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

`unsupported-region.emf` intentionally requests unsupported painting and must fail
explicitly. The historical filename `unsupported-rop.emf` contains valid R2_XORPEN;
the Boolean raster batch now verifies its actual cyan/yellow pixels on a white DC.

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

Additional intentional refusal cases cover invalid Clamp values, invalid wrap5,
wrong-type attributes and malformed preset stop order. They must not render as
successful approximate/blank images. The historical `unsupported-image-effect.emf`
bytes now assert the measured Windows ordinary-image fallback for E=0x2000 without
a pending serialized effect; E remains an effect flag, not relative point encoding.
The ImageEffects subdirectory covers actual serialized effects and malformed blocks.
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
- `plus-gradient-large-offset-distorted.emf`: the exact former
  `unsupported-gradient-precision.emf` bytes (SHA256
  `dac9ffe587ce0ea4a0a007b1bc16bb515fa4f3f54f3136c2b54e482f51dd2a12`).
  The boundary near coordinate900000000 has radius1024 and one Bezier control
  shifted256 units. General cubic support now renders this noncanonical path;
  it must use its raster boundary rather than an analytic radial-gradient ellipse.
- `plus-gradient-translated-distorted.emf` independently subtracts the common
  origin from the decoded Float32 path and conjugates the decoded world matrix.
  Its geometry and colors must match the large-offset input (one byte allowed
  for final Float32 translation quantization, below0.000002 device pixels).
  `plus-gradient-translated-unshifted.emf` removes only the256-unit control
  displacement and must produce a distinct result. These are geometric controls,
  not a newly asserted Windows large-coordinate pixel oracle. All three retain
  their natural97×65 canvas; comparisons crop the same top-left96×64 interior.
- `unsupported-gradient-canonical-precision.emf`: an unshifted canonical ellipse
  at the same large origin/radius/world scale. It retains the explicit analytic
  ellipse Float32 precision refusal independently of supported general cubics.

Core color samples normalize the actual CGImage into a named sRGB8-bit buffer.
This avoids NSBitmapImageRep.colorAt's generic-calibrated NSColor interpretation
changing pure tagged-sRGB magenta. All original pixel thresholds remain intact.

Raw bitmap batch (original generator inputs, no upstream picture bytes):

- `plus-raw-indexed{1,4,8}-{positive,negative}.emf` use odd widths, deliberately
  nonzero unused bits/nibbles and row padding, and distinct top/bottom rows.
  One-bit values are MSB-first; four-bit values use the high nibble first.
  Eight-bit uses index 200 in a201-entry palette; padding255 must be ignored.
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

## Positioned Unicode and glyph-index text

The 52 original `plus-driver-*` / `classic-positioned-*` pictures use Helvetica
at an 18-pixel em height on a 96×64 canvas, except the paired Arial
positive-cell/negative-em height controls. Arial has a different ascent+descent
from its em height, so those pictures distinguish the two sizing modes. They contain no font outlines or
platform-dependent glyph IDs. The three explicit `H` origins are (8,28),
(36,28), (64,28), in alphabetic baseline coordinates. Native and Core checks
make private raw-glyph record copies using the installed font's actual cmap;
only the glyph-mode bit and UInt16 values change. Corpus bytes stay unchanged.

The independent comparisons cover:

- Driver Unicode, privately mapped glyph IDs and classic `Dx=28` paths with
  identical intended pixels. Natural advances come from the actual font.
- RealizedAdvance's first meaningful origin and ignored remaining wire slots,
  including NaN/Infinity in unused slots; all GlyphCount slots remain present.
- Clockwise vertical glyphs/advances, fractional origins and the subpixel hint,
  glyph-local shear, unused driver-matrix translation, and separate graphics
  world translation. The combined vertical/anisotropic-shear fixture applies
  the driver matrix **before** vertical orientation, about the supplied origin.
- Gradient/hatch glyph brushes, captured clipping and restored graphics state.
- GM_COMPATIBLE horizontal anisotropy: explicit Dx follows the full mapping,
  while glyph ink and natural advances use the uniform realized font. Separate
  driver controls cover X/Y reflections and ignored exScale/eyScale conversion
  metadata, distinguishing compensation from mirrored or stretched glyphs.
- Classic signed `Dx/Pdy` (positive Pdy moves up), center/right baseline
  alignment, and Left/Right/Center `TA_UPDATECP` continuation controls.
- Explicit clipped/opaque rectangles, zero-character opaque output,
  transparent BeginPath/FillPath, positive cell height, and two requested
  average font widths. Width controls distinguish glyph scaling from advances.

The 22 `unsupported-positioned-text-*` records independently exercise invalid
font/brush references, reserved options, counts, truncated positions/displacements,
UTF-16 errors, missing raw-glyph fonts, glyph IDs outside the selected font,
nonfinite meaningful coordinates/matrices, malformed matrix-presence values,
invalid string/Dx offsets, and the explicit opaque-BeginPath boundary. A Unicode
cmap request may substitute a missing family; a raw-glyph request may not.
The 32,769-unit fixture exceeds the per-call 32,768 limit; nine 32,768-space
records exceed the conversion-wide 262,144-unit limit without manufacturing
large glyph outlines. This is an explicit refusal, not a partial rendering.

These controls establish native outline placement and ownership, not Windows
ClearType/subpixel raster certification or availability of every installed font.

## Classic Boolean raster operations

`generate-raster.py` writes only the original Boolean-family fixtures. It does
not execute or read output from a renderer. The six `*-rop3-matrix-*` metafiles
cover every truth byte for EMF BitBlt/StretchBlt/StretchDIBits and WMF
DIBBitBlt/DIBStretchBlt/StretchDIB. Solid pattern F0, bitmap source CC and existing
destination AA enumerate all eight P/S/D input combinations in the bits of one
byte. Thus the independently specified expected gray byte equals the operation
index. The two ROP2 matrices use CC/AA and independently expect the four-bit truth
nibble repeated twice for each of the sixteen brush and pen operations.

Additional originals cover source-independent PATBLT and missing DIBs, irrelevant
null patterns, white opaque destination, successive clipped operations, saved
mixing/mapping/clip state, device-fixed 2×2 pattern phase under world transforms,
source crop/reflection/scale and separate fractional geometric coverage. Native
color assertions use the actual named-sRGB pixel buffer; fractional coverage has
an independent literal-SVG reference without metafile parsing or Boolean code.

The `unsupported-raster-*` records retain explicit refusal for missing required
operands, unsupported high flags, palette/device-dependent layouts, malformed
offsets and records, nonfinite/rotated/sheared source transforms, invalid ROP2
values and a canvas exceeding the native raster pixel budget. P-dependent null
brush handling remains a deliberate refusal; this corpus does not claim its
behavior as a no-op. The old unrelated refusal families retain their assertions.

Four `wmf-rop3-without-bitmap-*` matrices independently frame the ReservedWORD
layouts for BITBLT/STRETCHBLT and DIBBITBLT/DIBSTRETCHBLT. Each covers all sixteen
source-independent P/D functions with nonzero ignored ReservedWORD and zero unused
source extents. Required-source versions still refuse. The device-dependent source
refusals contain complete Bitmap16 payloads rather than relying on short records.

`classic-rop3-source-bottom-up.emf` and `wmf-rop3-source-bottom-up.wmf`
store a positive-height four-row red/green/blue/yellow DIB. Their partial crop
selects ySrc0/cySrc2 from the bottom-origin StretchDIBits/STRETCHDIB source,
independently expecting blue/yellow instead of red/green.

The no-source BitBlt/StretchBlt fixtures additionally use zero and skewed unused
`XformSrc` metadata: PATCOPY must still use P, and DSTINVERT must still invert D.
Source-dependent singular/nonfinite/rotated/sheared transforms remain refusals.
The three logical-palette refusals use actual indexed eight-bit
`DIB_PAL_COLORS` WORD table entries 20 outside the explicitly chosen 20-entry
common-display default profile, rather than truecolor data with no palette.
Index 0 without an explicit custom palette is now a valid default-profile lookup.
The EMF ROP2 pen matrix intentionally declares a two-logical-unit solid
`EMR_CREATEPEN` pen; interior truth samples require its full stroke coverage.

`generate-raster-roi.py` authors the original `classic-roi-*` EMF scenes and
`unsupported-roi-offcanvas-payload.emf` (MIT). They use small offset Boolean
patches on a 64×64 canvas: four-corner affine destination plus mirrored middle
source crop; asymmetric upper/lower device Y; checkpoint/vector/full-viewport
interleaving; saved pattern/clip/brush-origin reuse; an offcanvas paint followed
by a partly clipped paint; destination-preserving 0xaa; and a ROP2 pen fallback.
The malformed offcanvas record still declares an invalid source bitmap offset.
Independent Core and native consumer expectations use literal device samples,
not serialized implementation ROI fields or timing thresholds. The exhaustive
ROP2/ROP3 truth matrices remain unchanged and retain the decoder's 15s deadline.


`generate-drawing-state.py` (MIT) authors original 64×64 EMF/WMF records for
`MetafileDrawingStateTests`. EMF stock DC_BRUSH 18/DC_PEN 19 use white/black
playback defaults; later colors are ordinary CreateBrush/CreatePen/SelectObject
records, matching real recorder output. Text/background color changes do not
change these stock defaults. Ordinary object controls independently reproduce
vector, explicit FillRgn, PATCOPY, flood, pen and saved-selection paintings.
Cosmetic black strokes receive an explicit half-device-unit transform so literal
interior samples are independent of edge antialiasing.

The default-palette profile fixtures compare all 20 logical entries of the chosen
Windows common-display profile with independently authored RGBQUAD DIBs. This is
an explicit macOS playback policy for a device-dependent Windows default, not a
hardware-palette equivalence claim. They cover initial/explicit DEFAULT selection,
read-only stock palette update, PALETTEINDEX vector brush/pen, nested SaveDC/
RestoreDC, live custom palette mutation while saved, ignored deletion while a
saved DC selects the object, and later unselected deletion. The color-consumer
pair reuses the same indexed ordinary/extended pen, brush, hatch and text objects
across two real custom palette selections; ordinary RGB replacement controls
provide a separate complete painting oracle. No invented DC-color setter record
is present; unverified WMF stock 18/19 remain refusals.

`classic-patternbrush-default-palette.emf` promotes the formerly refused valid
WORD indices 0/1 to positive black/maroon default-profile coverage. Its replacement
negative uses actual out-of-profile indices 20/21. Other `unsupported-drawing-state`
records cover default index 20, PC_EXPLICIT unknown hardware entries and WMF
stock18/19. Original-byte and conversion-isolation checks accompany all scenes.

`classic-deferred-palette-brush.emf` selects a PALETTEINDEX 25 logical brush
before its custom palette exists, saves/restores that selection, changes text/
background attributes, then selects a 26-entry custom palette and paints cyan.
Its final selected PALETTEINDEX 1000 brush remains unused and valid. The separate
painted-unresolved brush refusal requires actual missing-color consumption,
retaining whole-image refusal after earlier legitimate marks.


## Embedded metafile images and textures

`generate-embedded.py` independently authors 57 accepted embedded-image/texture
EMFs, 15 malformed/budget refusals and one literal RGBA PNG control. WMF,
placeable WMF, EMF, EMF+ only and dual children contain known red/green geometry
with unpainted holes. Direct draws exercise crop, affine mapping, device clip,
recursive/repeated use, fresh-child/explicit composition, classic DSTINVERT,
Clear and parent-state restoration. Textures compare against literal raw BGRA
images for all wrap modes, pen, glyph and SourceCopy; checkpoint-scope fixtures
retain a separately painted parent prefix. ImageAttributes fixtures prove direct vector wrap/clamp is ignored, while
bitmap attributes retain their existing behavior. Classic glyph axes and a WMF
round rectangle/clip exercise the full parent affine rather than a bounding box. Clamp BOOL=1 is accepted as ignored
GDI+ 1.0 metadata; `plus-image-attributes-clamp-ignored.emf` retains the bytes of
the old `unsupported-image-attributes.emf` sample. All other prior payloads are
unchanged. Invalid child/header/type/size/reference, recursion and playback-count
samples must fail the whole outer image. See
[embedded image parity](../../../../docs/METAFILE-EMBEDDED-IMAGE-PARITY.md) for
source contracts, bounds and the pending grouped checkpoint.


## Compressed raster sources

`generate-compressed-raster.py` authors 110 accepted EMF/WMF payloads and 21
malformed/budget refusals, plus 14 original GIF/TIFF/JPEG source containers.
Previous 1,334 EMF/WMF/PNG payloads remain byte-identical. EMF+ Object DataSize
includes its DWORD alignment padding, including compressed streams with an odd
length. GIF/TIFF images and texture/pen brushes compare with independent raw BGRA
controls. Crop, affine/mirrored placement, clip, wrap, image attributes, partial
alpha and SourceCopy retain the same consumers as other bitmap images.

GIF controls distinguish timed/NETSCAPE-loop animation (default first frame) from
an untimed nonlooping sequence (static final composite), with transparent delta
rectangles preserving the earlier canvas. TIFF defaults to its first page.
TIFF/JPEG orientation6 metadata is intentionally ignored as observed in Windows
GDI+ serialized playback. The raw source containers accompany the records so the
reference decoder can independently distinguish a valid codec from a record
framing error. Classic compressed JPEG/PNG stretched transfers retain RGB-only,
SRCCOPY and opaque-color semantics. Wrong compression tags/codec payloads,
indexed usage, noncopy ROPs, negative compressed DIB height, corrupt containers,
trailing junk, frame/dimension limits and aggregate expansion must fail the whole
conversion. See [compressed raster parity](../../../../docs/METAFILE-COMPRESSED-RASTER-PARITY.md)
for Windows observations and remaining platform limits.


The October 26 formatted-control family includes visible zero-advance LRM/RLM
glyphs, lone joiners, retained bidi/joining text, vertical/wrapped/trimmed layouts
and original Windows recordings with nonzero upper LANGID storage bits. Font and
DrawString DataSize fields in the handwritten formatted-text family include their
required zero padding. The prior unaligned font payloads caused Windows replay
status9 (Aborted); the aligned references replay successfully.

Digit-mode controls distinguish native Windows literal numeric playback from
host-locale rewriting. The previous local ICU-substitution expectations are
superseded by direct and serialized Windows references, including Arabic/RTL.
See [source and recorded evidence](../../../../docs/METAFILE-TEXT-PARITY.md).

`generate-classic-text.py` creates the original `classic-text-*` compact and
batched text family. It writes only its own files and preserves every earlier
fixture. SmallTextOut's `ETO_SMALL_CHARS` stores low Unicode bytes, independently
of ANSI font charset; PolyTextOutA/W and ExtTextOutA use original-record-relative
string/DX offsets. Each positive paint has an independent ExtTextOutW counterpart
for full-raster equality, including clipping, opaque empty text, explicit DX/PDY,
current-position updates, transforms, path capture and SaveDC/RestoreDC. Refusals
keep a valid outer EMF while corrupting inner descriptor counts, offsets, options,
encoding, compact rectangle/tail framing and per-string/shared text budgets. No
font glyph IDs are hardcoded and no Windows font or image bytes are copied.

Run `python3 Tests/TurtleGitCoreTests/Fixtures/Metafile/generate-classic-text.py`
from the repository root. The family currently comprises 72 positive/control pairs
(144 positive files) and 40 refusals. Additional charset controls cover 1250/1251/
1253/1254/1255/1256/1257/1258/874 and Shift-JIS/UHC/GBK/Big5. DBCS DX and PDY
fixtures have deliberately unequal lead/trail byte advances whose sums must match
the literal UTF16 control. Truncated leads, invalid trails, Symbol/OEM ambiguity
refuse explicitly. Compact low-byte glyph IDs are constructed privately from the
installed font cmap at runtime and compared against the UInt16 glyph record.
Windows-measured NO_RECT ignores opaque/clip flags; Poly offDx zero uses
bounded DWORD advances from its source record header, with independent
UPDATECP witnesses and literal ExtTextOutW controls.

`generate-wmf-text.py` writes only new `wmf-text-*` originals and
`unsupported-wmf-text-*` refusals. Run it with Python3 from the repository root.
WMF TextOut/ExtTextOut records retain byte counts, odd-byte padding, signed WORD
spacing and complete LOGFONT metadata. Independently framed Unicode ExtTextOutW
EMF controls use the same compatible graphics mode and logical font; comparisons
crop the EMF's extra frame pixel without rescaling. Cases include real glyph ink,
font cell/width/angle/decorations, current-position updates, positive/negative DX,
clipping/opaque backgrounds, SaveDC/RestoreDC, charset/DBCS bytes and an affine
EMF+ parent around WMF and EMF child images. Inner framing/encoding failures and
conversion-wide text budgets refuse the complete image and preserve input bytes.
No earlier fixtures, font bytes or upstream pictures are rewritten or copied.
Windows replay evidence also drives the WMF-specific controls: an explicit null
pen is created and selected instead of assuming an EMF-style stock selector;
signed character extra applies with explicit DX while break justification is
ignored in that case. Natural character-extra ink assertions preserve each glyph
outline and shift its origin; natural justification conserves the total over the
breaks. WMF PDY replay consumes the first character-count WORDs as ordinary DX
and ignores the additional vertical-looking WORDs, so its Unicode control uses
that measured sequence. OEM437 and JOHAB bytes have literal Unicode controls.

This WMF family has 62 positive/control pairs, five additional natural-spacing
subjects and 29 refusals. JOHAB's DX control intentionally consumes the first
Unicode-character-count WORDs rather than summing lead/trail byte advances;
the other four DBCS codepages retain byte sums. PDY negative fixtures require the
full twice-count WORD framing even though playback uses horizontal-only values.
Independent Core checks resolve the installed font's actual missing-CJK fallback,
render its real native glyph path and compare source ink, then check repeated
fallback scalars at three supplied origins. Shared-budget refusals remain in the
same group; no screen count or fixture count establishes whole-port completion.

`generate-wmf-bitmap16.py` writes only `wmf-bitmap16-*` and
`unsupported-wmf-bitmap16-*`. Run it with Python3 from the repository root.
BITBLT/STRETCHBLT use ten-byte Bitmap16 headers and WORD-aligned scanlines,
independent of the 32-byte pattern-brush wrapper. Independently encoded 32bpp DIB
controls freeze the source colors; monochrome transfers use live foreground/
background colors. Source rows contain distinctive MSB and unused-padding bits.
Cases exercise source cropping, signed/mirrored extents, ROP source/pattern/
destination dependencies, live colors, clips, saved state, logical mapping and
an affine embedded WMF. Core checks include exact source pixels, per-channel
ternary truth, a real embedded red-pixel count and full-raster control equality.
Complete unused 24bpp storage remains legal for source-independent operations;
truncated storage still refuses. A cheap preflight isolates the nine-record
aggregate decoded-pixel refusal before expensive expansion. Existing corpus
bytes are not regenerated, including earlier unsupported device-color fixtures.

The measured 32bpp transfer profile is B,G,R,X with X ignored; source-dependent
4/8/16/24bpp device color storage retains explicit refusal. Transfer WidthBytes
is advisory on Windows and positive controls include zero, negative, odd and
mismatched values with complete computed scanlines. The older pattern-brush
wrapper keeps its independently verified stricter contract.

Source-dependent omitted-source DDB BITBLT/STRETCHBLT self-copy is supported.
DIB variants retain explicit refusal; their source-independent omitted-source
operations remain supported.
Their controls contain an independently hand-encoded four-color atlas; exact
pixel assertions verify overlap uses the frozen preceding destination, clips,
ROP operands and mirror decisions. Four old unsupported-named fixtures retain
their bytes and now have positive BGRX/source-omitted checks. The historical
`unsupported-rop.emf` likewise remains covered by its exact cyan/yellow ROP2
Core check and is excluded explicitly from the stale generic native refusal set.
These are named measured contracts, never runtime-derived exemptions.
The source-omitted mapping atlas is drawn before changing the window extent:
subsequent logical source and destination rectangles must map into the frozen
device snapshot once. A dedicated WMFC alternate-EMF skip fixture remains
unverified; preflight currently belongs to the first actual WMF playback record.
No guessed WMFC comment/checksum envelope was added.


The Bitmap16 family currently has 67 positive/control pairs, one additional
HALFTONE quality subject and 34 refusals. Strict shrink-mode1/2/3 controls use
captured six-pixel RGB constants from the raw Bitmap16 `hand-final-color32-*`
Windows fixtures (run 40385962693), whose DIRECT/GDI/GDI+ results agree. The
similarly named native-recorded `final-color32-*` DIB files have different GDI+
replay and are not substituted as Bitmap16 evidence.

HALFTONE uses a declared native quality profile: integer reduction uses exact
box means, enlargement uses nearest, and nonintegral reduction uses separable
antialiased Lanczos3 with standard pixel centers and REFLECT_101 edges. Fixed
independently calculated RGB constants allow one channel unit for final rounding;
this profile differs from the captured Windows HALFTONE example by up to ten
channel units and is not claimed to reproduce its undocumented device kernel.
Nested Windows captures remain blank despite successful DrawImage status after
Object DataSize alignment; positive nested rendering is asserted locally, not
claimed as positive Windows pixel parity. WMFC alternate-EMF suppression likewise
retains its explicitly unverified fixture status.

DDB out-of-bounds subjects retain their original source rectangles. Their
independent DIB references explicitly intersect/crop to an in-range source and
shift/shrink the destination correspondingly; they do not ask the strict DIB
reader to accept a negative source origin. The source-omitted atlas likewise
preserves the two deliberately cyan destination columns omitted by clipping.
A zero-width DDB source has an empty-operation control. These control framing
repairs retain all original subject bytes and pixel assertions.
