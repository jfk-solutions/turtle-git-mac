# Large Blur decision-boundary assay

`LargeBlurDecisionReference.cpp` observes24 NEW SDK cases. It does not recapture
any earlier spatial, fractional, vertical or pointwise case inventory. It reuses
the original pointwise native utility include with main renamed, plus the proven
local512-dimension pixelwriter and checked direct/create/replay plumbing.

Inventory:

- Opaque asymmetric32×32, radius17,31,32,33,63,64,127,128, each expandEdge=false/true:16.
- Opaque asymmetric17×33 and33×17, radius31,32, each expandEdge=false/true:8.

Every source has RGB((11x+53y) mod256,(43x+7y) mod256,(19x+37y) mod256), alpha255,
96DPI. Source dimensions and complete requested/actual source RGBA/PNG are
retained per case. The original recorded source rectangle is the whole image.
Its image matrix is identity translated by(radius,radius) for expandEdge=true,
or zero translation otherwise. The fixed metafile pixel frame is source size
plus twice that padding; largest frame288×288. Thus expanded output can extend
outside the original source rectangle without disappearing at the recording
frame. The manifest records exact source/matrix/frame and true loaded dimensions.

These boundaries resolve whether the native optimized/large branch depends on
width, minimum dimension, or another size rule, and how pyramid scale changes
near powers of two. Earlier radius255 evidence supports a reduced-image pipeline
but leaves general dispatch and unexpanded coarse precision unresolved. No
candidate reduction threshold, Gaussian formula, or expected pixels are embedded
in this assay.

Run `generate`, `direct-v1`, `replay`, `replay-v1` with the same output directory.
Generation records original native SDK EMFs; independent fresh effect objects
observe in-place ApplyEffect and bitmap-returning ApplyEffect, including actual
outputRect/dimensions. The direct calls use null/full ROI. In-place Blur ignores
expandEdge by the official contract, so created outputs and recorded playback
are separate necessary expansion observations.

Replayv1/v2 use actual Bitmap(path,FALSE), full intrinsic GetPixel RGBA/PNG, and
natural-size Picture drawing with default interpolation, PixelOffsetHalf,
WrapTileFlipXY, transparent SourceCopy. Neither intrinsic nor final results are
stretched to a proposed size. Every output pixel and SDK status is retained.
Nonzero SDK statuses remain observations. Setup/output/internal exceptions create
caseerror and cause process failure; complete cases flush as they finish. Aux
bytes, if provided, are saved with a1MiB bound.

The new workflow is triggered only by this new C++ and its own workflow path.
It records source/compiler/platform/loaded GDI+ module version and SHA256/length
input/output inventories. The included original utility source is explicitly
hashed. No previous files or corpora are changed and no application checks are
run. Parameter and overload contracts are linked in the original spatial README.
Implementation equivalence must follow measured results, not this probe existing.
