# Blur/Sharpen precision continuation

This supersedes the numerical gaps in the earlier
[axis implementation snapshot](README-blur-axis-implementation-2026-10-28.md).
The [receipt](../blur-sharpen-precision-implementation-2026-10-28.json) records
all comparisons and their limits. The application integration checkpoint is
still pending.

## Mechanisms and independent evidence

The center coefficient is two half contributions, each rounded independently
to Q8 before summation. Combining them into one product loses a bit at rounding
boundaries. This explains the earlier matched-contribution witness and the
apparently inconsistent Gaussian coefficient constraints without fitting a
coefficient: the isolated/pair and independent asymmetric radius-five rows
become exact under the same nominal kernel once the center is split.

Gaussian construction also follows ordered float32 operations rounded toward
zero: accumulate the offset step, evaluate its squared exponential, accumulate
the symmetric weight sum, then normalize. The small-radius source geometry
retains its measured leading-row vertical extent; each axis selects endpoint
clamping when the kernel's support rounded up to odd reaches that axis.

Large effects complete reduction, filtering and reconstruction on one axis
before starting the other. Partial blocks divide by the actual sample count.
Expanded effects first create the full-resolution transparent output canvas;
reduction blocks begin at that canvas's origin. Adding coarse padding after
reducing the original image changes alignment and caused the expanded residuals.
The same reduction rule uses ceil-based coarse dimensions for narrow images,
removing the unsupported full-resolution fallback. Radius 80 retains factor four.

All plans, private planes and scalar work reservations precede pixel allocation,
including the padded source, center half products, small-radius scratch prefix
and Sharpen output. Source pixels remain immutable and aggregate budgets remain
shared across the conversion.

## Research provenance

Behavioral research consulted ChristopherVR/emf-converter at commit
[`effcf337218fefc08e4ac8f74e59cd2af1a9235c`](https://github.com/ChristopherVR/emf-converter/tree/effcf337218fefc08e4ac8f74e59cd2af1a9235c),
particularly its [parity notes](https://christophervr.github.io/emf-converter/parity-notes)
and `src/emf-plus-image-effects.ts`. That project is Apache-2.0 licensed.
Our Swift implementation and arithmetic predictors are original implementations
of the researched mathematical behavior. No external implementation code,
dependency or native pixel oracle was copied, and project license declarations
were not changed. Our previously verified Windows captures remain the oracle.

## Actual isolated result

An optimized standalone Swift arithmetic executable compiled only the spatial
source, its RedEye dependency and a private buffer probe. All 389 profiles are
byte exact: 69 large, 311 small, six coefficient and three matched-contribution
cases. Every created-output dimension and image-space RECT matches too.
The three matched-contribution cases and three small boundary controls ran
separately after the first 383 outputs; those 383
were not rerun. No tolerance or expected buffer changed.

The first compile command used an incorrect RedEye dependency filename and
failed before compilation. The corrected command compiled and ran successfully;
both logs remain in the receipt. An initial receipt bookkeeping assertion used
width/height where the SDK records right/bottom endpoints; correcting that
comparison to origin plus extent confirmed all 389 rectangles.

This is an arithmetic result, not an application build, full 627-case playback
run, Core/native UI suite or physical integration acceptance. Parent-owned
validation must still cover draw-time ROI/contained/cropped playback and budget
failure behavior with the integrated renderer. Finite references do not establish
every undocumented Windows radius/dimension branch, and the whole port is not
being declared complete.

## Static adapter review after the arithmetic freeze

The native bridge now reserves the cropped source plane before allocation and
the output normalization COW plane plus both RGB association passes before
mutation. The immutable result remains alive during normalization, so this
second allocation is real. These reservations can legitimately reject an
aggregate conversion earlier. Coordinates, association arithmetic and patch
geometry are unchanged; no further execution was performed for this review.

Research suggests additional ROI cases still needing independent native
evidence: an ROI beginning inside the bitmap and touching its right/bottom
edge may read surrounding source pixels into its expanded canvas; a negative
left/top origin may choose a different cropped branch; a wholly missing source
rectangle may require no paint instead of a transparent dummy under SourceCopy.
The existing strict-contained fractional ROI and full-image expansion controls
do not establish those cases. No speculative geometry replacement was made.

The later [five-case source contract observation](README-blur-source-roi-contract.md)
resolves the ROI questions above with independent actual Picture buffers and
records the supported native bridge correction. The original 389-profile
arithmetic observation remains unchanged.
