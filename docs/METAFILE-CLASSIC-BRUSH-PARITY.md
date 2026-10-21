# Classic monochrome and bitmap pattern brushes

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d` opens WMF/EMF
through `TortoiseIDiff/PicWindow.cpp` and `Utils/MiscUI/Picture.cpp` using Windows
GDI+. TurtleGit's display helper must interpret these brush records before its
existing native comparison and conflict panes can display the image. Rejecting a
brush rejects the complete image; successful record framing alone does not prove
correct painting. The [dated grouped checkpoint](qa/classic-patternbrush-2026-10-21.json)
records implementation, source review and actual runtime/pixel/native checks.
It does not certify every Windows metafile or the full application.

## Serialized brush contract

[WMF CREATEPATTERNBRUSH](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wmf/6f1c6ba3-7710-42c1-b6e2-1b776c2f769b)
contains a partial [Bitmap16](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wmf/dc487315-3bb9-40c8-9f49-55ffc6152d8c),
ignored pointer/reserved fields and the actual serialized pattern bytes. The
reader must validate dimensions, planes, bit depth, WORD-aligned rows and complete
payload extents before creating an object. Pointer-like fields are data, never
addresses to dereference. Device-dependent bitmap layouts without a defined
portable color interpretation remain explicit refusals.

[EMR_CREATEMONOBRUSH](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/49b42277-31b0-4eb9-a6af-86d9be9b568f)
uses record-relative bitmap-information and pixel offsets. Both ranges need
independent bounds and overlap checks. Its
[color-usage field](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/a5e722e3-891a-4a67-be1a-ed5a48a7fda1)
distinguishes RGB tables, logical-palette indices and no-table indices. The
[Win32 record description](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-emrcreatemonobrush)
covers both monochrome CreatePatternBrush and two-color CreateDIBPatternBrush
origins. The record name does not justify discarding every supplied color table.

## Color and drawing state

[CreatePatternBrush](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createpatternbrush)
uses the destination context's text color for zero bits and background color for
one bits in a monochrome pattern. Those colors are live drawing state. They are
not a permanently black/white image created when the object is parsed. Bitmap
patterns retain both colors even when background mode is transparent; hatch holes
have their own existing policy.

[CreateDIBPatternBrushPt](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createdibpatternbrushpt)
defines logical-palette indices relative to the context into which the brush is
selected. Retain the indices and resolve them through the active palette at paint
time, rather than baking whichever palette happened to exist at creation.
Supplied true-color tables remain supplied colors on the native color target.

Microsoft's record description does not fully specify the distinction between a
canonical black/white DIB and a monochrome device bitmap in every recording path.
The native compatibility policy is checked against
[Wine's metafile playback](https://raw.githubusercontent.com/wine-mirror/wine/master/dlls/gdi32/enhmetafile.c):
no-table mono indices and canonical zero-black/one-white monochrome data follow
live text/background binding; arbitrary and reversed true-color tables retain
their supplied colors. This is an explicit compatibility policy, not a claim that
every EMF93 color table is ignored. No Wine implementation code is copied for this
family.

Brush objects share the existing allocation, selection and deletion mechanism.
[SaveDC](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-savedc)
and RestoreDC must retain selected brush, text/background colors, palette and
[device brush origin](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setbrushorgex).
Later color/palette changes cannot reuse a cached pattern with obsolete colors.
Brush creation and selection do not require a palette before it is actually used
for paint. Palette objects retain actual R/G/B/flags wire order, selection, entry
edits and resize; newly expanded, undefined entries fail only if used. WMF accepts
the normative one-WORD SelectPalette handle and the two-WORD Windows-compatible
forceBackground/handle framing as distinct bounded forms.
Fills, extended-pen strokes, Boolean raster operands, explicit region brushes and
flood painting use the same pattern source and existing transform/clip rules.
The brush extension must not change unrelated bitmap-transfer color semantics.

## Verification and remaining limits

Eleven focused Core methods pass on the final rebuilt renderer: four new methods
check all 24 valid and 19 refusal fixtures, and seven existing methods cover the
connected brush, text-background, region/flood and transfer paths. Both system and
bundled Git native consumer pairs pass for five representative inputs, whole-image
refusal, default/explicit IDiff, actual three-stage conflicts and owned decoder
retirement. Both receiver processes are absent. The Debug app embeds the same
renderer and measured helper receipts as the rebuilt universal macOS13 runtime.
The helper is built for arm64/x86_64; this does not claim a physical Intel run.

The first runtime reconstruction correctly rejected a source-hash change while
a late text-background/work-budget repair was being finalized. The frozen source
was rebuilt before Core or native tests ran. No behavioral test assertions were
removed, and no full Core suite was rerun. Native labels/layout are unchanged;
no new UI captures or localization regeneration were needed for this batch.

Independent record fixtures must check actual pixels, row orientation and
padding, live color/palette state, Save/Restore, object lifetime, device phase,
transforms/clips and representative connected paint consumers. Malformed inputs
must refuse the whole image without modifying original bytes. Native consumers
must retain cancellation, late-result rejection and owned helper cleanup.

The WMF device-bitmap subset accepts positive monochrome dimensions and canonical
WORD-aligned stride. Noncanonical or device-specific color layouts are unsupported
scope, rather than claims that every such Windows bitmap is malformed. Ignored
pointer/reserved values need not be zero, and the serialized Type field is not
forced to the separate native BITMAP API's zero convention.

Default logical-palette fallback and device-explicit palette entries remain
unimplemented. Palettes are bounded to 65,536 entries each and 1,048,576 entries
allocated across playback. Bitmap dimensions/pixel work and retained brush bytes
retain their existing 16,777,216-pixel per-image, 67,108,864-pixel aggregate and
64 MiB brush bounds. Live mono/palette recoloring charges an additional aggregate
67,108,864-pixel work bound before allocating or looping, even for a large brush
painted into a tiny viewport.

The existing input/output, dimension, decoded-pixel, brush-memory, raster-work,
markup and helper-deadline bounds remain. Full Windows device/palette identity,
all device-dependent color bitmap variants, dynamic stock DC_BRUSH/DC_PEN,
remaining record families, physical image/Finder behavior, minimum-OS/Intel and
current signed distribution acceptance require separate evidence. A local
focused pass cannot establish a complete hosted CI pass or whole-port parity.
