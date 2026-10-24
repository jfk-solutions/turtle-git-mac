# EMF+ SourceCopy composition

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d` delegates metafile
painting to Windows GDI+ in `src/Utils/MiscUI/Picture.cpp::Load`. TurtleGit must
implement the corresponding drawing state before Image Compare can display these
files. This family extends the existing private renderer; original repository
bytes remain the comparison, conflict and Save inputs.

## Source contract

[EmfPlusSetCompositingMode](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/d7ace3ef-2092-4e94-89da-103ac3f9ac5f)
has no record body. Its low flag byte is the mode; the upper reserved flag bits
are ignored. The [mode enumeration](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/cbfc8c78-778d-466e-a52a-a82f8ce6cfee)
defines SourceOver (0), which blends source alpha with existing pixels, and
SourceCopy (1), which replaces the covered destination with the source color,
including its alpha. Other mode values or nonempty bodies fail decoding.

A transparent source is an actual clearing paint under SourceCopy. Inferring
coverage from source alpha would leave the previous destination visible and is
incorrect. Combining several paints with SourceOver before replacing the
background is also incorrect: overlapping rectangles in one FillRects record
must each replace in their original order.

The captured mode follows Save/Restore and both container forms. EMF+ GetDC
intervals continue to use classic GDI painting; they do not inherit EMF+ alpha
replacement. Returning to EMF+ retains its preceding graphics state. Text
rendering hint state follows the same saves; SourceCopy text with
[ClearTypeGridFit](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusenums/ne-gdiplusenums-compositingmode)
is refused rather than silently substituted.

Clear is a separate operation: the pinned
[Wine GdipGraphicsClear reference](https://github.com/wine-mirror/wine/blob/7298a818b79446bae153b8d5aa27235ab3703bf9/dlls/gdiplus/graphics.c#L5216-L5248)
temporarily uses SourceCopy and restores the previous mode. TurtleGit clears the
intrinsic device canvas through the captured device clip, including under
SourceOver; it does not transform a canvas-sized world rectangle a second time.
This reference behavior is not a Windows pixel-identity oracle.

## Connected paint pipeline

Each individual accepted fill, rectangle, path, region, native pen outline and
formatted or positioned native glyph paint captures its concrete source and an
independent opaque-white copy of its geometry. The copy retains the same local
text/layout clipping. A brush reference must name a present brush object in slots
0–63; missing, out-of-range and wrong-type references fail. Only the record's
explicit inline-color flag permits treating the brush field as ARGB. The upstream
fallback to black or an inferred inline color is not used in either mode.
Gradient, hatch and texture sources keep their existing
brush pipeline; transparent brush cells clear within the actual shape, without
using brush opacity as a substitute for that shape. Images capture their intended
destination parallelogram independently of bitmap alpha, including affine
placement, source crop and accepted image attributes. Nested accepted image
representations remain a single image paint.

After the record has supplied its complete region clip, source and coverage
receive the identical world/page/device transform and device clip. The native
transfer adapter processes the captured paints in order. For premultiplied
channels it computes `out = sourceAlreadyCovered + destination * (1 - coverage)`;
alpha uses the same equation. Source coverage is not multiplied twice. Invalid
source/coverage relationships fail rather than leaking a successful partial
picture. A completed intrinsic-resolution PNG checkpoint remains available to
later EMF+, classic GetDC and Boolean raster operations.

Conservative device bounds come from rectangle corners, tracked path control
bounds, actual native glyph/pen bounds and image corners. A one-pixel halo and
canvas clamp produce the existing ROI request. Unknown text bounds use the full
canvas. Neither bounds nor source alpha replace the actual geometric clip.
Valid SourceOver paint dispatch remains in place, apart from the separately
specified Clear operation. Classic ROP behavior remains its separate model.

## Bounds and verification limits

The renderer permits at most 4,096 captured SourceCopy/Clear paints and 64 MiB of
aggregate captured paint markup. Existing path, pen, glyph, bitmap, mask,
transform and output bounds still apply. The native adapter shares the existing
raster call, ROI/composite-work, operand-render, SVG input, buffer and checkpoint
budgets; SourceCopy does not create an unbounded second rendering engine. Saved
state limits remain 4,096. Visible output without an explicit coverage receipt
fails closed, so a future painting consumer cannot silently use source opacity.

The [dated grouped checkpoint and focused repairs](qa/metafile-source-copy-2026-10-24.json)
record actual runtime, Core and native results. Across the recorded checkpoint
and affected reruns, 19 distinct Core methods passed, including all seven new
SourceCopy methods. The universal runtime rebuilt successfully, both actual CLI
architectures passed their probes, and the current Debug app and embedded-runtime
validator passed. Native SourceCopy consumer and conflict checks passed all four
system/bundled-Git pairs; their owned receiver processes were reaped. The separate
Blame CI-fixture repair is outside this rendering result and remains separately
tracked in the dated evidence.
The initial checkpoint exposed the invalid-brush fallback and an isolated-control
oracle that inherited the renderer's opaque white initial canvas. Brush lookup
now refuses that fallback, and isolated controls explicitly Clear to transparent
before painting with SourceOver; their alpha and geometry assertions remain.

Checks distinguish literal transparent/semitransparent/opaque pixels,
brush and image sources, independent native glyph geometry, overlapping paints,
path/region clips, transforms, saves/containers, GetDC and Clear continuity.
They use the production `ComparisonImage(bytes: originalMetafile)` path. Feeding
its display SVG back as an ordinary SVG selects a different reconstruction
profile and cannot establish the original metafile's device-pixel rendering.
Malformed-side refusal, source-byte preservation, cancellation and owned helper
cleanup remain part of the checkpoint. Successful local checks do not establish complete
WMF/EMF record coverage, Windows antialias/interpolation/font identity, physical
Finder behavior, minimum-OS/Intel acceptance or signed distribution acceptance.
