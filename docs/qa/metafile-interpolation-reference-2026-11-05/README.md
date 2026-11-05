# Independent Windows interpolation and pixel-phase reference

This witness calls Windows GDI+ directly. It does not link or execute TurtleGit,
the JavaScript renderer, CoreGraphics, SVG, or a third-party rasterizer. Captures
were made headlessly with the existing running Windows 11 VM, current-user
Parallels execution, native ARM64 MSVC 18 Professional and Windows SDK
10.0.26100.0. The read-only `ver` observation was Windows 10.0.26200.8655.
Compilation and recording used isolated unique guest Temp directories; those
directories were removed after successful transfer over the existing shared
folder. No VM configuration, persistent execution policy, user files, registry,
network credentials, or GUI application were changed.

The original `InterpolationReference.cpp` captures 192 cases on a 32×24,
96-DPI canvas. The 2×2 source is red/green above blue/yellow. Opaque cases use
alpha255; alpha controls use 255/128/64/0 in that order. API interpolation
requests 0/1/3/5 are crossed with PixelOffsetDefault0, None3 and Half4. Eight
geometries retain integer placement, quarter/half/three-quarter translation,
negative placement, X reflection, affine shear and fractional source crop.
The base destination is `(4,4,8,8)` and the source rectangle `(0,0,2,2)`.
Every case retains the native EMF, complete EMF+ record bodies and headers,
API getters, and complete direct, natural and Picture straight-RGBA readback.
Transparent RGB bytes are not rewritten.

`windows-capture` retains the first screen-HDC measurement.
`InterpolationReference96DPI.cpp` separately repeats the capture using the
modern QualityReference setup: Bitmap.SetResolution96 before Graphics.GetHDC.
`windows-capture96` retains that complete independent capture. All 192 EMFs and
all 576 direct/natural/Picture images are byte-identical between these setups.
The native recorders' physical frame metadata is therefore an observation,
not something this importer normalizes. Integer cases have header ink bounds
`[0,0,11,11]`, frame `[0,0,610,446]` in0.01mm, device1728×1084,
device340×210mm, and EMF+ logical DPI96×96. The requested recording/replay
rectangle and capture canvas are32×24. A consumer using another whole-file
canvas must validate that separately. The current natural-sizing policy using
the recorded device DPI and inclusive frame computes32×24 here:
`round(frame100mm * devicePixels / (deviceMM * 100)) + 1` on each axis. No
padding, cropping or rescaling is needed or applied to these reference bytes.

`WireVariants.cpp` patches only the low interpolation flag byte in native
mode5 files. `windows-wire-capture` retains192 raw-wire0/1/3/5 variants, covering
all48 alpha/geometry/pixel-offset inputs. Wire5 controls exactly match native
originals. **Raw wire1 is byte-identical to wire0/3 bilinear playback** in all
natural and Picture captures on this Windows build. This conflicts with the
MS-EMFPLUS enum description of LowQuality1 as nearest. API1 itself is also
normalized to getter3 and emits no interpolation property. The distinction is
retained explicitly; a spec alias must not be mistaken for a measured native
result. Raw wire5 is the measured nearest-neighbor choice.

`PixelOffsetVariants.cpp` changes only the native Half4 property byte to2.
`windows-pixel-capture` retains32 such aliases. All64 natural/Picture comparisons
are byte-identical to their native4 controls, including alpha, bilinear,
nearest, reflection, affine and crop cases.

The recorded DrawImage API writes DrawImagePoints0x401B. At Half4 it already
subtracts0.5 from each serialized source origin: the base source rectangle is
`(-0.5,-0.5,2,2)`, with unchanged destination points `(4,4),(12,4),(4,12)`.
Recorded sampling still differs from the direct API call. Natural/Picture
nearest Default/None paints red at device x4/5 and green fromx6, at y5:
the exact source0.5 tie chooses index1. Direct Half paints redx4–7/greenx8–11;
recorded Half paints redx6–9/greenx10–11 and has nonzero bounds6..11.

