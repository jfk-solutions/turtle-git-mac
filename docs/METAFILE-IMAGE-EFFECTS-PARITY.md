# EMF+ serialized bitmap image effects

The pinned TortoiseGit image consumer opens images through GDI+ `Bitmap(file,
FALSE)` in `src/Utils/MiscUI/Picture.cpp`; IDiff selects files through
`src/TortoiseIDiff/MainWindow.cpp`. This family adds three previously rejected
EMF+ effects to the native image decoder used by IDiff, repository comparisons,
and image-conflict previews: ColorMatrix, ColorLookupTable and Brightness/Contrast.
It does not certify complete image-format or application parity.

## Connected implementation

`EmfPlusSerializableObject` (0x4038) validates its GUID packet, exact declared
parameter extent and finite/ranged fields before retaining immutable parameters
on the current playback owner. DrawImagePoints validates its complete point data
before consuming that owner's pending block. An E-set draw applies the block to
a copy of the source bitmap; E-clear and missing-block draws paint the ordinary
source. Unused effects survive no-draw Save/Restore and container pairs. Child
metafile playback has its own effect owner, while pixel/output work budgets are
shared across nested conversions.

The PNG pixel bridge runs effects before the existing crop, affine placement,
wrap, clip and SourceCopy paths. Image-table objects, original file bytes and
comparison data remain unchanged. Ordinary 8-bit RGB samples retain their source
color profile and use the measured premultiplied-source round-trip before drawn
effects; other supported native image layouts use bounded RGBA conversion. Direct
Bitmap.ApplyEffect and metafile DrawImage playback are distinct reference paths. Matrix channel calculation uses original channels
for every output component, including alpha. Lookup tables preserve distinct
B/G/R/A wire channels. Brightness/contrast changes RGB and leaves alpha unchanged;
its saturated endpoints and contrast-100 threshold have explicit bounded paths.
Unknown effects, bad lengths/values, excessive pixel work and failed native
adapters fail the whole conversion instead of exposing a partial image.

## Native Windows contracts

The standalone reference was necessary before application validation because
parameter documentation does not specify exact brightness rounding or tolerant
playback lifetime. The [initial native run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40491004875)
records 81 brightness/contrast parameter pairs across all 256 channel levels,
independent RGB and alpha ramps, matrix/lookup channels, original native EMF and
playback through the file constructor. Its artifact SHA256 is
`a7096a1bb97b248fac11ba7ffe3e0ff57b93f6b3d331435ee30feb20ea76633e`.

The [focused replay follow-up](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40491928071)
reuses those direct ramps, adds isolated pending-block/plain-draw and state-stack
witnesses, and replays using both GDI+ startup versions 1 and 2. All 18 loads and
draws succeed and all nine complete image buffers are byte-identical between
startup versions. In the plain-draw witness, an E-clear clone at Y4 precedes the
original E-set draw at Y0; both paint plain pixels, proving consumption by the
first draw. The follow-up artifact SHA256 is
`1a3147347a5d3b7df6ff90ac93be710e3253aa894f93d4e9fd20a3a1f1c943d0`.
Original wires, derived fixtures and hash provenance remain distinct.

The clear Float32 brightness model differs from native Windows by at most one
channel value in this recorded grid: 606 of 20,736 scalar entries differ. The
2,304 sampled contrast-100 entries match exactly. This is a measured precision
limit over these parameter pairs, not proof of exact agreement for every pair.

## Checkpoint and remaining scope

[The batch record](qa/metafile-image-effects-2026-10-27.json) records grouped
runtime/Core/native validation and original failures. E without a pending block
is a positive ordinary-image case; the old fixture name and bytes are retained.
Malformed known blocks and unknown effects remain negative cases. The local checkpoint passes eight distinct focused Core methods cumulatively
and two native workflow groups using Apple Git2.54 and bundled Git2.55. The
17 positive images and ten malformed refusals retain source-byte checks; actual
helper cancellation and original-image conflict staging are included. Both
receivers are reaped and independently absent. Initial fixture extent/background
errors and the low-alpha source-normalization repair remain recorded.

The renderer
retains its existing opaque-white initial canvas outside command coverage. The
Windows reference uses transparent initialization, so fixture expectations adapt
only unpainted pixels; every painted pixel retains the native alpha assertion,
including fully transparent lookup-table output.

The [supplementary pointwise family](METAFILE-POINTWISE-EFFECTS-PARITY.md) adds
ColorBalance, HueSaturationLightness, Levels, ColorCurve and Tint, including
measured ordinary-image compatibility for native Curve serialization.

Independent rectangle-record interposition, effects on embedded metafile image
objects, spatial serialized effect classes, every color profile/decoder layout,
physical image-window acceptance and signed distribution remain separate. The
installed build19 includes this earlier three-effect source batch; it predates
the supplementary five-effect source batch. A green Windows reference run proves
the reference assay, not that the new macOS decoder or whole port has passed.
