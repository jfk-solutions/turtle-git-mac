# Classic metafile stock drawing state

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`
accepts WMF/EMF in `TortoiseIDiff/MainWindow.cpp:1255` and loads the image through
Windows GDI+ in `Utils/MiscUI/Picture.cpp:418`. TurtleGit interprets captured
records in its bundled bounded renderer before displaying private image pixels.
Repository and conflict-stage bytes remain the original metafile. This family
extends the existing image workflow; it adds no dialog setting or persistent
per-document color preference.

## Stock handles and real recording behavior

The [MS-EMF StockObject enumeration](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/d6dffd25-8615-42f8-aed1-309f1fe54ab2)
defines `DC_BRUSH` as stock index 18 and `DC_PEN` as index 19 for EMF playback. Their initial
colors follow white brush and black pen respectively. Selecting one of these
handles must select its drawing-context object, rather than fail object lookup,
reuse a previously selected ordinary object or silently remove its ink. Stock
selection remains distinct from creation and deletion of ordinary objects.

The [GetStockObject API](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-getstockobject)
also describes live `SetDCBrushColor` and `SetDCPenColor` calls. API behavior does
not establish a serialized EMF color-setter record. The inspected Wine recording
implementation in
[`gdi32/emfdc.c` at `7298a818`](https://github.com/wine-mirror/wine/blob/7298a818b79446bae153b8d5aa27235ab3703bf9/dlls/gdi32/emfdc.c#L2080-L2117)
emits ordinary brush/pen creation and selection for these color
changes. The renderer therefore accepts the actual create/select replacement
sequence; this family invents no `EMR_SETDCBRUSHCOLOR` or `EMR_SETDCPENCOLOR`
record. An ordinary red brush remains distinct from the default white stock
brush when the recording later selects the stock handle again.

[SaveDC](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-savedc)
and [RestoreDC](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-restoredc)
retain drawing-context selections and related color state. Existing vector,
pen-outline, brush, region, flood and raster consumers must resolve their paint
from that current state. A saved selection cannot be flattened into whatever
ordinary brush or pen happens to be selected after the save. The existing clip,
transform, ROP and aggregate painting budgets still apply.

## Palette boundaries

`DEFAULT_PALETTE` is a stock logical palette whose actual system colors are
device dependent. TurtleGit uses an explicit common Windows display adaptation:
the twenty-entry default logical palette described by Microsoft's
[default palette documentation](https://learn.microsoft.com/en-us/windows/win32/gdi/default-palette).
This supports ordinary indexed-color playback without claiming a universal
printer, custom display or hardware palette. Palette identity, selection and
Save/Restore remain part of the drawing context; existing explicit logical
palette objects retain their recorded entries and edits.

Indices outside the represented logical palette and `PC_EXPLICIT` hardware
indices still refuse the whole conversion. The fixed display profile is a
macOS compatibility policy, not a physical Windows device measurement or a
claim that every device uses these exact colors.

## Native integration and verification scope

The grouped native case uses the real `FileComparisonWindowController` and
`ImageConflictWindowController`, the packaged asynchronous decoder, independent
record controls and actual private Git conflict stages. It checks decoded image
pixels, source-byte preservation and reload behavior. Final functional automation
uses a receiver-only frame-constraint override, places every test-owned window
outside the union of all desktop screens and checks that no frame intersects a
screen. Owners close and decoder requests drain before releasing private inputs.

The retained full-window light/dark photographs came from an earlier owned
capture attempt against the same production UI. AppKit constrained those window
frames to leave a 40-pixel-wide desktop edge; those photographs must not be
described as fully offscreen captures. After strict offscreen placement was
implemented, ScreenCaptureKit returned internal start error `-3811` on all three
bounded attempts. No further compositor attempts or substitute pictures were
used. The final functional check therefore runs without capture; the earlier
actual photographs are separate visual evidence and do not replace pixel or
ownership assertions.

Actual grouped results and focused repairs are recorded separately in the dated
QA evidence after checks finish; no passing result is inferred here from source
inspection. Existing signed runtime checks cover their earlier measured corpus
only.

Windows device-palette identity, exact GDI raster edge stepping, arbitrary device
objects, unimplemented records, physical image-window acceptance and current
signed deployment remain open. See the [central metafile scope](IMAGE-METAFILE-PARITY.md),
[classic brush contract](METAFILE-CLASSIC-BRUSH-PARITY.md) and
[classic pen contract](METAFILE-CLASSIC-PEN-PARITY.md). This family does not declare
complete WMF, EMF or TortoiseGit image parity.
