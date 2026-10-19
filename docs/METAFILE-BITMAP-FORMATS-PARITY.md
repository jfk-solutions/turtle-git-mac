# EMF+ indexed and 16-bit bitmap comparison

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
`TortoiseIDiff` delegates image loading to GDI+. TurtleGit's native image
comparison, dropped previews and conflict panes share the bundled metafile
renderer. This extension closes a concrete decoder gap in that shared path;
it introduces no additional window or Git operation.

## Format contract

Microsoft's [PixelFormat enumeration](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/47cbe48e-d13c-450b-8a23-6aa95488428e)
defines indexed 1/4/8-bit color, RGB555, RGB565 and ARGB1555 alongside the
previously supported 24/32-bit formats. Indexed input uses a
[palette](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/dfb51d9c-7d65-45ec-ac00-9666e0578783)
before its packed pixel array, as required by
[BitmapData](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/c236db12-fc5d-4e5b-8266-0468881cd940).
The [bitmap header](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/112a5e2c-6bb3-4daf-8ee3-0f3d3984410f)
provides width, height, signed stride and format.

The same raw-bitmap parser serves image objects and texture brushes. A texture
must account for the complete palette as well as scan lines; treating the whole
body as stride-times-height pixels would either reject valid indexed textures
or read palette words as image pixels. Packed indices retain their bit/nibble
order, and each used index must address an existing entry. Padding bits and row
padding are not pixels. Palette color and alpha feed the existing native RGBA
conversion, independently of texture wrap and image attributes. Palette flags
describe the supplied entries; they do not generate a replacement palette.
Unknown flags and a grayscale declaration containing colored entries are refused.

RGB555 ignores its unused high bit. RGB565 keeps its sixth green bit. ARGB1555
uses its high bit as alpha. The native conversion expands the stored components
for display, retaining row orientation and padding. Existing 24-bit BGR,
32-bit BGRX, ARGB and premultiplied ARGB remain supported.

New indexed/16-bit inputs require four-byte-aligned scan lines. Existing
24/32-bit inputs retain the earlier sufficient-stride compatibility policy.
Dimensions, row extents, palette size and pixel storage are validated before
allocation/iteration. Native bitmap expansion reserves a shared 64-million-pixel
budget per conversion, including generated brush cells, before RGBA allocation. Truncated data, absent palettes, invalid indices or
unsupported formats fail decoding instead of producing a plausible blank image.
The existing helper input/output/deadline limits, process ownership and native
source-byte preservation remain in force.

## Evidence and limits

[Batch evidence](qa/metafile-bitmap-formats-2026-10-19.json) records the actual
runtime build, focused Core and grouped native results, including failed attempts
and affected rechecks. Synthetic records are original TurtleGit fixtures; they
are not Windows GDI+ acceptance captures.

Negative dimensions, extended 16-bit grayscale, 48/64-bit channel formats,
nested WMF images, complex
text/pen behavior and the other documented graphics gaps remain unsupported.
This extension does not certify every metafile, Windows pixel identity, physical
image-window gestures, current signed helper execution, Finder grants or an
App Store release. Original image/conflict bytes remain the comparison and save
inputs; decoding only prepares the display representation.

The grouped checkpoint passed thirty distinct metafile Core methods, the
universal runtime/source reconstruction, Debug app build and native consumers
with system and bundled Git. Two new alpha methods initially assumed literal
sRGB half-red components after native display compositing. Exact embedded PNG
checks showed the source RGBA was correct; an independent plain CSS SVG produced
the same displayed colors as the bitmap. The repaired fixtures retain exact
source-alpha checks and compare uniform interiors to that native reference.
Only those two methods were repeated; twenty-eight earlier passes and both
native passes were retained. Failed attempts and the accidentally empty first
focused filter are recorded in the linked evidence. Both owned receivers were
reaped and their PIDs/process groups independently checked absent.
