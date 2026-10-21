# Classic metafile direct scanlines and gradient meshes

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d` accepts WMF/EMF
images through `src/Utils/MiscUI/Picture.cpp` and displays them in TortoiseIDiff.
Windows GDI+ supplies the record playback. The native port must interpret those
records before its existing Image Compare and image-conflict panes can display
them. A previously rejected or ignored paint record is a missing image capability,
not a missing file association.

## Direct bitmap scanlines

[EMR_SETDIBITSTODEVICE](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/e8816cc6-35d2-43e6-8d88-d69cd342372e)
and [META_SETDIBTODEV](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wmf/d0e77d4d-653f-4535-a4db-1496af84acdc)
transfer specified source scanlines to the playback destination. Their framing is
different: EMF declares record-relative bitmap information/pixel ranges, whereas
WMF packs a DIB after its WORD parameters. The
[Win32 banding contract](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setdibitstodevice)
allows the pixel payload to contain only the selected scanline band. Requiring
all declared bitmap rows would incorrectly reject those images.

The native reader keeps header dimensions, source coordinates, scanline start/count
and supplied pixel storage separate. It validates offsets, row alignment, palette
and channel formats, and complete required payloads before painting. Unprovided
rows cannot become invented black image content. The operation copies source
colors and does not inherit the selected pen's Boolean ROP2. Clipping, mapping
and earlier destination drawing remain part of the shared playback pipeline.

Source-copy placement follows the Windows-compatible device behavior: the logical
destination origin is mapped, while bitmap pixels keep device extents rather than
being stretched or rotated as a complete rectangle. Source coordinates retain the
lower-left convention independently of physical top-down/bottom-up row storage.
WMF source/destination WORD coordinates are sign-extended for playback, while
scan counts and extents retain unsigned fields. These compatibility details are
checked against Wine `840a939ee526137639665ff5f587224d6a36403f`:
[direct playback](https://github.com/wine-mirror/wine/blob/840a939ee526137639665ff5f587224d6a36403f/dlls/win32u/dib.c#L709-L815),
[independent API tests](https://github.com/wine-mirror/wine/blob/840a939ee526137639665ff5f587224d6a36403f/dlls/gdi32/tests/bitmap.c#L4612-L4786)
and [WMF coordinate playback](https://github.com/wine-mirror/wine/blob/840a939ee526137639665ff5f587224d6a36403f/dlls/gdi32/metafile.c#L920-L928).
No Wine implementation code is copied.

Full RLE, JPEG and PNG inputs use the applicable existing decoder. Partial
compressed bands remain explicit refusals. Classic compressed input has its own
opaque-color bridge: straight 8/16-bit RGB/grayscale channel storage retains its
RGB samples while alpha becomes opaque. It does not blend a PNG over white and
does not change the alpha-aware EMF+ image/texture bridge. Transparent
premultiplied or unsupported channel packing is refused when original RGB cannot
be proved from the supplied decoder representation.

## Gradient meshes

[EMR_GRADIENTFILL](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/1a3849c8-be6c-4d30-b5d3-f43b4c70ca0d)
contains vertices followed by rectangle or triangle index meshes. Rectangle modes
interpolate along their horizontal or vertical axis; triangle mode interpolates
among three vertex colors. The
[Win32 record contract](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-emrgradientfill)
and [TRIVERTEX color contract](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-trivertex)
are separate from EMF+ gradient brush objects. The Alpha field is ignored for this
classic record; it is not an alpha-gradient blend.

The native implementation evaluates the actual mesh instead of replacing each
triangle with an average or two-color gradient. Device mapping and existing clips
constrain the painted region. Mesh order, vertex indices, record extent and work
budgets are validated. Rectangle and triangle records share bounded color
interpolation, while retaining their distinct serialized framing. The normative
rectangle record includes ignored padding after the index array. The exact compact
Win32 structure representation is also accepted; partial padding or unrelated
trailing bytes are refused. Triangle records have no such padding.

Rasterization uses intrinsic device-pixel centers and a single-coverage edge
convention. It preserves mesh order, including overlaps, and affine reflection,
rotation and shear. Bounded raster output does not promise vector-resolution zoom
or the same antialiased edge pixels as every Windows driver.

## Consumers and verification boundary

The bundled interpreter serves existing default comparisons, explicit IDiff and
three-stage image conflicts. Decoded display pixels do not replace repository
bytes. Selecting a conflict side copies that side's original metafile bytes,
including records that are unrelated to the selected display operation.

The [dated checkpoint](qa/metafile-scanline-gradient-2026-10-21.json) records
16 focused Core methods passing: seven new scanline/gradient methods and nine
related existing rendering methods. The rebuilt universal macOS13 helper passes
source reconstruction and actual conversion/refusal checks on both architectures.
The Debug app embeds matching renderer and source receipts. Four native
case/engine pairs pass on the first run across system and bundled Git, including
default/explicit comparison, malformed whole-image refusal, actual three-stage
conflict resolution and held decoded-result retirement/Quit accounting.

The runtime's first compile required the missing `Data(bytes:)` constructor label;
the successful rebuild includes a static WMF compressed-payload/padding repair.
Core and native groups needed no repairs or repeats. All four owned receivers
were reaped and independently absent, and completed requests fail validation if
an approved helper outlives their private request. No new screenshots or literal
native labels were needed. Help was regenerated before the app build; the source
coverage ledger retains partial review status.

This family does not implement graph export to WMF/EMF, every Windows metafile
record, Windows pixel/font identity, physical Intel/minimum-OS acceptance, or
current signed/App Store distribution acceptance. Those remain separate from
successful decoding of this record family.
