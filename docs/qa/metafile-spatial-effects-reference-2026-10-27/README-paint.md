# RedEye draw versus no-paint native reference

This is an original six-case Windows SDK observation utility, not a numerical
renderer or an application test. It records only new cases. It uses the same
bounded parameter-buffer transport as `RedEyeSeedReference.cpp`, with independent
fresh effect and source instances for recording, in-place ApplyEffect and the
create-output ApplyEffect overload.

Every source is a 32 by 32 opaque image whose straight RGBA is
`[240, 20, 10, 255]`. Each original EMF+ file first clears its 32 by 32 frame to
opaque sentinel RGBA `[17, 61, 173, 255]`, then records one identity full-source
DrawImage(effect) in SourceCopy mode. The ordered area lists are:

| Case | RECT list, in submitted order |
| --- | --- |
| outside-negative | `[-20,-20,-1,-1]` |
| outside-positive | `[40,40,50,50]` |
| valid-then-outside | `[0,0,32,32]`, `[40,40,50,50]` |
| outside-then-valid | `[40,40,50,50]`, `[0,0,32,32]` |
| partial-outside | `[-5,-3,12,17]` |
| full-control | `[0,0,32,32]` |

The opaque sentinel distinguishes a skipped draw (sentinel survives) from a
transparent result copied over the background. No expected pixel result is
constructed by this utility. The order-dependent mixed lists are retained as
separate cases. Source definitions, area lists, background, identity transform
and recording frame are written to each JSON case.

Four fresh-process modes retain startup-version 2 recording/direct/create,
startup-version 1 direct/create, and actual `Bitmap(file,FALSE)` intrinsic/final
pixels for startup versions 2 and 1. Final drawing uses the pinned Picture path's
SourceCopy, InterpolationModeDefault, PixelOffsetModeHalf and TileFlipXY. Requested
and actual source RGBA, original EMFs, full intrinsic/final RGBA and PNGs, native
statuses, output bounds, compiler/platform/DLL identities and SHA-256 inventories
are retained by the scoped workflow.

`InvalidParameter` status 2 from direct/create ApplyEffect is an expected possible
observation for out-of-bounds areas. It is recorded without turning that result
into an exception, rewriting it to success, or inferring the file-consumer result.
A successful workflow therefore establishes capture completion only: each
SetParameters/record/load/draw/apply status and each actual pixel output must be
reviewed separately. Unexpected harness exceptions are written as `error` and
cause a nonzero mode exit.

The parent agent reviews and dispatches
`.github/workflows/metafile-redeye-paint-reference.yml`. No old capture job or
application validation is included.
