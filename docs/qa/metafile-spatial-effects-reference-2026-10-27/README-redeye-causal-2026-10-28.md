# RedEye causal model development checkpoint

The original Swift implementation in `Sources/TurtleGitMetafile/RedEyeImageEffect.swift`
now applies the nonuniform detector with an explicit **deterministic fresh-first-use
FILE-v1 contract**. Original process-history observations remain unchanged and
separately identified; the renderer does not invent native prior-process state.

The isolated arithmetic comparison covers every one of the **195 retained RedEye
source cases** under that verified input domain: 185 complete painted buffers
within the existing one-byte bound (182 byte-exact), plus ten whole-draw no-paint
results. Two old pure-red255 expected buffers require the independently captured
fresh-context overlay described below. No source case is removed, no tolerance is
widened, and no output is fitted. Grouped application/helper/Core/native acceptance
has not run at this checkpoint.

## Causal components

The implementation uses one source-derived pipeline for every source, without source
names, source hashes, captured-pixel tables or case-dependent constants:

* Integer luma is `floor((9G + 2B + 5) / 11)`; darkness is `G + 2B/9`.
  Red excess is `max(0, R - max(G,B))`. The centroid weights are red excess
  divided by integer luma, with unit weight for positive-red/zero-luma pixels.
* The 30th/70th percentile luma spread selects the radial coefficient from
  `.25, .5, .66, .75` at spread boundaries `25, 40, 80`. This independently
  explains why the centered square26 and square28 have disjoint radial
  coefficients despite identical fully-red angular bins. All five new continuous
  gradients and all 29 matched-model inputs are byte-exact.
* Sixty angular sectors accumulate red excess and darkness inside the detected
  disc. Radial falloff competes with the squared relative-darkness falloff;
  the squared term is disabled at twice the sector's mean darkness. Per-operation
  binary32 rounding toward zero is explicit. The final channel correction uses
  the previously measured `(-11, +5, +5)/16` direction with half-up rounding.
* Alpha-zero source pixels do not participate in angular populations or luma
  percentile populations. Source normalization and the two output associations
  match the existing Windows bridge conversion; alpha itself is retained.
* Every authored area reads the immutable original source and replaces its
  complete clipped ROI. The preceding red centroid is carried into later area
  moments. Removing that carry regresses 13 previously exact multiple-area
  buffers. A first-brightest image-coordinate point also survives tied maxima
  across areas. This fixes all 14 residual pixels in the disjoint `redeye-17`
  witness while leaving the other 194 numerical predictions unchanged.
* A single-pixel ROI copies its source. Valid areas clipping empty reject the
  entire draw, including lists with an earlier valid area. That no-paint result
  preserves existing destination paint rather than emitting transparent pixels.

The original fixed-ROI, connected-component, mean-mixture and fitted radial
hypotheses remain historical development evidence. Their partial matches do not
constitute accepted general application paths.

## Research attribution and independent evidence

A primary implementation research lead was ChristopherVR's
[emf-converter source at commit effcf337218fefc08e4ac8f74e59cd2af1a9235c](https://github.com/ChristopherVR/emf-converter/blob/effcf337218fefc08e4ac8f74e59cd2af1a9235c/src/emf-plus-image-effects.ts),
published under Apache-2.0. Its mathematical behavior suggested the luma,
percentile, darkness and precision mechanisms. The Swift code is an original
formulation integrated with our existing area/budget/correction architecture;
no external code, external capture buffers or expected pixels are incorporated.
The existing GPL declaration is unchanged. Our original Windows buffers are the
only numerical oracle.

Executing that external model unchanged against our inputs gave 122/195 buffers
within one byte. Our independent observations are necessary: tied highlights,
central eligibility, immutable per-area sources, alpha-zero populations,
single-pixel identity and first-brightest carry initially raised the candidate to 183 plus
ten no-paint results. Independent fresh-process observations then resolve the two
remaining source-context differences without changing the mathematical model. The external model's claims about process memory are a
research hypothesis, not an explanation accepted without our own observations.

## Reproducing the arithmetic development probe

From the repository root, use a Python environment with NumPy:

```sh
python3 docs/qa/metafile-spatial-effects-reference-2026-10-27/prepare-redeye-causal-inputs.py \
  Tests/TurtleGitCoreTests/Fixtures/Metafile/SpatialEffects build/qa \
  build/qa/redeye-causal-inputs.json \
  --context-overlay Tests/TurtleGitCoreTests/Fixtures/Metafile/SpatialEffects/playback-context-reference.json
/usr/bin/swiftc -O Sources/TurtleGitMetafile/SpatialImageEffects.swift \
  Sources/TurtleGitMetafile/RedEyeImageEffect.swift \
  docs/qa/metafile-spatial-effects-reference-2026-10-27/RedEyeCausalArithmeticMain.swift \
  -o build/qa/redeye-causal-arithmetic
build/qa/redeye-causal-arithmetic build/qa/redeye-causal-inputs.json \
  build/qa/redeye-causal-arithmetic.json
```

The preparer verifies retained EMF and reference RGBA hashes, locates the original
source atlases by exact EMF hash, and verifies byte dimensions. The capture
ZIP/member/source receipts remain the atlas provenance authority. The command
compiles a standalone Foundation arithmetic executable; it does not launch the
app, helper, receiver, Core tests or native windows.

## Verified fresh process and historical process contexts

Native Windows run40683242082, artifact12812964186, replays the unchanged three
retained EMFs in nine fresh processes and two forward/reverse sequence processes.
All three fresh repetitions of each input agree byte-for-byte with the model;
intrinsic and final output agree for all 15 playbacks. The accepted disjoint-area
control is invariant across every context.

The pure-red255 inputs depend on preceding native process activity:

* `followup-solid-pure-red.emf` is fresh SHA `4cee5c0822ca13d8009fe27456df4138ceefaedb0322fcb7f1137a23e3bf80fa`.
  Reversed sequence playback reproduces old SHA `8cc83b558ddccbfb918c639091395b262dd299487e94c33a034f7dfe55aa5ee1` exactly.
* `detector-color-pure-red.emf` is fresh SHA `6464cf18abe8b53f67d1df665201304034bc8417c3a508ce505493be493e4489`.
  Both sequence orders reproduce old SHA `5adb84f7707e795ba9e273a454fc42bc0db13a7a370026eac9d87d003af14b44` exactly.

Fresh outputs use the source-derived quarter radial coefficient. Both old
outputs are also exactly reproduced by the already measured `.75` coefficient,
with every other term unchanged. This explains the numerical difference but
identifies no internal memory mechanism. Observations/PNG encoding occur between
sequence files, so the evidence establishes native process-history dependence,
not exclusively a dependency on preceding RedEye calls or random nondeterminism.

The separate `playback-context-reference.json` overlay verifies the unchanged
original manifest, input SHA, old reference path/SHA and fresh observation SHA
before selecting a fresh expected buffer. Every old manifest entry and reference
buffer remains intact. There is no such mapping or fixture knowledge in the
production renderer. The source-derived fresh model applies uniformly to every
input, including the distinct pure-red240 controls.

The atomic preflight validates every authored endpoint before reporting no-paint
or allocating detector/output storage. It reserves aggregate work and four-byte
allocation-equivalent units for full-image copies, per-area sample/sector buffers
and fixed tables, with overflow checked before changing the shared budget.

The next checkpoint is the complete grouped renderer/application validation;
these arithmetic observations alone do not establish that acceptance.
