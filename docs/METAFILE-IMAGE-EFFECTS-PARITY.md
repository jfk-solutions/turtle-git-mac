# EMF+ serialized bitmap image effects

The pinned TortoiseGit image consumer opens images through GDI+ `Bitmap(file,
FALSE)` in `src/Utils/MiscUI/Picture.cpp`; IDiff selects files through
`src/TortoiseIDiff/MainWindow.cpp`. The native image decoder used by IDiff,
repository comparisons and image-conflict previews implements serialized
ColorMatrix, ColorLookupTable and Brightness/Contrast, the separate
[supplementary pointwise family](METAFILE-POINTWISE-EFFECTS-PARITY.md), and the
Blur, Sharpen and RedEyeCorrection continuation below. Implementation and native
source observations do not certify complete image-format or application parity.

## Connected implementation

`EmfPlusSerializableObject` (0x4038) validates its GUID packet, exact declared
parameter extent and finite/ranged fields before retaining immutable parameters
on the current playback owner. DrawImagePoints validates its complete point data
before consuming that owner's pending block. An E-set draw applies the block to
a copy of the source bitmap; E-clear and missing-block draws paint the ordinary
source. Unused effects survive no-draw Save/Restore and container pairs. Child
metafile playback has its own effect owner, while pixel/output work budgets are
shared across nested conversions.

The PNG pixel bridge runs effects before the existing crop, affine placement,
wrap, clip and SourceCopy paths. Image-table objects, original file bytes and
comparison data remain unchanged. Ordinary 8-bit RGB samples retain their source
color profile and use the measured premultiplied-source round-trip before drawn
effects; other supported native image layouts use bounded RGBA conversion. Direct
Bitmap.ApplyEffect and metafile DrawImage playback are distinct reference paths. Matrix channel calculation uses original channels
for every output component, including alpha. Lookup tables preserve distinct
B/G/R/A wire channels. Brightness/contrast changes RGB and leaves alpha unchanged;
its saturated endpoints and contrast-100 threshold have explicit bounded paths.
Unknown effects, bad lengths/values, excessive pixel work and failed native
adapters fail the whole conversion instead of exposing a partial image.

## Native Windows contracts

The standalone reference was necessary before application validation because
parameter documentation does not specify exact brightness rounding or tolerant
playback lifetime. The [initial native run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40491004875)
records 81 brightness/contrast parameter pairs across all 256 channel levels,
independent RGB and alpha ramps, matrix/lookup channels, original native EMF and
playback through the file constructor. Its artifact SHA256 is
`a7096a1bb97b248fac11ba7ffe3e0ff57b93f6b3d331435ee30feb20ea76633e`.

The [focused replay follow-up](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40491928071)
reuses those direct ramps, adds isolated pending-block/plain-draw and state-stack
witnesses, and replays using both GDI+ startup versions 1 and 2. All 18 loads and
draws succeed and all nine complete image buffers are byte-identical between
startup versions. In the plain-draw witness, an E-clear clone at Y4 precedes the
original E-set draw at Y0; both paint plain pixels, proving consumption by the
first draw. The follow-up artifact SHA256 is
`1a3147347a5d3b7df6ff90ac93be710e3253aa894f93d4e9fd20a3a1f1c943d0`.
Original wires, derived fixtures and hash provenance remain distinct.

The clear Float32 brightness model differs from native Windows by at most one
channel value in this recorded grid: 606 of 20,736 scalar entries differ. The
2,304 sampled contrast-100 entries match exactly. This is a measured precision
limit over these parameter pairs, not proof of exact agreement for every pair.

## Spatial effects implementation and source contract

Blur, Sharpen and RedEyeCorrection now use bounded native pixel operations before
source clipping, affine placement, image wrapping and SourceCopy composition.
Their serialized parameter lengths, finite ranges and signed area endpoints are
validated before use. Source bytes and the image-table object remain immutable.
Every spatial conversion reserves aggregate pixel planes and scalar work before
allocation, including crop/halo preparation, axis scratch planes and output
association copies. Limits apply across nested draws, not independently per
bitmap. Malformed input and exhausted limits remain conversion failures.

Blur follows the measured ordered Gaussian construction and independent Q8
rounding of the center's two half contributions. Small kernels retain the native
leading-row vertical extent; large kernels complete reduction, filtering and
reconstruction along one axis before starting the other. Partial blocks average
their actual samples, and expanded canvas alignment follows its image-space
origin. Sharpen uses the measured quantized unsharp gain and alpha behavior.
The [arithmetic receipt](qa/blur-sharpen-precision-implementation-2026-10-28.json)
records an optimized standalone Swift comparison: all 389 retained profiles are
byte exact, including 69 large, 311 small, six coefficient and three matched
contribution cases. These are arithmetic buffers, not application acceptance.

The [five-file ROI observation](qa/blur-source-roi-observation-2026-10-28.json)
establishes the adapter contract independently. A noncontained expanding Blur
reads surrounding original bitmap pixels into a bounded halo canvas, with zero
only beyond the bitmap, and filters that canvas in place. Strictly contained
regions keep their cropped edge behavior. An empty clamped working region is a
no-paint result: it preserves the destination under SourceCopy. Exact touch is
different, because the inclusive extra working sample can still produce paint;
no visible-intersection shortcut discards that draw. All five complete actual
Picture outputs match the original mathematical adapter predictor exactly.
The original 389-profile arithmetic source is unchanged by this adapter repair.

