# Spatial bitmap effects: independent Windows SDK contract assay

This original program observes Blur, Sharpen, and RedEyeCorrection before their
macOS implementation. It contains no port formulas, reference expectations, or
Wine code. It includes the earlier pointwise C++ only for native startup,
encoders, checked output and JSON helpers; the renamed earlier main is never
called and its 288-case corpus is not captured again. No TurtleGit app or Core
checks are part of this workflow.

The deterministic inventory contains **410 cases**:

- Five 32×32 atlases × eleven radii (0, .1, .25, .5, 1, 1.5, 2, 3, 5, 10, 255)
  × Blur expandEdge false/true: 110.
- Those same atlases/radii × Sharpen amounts 0, 25, 50, 100: 220.
- Five padded Blur recordings at radii .25, 1, 2, 5, 255: 5.
- One cropped/scaled Blur recording: 1.
- Two513×17 strip atlases × five radii (1,1.5,3,10,255) × Blur expand false/true:20.
- Three RedEye atlases × eighteen area-array variants: 54.

## Source pixels and geometry

Except the two513×17 strips, sources are32×32. Every source is straight ARGB at 96 DPI. Requested RGBA and actual native GetPixel
RGBA/PNG are saved separately for each atlas in `generate`, before any effect.
The C++ functions are the executable pixel definitions; arithmetic cast to BYTE
wraps modulo256. Top-left row-major source coordinates are x,y=0…31.

- `impulse`: opaque black, red255 at (15,16), green255 at (2,3), blue255 at (31,0).
- `step`: opaque; R=0/255 split at x16; G=31/223 split at y11;
  B=240/17 split at x+y23.
- `constant`: opaque RGB71,139,213, for constant preservation and border taps.
- `asymmetric`: opaque RGB(11x+53y,43x+7y,19x+37y), modulo256.
- `alpha`: RGB(17x+3y,5x+29y,251−7x+11y), modulo256; alpha cycles through
  0,1,2,3,7,15,31,63,127,128,191,254,255 at index (floor(x/3)+floor(y/7)) mod13.
- `strip-impulse`: opaque black513×17 with vertical bars across all17rows: red255 at x256, green255 at x2, blue255 at x510. The vertical-constant signal preserves measurable horizontal response at large radius; the32×32 atlas retains independent2D point impulses.
- `strip-constant`:513×17 opaque RGB71,139,213. These expose full large-radius horizontal support independently of32-pixel source clipping.
- `redeye`: i=x+32(y mod16); RGB indices i mod13, floor(i/13) mod13,
  floor(i/169) mod13 into 0,15,31,63,95,127,128,159,191,223,239,254,255.
  Upper half opaque; lower half alpha=(x mod4)×85.
- `redeye-swapped`: the same lattice with G/B exchanged.
- `eye`: red square on gray and red disk on skin-like surroundings above;
  isolated red pixel and increasing disks below, crossed with alpha0,1,127,254,255.
  These synthetic spatial witnesses avoid assuming the correction is a purely
  pointwise threshold. They do not claim photographic detection fidelity.

The eighteen RedEye area arrays include none/full/left/right/interior/single
pixels, zero-width/height, reversed endpoints, partial and complete out-of-bounds,
ordered overlapping pairs, reversed overlap order, duplicate full area, and
separate areas. All original coordinates are retained; no pre-clipping occurs.
This distinguishes **effect areas** from the ApplyEffect ROI (null/full image in
this assay). Legitimate SDK refusals remain observations, not setup failures.

Ordinary recordings have a fixed32×32 frame and source at0,0. Padded recordings
have source origin (ceil(radius),ceil(radius)), frame(sourceWidth+2ceil(radius))×(sourceHeight+2ceil(radius)), up to1023×527 for the strips;
thus expandEdge output outside original image bounds remains visible. The one
cropped witness uses source RectF(4,6,17,19), image matrix(2,0,0,1.5,16,16), and
96×96 frame. Manifests record source rectangle, matrix, source origin, frame and
actual intrinsic sizes. Nothing is rescaled to fit expected dimensions.

