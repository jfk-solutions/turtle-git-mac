# Causal per-axis Blur/Sharpen implementation snapshot

The later [precision continuation](README-blur-sharpen-precision-2026-10-28.md)
resolves the arithmetic gaps recorded below. This document retains the actual
earlier observation; it is not the current numerical result.

This continues the verified axis observations and earlier inverse diagnostics.
The [implementation receipt](../blur-axis-implementation-2026-10-28.json) records
the exact source, isolated arithmetic executable and all69 comparison results.
It does not certify the whole spatial family or a macOS application build.

## What the independent pixels establish

The radius255 amplitude255 quadrant has a nonmonotonic horizontal output row
but a monotonic vertical column. That is explained by a complete quantized
one-dimensional wrapper running before the other axis, rather than by fitting
four coarse corners or adding a Gaussian output halo. Its repeated scalar
quantization can change the next axis's rounded coarse pair as the first axis's
byte amplitude steps downward.

The general wrapper is:

1. Average each whole dyadic source block and floor once. Repeated average-floor
   pairs lose fractions between levels and do not reproduce the asymmetric maps.
2. Apply normalized Gaussian nearest-Q8 products and nearest byte output.
3. Reconstruct that axis at half-center coordinates, flooring the byte result.
4. Apply the same complete wrapper to the other axis.

There are no measured intermediate corners, fixture-name branches or fitted
coefficients. The verified scalar axis cases are exact under the same rule.
The radius255 quadrant controls and all20 retained large Sharpen observations
are now byte exact too. On the27 old/new unexpanded large Blur controls, the
original two-dimensional pyramid/fractional-pass model had998 channels exceeding
one and27273 total absolute error. The causal wrapper has six channels exceeding
one and129 total absolute error; all six are in the radius63 asymmetric control.
This residual remains a failure, not a reason to change its oracle.

## Geometry, allocation and retained boundaries

An expanded transparent partial source block includes zero for samples outside
the bitmap; repeating the final source pixel introduces false edge energy in
odd-sized inputs. Expanded and cropped output maps retain the requested image
origin and the corresponding coarse offset. Both axis plans, all private
reduced/filtered/reconstructed byte planes and all channel work reservations are
computed before any pixel buffer allocation. The source remains immutable and
the conversion-owned aggregate budget remains shared across draws.

The independent full-resolution narrow-image fallback is retained as before.
No new radius or dimension exclusion is added, and no subset is described as the
whole requested family. Removing the unused unverified construction sentinel
never removed a live valid-input gate.

## Actual isolated comparison

An optimized standalone Swift arithmetic executable compiled the current
SpatialImageEffects and RedEye source dependency with a private probe. It read
only the69 relevant large Blur/Sharpen source buffers, wrote private outputs and
was compared afterward with the native Windows created-output buffers. Native
expected pixels are not inputs to the predictor. All output dimensions and
image-space output RECTs agree;37 profiles are byte exact. Remaining maximum2
channels persist in coefficient, expanded and narrow-image cases, with every
case retained in the receipt. The large full-resolution fallback's residuals
are unchanged by the new axis implementation.

The initial isolated compile found a line-breaking operator syntax issue, which
was fixed before the successful compile/run. Both compiler logs are retained.
No build-metafile-runtime invocation, app/helper build, Core/native suite,
physical Finder check, tolerance widening or wholesale627-case rerun occurred.
General coefficient precision, expanded/narrow behavior and the earlier small
high-gain Sharpen residuals must still be resolved before family acceptance.
