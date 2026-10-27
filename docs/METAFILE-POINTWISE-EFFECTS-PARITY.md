# Supplementary EMF+ pointwise bitmap effects

TurtleGit's native WMF/EMF decoder supports ColorBalance,
HueSaturationLightness, Levels, ColorCurve and Tint in addition to the earlier
matrix, lookup-table and brightness/contrast effects. These render through the
existing IDiff, repository comparison and image-conflict panes. Original image
bytes remain the comparison, Save and conflict-resolution inputs.

This follows the pinned TortoiseGit `src/Utils/MiscUI/Picture.cpp` consumer:
GDI+ `Bitmap(file, FALSE)` followed by image drawing. Direct `Bitmap.ApplyEffect`
is useful numerical evidence but does not by itself establish file playback.

## Wire and playback contracts

The fixed-size SerializableObject packets validate lengths, GUIDs, signed
ranges and curve mode/channel enums. Effects retain the existing playback-owner,
pending-block, image-placement, clipping, SourceCopy and shared work-budget rules.
Malformed late records refuse the entire conversion, including already painted
content; they do not publish a successful partial image.

Windows' own ColorCurve recording uses the ColorLUT GUID with a 12-byte curve
payload. All 152 successful native Curve recordings in this capture paint the
ordinary image through `Bitmap(file, FALSE)`. This profile clears an earlier
pending active effect, while retaining an ordinary-fallback preparation marker;
a later valid effect still replaces it. The actual
three state witnesses retain their complete native pixels, including repeated
SourceCopy alpha rounding. They are not reinterpreted as active curves or
truncated 1,024-byte lookup tables.

Correctly identified ColorCurve records use the specified Curve GUID. A separate
native replay verifies all 160 captured mode/channel/value combinations. White
saturation 0 and black saturation 255 are rejected by SDK `SetParameters`, yet
correctly identified files containing those values load and paint the ordinary
image. These endpoints bypass the Curve transform; they are not whole-file errors.

## Complete finite curve domain

The native curve smoothing does not follow a simple linear approximation of the
parameter descriptions. The bundled `color-curves.bin` contains the complete
finite domain: 2,336 valid integer mode/intensity pairs, each with all 256 input
byte values. All four channel masks, every auxiliary table entry and actual
native pixels are verified for every pair. GDI+ startup versions 1 and 2 produce
byte-identical tables. There is no interpolation between captured settings and
no subset of sampled parameter values used as a fallback.

The 598,032-byte file has a versioned `TGCCLUT1` header and a pinned SHA256.
The helper checks its exact length, header, dimensions and hash before using a
row, then retains immutable data for that conversion. Missing, replaced or
corrupt data refuses the conversion. Builder cache inputs, corresponding
sources, staged resources and embedded validation include the same bytes and
metadata. The generating tool and original independent Windows SDK assay remain
in the repository and the runtime's corresponding sources.

## Numerical and alpha boundaries

Balance and Levels use measured per-channel tables generated procedurally.
HSL uses the observed integer conversion and lookup rules, including native
hue wrapping and tie behavior. Their standalone analysis compares direct,
auxiliary, intrinsic-file and final-draw observations separately.

Windows' fixed-point unassociation differs from exact integer division at some
alpha values. The shared adapter reproduces the measured source normalization,
then the intrinsic-bitmap and final-viewer association boundaries for active
effects. Matrix and lookup-table alpha changes use the resulting alpha at those
boundaries. The adapter models ordinary EMF+ bitmap playback with two
normalization steps. A serialized ignored-effect or endpoint fallback consumed
with the effect flag adds source preparation, giving three. These profiles are
inferred from the independent native pixels, rather than Windows internal code. Clearing the
flag still consumes the pending marker and uses the ordinary two-step path.
Neither fallback applies Curve arithmetic. Conversion-local preparation caches
immutable source objects separately by preparation profile and avoids repeating
normalization for an active-effect result.
This is separate from Apple's PNG encoding and does not change the
original source data or its supported color profile.

Tint currently uses a general procedural hue/luminance model rather than an
exact reconstruction of Windows' numerical algorithm. Across the 35 independently
captured hue/amount profiles, its maximum error is three associated-channel
levels; alpha is unchanged. Straight RGB errors at very low alpha can reach 85,
so the associated-channel bound must not be described as straight-RGB precision.
The full-pixel fixtures retain the original Windows bytes and allow three levels
only for Tint, with one for the other families. This is a temporary, measured
precision gap, not a universal bound for every Tint setting. Exact Tint precision
remains open. [The reproducible report](qa/metafile-pointwise-effects-reference-2026-10-27/tint-model-2026-10-27.json)
records both representations and every captured profile.

## Evidence and limits

[The batch record](qa/metafile-pointwise-effects-2026-10-27.json) records exact
source/artifact identities, original failures, numerical analysis and the grouped
application checkpoint. The original 288-case capture, normative Curve replay
and exhaustive curve-domain capture are independent Windows reference runs;
their success is not a macOS application pass.

Other spatial effects, effects applied to embedded metafile images, every
possible color profile, independent rectangle-record interposition and complete
physical/signed acceptance remain separate. This family does not certify the
whole image renderer or application port.