## Four execution modes and output contract

`generate OUTPUT` starts GDI+ v2 and writes each original SDK-recorded `.emf`.
Fresh concrete effect instances independently observe in-place ApplyEffect in
`direct`, and bitmap-returning ApplyEffect in `created`. The latter retains the
returned outputRect and true dimensions, including possible expansion. In-place
Blur explicitly ignores expandEdge according to Microsoft; that path alone
cannot establish expansion behavior. `direct-v1 OUTPUT` observes both overloads
under startupv1 without replacing original EMFs.

`replay OUTPUT` and `replay-v1 OUTPUT` use startupv2/v1 and the pinned Picture path:
`Bitmap(path,FALSE)`, intrinsic GetPixel capture, then natural-size DrawImage with
default interpolation, PixelOffsetHalf, WrapTileFlipXY, transparent SourceCopy.
Every result includes actual dimensions and `expectedSize` separately. Successful
pixels have `.rgba` and `.png`; no opacity or direct/playback equivalence is
assumed. Aux data, if supplied, is preserved as `.aux`, bounded1MiB. All output
images are bounded1024², sufficient for the largest requested radius.

Manifests `generate.json`, `direct-v1.json`, `replay.json`, `replay-v1.json` contain
ordered cases with exact parameters, atlas and original EMF filename. Nested
`direct` and `created` objects have independent setParameters/apply statuses and
pixels; replay has bitmapLoadStatus, intrinsicWidth/Height, intrinsic pixels,
drawStatus and final pixels. Nonzero API statuses do not become process errors.
Setup, output, unexpected-size-bound and internal exceptions do cause a nonzero
exit; their case records retain an error, and each completed case is flushed.
The loaded GDI+ DLL path is recorded. Workflow provenance includes its version,
compiler/platform/source revision and sorted byte-length/SHA256 inventory.

The SDK RedEye SetParameters wrapper passes struct size plus N×RECT bytes despite
having a pointer member. The assay provides readable struct-plus-tail allocation
and a stable pointed RECT array, avoiding an out-of-bounds host-memory read while
calling the ordinary SDK wrapper. Both the requested areas and original recorded
wire survive. A successful direct call does not prove correct serialization; the
replayed wire must independently show an active correction. No pointer payload
is treated as the normative serialized effect format.

Compile with the new narrow workflow's MSVC command. Automatic dispatch is scoped
to this new C++ and new workflow only. The workflow does not change or dispatch
any older assay. Initial source is prepared for review; no native observations
or algorithm precision claims exist until its artifact has actually run.

Primary contracts read for this assay:
[BlurParams](https://learn.microsoft.com/en-us/windows/win32/api/gdipluseffects/ns-gdipluseffects-blurparams),
[SharpenParams](https://learn.microsoft.com/en-us/windows/win32/api/gdipluseffects/ns-gdipluseffects-sharpenparams),
[RedEyeCorrectionParams](https://learn.microsoft.com/en-us/windows/win32/api/gdipluseffects/ns-gdipluseffects-redeyecorrectionparams),
[bitmap-returning ApplyEffect](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusheaders/nf-gdiplusheaders-bitmap-applyeffect%28bitmap_int_effect_rect_rect_bitmap%29).
Microsoft specifies parameter ranges and ROI/expansion behavior, but these pages
do not supply complete numeric algorithms. The native results must establish them.

## Initial compile failure and scoped repair

Windows run40511117352 (source1cf1a17a, job122212980515) failed before native
observations: the Windows `min` macro expanded the qualified `std::min` call.
The repair parenthesizes that function name. The same affected-source revision
changes the long-strip impulses to vertical bars, retaining the410-case count.
No pixel results are inferred from the failed run. The next native artifact must
identify this repaired source revision and its exact input hashes.
