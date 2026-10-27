# Native Windows RedEye inverse-hole discriminator

`RedEyeInverseReference.cpp` records six original Windows SDK cases and one fresh
solid-red control. It includes utility code from the pointwise reference, but
never runs that reference's inventory. The scoped workflow compiles and runs only
this tool. No TurtleGit renderer or substitute image algorithm generates pixels.

The six 32×32 opaque inputs have background RGBA `(240,20,10,255)` and one full
`RECT(0,0,32,32)` effect area:

- One gray `(96,96,96)` pixel at `(15,15)`, `(12,12)` or `(4,4)`.
- One lower-red `(128,20,10)` pixel at `(15,15)`.
- Two gray pixels at `(15,15)` and `(16,16)`.
- Two gray pixels at `(15,15)` and `(16,15)`.

The separate `baseline` is the same solid red with no hole. This control permits
same-job influence comparisons without assuming that two hosted Windows images
have identical GDI+ versions. It is not a repeat of the preceding 410-case assay.

The earlier red-on-gray pictures reveal no kernel response at gray neighboring
pixels because their red excess is zero. Inverse inputs retain nonzero red excess
at every neighboring pixel, exposing any influence field across the full image.
The lower-red and two-hole cases distinguish amplitude dependence and directional
or nonlinear interaction. These are discriminators, not assumed algorithms.

Every mode writes a JSON manifest. `cases` contains exactly six cases and
`baseline` one control. `generate` retains requested RGBA and actual source
`GetPixel` RGBA, original recorded EMFs, fresh direct `ApplyEffect` outputs and
fresh create-output `ApplyEffect` outputs. `direct-v1` repeats the direct paths
under SDK startup version1. `replay` and `replay-v1` retain the intrinsic
`Bitmap(file,FALSE)` pixels and final pixels drawn using the pinned Picture
compositing/interpolation/wrap configuration. All pixels are full straight RGBA,
top-row first; PNG files are additional visual evidence. Original status values,
actual dimensions and create-output rectangles are retained, including failures.

The RedEye native parameter storage has the full readable extent passed by the
SDK wrapper, a stable pointer to the rectangle vector, and copied trailing
rectangles. Each action uses a fresh source bitmap and effect. `NOMINMAX` prevents
the Windows macro collision encountered and repaired before the original assay.
Workflow receipts retain source/compiler/Windows/GDI+ identities and SHA-256 hashes
of inputs, executable and every artifact file. A green job does not replace
checking every recorded SDK/load/draw status.
