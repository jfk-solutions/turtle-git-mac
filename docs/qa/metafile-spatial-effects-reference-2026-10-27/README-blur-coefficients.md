# Six-case native Blur coefficient diagnostic

This independent Windows SDK observation records only six new inputs. It does
not rerun the previous spatial corpus, execute the Mac renderer, or encode any
proposed port formula.

Each original input is 32 × 266 opaque RGBA. Rows 0–9 are black. In row `10+a`,
`a` runs through every byte value 0–255. Four cases place that gray amplitude
at x = 0, 1, 3, or 16, with black elsewhere. Two cases place `a` and `255-a`
at x = (0, 1) or (15, 16). Every case requests native Blur radius 5 with
ExpandEdge false. The ten leading dummy rows separate the diagnostic samples
from the leading-row vertical work observed in the preceding tall-gradient
assay; this new assay does not assume those rows are unaffected in its results.

The isolated sources expose each reflected-edge/product transfer over the full
byte domain. Complementary pairs additionally distinguish product rounding
from the subsequent accumulation. They are measurements for recovering a
general algorithm; no captured lookup table is proposed as a shipping kernel.

`generate` uses GDI+ startup version 2, records each unmodified SDK EMF, captures
both requested and actual source bytes, and observes independent fresh-input
in-place and created-output operations. `direct-v1` repeats those independent
operations and actual/requested input captures under startup version 1.
`replay` and `replay-v1` separately record the original file's actual
`Bitmap(path, FALSE)` intrinsic pixels and the Picture-style natural-size final
draw. The latter retains default interpolation, half pixel offset, SourceCopy,
and TileFlipXY wrapping. Status values remain separate for parameter setting,
recording, each direct operation, file loading, and final drawing.

The workflow records the source revision, source and executable SHA-256,
compiler output, OS information, GDI+ module version, and a complete output
inventory with byte lengths and SHA-256. A green workflow alone does not prove
any numerical model or Mac implementation passes.
