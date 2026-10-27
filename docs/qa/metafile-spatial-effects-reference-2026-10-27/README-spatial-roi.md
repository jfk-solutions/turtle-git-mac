# Native source-region geometry observations

This independent Windows SDK capture distinguishes the original floating source
rectangle supplied to `Graphics::DrawImage` from an explicit integer `RECT`
supplied to each fresh in-place and bitmap-returning `Bitmap::ApplyEffect` call.
It does not execute the Mac renderer or rerun an earlier corpus.

Twelve cases use the same opaque32×32 asymmetric source and radius2: six source
rectangles with ExpandEdge false and true. They cover the whole image,
(4.25,6.5,17.5,18.25), the same extent near the origin, a farther fractional
origin, and integer rectangles at(4,6) and(1,1). Each original EMF uses a64×64
frame and translation(16,16), retaining its floating source rectangle unchanged.

For the direct SDK calls only, the authored integer hypothesis is floor(left/top)
and ceil(right/bottom)+1. That policy is recorded in every manifest row; it is
not assumed to be equivalent to the original DrawImage operation. SDK refusal,
output rectangle and dimensions remain separately observable. In particular the
full-image hypothesis extends one pixel beyond the image; an API refusal does
not invalidate its independently recorded EMF.

The integer hypothesis follows an exact fit of all306 painted pixels in the
existing fractional, non-expanding file capture. The expanding capture has a
separate leading-row placement difference; this assay determines whether explicit
source-region application explains it. No hypothesis or fitted pixel table is
encoded as a production algorithm.

The four modes independently retain startup v1/v2 actual and requested input,
original SDK-generated EMF, in-place output, created output and bounds, intrinsic
Bitmap(file,FALSE) pixels and the final Picture-style natural-size draw. The
workflow records source/executable hashes, compiler, OS, GDI+ version and a
complete output inventory. API statuses and pixels require inspection even when
the workflow succeeds. No full Mac app or dialog parity claim follows from it.
