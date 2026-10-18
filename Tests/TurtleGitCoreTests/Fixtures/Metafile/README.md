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
