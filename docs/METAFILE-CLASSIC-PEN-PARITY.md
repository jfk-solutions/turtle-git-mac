# Classic EMF extended pens

This partial rendering family follows EMR_EXTCREATEPEN and its connected classic
path/shape operations. It uses the existing pinned renderer and native stroke,
brush, clipping and Boolean-composition adapters. [Dated checkpoint evidence](qa/classic-extpen-2026-10-21.json) records actual
painting/consumer coverage, failed attempts and focused repairs. Parsing a record
alone does not establish painting or complete TortoiseGit image parity.

## Record and API contract

The [EMR_EXTCREATEPEN record](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/d7f51e05-4024-497c-ad4a-8aeca9d34256)
contains an object handle, optional bitmap ranges and a variable LogPenEx object.
Bitmap offsets are relative to the whole record; the bitmap need not immediately
follow the style array. Bounds, style lengths and optional DIB data must be
validated before publishing a reusable pen object.

[LogPenEx](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/5b67b3ee-ea00-4f80-9b73-2959804381be)
separates pen type, line style, cap and join. Cosmetic width is one device pixel;
geometric width and user-style lengths are logical units. The native outline
must therefore retain the full affine mapping instead of reducing a sheared or
nonuniformly scaled geometric pen to a single device width.

The [ExtCreatePen API](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-extcreatepen)
limits custom style arrays to sixteen entries. Odd-length arrays reverse the
dash/gap roles on their next cycle. Alternate is cosmetic-only. InsideFrame
shrinks geometric figures drawn by bounding-rectangle operations; ordinary
open paths retain centered strokes. Geometric caps and joins remain independent
attributes rather than being discarded with the style bits. Zero-length entries
in a nonzero custom cycle remain real dash/gap transitions: round/square caps
can paint zero-length dashes, while flat zero-length dashes have no area.
Geometric width zero follows a device-hairline policy, including under scaling.
These compatibility cases are compared with the [Wine pen implementation](https://raw.githubusercontent.com/wine-mirror/wine/master/dlls/win32u/pen.c)
and its [device-width consumer](https://raw.githubusercontent.com/wine-mirror/wine/master/dlls/win32u/dibdrv/objects.c).

[Brush attributes](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-logbrush)
define solid, hatch and bitmap-backed paint. Hatch foreground/background and
brush origin remain drawing-context state. A pen's brush must paint the stroked
outline; it must not be replaced by the currently selected fill brush. Optional
DIB headers/bits need their own bounded decoder and palette policy. Styled gaps
from extended pens do not receive opaque background fill, following the
[SetBkMode distinction](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setbkmode)
from CreatePen. Hollow/null pen brushes retain no-ink behavior.

## Related state records

EMR_SETMITERLIMIT has a normative unsigned field but
[Windows product behavior, note 90](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/f5148c7c-30c5-4d95-bf1b-b449c1f8f53d)
uses FLOAT. The adapter accepts both encodings within its existing finite
1…1,000,000 native limit, retaining miter state through Save/Restore. This dual
interpretation is a compatibility policy, distinct from either wire description
alone. NaN, infinity and out-of-budget values refuse conversion. ArcTo also
retains its current-position connector and final position through bounded-shape
InsideFrame handling.

## Connected scope and limits

The batch covers object selection and saved-state restoration, custom and
alternate dashes, geometric caps/joins, hatch/DIB stroke paint, bounded-shape
InsideFrame, device/world transforms, clipping and existing ROP2 composition.
Malformed or unrepresentable operands must refuse the whole conversion, retaining
input bytes and avoiding a successful partial or silently solid fallback.

The existing input, geometry, bitmap, markup, raster-work and helper-deadline
budgets remain consumers. This family does not implement framed regions or flood
fills, certify Windows-exact cosmetic pixel stepping, every pathological curve,
all legacy palette modes, unavailable Windows fonts, signed execution, physical
Finder acceptance or the complete WMF/EMF/EMF+ format families.

The macOS adapter chooses one device pixel per cosmetic style unit and aligns
integer device centerlines to native pixel centers. ALTERNATE instead walks
flattened device paths into alternating complete pixel cells, preserving phase
across joined segments and excluding the terminal endpoint. Microsoft defines cosmetic
style units by device; Wine's DIB implementation uses a different unit scale.
Predefined dash patterns and edge antialiasing therefore have platform adaptation
limits. They are not evidence of Windows-exact pixel stepping. DDB patterns
without representable serialized bitmap data and dithering hatch aliases remain
explicit refusals. Existing native geometry, record, bitmap and aggregate work
budgets bound accepted input rather than certifying all numeric extremes.
