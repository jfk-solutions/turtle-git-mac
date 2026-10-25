# General EMF+ path-gradient boundaries

The general boundary continuation adds cubic paths, multiple
figures and self-intersections to the existing path-gradient renderer. It retains
uniform and separate surrounding colors, the existing focus/preset/gamma rules,
brush/world transforms, and the common fill, pen, glyph, clip and SourceCopy
consumers. The canonical single-color ellipse keeps its existing analytic path.
The rebuilt decoder passes 12 focused Core methods (six retained and six new)
and the actual native Compare/Conflict workload with both system and bundled Git.
The [dated checkpoint](qa/metafile-general-path-gradient-2026-10-25.json) records
the reconstruction, passes, repairs and execution scope. This is acceptance of the
bounded profile below, not complete metafile or application parity.

Microsoft's [BoundaryPathData specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/2065ba3d-b70f-4bc0-b025-6978b1aa7311)
embeds an EmfPlusPath, while its [GDI+ path-gradient examples](https://learn.microsoft.com/en-us/windows/win32/gdiplus/-gdiplus-creating-a-path-gradient-use)
describe paths containing lines and curves. Neither specifies enough raster
behavior to infer contour order or cubic surrounding-color assignment. Two
isolated Windows assays provide the independent reference:

- [Twelve native controls](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40225687395),
  revision `dc16d3c42e5a246237d530e3dd53bd3c57db38b2`: asymmetric cubic
  uniform/multicolor, disjoint figures in both orders, nested figures in both
  orientations, a crossing and its reversal, plus cubic clip, SourceCopy, pen
  and glyph consumers. Original native-recorded EMFs, direct/replay RGBA and
  native flattened points are retained. No earlier corpus was rerun.
- [Three explicit-path playback controls](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40225939610),
  revision `9adc067b41268448ed43159fd595fd44b5802cfc`: the native writer had
  serialized flattened point arrays. These controls replace only the boundary
  with the original cubic or multiple-figure EmfPlusPath and update its flag and
  enclosing lengths. Colors, transforms and drawing records remain unchanged.
  Multicolor cubic and multiple-figure playback match their native-recorded
  equivalents byte-for-byte; uniform cubic differs by at most two channel units.

The [reference receipt](qa/metafile-general-path-gradient-windows-reference-2026-10-25.json)
binds run/job/artifact hashes, original probe sources, substitutions and numeric
profiles. Core fixtures bind original EMF and full 64 × 64 RGBA hashes. Glyph
coverage uses a colored-ink property because Windows Arial and macOS font
fallback do not guarantee identical outlines.

## Boundary and interpolation behavior

For the measured cubic, GDI+ flattens the original seven points to 33 points.
Recursive midpoint subdivision at chord/control flatness 0.25, followed by
rounding to a 1/16 path-space grid, reproduces all 33 native points exactly.
Explicit cubic playback agrees with this flattened representation. The renderer
uses that general bounded subdivision, not an ellipse fitted to an arbitrary
curve. Surrounding colors retain their ordinal assignment after flattening;
unspecified entries become opaque white, consistent with the existing measured
point-array profile. They are not resampled along the original cubic controls.

Closed figures contribute one ordered point array. A new figure does not create
a separate gradient or a hole; crossings do not imply a polygon winding clip.
The final covering center/edge fan owns a pixel. SourceCopy still uses independent
recorded drawing geometry, so brush alpha and gradient coverage do not replace
the command's geometric mask. The earlier rejection of intersecting edges and
zero signed area prevented valid crossing brushes and is removed. Wholly
collinear boundaries remain unsupported.

The existing Gouraud counter reflected negative startup progress with an absolute
value. Three outer pixels on the new curved boundary exposed that error. A vertex
exactly on a scanline retains the measured quantized seed; after stepping above a
fractional vertex, negative progress stays at zero. This common endpoint-phase
rule matches all seven new multicolor full frames and nine retained native
phase/triangle/quad controls with exact coverage and maximum channel error one.
These are numerical probes of the shipping shader functions against immutable
Windows data, not decoder or application acceptance. Rejected unconditional-clamp
and first-span experiments remain in ignored diagnostic evidence. No per-case
coordinates, pixel substitutions or relaxed tolerances are used.

## Implicit closure

The initial implementation inherited an explicit-close-bit requirement from the
old bounded polygon profile. That was an unsupported validity assumption.
Microsoft's [open-figure fill contract](https://learn.microsoft.com/en-us/windows/win32/gdiplus/-gdiplus-filling-open-figures-use)
treats an open figure as closed. A [focused Windows replay](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40227267929),
revision `9cfb66907a224c6fc743fd6b055727a4da7d465a`, compares the exact earlier-red-paint
cubic fixture with a counterpart differing only in the final CloseSubpath bit.
Both succeed and their full RGBA frames are byte-identical. The original cubic
already ends at its starting coordinate: this directly proves close-bit
irrelevance, rather than independently measuring a distinct-endpoint closure.

The renderer accepts open line/cubic figures and new-figure adjacency through the
same measured ordered fan, whose last point joins the first. General implicit
closure follows that fan model and the documented fill contract. Separate
open-multicolor and open-line fixtures retain the previously measured closed
frames as explicit derived regressions; they are labeled as derivatives rather
than new Windows pixel measurements. Normalizing the final flag in a private
decoded copy also keeps an otherwise canonical open ellipse on its established
analytic profile. Original source bytes and intermediate figure order remain.
The old open negative fixture is replaced by a positive full-frame/source-byte
check; the excessive-subdivision fixture still refuses the whole image.

## Ownership, refusal and limits

The renderer still completes the whole decode before publishing an image.
Malformed or excessive later boundaries cannot expose earlier painting as
a successful partial result. Original file bytes remain the comparison/editor
identity. Shared native image consumers retain their existing permission,
cancellation, operation and retirement ownership.

Input and flattened boundaries each admit at most 4,096 points. Cubic subdivision
allows depth 20 and 65,536 subdivision visits per boundary; flattened points also
count toward the existing 1,048,576 aggregate decoded-point limit. Existing
16,777,216 boundary-work, 16,777,216 viewport-pixel and 67,108,864 aggregate
raster/work limits remain. A Gouraud edge with zero truncated major-axis extent
is still explicitly refused; this continuation does not invent subpixel colors.
Wholly collinear boundaries are also refused. These bounds do not
promise arbitrary devices, fonts, giant coordinates, signed sandbox acceptance,
complete GDI+ raster parity or full application parity. No Wine implementation
code was copied; the subdivision and shader changes are original code grounded
in the specification and retained Windows observations.
