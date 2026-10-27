# Large Blur basis and radius-boundary assay

`LargeBlurBasisReference.cpp` records eight new native SDK observations. It does
not regenerate the earlier 410-case, followup, decision-boundary, or pointwise
inventories. It includes only the original pointwise utility implementation with
its main renamed; direct/create/record/replay transport follows the independently
run large decision-boundary assay. `NOMINMAX` is defined before Windows headers.

All sources are opaque 32×32, tightly described by original requested RGBA and
actual SDK GetPixel RGBA/PNG, at 96 DPI. The six basis cases use four 16×16
quadrants: top-left red, top-right green, bottom-left blue, bottom-right black.
The active channel amplitude is 255 or 128, each observed at radius 31, 32, and
255. These independent channel bases expose coefficient/interpolation and
quantization behavior without fitting arbitrary output tables. Alpha is 255 in
every quadrant, including black.

The other two cases use the original asymmetric formula
RGB((11x+53y) mod256, (43x+7y) mod256, (19x+37y) mod256) at radius 19 and 20. They
bound the current modeled small/large transition without embedding that model
or an expected outcome in the assay. Every case uses expandEdge=false and
null/full direct ROI. Original recorded source rectangles cover the full source,
with identity image matrix, zero translation, and a 32×32 pixel metafile frame.
True constructor/intrinsic sizes are recorded and checked against that frame;
replay is never resized to disguise another intrinsic size.

The four executable modes are `generate`, `direct-v1`, `replay`, and `replay-v1`,
sharing one private output directory. Each direct operation constructs a fresh
source bitmap and a fresh SDK Blur object. Generation additionally records the
original SDK EMF. Both in-place ApplyEffect and the bitmap-returning overload are
observed, retaining all statuses, outputRect, complete pixels, dimensions, and
bounded auxiliary bytes if provided. Separate startup-v1/v2 replay processes
load the original EMF with `Bitmap(path,FALSE)`, emit intrinsic GetPixel pixels,
and perform the pinned Picture natural-size draw with default interpolation,
PixelOffsetHalf, WrapTileFlipXY, and transparent SourceCopy. SDK rejection statuses
remain observations; setup, output, or internal exceptions emit an error and
make the process fail.

The narrowly scoped workflow triggers only on this new C++ source or its own
workflow. It records source revision, compiler/platform, loaded GDI+ version,
and SHA256/length inventories of inputs and all outputs. The shared utility
include is explicitly hashed. No application checks, proposed blur formulas,
fitted lookup tables, or pixel tolerances are part of this measurement tool.
