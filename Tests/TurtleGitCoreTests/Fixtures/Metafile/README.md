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
