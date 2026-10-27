# RedEye seed, grid and diagonal discriminator

This independent Windows SDK assay records six new opaque 32×32 sources and one
same-job solid control. It does not repeat the previous spatial or inverse-hole
inventories. `RedEyeSeedReference.cpp` preserves the inverse assay's transport,
safe parameter backing, fresh source/effect allocation, native recording and
actual `Bitmap(file, FALSE)` consumer; only the six source definitions and the
recording description differ.

Every source has RGBA background `(240,20,10,255)` and gray `(96,96,96,255)` at:

| Case | Gray coordinates |
| --- | --- |
| `hole-gray-12-15` | `(12,15)` |
| `hole-gray-15-12` | `(15,12)` |
| `hole-gray-16-15` | `(16,15)` |
| `hole-gray-6-6` | `(6,6)` |
| `holes-gray-separated-main` | `(12,12)`, `(20,20)` |
| `holes-gray-separated-anti` | `(20,12)`, `(12,20)` |

The one correction rectangle is `[0,0,32,32]`. The control has no gray pixels.
The off-diagonal and off-grid singletons distinguish candidate sampling or
diagonal selection from general local influence. The separated pairs distinguish
one selected seed or component from superposed influence fields. They do not
assume any of those detector hypotheses is correct.

The scoped workflow is `.github/workflows/metafile-redeye-seed-reference.yml`.
It runs `generate`, `direct-v1`, `replay`, and `replay-v1`, retaining requested
and actual input RGBA, original native EMF, direct in-place and created-image
outputs, intrinsic and final file-consumer outputs, native PNG and raw RGBA,
separate SDK/file statuses, source revision, compiler/platform/GDI+ identity and
SHA-256 provenance. Startup versions 1 and 2 receive fresh effect/source state.

The source is standalone MSVC C++17 and links the Windows SDK GDI+, User32 and
Gdi32 libraries. Its included pointwise reference contributes shared native SDK
utilities; its old entry point is renamed and none of its inventory is invoked.
No application renderer output is used as a reference. A successful job alone
does not establish effect support: inspect all recorded SDK and file statuses
and compare the complete buffers before drawing numerical conclusions.
