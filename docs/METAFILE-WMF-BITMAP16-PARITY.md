# WMF Bitmap16 bitmap transfers

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d` loads WMF
through GDI+ in `Utils/MiscUI/Picture.cpp::Load`. This family extends the private
display conversion shared by image comparisons and conflict panes. Original
repository, conflict and Save bytes remain unchanged.

## Serialized transfer contract

The [Bitmap16 object](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wmf/dc487315-3bb9-40c8-9f49-55ffc6152d8c)
has a ten-byte transfer header followed by WORD-aligned scanlines. Its dimensions
and row byte count are signed WORDs; planes must be one. The row extent derives
from width and bit depth, with each row rounded up to a multiple of two bytes.
Windows transfer playback ignores the serialized Type and WidthBytes fields and
uses the computed row extent; the existing pattern-wrapper contract remains
separate. Positive dimensions and complete computed scanline storage are still
required. The pattern-brush record's extra reserved framing is separate and cannot be
mistaken for bitmap pixels in BITBLT or STRETCHBLT.

Embedded BITBLT retains source coordinates and a common source/destination
extent. STRETCHBLT retains independent source and destination extents. The
source-omitted forms have a separate reserved WORD in their fixed fields.
Independent Windows playback shows the DDB BITBLT/STRETCHBLT forms can use the
existing destination surface as their source, including SRCCOPY. The corresponding
DIB forms fail when their Boolean operation requires an omitted source. This differs from the specification’s
failure wording; the target is the measured GDI+ playback used by upstream.
Overlapping copies need a pre-operation snapshot, not pixels modified while the
copy is in progress.

[CreateBitmap](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createbitmap)
defines WORD-aligned rows and maps monochrome zero/one bits through the
destination drawing context's text/background colors. Monochrome interpretation
must retain bit order and scanline orientation. The measured Windows display
profile also accepts 32-bit BGRX bytes as opaque BGR colors; the fourth byte is
ignored. Unused source storage is framed but need not be decoded for a
source-independent operation. Crop, signed extents,
clipping, mapping, selected patterns and destination-dependent operations use the
existing [Boolean raster pipeline](METAFILE-RASTER-PARITY.md). Saved drawing
state and embedded child transforms belong to that same pipeline.

## Shrinking and saved stretch mode

[SetStretchBltMode](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setstretchbltmode)
defines how eliminated source samples contribute to a smaller destination. The
independent Windows reference confirms that the default BLACKONWHITE mode uses
RGB bitwise AND after monochrome colorization. WHITEONBLACK uses OR;
COLORONCOLOR selects samples and HALFTONE averages them. The mode belongs to
saved drawing state, not the serialized bitmap. New sampling applies to
Bitmap16 DDB transfers and their self-source forms; the existing DIB/EMF path
is retained because its Windows playback differs. Exact sampled coverage, rounding
and device-phase limits must be recorded with the reference and implementation
rather than treating nearest-neighbor scaling as all four modes.
AND/OR reduction uses exclusive source buckets and an anchored 16.16 advance
model to retain the observed fractional endpoint. The captured gradient detects
an extra final source column; the existing monochrome vectors do not uniquely
establish Windows’ internal fixed-point precision. This is an explicit inference
checked against the retained observations. Zero source extent is a successful
no-op; partially out-of-bounds Bitmap16 sources clip mapped coverage and preserve
the excluded destination pixels.

HALFTONE’s nonintegral Windows kernel and device-phase heuristics are not fully
reconstructed. A bounded native quality profile uses integer block averaging,
nearest-neighbor enlargement and Lanczos3 for nonintegral reduction. The
[Wine implementation author’s reference report](https://www.winehq.org/pipermail/wine-devel/2021-May/187917.html)
also distinguishes the observed Windows heuristics from its own approximation;
no Wine resampling implementation is copied here. Captured Windows gradient
values differ from a standard Lanczos3 filter, so this is an explicit rendering
compatibility difference that remains open, not a claim of exact HALFTONE
playback or a missing physical test alone.

## Exact upstream load path

The reference also follows `Picture.cpp:418,420,547–556`: `Bitmap(file,FALSE)`,
raw format/status and intrinsic size, followed by natural-size drawing with
default interpolation, PixelOffsetHalf and TileFlipXY wrapping. All 39 supported
inputs load; all ten selected source-omitted DIB inputs fail construction. Raw
DDB mode/self-copy pixels match the earlier Metafile captures at natural size.
This resolves the class/load-path question without treating GDI API behavior
alone as the application target.

The DIB subject/control pairs compare independent encodings in the local native
renderer; they do not establish Windows cross-format equality. Some DIB controls
remain gray in Windows while the DDB transfer paints. The repaired nested
subject/control both load in Windows but remain blank, so their equality is not
positive nested-rendering evidence. Local nested checks must still require real
colored ink. A naturally transparent last row/column in the 64-pixel Windows
inputs is composited over white in the reference; it is not a transfer-color
measurement.

## Ownership and validation boundary

The [dated checkpoint](qa/metafile-wmf-bitmap16-2026-10-26.json) records the
actual grouped checks and repairs. Thirty-four distinct relevant Core methods
pass cumulatively: 32 on the initial run and the two failed methods after the
endpoint, source-coverage and independent-control repairs. The rebuilt universal
helper and Debug app share source/renderer/unsigned-binary identity; affected
conversion cases pass on arm64 and Rosetta x86_64. The complete Core suite was
not rerun. Both native Git-engine pairs pass 29 samples, 24 independent pairs and 34
refusals each, together with comparison/conflict/drop and cancellation ownership.
Both receivers were reaped and independently absent. Automated windows were
hidden/offscreen with private repositories and preferences. All 1,968 older
binary fixtures retain their bytes. Existing limits still apply to input/output,
decoded bitmap pixels, raster operands and composite work. Malformed records
must reject the whole image; no prefix picture may become a successful result.
Image-loader cancellation retains ownership of helper drain and private files.

A Bitmap16 header supplies no color table, masks or originating device identity.
The measured 32-bit display profile does not define portable 4/8-bit palette
entries, 16-bit channel masks or a compatible 24-bit device context.
[Device-dependent bitmap colors](https://learn.microsoft.com/en-us/windows/win32/gdi/device-dependent-bitmaps)
therefore need a defined compatibility profile rather than an invented palette
or arbitrary RGB masks. Complete device-dependent color interpretation, Windows pixel identity and
current signed-installed, physical Intel/minimum-macOS and full hosted acceptance
are separate requirements. Supported transfer profiles do not certify the
entire Windows graphics API or the whole application port.
