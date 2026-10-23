# High-depth EMF+ bitmap display

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
TortoiseIDiff delegates image loading to GDI+. TurtleGit extends its shared
metafile image/texture decoder without adding a new window or changing saved Git
bytes. Native Compare, image conflicts and dropped image previews use that path.

## Supported wire formats

The [MS-EMFPLUS PixelFormat enumeration](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/47cbe48e-d13c-450b-8a23-6aa95488428e)
and [Bitmap header](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/112a5e2c-6bb3-4daf-8ee3-0f3d3984410f)
define 16-bit grayscale, 48-bit RGB and 64-bit straight/premultiplied ARGB, signed
stride and raw storage. The SDK and wire enumeration disagree on the numeric
64-bit premultiplied identifier: the decoder explicitly accepts wire `0x001A400E`
and SDK `0x001C400E`, rather than inferring alpha from one flag bit. Other unknown
format combinations remain refused.

Raw little-endian WORD samples store B, G, R and optional alpha, or a single gray
intensity. The display adapter projects each WORD's high byte into the existing
eight-bit image pipeline. This follows the actual raw-image playback path in
Wine, pinned at `7298a818b79446bae153b8d5aa27235ab3703bf9`:
[metafile deserialization](https://github.com/wine-mirror/wine/blob/7298a818b79446bae153b8d5aa27235ab3703bf9/dlls/gdiplus/metafile.c)
passes PixelFormat/stride/scan0 to bitmap creation, and the
[pixel readers](https://github.com/wine-mirror/wine/blob/7298a818b79446bae153b8d5aa27235ab3703bf9/dlls/gdiplus/image.c)
consume the WORD high bytes. No Wine function was copied; this is an original
adapter of the documented layout and observed playback facts.

Premultiplied components and alpha are quantized before the existing premultiplied
PNG pipeline; zero-alpha premultiplied RGB is cleared. Straight alpha remains
straight. The exact raw parser serves normal image objects and texture brushes,
including cropping, world transforms, negative stride and nonzero padding.

All raw formats now enforce the wire header's four-byte stride alignment, enough
bytes per row and exact total storage. The earlier RGB24 positive/negative test
fixtures used nine-byte rows; they now use aligned twelve-byte rows with identical
six-color samples, while explicit unaligned positive/negative fixtures retain
refusal coverage. Dimensions, overflow, palette isolation, format whitelists,
aggregate expansion limits and whole-conversion refusal remain enforced.

## Palette regression and source bytes

The hosted `cb676f1a` Core run accepted `unsupported-scanlines-palette.emf` because
that stale negative used legitimate default-palette indices 0 through 3. The
explicit Windows common-display twenty-entry profile made those values valid.
The negative now uses invalid index 20, and a separate short-custom-palette case
also remains invalid. Positive EMF/WMF full and partial bands retain coverage of
valid default colors. These are fixture corrections, not removal of the original
whole-painted-prefix refusal or unchanged-source assertions.

## Validation and limits

The universal runtime and both architecture conversion audits, Debug app and
20 distinct affected Core methods pass cumulatively after test-only repairs.
Four native consumer/conflict case and Git-engine pairs pass; all four receivers
were reaped and independently confirmed absent. The first Core attempt did not
compile; the next exposed an incorrect nil assertion for the throwing decoder.
The repaired method checks both the thrown refusal and absence of a displayed
painted prefix. [Batch evidence](qa/metafile-high-depth-2026-10-23.json) records
these attempts and the development-helper execution scope. Raw embedded PNG colors/alpha and native display are checked
separately, alongside independent 32-bit controls, malformed prefixes and owned
late decode/conflict resolution. The original EMF bytes remain the Save/stage
inputs; rendering prepares a display representation only.

This is an eight-bit macOS display profile. The
[.NET GDI+ remarks](https://learn.microsoft.com/en-us/dotnet/api/system.drawing.imaging.pixelformat?view=windowsdesktop-10.0#remarks)
describe an internal thirteen-bit intensity range; Windows LockBits, HDR/color
management, arbitrary device profiles and complete GDI+ pixel identity are not
certified by these raw wire fixtures. Extended compressed/embedded formats,
physical image gestures, signed helper/grant execution and full hosted CI remain
separate work. Earlier signed-parent evidence does not certify the new formats.
