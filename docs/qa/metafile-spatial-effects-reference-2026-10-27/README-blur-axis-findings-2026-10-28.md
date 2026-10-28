# Verified Blur axis observations and remaining reconstruction gap

Windows run40672793339/job122763547688 succeeded for source
45121d933ece78d7b0c56cd71c5f66346a02e52d. The
[artifact receipt](../blur-axis-quantization-observations-2026-10-28.json) records
artifact12809261798 and archive SHA256
1321efb780f76a6252e0664fede7020cc1b52a709dc23c12d9285229f5de58e4.
All124 hashed members passed recorded length/SHA verification; the archive has
125 members including its hash manifest. Git LF and observed Windows CRLF hashes
were compared explicitly for the capture, workflow and shared SDK utility.

The four mode manifests each contain five cases: four new axis witnesses plus
one constant control. All75 serialized SDK status fields are zero. All20
requested/actual source RGBA buffers match their authored opaque32×32 geometry;
all40 effect/replay buffers have actual32×32 extent. Each case's eight direct,
created, intrinsic and Picture buffers across startup1/2 are byte identical.
Five original SDK EMFs are retained. The constant control remains exactly
RGB91,157,223/alpha255 at all1024 output pixels.

## New independent constraints

For both RGB amplitude packets, horizontal and vertical effect outputs are
exact whole-RGBA transposes. Each is invariant along its perpendicular source
axis. Thus these observations do not support a different horizontal versus
vertical quantization rule as the actual general kernel.

For amplitudes1,63,128,97,200,255 respectively, all32 one-dimensional native
samples match half-center floor interpolation of rounded Gaussian coarse pairs:
(1,0), (33,30), (67,61), (51,46), (105,95), (134,121). Here Gaussian uses the
existing normalized exponent1.96/radius(255/16) construction, and the source
halfplane has that amplitude on its leading half and zero on its trailing half.
This is a reproducible generative scalar constraint, not a proof that the full
native two-dimensional lattice consists of exactly two samples. In particular,
amplitude1 emits1 only in the first eight positions, then0.

The previous horizontal-floor/fractional-vertical model therefore cannot be
claimed as identified SDK arithmetic merely because it fits many old buffers
within a byte. The new witnesses reject that interpretation without authorizing
a replacement that would worsen independent controls.

## Bounded falsifications

- A fresh inverse diagnostic searched every integer four-corner tuple within
  ±2 of generative rounded coarse values, separately for all RGB channels of
  the128/255 quadrant bases at radius255. Joint half-center bilinear and both
  intermediate-floor axis orders have zero tuples reproducing their full
  buffers even within1. Every one of these18 inverse diagnostics has best
  maximum2. Inferred source-specific corners are diagnostics only and must not
  become shipping data. This bounded search is not an unbounded proof about
  every possible interpolation operator.
- Keeping the horizontal Gaussian fractional, rounding only the final vertical
  coarse result, and then reconstructing was compared across the same27 old
  and new source/output pairs. Some variants preserve the axis witnesses
  exactly, but all retained failures; the strongest axis-exact ranking still
  has maximum2 and736 channels exceeding1. A reduced aggregate error is not
  sufficient to choose a new general algorithm.
- Evaluating a Gaussian halo at the neighboring coarse centers explains an
  individual quadrant corner, but432 general stage/reduction/interpolation
  hypotheses do not close the full dataset. None matches all four new axis
  outputs byte exactly. For example, the rounded amplitude128 halo introduces
  a first sample70 where native is69. This proposed halo is not adopted.
- Four coherent endpoint-retaining sampling geometries were tested: recursive
  inclusive pairs, direct inclusive blocks, centered inclusive centers and
  corner-aligned inclusive centers. They retain failures with maximum56–67 and
  nonzero axis errors. These specific constructions are rejected; other
  unidentified lattice/quantization couplings are not thereby excluded.

## Initial production state and subsequent continuation

The state below records this initial capture/inverse checkpoint. The subsequent
[causal per-axis implementation](README-blur-axis-implementation-2026-10-28.md)
uses the same observations to replace the old two-dimensional pyramid. Its
source receipt and retained failures supersede this earlier production snapshot.


Only the obsolete, unused VerticalPolicy.unverified construction sentinel and
its pending-contract throws were removed. Every valid small-kernel dimension
already selected min(height,ceil(height/width)) leading rows; large kernels
already selected the full vertical pass. No live input behavior, pixel oracle,
tolerance, fitted coefficient or broad renderer path was changed by this
continuation.

General two-dimensional large-kernel reconstruction/lattice and coupled
quantization remain unidentified. Small-kernel high-gain Sharpen precision
residuals remain too. Blur and Sharpen share this numerical boundary; the whole
spatial family is not certified, and no bounded radius/dimension subset is
substituted for the requested general behavior. No Core/native macOS suite,
application/helper build or broad627-case rerun occurred in this continuation.

Reproducers and full per-case results are retained under build/qa:
verify-blur-axis-capture-2026-10-28.py,
invert-large-quadrant-reconstruction-2026-10-28.py,
analyze-blur-axis-Hfloat-Vround-2026-10-28.py,
analyze-large-gaussian-halo-2026-10-28.py and
analyze-large-endpoint-lattices-2026-10-28.py, with their JSON outputs. They read
original Windows bytes only; no measured output is used as a predictor.
