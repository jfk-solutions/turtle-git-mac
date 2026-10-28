# Bounded Blur source-rectangle contract capture

The authored experiment below has now returned native observations in
[run 40683242082](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40683242082).
The [observation receipt](../blur-source-roi-observation-2026-10-28.json) records
source verification, actual Picture pixels and the resulting adapter correction.
It preserves previous native captures unchanged.
`BlurSourceRoiContractReference.cpp` records exactly four new SDK witnesses and
one contained transport control. The shared source is the existing independent
opaque 32×32 asymmetric RGB formula, without new colors or a candidate kernel.

Every original EmfPlusOnly file has a 64×64 frame. It first paints an opaque
RGB(17,41,73) rectangle, then requests Blur radius 2 with ExpandEdge, SourceCopy
and image-space translation (16,16). The prior paint distinguishes a rejected
or empty draw from a transparent bitmap that erases destination pixels.

| Original SDK file | Source rectangle x,y,w,h | Discriminator |
| --- | --- | --- |
| `blur-roi-fully-outside.emf` | -8,6,4,12 | Visible source ends before bitmap |
| `blur-roi-exact-touch.emf` | -6,6,6,12 | Right endpoint exactly zero |
| `blur-roi-partial-right-bottom.emf` | 24,25,12,11 | Source begins inside and crosses right/bottom |
| `blur-roi-negative-left-top.emf` | -4,-3,18,19 | Crosses left/top with contained far endpoints |
| `blur-roi-contained-control.emf` | 4,6,17,19 | Accepted contained integer control |

The generator runs as `BlurSourceRoiContractReference.exe OUTPUTDIR` using SDK
startup version 2, and writes `generate-blur-roi.json`, five untouched SDK EMFs,
one observed source PNG/RGBA and its separately authored requested RGBA. It
asserts exact requested/observed source equality. It records parameter,
metafile-creation, sentinel-paint and effect-draw statuses separately. A rejected
out-of-bounds effect-draw status is retained as an observation; construction and
contained-control failures are fatal. SDK rejection may omit an effect draw
from the original wire, so later interpretation must inspect that wire and the
recorded status rather than assume it contains one.

The coordinated playback utility opens each file in its own startup-version-1
process through `Bitmap(file,FALSE)`, retains intrinsic RGBA/PNG, and then runs
the actual Picture path: SourceCopy, Default interpolation, Half pixel offset,
TileFlipXY. It retains final RGBA/PNG and load/draw statuses. These five fresh
playbacks join the separately approved minimal RedEye state discriminator in
one workflow; they do not add repeats, a direct-effect sweep or a new corpus.
The workflow records source hashes, original EMF hashes and all artifact member
hashes. No expected pixels, tolerance changes, fitted coefficients or production
geometry replacement are part of the proposed capture.

## Observed result and adapter correction

All 20 generator status fields and 15 playback startup/load/draw status fields
are zero. Each of the five 4240-byte originals contains one serialized Blur and
one E-set DrawImagePoints; its embedded 32×32 source matches the separately
observed and authored source pixels exactly. Each playback has its own startup-1
process. Parent verification checked all 115 combined artifact member hashes and
lengths; the receipt retains that provenance separately from this Blur analysis.

The fully outside working crop leaves every sentinel pixel unchanged. It now
returns the existing typed no-paint result rather than an erasing transparent
dummy. Exact touch behaves differently: its inclusive extra working source
column produces paint over the whole 6×12 destination, including transparent
pixels under SourceCopy. A visible-intersection early gate would be incorrect.

The other discrepancies come from preparing the expanded canvas after cropping
away surrounding bitmap pixels. Noncontained expanding Blur now copies the
original bitmap intersection into a bounded full-resolution halo canvas, with
zero only outside the bitmap, filters that canvas in place, and returns its
image-space origin. Its dimensions also select the small-radius vertical row
extent. The exact-touch witness distinguishes this from retaining the original
ROI row count. The contained control keeps its previous cropped behavior.

The original mathematical adapter predictor reproduces all 20,480 actual
Picture pixels exactly across the five full 64×64 outputs, including sentinel
paint, clipping and both association boundaries. No expected buffer or tolerance
changed. Later intrinsic reads retain one-level differences on 9, 32 and 89
channels for the partial, negative and contained cases; these are separate
consumer-stage observations, not replacements for actual Picture output.

This is source/wire and arithmetic analysis. Application/helper builds, Core and
native suites remain the parent-owned grouped integration checkpoint. The
389-profile kernel source is unchanged, and no patch geometry changed.
