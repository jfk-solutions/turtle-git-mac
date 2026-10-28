# Proposed bounded Blur source-rectangle contract capture

This is an authored source-contract experiment, not an observed result or a
macOS application check. It preserves previous native captures unchanged.
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

The scoped contract remains pending source review, commit and Windows execution.
Only independently verified returned pixels can resolve the adapter questions.
