# EMF+ ordinary paint quality

This continuation connects recorded smoothing, pixel offset and compositing
quality to the native WMF/EMF image decoder used by comparison and conflict
previews. Original repository bytes remain unchanged. The
[batch record](qa/metafile-quality-2026-11-05.json) retains the initial failures,
connected repairs and passing focused checkpoint: 31 distinct Core methods
cumulatively and eight native case/engine combinations. It is not signed,
installed, complete hosted or whole-application acceptance.

## Independent Windows reference

The independent GDI+ observer in
`qa/metafile-quality-reference-2026-11-05/QualityReference.cpp` captured 53 cases
in Windows run [41938727574](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/41938727574),
source `d39b4ff42a0e5f9161ca6b4f40d0436c7400c19c`. Its artifact ZIP SHA-256 is
`bca1e883888e790f92174fdf0803b3b3202b3435b79c902cf5091acff7f5cfee`.
The fixture importer verifies all 377 capture-file hashes, including the exact
Windows CRLF source identity, before importing EMF files and lossless PNGs from
Windows RGBA output. It does not render expected images with TurtleGit.

The first observer run failed to compile because ReleaseHDC returns void. The
corrected observer calls GetLastStatus separately. Only the successful second
run supplies pixel evidence. Direct drawing and natural-size native metafile
playback agree for all 53 cases; Picture-style loading is retained separately.

## Implemented behavior

Ordinary solid, linear, hatch and texture fills and native pen outlines capture
quality with their world transform. Geometry coverage and brush color are
independent planes. Aliased coverage samples the integer device lattice, or its
half-pixel translation for pixel-offset modes 2 and 4. Antialiased ordinary
geometry uses the measured 8 by 4 lattice, or 8 by 8 for smoothing mode 5.
Opaque linear brush colors follow the measured half-pixel phase and sixteen
quantized color intervals; opaque hatch mixed channels use the measured floor
quantization. Hatch and texture colors retain their captured phase. Texture
brushes need one wrapped bilinear paint plane rather than separately antialiased
SVG tiles. Work, points, coverage tiles and output are
bounded by the existing decoder limits.

Coverage uses explicit half-open scanline crossings at the captured sample
coordinates. Core Graphics' antialias-disabled fill covers touched cells and
therefore cannot supply the required point samples through a transform alone.
Retained native pen paths are flattened under a separate bounded derived-point
budget; they are not serialized and reparsed for coverage. The existing
path-gradient rasterizer remains separate.

Independent scaled and affine wedge captures additionally establish device-space
vertex quantization upward to a 1/16-pixel grid before fill scan conversion.
The initial and restored miniature wedges agree under that rule; unquantized,
nearest-rounded and downward-rounded alternatives do not. Straight aliased
one-pixel lines require a distinct device-line path rather than a filled stroke
quadrilateral. Captured verticals, the exposed ordinary diagonal and both
container markers identify an initial minor-axis intercept rounded down to
1/16, followed by the original slope and nearest minor pixel with ties down.
This evidence is bounded to those controls and the qualified simple-line path;
it does not certify arbitrary caps, dashes or antialiased endpoints.
The line path requires an open straight two-point source, converted width one,
identity pen transform, centered full band, flat endpoints, no dashes or custom
caps, nonalternate drawing, and a world transform whose largest scale is at most
one. It applies only with antialias disabled and pixel-offset 0/1/3. Half-offset,
wider and other native stroke profiles remain separate; the captured Half-mode
endpoint counterexamples are retained in the reference analysis.

Save/Restore retains quality. Both BeginContainer forms enter default quality;
EndContainer restores the parent state. Reserved high flag bytes follow the
captured Windows behavior. Unsupported modes and forbidden record bodies refuse
the whole conversion rather than returning a partial successful image.

The Windows SDK recorder emits compositing-quality values 0 through 4, including
omission of the default setter; these actual wire observations differ from the
normative specification's enum numbering. SourceOver groups 0/1/4 and 2/3 are
distinct: the latter use the captured gamma-corrected blend, with measured
13-bit intermediate quantization. SourceCopy ignores compositing quality and
replaces a touched destination pixel with the covered source, including partial
antialias coverage and transparent source pixels. It does not fade the old
destination back into a partially covered SourceCopy pixel.

## Remaining boundaries

The independent rectangle, wedge and stroke-interior controls cover all 30
smoothing/pixel-offset combinations. They do not certify every curve, pen cap or
endpoint: the Windows capture exposes endpoint rules that differ from a simple
filled butt outline. Native curve/cap geometry remains a separate compatibility
profile. Existing device-clip rasterization, partially transparent destination
gamma combinations, text/ClearType, raw bitmap interpolation and path-gradient
geometry are not certified by ordinary-shape quality controls. Their existing
separate profiles and explicit refusals remain in force.
The subsequent [recorded image interpolation family](METAFILE-IMAGE-INTERPOLATION-PARITY.md)
connects bitmap kernels, pixel-offset phase and native image workflows; its own
Windows observations and grouped Mac checkpoint do not inherit this shape pass.
The new brush controls establish opaque linear/hatch colors and the captured
default periodic texture interpolation, rather than every translucent ramp or
arbitrary texture interpolation kernel.

Core comparisons normalize both independent PNGs and native results through the
same premultiplied sRGB RGBA8 display representation. This does not promise that
every straight-alpha Windows GetPixel channel survives an RGBA8 display roundtrip.
Comparison, reload, file-drop and conflict-resolution checks must also preserve
the original EMF document/stage bytes. Neither reference capture nor these
bounded controls establish complete TortoiseGit image or application parity.

The native checkpoint verifies actual helper binary, renderer and curve-resource
identity before using production image paths with both Git engines. The first
native attempt exposed a fixture that reused DrawImage samples for a filtered
texture brush. Its corrected texture expectations derive from the authored
scale24/translation8 matrix and bilinear source-alpha weights; the original
DrawImage samples and document/index/lifecycle assertions remain intact. All
owned receiver processes are reaped; automated windows remain hidden/offscreen.