The measured recorded phase model inverts the affine map at device
`(x+phase,y+phase)`, then subtracts `phase` in source coordinates; phase is0.5
for raw PixelOffset2/4 and0 for0/3. The wire source rectangle remains unchanged.
Bilinear Half at device(4,6) has source sample(-0.875,-0.375), red edge weight
0.125×0.625, and observed alpha20. Source-only subtraction at integer device
coordinates predicts zero there and is contradicted by the capture.

`analyze-nearest.py` evaluates mathematical arithmetic profiles against full
native pixels without importing TurtleGit code or output. The coherent nearest
profile `mixed-NZN-bias32` matches every pixel of all48 opaque and alpha nearest
natural images:

- Round row-start affine inverse to nearest Float32.
- Round inverse increments toward zero Float32 (positive down, negative up).
- Round each incremental addition to nearest Float32.
- Perform source phase subtraction and the nearest0.5 addition in Float32,
  then floor to the sample index.
- Retain the existing device-space scanline convention and original ceil bbox.

This is a corpus observation, not proof for every arbitrary affine transform.
All alternative profile results and the troublesome Half-affine crossing values
remain retained. Replacing the device scanline with inclusive source boundaries
failed measured reflected/affine edge controls. The earlier all-down bilinear
effect profile must not be changed globally from these ordinary-nearest results.

`capture-summary.json` records verified transferred hashes, runtime versions and
the hashes of removed generated executables/objects. No executable, object file
or Windows DLL is retained here. Native DLL hashes are observations only; their
binaries were never transferred. Each capture's original `sha256.json`, compiler
output, source and environment metadata remain intact.

`VariedReference.cpp` and `windows-varied-capture` add a separate32-case
measurement: source RGBA `(70,140,210,248)`, `(37,91,143,127)`,
`(197,63,121,7)`, `(254,195,83,64)`, crossed with interpolation0/5,
pixel-offset0/4 and all eight geometries. Native GetPixel readback preserves
these requested source values before direct and recorded draws. Natural nearest
integer source centers produce `(69,139,209,248)`, `(36,90,142,127)`,
`(182,72,109,7)`, `(255,195,83,64)`. Picture readback makes the first center
`(68,138,208,248)` while the other listed centers remain unchanged. Direct and
recorded natural agree on these samples. These original bytes expose repeated
association/unassociation losses hidden by the earlier0/255 primary-color atlas;
no normalization cycle is inferred merely from visual similarity.

Run `python3 import-reference.py` to import all192 preferred96-DPI recordings,
48 raw interpolation1 witnesses,32 raw pixel-offset2 witnesses and32 varied-color
recordings (304 total) into
`Tests/TurtleGitCoreTests/Fixtures/Metafile/Interpolation/Windows`. It copies only
original EMF and separate untouched `.natural.rgba` and `.picture.rgba` files,
with `expectedNatural`/`natural_sha256` and `expectedPicture`/`picture_sha256` in
the manifest. Legacy `expected`/`rgba_sha256` are explicitly natural aliases; a
Picture consumer must not use them. No equality between these consumers is
assumed. Existing owned manifests from the earlier suffix schema must be
retired by their owner before regeneration; changed references are refused. Use
`--check` to compare an existing import without writing. Import/check were
verified against a private temporary destination, not the product fixtures.
Reference capture and arithmetic analysis are not a passing Core/native app
validation checkpoint or a claim of complete format parity.

Primary sources:

- [MS-EMFPLUS InterpolationMode](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/51312252-755a-4c8b-84bd-6ae73da1b5ea)
- [SetInterpolationMode wire record](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/2fe03573-1e0c-4cc5-8ab3-74421ef17c18)
- [PixelOffsetMode device centers](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusenums/ne-gdiplusenums-pixeloffsetmode)
- [DrawImagePoints source rectangle](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/9bad3867-71b0-46fb-9b90-f7d8fb37ff76)
