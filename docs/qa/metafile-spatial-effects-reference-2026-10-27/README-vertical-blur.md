# Two-case vertical Blur contract assay

This new standalone SDK program observes exactly two NEW inputs,17×129 and33×129.
Both contain opaque RGB((37y+11x) mod256,(71y+19x) mod256,(13y+29x) mod256), with
96DPI and top-left row-major coordinates. Blur radius3, expandEdge=false, full
source rectangle, identity matrix and matching actual source-sized metafile frame
are the only effect/placement settings.

Every row varies, so full output distinguishes the leading vertical-processing
extent across differing widths. Earlier sparse bars could not distinguish two
candidate row-count rules once the untouched source rows were all black. This
program supplies native observations, not a guessed tile algorithm or expected
pixels. It does not re-run the410,65,10, or288-case inventories.

`TwoCaseVerticalBlurReference.cpp` includes the original pointwise native utility
source with its main renamed, and uses a local checked pixelwriter bounded512 in
each dimension. The two source sizes are honored by allocation, requested-byte
loops, original EMF frame, intrinsic GetPixel capture, and final output. Actual
intrinsic dimensions and expectedSize remain separate, with no rescaling.

Run `generate`, `direct-v1`, `replay`, `replay-v1` against the same output directory.
The first mode records originalSDK EMFs and actual/requested source RGBA/PNG;
independent fresh effects capture in-place and bitmap-returning ApplyEffect,
including outputRect and auxiliary bytes if supplied. Direct-v1 observes those
overloads under startupv1. Replayv1/v2 use actual Bitmap(path,FALSE), retain
intrinsic pixels and natural-size Picture drawing with default interpolation,
PixelOffsetHalf, WrapTileFlipXY, transparent SourceCopy.

All output RGBA is complete, not row samples. Exact source definition/dimensions,
parameters, matrix/frame, statuses, filenames and original wires are retained.
Nonzero SDK statuses remain observations; setup/output/internal exceptions fail
the process and preserve a caseerror. The narrowly triggered new workflow records
compiler/platform/source, loaded GDI+ DLL/version and SHA256 input/output inventory.
No previous source/workflow is edited, and no application checks are part of this
contract measurement. Official Blur/ApplyEffect references are linked in the
original spatial README. Numerical implementation remains dependent on the
actual native artifact, not this source merely existing.
