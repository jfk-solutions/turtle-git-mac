# Final ten-case spatial boundary assay

`TinyNativeSpatialBoundaryReference.cpp` observes only ten NEW cases. Neither the
288-case pointwise,410-case spatial, nor65-case follow-up inventory runs. It
includes pointwise native startup/JSON/pixel/encoder utilities with main renamed.
No port formulas, expected pixels, or third-party renderer algorithms are used.

Eight Sharpen cases pair opaque32×32 `step` and `asymmetric` sources with radius3
and amounts12.5,37.5,75,99. These distinguish continuous amount quantization from
the first assay's0/25/50/100 samples. The observations must decide the formula;
no Q6 gain or rounding rule is asserted by this program.

Two Blur cases use the asymmetric32² source, radius2, expandEdge=false/true. Both
record fractional source RectF(4.25,6.5,17.5,18.25), identity linear transform with
translation(16,16), on a64×64 pixel metafile frame. Padding retains expanded
pixels outside the fractional crop. Manifests state exact source rectangle,
image matrix, fixed recording frame and true loaded dimensions. There is no
integer rounding of the requested crop in the observation code.

Source images at96DPI:

- Step RGB: R0/255 split at x16; G31/223 split at y11; B240/17 split at x+y23.
- Asymmetric RGB: (11x+53y,43x+7y,19x+37y), each modulo256.
- All pixels have alpha255. Both requested and actual native source RGBA/PNG
  are preserved; all captured outputs are COMPLETE straightRGBA, top-left
  row-major. Output dimensions are bounded128 in each axis.

`generate OUTPUT` starts GDI+v2, records each original nativeSDK EMF and separately
applies the same effect in-place and through the bitmap-returning ApplyEffect
overload, with fresh effect instances. **Direct ApplyEffect uses null/full ROI**;
only the original recorded Blur wires exercise fractional source cropping. The
direct objects are not mislabeled as fractional-ROI evidence. Created bitmap
results retain returned outputRect and true dimensions; aux data is retained if
available, bounded1MiB.

`direct-v1 OUTPUT` repeats the direct observations under startupv1 without
rewriting original EMFs. `replay OUTPUT` / `replay-v1 OUTPUT` load those original
wires with actual `Bitmap(path,FALSE)`, retain intrinsic GetPixel pixels, then
natural-size DrawImage using default interpolation, PixelOffsetHalf,
WrapTileFlipXY and transparent SourceCopy. Actual dimensions and expectedSize
remain distinct; neither32² nor64² discrepancies are silently rescaled.

The four JSON manifests retain all SDK statuses. Legitimate nonzero statuses are
observations; setup/output/internal exceptions produce caseerror and fail the
process. Each completed case is flushed. The new narrowly triggered workflow
collects compiler/platform/source/GDI+ module version and input/output SHA256
inventories. Earlier sources, workflows and corpora remain unchanged.

This is the final focused contract dependency for the current spatial family,
not an application test or a claim that the implementation has passed validation.
Official parameter and overload references are linked in the original spatial
README. No additional speculative probes are included.
