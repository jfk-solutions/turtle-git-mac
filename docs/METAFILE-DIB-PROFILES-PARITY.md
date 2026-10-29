# V4/V5 DIB color metadata and recorded ICM

This family continues the native WMF/EMF image implementation against TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. It covers DIB metadata in raster
transfers, bitmap brushes and direct scanline bands; it does not certify every
Windows color-management or metafile operation.

## Source and independently observed paint policy

Pinned `src/Utils/MiscUI/Picture.cpp:415` loads `Bitmap(file,FALSE)`. Natural-size
painting at 545–556 uses default interpolation, PixelOffsetHalf and TileFlipXY.
Automatic loader correction and a metafile's recorded ICM settings are distinct
stages, so the implementation does not assume that an ICC profile authorizes a
ColorSync conversion.

The original Windows SDK utility in
[the reference directory](qa/metafile-dib-profile-reference-2026-10-29/DibProfileReference.cpp)
ran on Windows2022 in [run40825035410](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40825035410),
source `b4824fc1`. Its two matrix/TRC profiles are original generated inputs,
not copied vendor/device profiles. Windows validates both. A direct GDI control
with an explicitly installed destination profile and successfully enabled ICM
changes linear gray128 to188, whereas sRGB remains128. The same source inputs
loaded and drawn through the actual Picture path retain the complete original
RGB buffers, including their chromatic region. All31 well-formed EMF/WMF cases
match their matching sRGB baseline byte for byte. This includes V4 calibrated
metadata, V5 embedded/linked metadata, explicit recorded ICM ON/OFF and SaveDC/
RestoreDC. Standalone BMP TRUE controls also retain128 on this system; their
TRUE flag alone is not evidence of conversion. Direct GDI attempts without a
usable destination profile fail to enable ICM and are not conversion evidence.

Two deliberately invalid packed WMF cases place the profile before implicit
pixels. Windows paints profile-prefix bytes rather than the intended bitmap.
Those cases do not establish valid before-pixel packed layout or intended-color
rendering. Native framing refuses their profile/pixel overlap.

Microsoft defines [V5 profile member interpretation and packed placement](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-bitmapv5header),
[direct DIB ICM eligibility](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setdibitstodevice)
and [recorded ICM values](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/4935fb3c-c646-4d16-a8f0-f86ee0a9d096).
Profile members are ignored unless CSType is PROFILE_EMBEDDED or PROFILE_LINKED.
Packed DIB profile data follows the pixels; separate EMF information and bit
ranges retain their declared offsets.

## Connected implementation

The shared original metadata module in `patches/metafile-renderer.patch` checks
V4/V5 headers, active profile byte ranges, and separation from the header,
bit masks, color table and actual pixel storage. Inactive profile offset/size
bits are not dereferenced. Embedded data has a bounded ICC-header-sized envelope;
its tags, transfer curves and semantic validity are not interpreted. Linked
names are bounded in-record strings and never become filesystem or network
reads. This is inert metadata support, not arbitrary ICC-transform support.

Raster, monochrome/masked and bitmap-brush consumers share that framing. Packed
pixel starts remain header/masks/palette based; no escaped name, profile offset
or guessed placement redirects them. Profile tails cannot masquerade as missing
pixel bytes. Direct scanline preparation checks the original complete/partial
storage, then preserves opaque metadata when making its private band copy,
relocating only that private copy's V5 profile offset. A conversion-wide64MiB
private-copy/slice budget is shared across nested images and drawing contexts.
Existing raster, clipping, palette, alpha and source-snapshot rules remain in
force.

The full Windows witness comparison also exposed an existing canvas mismatch:
classic EMF's natural inclusive Bitmap allocation gained an extra row/column,
but synthetic white DC initialization filled that allocation too. Initialization
now uses the recorded drawable device extent captured before allocation expands.
The complete natural canvas and pixel assertions remain intact; no output crop
or profile-specific edge rewrite is used. Real painting still owns its pixels,
and Boolean operations retain their existing logical white DC operands.

EMR_SETICMMODE requires exactly one DWORD with values1–4. QUERY leaves current
state unchanged. SaveDC/RestoreDC preserve the recorded mode. Painting follows
the measured Picture byte-RGB profile rather than inventing a transform from the
mode alone. Pixel equality under this policy does not independently prove each
internal saved-state value; the parser/state implementation and accepted record
sequences are separate evidence.

## Checkpoint and limits

[The family receipt](qa/metafile-dib-profiles-2026-10-29.json) records actual
build, focused Core and grouped native outcomes after implementation freezes.
Independent generated fixtures cover six consumers, both profile placements,
inactive metadata, valid embedded spans, malformed overlaps/extents and recorded
mode sequences. The curated `DIBProfileWindows` fixture manifest retains33
original Windows inputs and their actual FALSE/Picture RGBA witnesses;31 are
well formed and two document the stricter packed-overlap refusal. Expected
Windows output was not generated by TurtleGit.

The Windows discriminator covers its recorded32-bit transfer inputs, not every
brush, direct-band, palette, compressed or device profile combination. Local
consumer equivalence extends that measured policy through the shared renderer;
it is not a claim of independent Windows pixels for every such combination.
General WCS conversion, arbitrary external profile loading, device-specific
halftone matching, complete GDI compatibility, signed installed image workflows,
Intel/minimum-macOS and full hosted acceptance remain separate requirements.
