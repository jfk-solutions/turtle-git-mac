# Three matched-contribution Blur captures

`ThreeMatchedBlurContributionsReference.cpp` contains exactly three new source
patterns. It does not regenerate the earlier six coefficient cases or any other
spatial inventory. Transport is reused from the independently executed six-case
assay, including fresh source/effect objects, full requested/actual RGBA, native
EMFs, both direct overloads and actual Bitmap replay. `NOMINMAX` is defined before
Windows headers.

Every source is opaque32×266 at96DPI, initially black. Rows0–9 are dummy rows.
For a=0…255, row10+a assigns gray(a) at firstX and gray(255−a) at secondX and
thirdX when present. Other pixels stay black. All cases use Blur radius5,
expandEdge=false, null/full direct ROI, identity recorded image transform, and
an exact32×266 metafile pixel frame.

| New pattern | firstX (a) | secondX (255−a) | thirdX (255−a) | diagnostic probeX |
| --- | --- | --- | --- | --- |
| Right reflected pair |31|30|absent|30|
| Interior forward triple |15|16|18|16|
| Interior reversed triple |17|16|14|16|

For a symmetric radius5 kernel with mirror-without-edge-repeat sampling, all
three diagnostic positions have identical mathematical contributions:
w1×a + w0×(255−a) + w2×(255−a). The reflected right pair supplies the w2 term
through its virtual x32 sample, whereas the interior triples supply it through
a real source pixel. The two interior orientations reverse contribution order
without changing those values. This identity explains the experiment; no kernel
weights, proposed quantization, or expected output bytes are encoded in the
program. Full output images are retained, not only the diagnostic pixels.

The earlier, independently captured left pair at x0/x1 has a one-level mismatch
at a63 under the current model. These new matched contributions can distinguish
physical boundary handling, orientation and ordinary coefficient/accumulation
precision without choosing a special rule for a63. Dummy rows keep every
full-byte sweep outside the previously measured nine-row vertical prefix; the
actual source/effect/output data must still establish behavior.

Run modes `generate`, `direct-v1`, `replay` and `replay-v1` use the same private
output directory. Both direct startup processes emit their own requested and
actual source PNG/RGBA, named explicitly by the manifest. Each in-place and
bitmap-returning ApplyEffect gets a fresh SDK object/source. Original generation
also records fresh native EMFs. Every status, created outputRect/dimensions and
auxiliary bytes (bounded1MiB) is retained. Legitimate SDK rejection remains a
status observation; setup/output/internal exceptions emit an error and fail.

Replayv1/v2 construct `Bitmap(path,FALSE)`, retain true intrinsic dimensions and
complete GetPixel pixels, then perform the pinned Picture natural-size draw
using default interpolation, PixelOffsetHalf, WrapTileFlipXY and transparent
SourceCopy. No image is stretched to the expected frame. The workflow records
source revision, compiler, Windows/GDI+ versions, executable/include/source hashes,
and a SHA256/length inventory of every output file. Only the new source or its
own workflow path triggers it.

No application checks or production kernel changes are part of this assay.
Implementation and precision claims must follow the observations; this tool
contains no tolerance, expected-image fallback or fitted parameter table.
