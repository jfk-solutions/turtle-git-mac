# Axis-isolated large Blur quantization discriminator

`BlurAxisQuantizationReference.cpp` contains exactly **four new cases plus one
same-job constant control**. It never recaptures the earlier spatial inventory.
The transport reuses the reviewed RedEye-model utility pattern and the original
pointwise utility's shared SDK setup, PNG encoder and JSON/file helpers. It does
not invoke those utilities' renamed entry points or their inventories.

All five inputs are opaque32×32 at96DPI. They use native Blur radius255,
expandEdge=false, null/full direct ROI, identity recorded image matrix and the
whole32×32 source rectangle. The original metafile frame is exactly32×32.

| Four new inputs | Nonblack half | RGB amplitudes | Other half |
| --- | --- | --- | --- |
| horizontal-a1-63-128 | x<16 | 1,63,128 | 0,0,0 |
| vertical-a1-63-128 | y<16 | 1,63,128 | 0,0,0 |
| horizontal-a97-200-255 | x<16 | 97,200,255 | 0,0,0 |
| vertical-a97-200-255 | y<16 | 97,200,255 | 0,0,0 |

“Horizontal” means variation along x and “vertical” means variation along y;
it does not name the dividing edge's orientation. Every pixel has alpha255.
The constant control has RGB91,157,223 and alpha255 over the entire source,
with the same effect, ROI and frame. It provides a transport/normalization
baseline without another previous corpus run.

The source has the same dimensions and dyadic model lattice as the retained
radius255 quadrant controls. Each new channel depends on only one source axis,
so its output isolates axis-product/rounding/reconstruction behavior from the
quadrants' two-dimensional mixing. The retained step control supplied a single
horizontal amplitude255 channel and a different vertical reduced91/223 channel;
it did not provide matched per-axis levels. The small amplitudes and values near
the existing scalar quantization witnesses provide independent observations.
There is no proposed Gaussian coefficient, resampling pipeline, fitted corner,
expected pixel buffer, threshold or acceptance tolerance in this capture tool.

Run four separate processes: `generate`, `direct-v1`, `replay` and `replay-v1`.
Generation uses GDI+ startup2 and records each original native EMF. Both direct
startup processes retain requested source bytes and actual GetPixel RGBA/PNG,
with explicit requested filename and comparison result. In-place and
bitmap-returning effects each receive a fresh source and effect object. Direct
outputs include full RGBA/PNG, SDK statuses, actual dimensions and the created
output RECT. Unexpected statuses, dimensions, setup/output failures and source
mismatches fail the capture; the source output is never replaced by an oracle.

Both replay processes open the original EMF through actual
`Bitmap(path,FALSE)`. They retain intrinsic GetPixel RGBA/PNG and a separate
natural-size Picture draw using InterpolationModeDefault, PixelOffsetHalf,
WrapModeTileFlipXY, transparent clear and SourceCopy. No result is stretched to a
proposed size. The four-mode inventory therefore contains **40 effect/replay
RGBA buffers**, plus **20 requested/observed source RGBA buffers**, **five
original EMFs** and **75 SDK status observations**. Direct and replay PNGs are
retained as well. Those counts describe the source experiment, not a renderer
verification result.

The scoped Windows workflow checks five cases per manifest, the four planned
cases/control count, output dimensions/RECTs, source identity and SDK statuses.
It hashes the new C++, workflow, original shared utility and compiled executable;
records commit/compiler/Windows/loaded GDI+ version; and hashes every emitted
artifact member with its byte length. Upload also runs on capture failure.
Parent review and a real Windows execution are required before observations can
change the mathematical model. No Core/native macOS suite or application build
is part of this experiment.
