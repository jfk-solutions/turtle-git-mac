# RedEye radial and within-bin statistics discriminator

This bounded original Windows SDK assay captures six new opaque 32×32 sources
and a same-job solid-red control. It does not recapture any earlier inventory.
`RedEyeRadialReference.cpp` preserves the proven seed assay transport; only its
six input definitions and recording description differ.

Every source starts with RGBA `(240,20,10,255)`. Gray holes are
`(96,96,96,255)`; the one low-red hole is `(128,20,10,255)`.

| Case | Holes |
| --- | --- |
| `gray-two-same-bin` | gray `(6,6)`, `(8,8)` |
| `gray-four-same-bin` | gray `(6,6)`, `(7,7)`, `(8,8)`, `(9,9)` |
| `gray-off-diagonal-6-12` | gray `(6,12)` |
| `gray-off-diagonal-5-15` | gray `(5,15)` |
| `gray-low-red-same-bin` | gray `(6,6)`, low-red `(8,8)` |
| `gray-two-off-diagonal` | gray `(6,12)`, `(5,15)` |

The correction rectangle is `[0,0,32,32]`. All holes are inside its full ellipse
and outside its half-radius ellipse, measured around `(15.5,15.5)` with radii
`15.5`. This avoids the already observed inner-hole circle in the selected
discriminator positions; it does not assume a general circle eligibility rule.

The two/four-hole inputs change mean, variance and minimum within the same
measured six-degree angular sector. They distinguish candidate rational and
finite-polynomial floor expressions at higher means. The off-diagonal inputs
expose the radial profile away from the previously available 225-degree ray.
The mixed gray/low-red input keeps the bin minimum and hole membership fixed
while changing mean and variance relative to the two-gray input. The final
input checks two angular sectors without an inner hole.
No candidate numerical formula is used to construct or accept native output.

The workflow `.github/workflows/metafile-redeye-radial-reference.yml` runs only
this inventory in `generate`, `direct-v1`, `replay`, and `replay-v1` modes. It
retains requested and actual sources, original native EMF, fresh direct in-place
and created-output SDK calls, intrinsic and final actual `Bitmap(file, FALSE)`
consumer pixels, native PNG/raw RGBA, all SDK and file statuses, native binary
identity, source revision and SHA-256 provenance. Each source/effect is freshly
allocated, using the prior safe pointed-vector plus inline-tail parameter
backing. The included pointwise source supplies utility functions; its old main
is renamed and no previous inventory is called.

Expected output is seven sources, seven original EMFs, four JSON manifests and
eight RGBA/PNG observations per source. Inspect every SDK/file status and complete
buffer before interpreting the observations. The executable reports exceptions
as failure while recording nonzero SDK statuses explicitly; a successful job is
not itself a claim that every operation succeeded or that a port matches it.