RedEyeCorrection processes authored areas in order, with image-local center and
first-brightest-point carry, angular statistics and radial correction. Each area
reads the immutable source rather than the preceding area's corrected pixels.
Measured source association precedes its statistics; zero-alpha samples do not
participate. A single-pixel area preserves its source. If any otherwise valid
area clips to empty, native FILE playback rejects the whole draw, including a
list containing earlier valid areas. The same typed no-paint path preserves
prior destination paint rather than replacing it with transparency. See the
[fresh-context implementation record](qa/metafile-redeye-fresh-context-2026-10-28.json)
for the public Swift entry point's 195-case scope: 185 painted cases remain within
the existing one-byte bound, including 182 exact buffers, and ten whole-draw
no-paint cases preserve prior output. The earlier causal receipt retains its
original unresolved observations; the fresh-context record resolves their domain.

The [bounded playback-state capture](qa/metafile-spatial-effects-reference-2026-10-27/README-playback-state.md)
uses 16 native startup-version-1 processes for 20 actual Picture file playbacks:
15 observations of three unchanged RedEye wires, followed by five separately
recorded Blur ROI files. Nine fresh RedEye playbacks match the source-derived
model exactly. The two opaque pure-red wires reproduce their different older
expected buffers in ordered process contexts, while the disjoint-area control
is invariant. TurtleGit's conversion contract is deterministic fresh first use;
unrelated prior native playback is not serialized input. Both old observations
remain intact. The separate generic references
`fresh-file-v1-followup-solid-pure-red.rgba` and
`fresh-file-v1-detector-color-pure-red.rgba` identify the fresh domain through
verified source identity while preserving every older manifest entry and buffer.
This evidence establishes a process-history difference, not an internal memory
mechanism or random behavior. Later intrinsic reads and first
Picture output are also retained as separate stages wherever they differ.

Behavioral research consulted ChristopherVR/emf-converter at
`effcf337218fefc08e4ac8f74e59cd2af1a9235c` (Apache-2.0). The Swift formulations
and arithmetic predictors are original implementations checked against our own
verified native buffers. No external implementation code, reference pixels or
new dependency was incorporated; project license declarations are unchanged.

Spatial placement now samples the raw effect plane with bounded premultiplied
bilinear arithmetic at native device sample positions. A separate opaque coverage
plane describes geometry; transparent color cannot become a no-paint decision.
Fractional source edges use the native hard coverage rather than SVG clip
antialiasing. The completed file uses the generic Picture rectangle sampler when
its directed binary32 coordinate recurrence has nonidentity quantized lookups;
the identity path preserves vector painting. A sampled result retains the original
SVG in nonrendered definitions for text/transform metadata, with a combined output
size guard. The source
association stays before effects, while output associations occur after filtering.
Ordinary/pointwise preparation removes the boundary supplied by this final sampler,
so mixed documents do not gain an extra normalization. Natural file dimensions
retain recorded device/mm DPI. The [sampling repair record](qa/metafile-spatial-sampling-repair-2026-10-28.json)
separates the original integration failures from its isolated arithmetic proof
and the actual grouped results below.

The [spatial checkpoint](qa/metafile-spatial-effects-2026-10-28.json) records the actual grouped helper/Core/native
validation, including initial failures and any affected rechecks. The Windows
capture and standalone arithmetic results alone do not prove that checkpoint,
physical image-window acceptance, signed deployment,
every undocumented native process state or whole-port completion. Existing
oracles and their original bytes remain preserved; no tolerance was widened.

## Earlier pointwise checkpoint and remaining scope

[The batch record](qa/metafile-image-effects-2026-10-27.json) records grouped
runtime/Core/native validation and original failures. E without a pending block
is a positive ordinary-image case; the old fixture name and bytes are retained.
Malformed known blocks and unknown effects remain negative cases. The local checkpoint passes eight distinct focused Core methods cumulatively
and two native workflow groups using Apple Git2.54 and bundled Git2.55. The
17 positive images and ten malformed refusals retain source-byte checks; actual
helper cancellation and original-image conflict staging are included. Both
receivers are reaped and independently absent. Initial fixture extent/background
errors and the low-alpha source-normalization repair remain recorded.

The renderer
retains its existing opaque-white initial canvas outside command coverage. The
Windows reference uses transparent initialization, so fixture expectations adapt
only unpainted pixels; every painted pixel retains the native alpha assertion,
including fully transparent lookup-table output.

The [supplementary pointwise family](METAFILE-POINTWISE-EFFECTS-PARITY.md) adds
ColorBalance, HueSaturationLightness, Levels, ColorCurve and Tint, including
measured ordinary-image compatibility for native Curve serialization.

Independent rectangle-record interposition, effects on embedded metafile image
objects, every color profile/decoder layout, physical image-window acceptance
and signed distribution remain separate. The spatial family above has its own
separate grouped checkpoint and does not inherit this earlier pointwise pass. The
installed build19 includes this earlier three-effect source batch; it predates
the supplementary five-effect source batch. A green Windows reference run proves
the reference assay, not that the new macOS decoder or whole port has passed.
