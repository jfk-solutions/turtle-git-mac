# Classic region and flood painting

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d` delegates WMF/EMF
image decoding to Windows GDI+. TurtleGit's separate native display decoder must
retain visible region and flood operations without rewriting repository bytes.
This partial family is implemented and source-reviewed;
[dated evidence](qa/classic-region-flood-2026-10-21.json) records its grouped
checkpoint and retained limits.

## Record and paint contract

[FrameRgn](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-framergn)
uses a specified brush and distinct logical widths for vertical and horizontal
border strokes. A region can contain adjacent bands, holes and disconnected
pieces. Framing its rectangles separately introduces internal borders that do
not belong to the region. The native adaptation must resolve the union first,
construct its inner border, then apply the drawing transform. The native geometry
policy extends normalized union-boundary strips by the distinct X/Y widths and
intersects them with the original region, including concave and hole corners.
It is a rectangular-erosion adaptation, not a Windows corner-pixel certification.
Signed widths use absolute extents; both zero paint nothing, while one zero keeps
the other direction's border. A scalar centered pen around each rectangle does not retain this behavior.

Fill and Frame use explicit brush arguments; Paint uses the selected brush.
Temporary explicit-brush operations must leave the selected brush available to
following records and Save/Restore. Invert uses destination inversion rather
than the selected pen or fill color. Coverage must remain subject to the active
clip and existing raster composition; hatch and bitmap brush holes must retain
their paint policy.

The [WMF region object](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wmf/28883669-449d-4723-9376-e853cc067aed)
is a scan-band object stored in the metafile object table. Its ignored linkage
and object-count fields are not application handles. Record readers must retain
scan extents/counts, horizontal intervals, object allocation/deletion and reuse,
and reject malformed data before publishing paint. EMF embeds its own RGNDATA
payload in drawing records; the outer record bounds are not a substitute for
that region's geometry. The bounded WMF reader accepts the object byte extent
and the additional-function-WORD convention used by
[Wine's recorder](https://raw.githubusercontent.com/wine-mirror/wine/master/dlls/gdi32/metadc.c)
for RegionSize, including its 16-bit representation; arbitrary inconsistent sizes
are not treated as ignored metadata.

[SelectClipRgn](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-selectcliprgn)
uses a copied region in device units. WMF region painting therefore applies the
current logical mapping, while selected-region clipping captures the initial
metafile-to-canvas mapping. Later transforms and deleting the source object must
not move or discard that captured clip. The adaptation follows the zero-argument
null-region convention also implemented by
[Wine metafile playback](https://raw.githubusercontent.com/wine-mirror/wine/master/dlls/gdi32/metafile.c);
the nonzero object-index path retains normal type/lifetime checks. Subsequent
WMF Intersect/ExcludeClipRect operations combine immutable device rectangle
coverage, including empty regions, and Save/Restore retains the captured state.
Direct normalized path children avoid CoreSVG's grouped clipPath limitation.

## Destination-dependent flood filling

[ExtFloodFill](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-extfloodfill)
uses the current brush. Border mode expands from a logical seed until it reaches
the supplied boundary color; surface mode follows adjacent pixels of the supplied
surface color. A seed outside the effective clip, on a border in border mode,
or on a different surface color in surface mode does not paint. Such a valid
no-op differs from malformed record framing or an unknown mode.

The [EMF record](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/4f1b52ba-325a-4da8-bd5b-987c4a572e5f)
stores a logical PointL seed, ColorRef and fill-mode enum. The corresponding WMF
records have their own field widths/order. Their readers must not guess a fill
from a vector bounding box: the operation depends on the actual destination
colors and connected visible domain after preceding paint.

The helper uses the existing guarded native SVG raster boundary and cumulative
work budgets. Native color matching and seed/device-grid policy are macOS
adaptations; they do not establish Windows-exact antialiasing, display palette or
pixel stepping. The native policy uses four-neighbor connectivity, floored mapped
seed coordinates, RGB composited over the white display backdrop, and a half-alpha
threshold for visible clip pixels. Clipped flood coverage then feeds the existing
brush/composition path. It adds no persistent process or document-derived filesystem access.

## Work and format limits

Native union/frame input is bounded to 4,096 rectangles per call and 65,536
aggregate, with 131,072 normalized points and aggregate frame edges. Source
records retain separate parsed-count limits. Logical coordinates have a finite
absolute limit of one billion and frame widths one million. The larger source
format domains are not all accepted merely because framing succeeds.

Flood work shares the raster adapter's per-call 16,777,216-pixel and aggregate
33,554,432-composite/67,108,864-rendered-pixel budgets. Its queue has at most one
entry per pixel; the 24-byte-per-pixel estimate must fit the existing 256 MiB
work bound. Existing call, markup, input/output and helper-deadline limits remain.
Palette-index colors use the selected palette; unavailable colors and CLR_INVALID
produce no flood paint. The true-color adapter accepts PALETTERGB's RGB value.

## Acceptance boundary

The batch includes independent geometry/color assertions and offscreen native
comparison/conflict consumers. No rendering tests ran during implementation. The
dated record separates subsequent actual painting/consumer checks from source review.
Remaining all-format, signed/distribution, physical image/Finder, font/palette,
minimum-OS and physical Intel acceptance require their own evidence. Parsing or
successful SVG output alone does not prove correct painting.
