# Independent EMF+ ordinary paint quality witness

This is a Windows GDI+ observation program, independent of TurtleGit's renderer.
It links only Windows/GDI+ system libraries. The manual-only
`metafile-quality-reference.yml` workflow compiles it with MSVC on Windows 2022;
there is no push trigger. Windows run
[41938727574](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/41938727574)
completed all 53 cases from source `d39b4ff42a0e5f9161ca6b4f40d0436c7400c19c`.
The preceding run failed to compile the ReleaseHDC status check and supplies no
pixel evidence. The complete implementation batch has its own later grouped
checkpoint; successful reference capture alone is not a Mac renderer pass.

The 53 native API cases comprise:

- Smoothing values 0–5 crossed with pixel-offset values 0–4 (30 cases).
- Save/Restore, parameterless and rectangle containers, affine transform and a
  device clip followed by a transform (five cases).
- Translucent SourceOver and SourceCopy overlap (two cases).
- Compositing-quality values 0–4 on the same overlap (five cases).
- Compositing-quality values 0–4 with SourceCopy on the same overlap (five cases),
  retaining partial geometric coverage and intrinsic alpha rather than assuming
  that quality is irrelevant for SourceCopy.
- Linear-gradient, hatch and 2×2 texture fills at pixel-offset None and Half
  (six cases).

The basic 128×96 scene contains isolated one-pixel strokes at X=8, 16.25, 24.5
and 32.75, opaque rectangle edges at eighth/quarter phases, a slanted opaque
wedge, a thin diagonal, an ellipse and a cubic path stroke. Opaque controls over
transparent Clear retain intrinsic alpha so coverage can be measured without
inferring it from a translucent source. State scenes record actual getter values
before and after the restore/container boundaries; setter enum values must not be
assumed to equal native serialized flags.
Both container forms also observe getters and draw an isolated opaque fractional
rectangle and thin diagonal immediately after entry, before any inner quality
setters. These distinguish native container-default quality from inherited outer
quality; later miniature scenes leave the markers exposed. No extra case is added.

Brush controls fill a large fractional rectangle. Their gradient endpoints,
colors, wrap mode, rendering origin, texture pixels and texture transform are
explicit in the JSON manifest. They distinguish a geometry-only pixel shift from
movement of the brush sampling lattice. Raw interior pixels remain available;
the small reported probe list is not the full acceptance oracle.

Each case writes native-recorded `.emf`, all EMF+ record headers and exact body
hex in `-records.json`, and three complete top-down straight-RGBA captures:

1. Direct `Graphics(Bitmap)` drawing.
2. Natural `Metafile(file)` replay into an explicit same-size rectangle.
3. The separate Picture consumer: `Bitmap(file,FALSE)`, `GetRawFormat` then
   `GetLastStatus`, default interpolation, PixelOffsetHalf and TileFlipXY.

The Picture boundary follows pinned `Picture.cpp`; it must not be conflated with
the metafile's recorded quality state. Direct/natural/Picture differences are
observations, never assumed equal. No alpha or zero-alpha RGB bytes are rewritten.
The auxiliary `-reserved.emf` changes only the high flag byte of native
anti-alias, pixel-offset and compositing-quality records to `0xFF`. Its natural
replay, or its explicit playback error, and pixel differences are recorded
separately. This tests reserved-bit treatment without silently changing the native
API case inventory or treating a failed variant as a passing control.

The manifest requires all 53 original direct/natural/Picture captures to complete.
The workflow checks dimensions and byte lengths and retains source revision,
compiler output, Windows build, GDI+/GDI/runtime versions and SHA-256 identities
for source, workflow, executable, runtimes and captures. Raw RGBA plus wire and
metadata are bounded to 16 MiB. No TurtleGit output is used as expected data.

Relevant primary specifications:

- [SmoothingMode](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/08ea5d19-dbd9-4056-9db3-424d8f47c3c1)
  distinguishes the recorded quality choices, including 8×4 and 8×8 smoothing.
- [PixelOffsetMode](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusenums/ne-gdiplusenums-pixeloffsetmode)
  distinguishes integer versus half-integer pixel centers and API aliases.
- [Property records](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/5df4ef02-3895-41a3-aa0e-a8f4b8b31e4e)
  identify anti-alias, pixel-offset and compositing-quality wire records.

This witness does not establish CoreGraphics kernel equivalence, every geometric
pathology, text/ClearType quality, image-interpolation kernels, Windows font
identity, the existing measured path-gradient profile, or full application parity.
