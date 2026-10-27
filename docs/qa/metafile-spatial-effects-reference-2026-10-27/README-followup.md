# Focused RedEye and fractional Blur follow-up

`RedEyeFollowupReference.cpp` is a new independent SDK observation program. It
reuses native startup, checked output/JSON and encoder helpers from the earlier
pointwise source by including it with its main renamed. Neither the earlier288
pointwise cases nor the410 spatial cases are invoked or re-recorded. Its new
workflow is triggered only by this new C++ and its own workflow path.

The first spatial artifact (run40511480514, sourcec712b62f, artifact12737507101)
showed deterministic but spatially varying RedEye correction that the original
mixed atlases could not distinguish. This follow-up isolates geometry, ROI,
repeated application and opaque colors; it does not supply guessed algorithms or
port-derived expected pixels. The changed source size witnesses distinguish
image-scale/stride effects from red classification.

There are **65 cases**,54 RedEye and11 Blur:

| RedEye group | Count |
| --- | ---: |
| Opaque solid red240,20,10; gray96; skin180,145,120; pure red255,0,0 |4|
| Centered squares of size1,2,4,8,16,24 and disks of diameter2,4,8,16,24; each full-image and exact blob-bounding ROI |22|
| Size8 square/disk shifted one pixel right, down, or both |6|
| Size8 square at4,4 and20,20 |2|
| Same center8 square with five single ROIs plus ordered overlap, reversed overlap, duplicate full ROI |8|
| Constant RGB128,20,10;240,120,10;240,20,120;120,60,60 |4|
| Horizontal red0…255 gradient, G20 B10 |1|
| Fresh repeat of identical solid-red and square8 inputs, later in the same process |2|
| Solid red at16×16,24×24,33×33; original32² solid with14² and16² ROIs |5|

Shapes are opaque RGB240,20,10 on opaque RGB96,96,96. Centered coordinates are
floor((32−size)/2). Squares cover half-open pixel rectangles. Disks use
(2x+1−(2left+size))²+(2y+1−(2top+size))²≤size², so their exact raster is
unambiguous. Single ROI variants are[0,0,16,32], [8,8,24,24], [11,11,21,21],
[−4,−4,20,20], [12,12,20,20]. Ordered overlaps use[0,0,24,24] and[8,8,32,32];
duplicate full ROI repeats[0,0,32,32] in one effect parameter array. This differs
from the two fresh-instance repeat cases, which observe same-input reproducibility.
No input alpha variation confounds this detector follow-up.

Eight Blur cases use original32² opaque step and asymmetric RGB definitions with
radii .75,1.25,2.5,7.3 and expandEdge=false. Step RGB splits at x16, y11 and
x+y23: R0/255, G31/223, B240/17. Asymmetric RGB is(11x+53y,43x+7y,19x+37y)
modulo256. These narrow fractional witnesses refine radius rounding without
recapturing the original radius/alpha/expanded matrix.

Three additional opaque black17×33,17×129,17×257 sources have full-width colored
horizontal bars: R255 at rows0 and128, G255 at rows1 and129, B255 at rows64 and256,
where those rows exist. Radius3, expandEdge=false, full-image source. Full-width
bars isolate vertical filtering from horizontal attenuation and distinguish
first-row effects from possible128-row tiling. Every row is captured; no numeric
expectations or special first-row implementation are assumed.

## Native paths and output

Execute `generate`, `direct-v1`, `replay`, `replay-v1` with the same outputfolder.
Generation records each original SDK EMF in its actual source-sized pixel frame.
Independent fresh effect instances measure in-place and bitmap-returning
ApplyEffect (including returned outputRect/true dimensions). Replay measures the
actual `Bitmap(path,FALSE)` constructor, intrinsic GetPixel data, and natural-size
Picture drawing with default interpolation, PixelOffsetHalf, WrapTileFlipXY and
transparent SourceCopy under startupv1 andv2. It never stretches different
intrinsic sizes into an assumed32² output, including the three tall images.

Every requested atlas and actual source GetPixel RGBA/PNG is saved, keyed by case
name. All output RGBA is complete row-major top-left straightRGBA, not selected
samples. Case metadata records exact source dimensions, shape/bounds/foreground,
parameter RECT arrays and matching originalEMF. `direct` and `created` nested
objects carry independent statuses and filenames. Aux bytes are preserved if
provided (bounded1MiB). The local pixelwriter bounds each output dimension to512; allrequested inputs
are≤257 in each dimension and no expanding effect is used here.

RedEye calls use the normal SDK wrapper with a readable struct-plus-tail buffer
and a stable pointed RECT array, matching the first assay's safe backing policy.
Direct success still does not prove correct serialized SDK pointer handling;
original wires and actual Bitmap playback are retained separately.

Nonzero SDK statuses are observations. Unexpected internal/setup/output failures
produce valid caseerror records and a nonzero process exit. The workflow records
source/compiler/platform, loaded GDI+ DLL path/version, included utility source
hash and sorted output SHA256/length inventory. No application tests are run.
Primary SDK contracts remain the official references linked by the original
spatial README; this follow-up adds no numerical formula assumption.
