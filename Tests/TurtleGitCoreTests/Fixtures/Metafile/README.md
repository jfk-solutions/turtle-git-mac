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
