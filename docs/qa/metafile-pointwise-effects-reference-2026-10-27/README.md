# Supplementary pointwise effects: native Windows contract assay

This original standalone Windows SDK program observes ColorBalance,
HueSaturationLightness, Levels, all eight ColorCurve adjustments on all four
channel selections, and Tint. It contains no TurtleGit formulas or port-derived
expected pixels. The new scoped workflow builds only this program; it does not
build or test TurtleGit and does not change the earlier three-effect assay.

The bounded inventory has 288 parameter cases:

| Family | Cases | Coverage |
| --- | ---: | --- |
| ColorBalance | 33 | The Cartesian product of −75, 0, 60 for all three channels, plus each axis at −100 and 100 |
| HSL | 33 | Hue −120/0/120 crossed with saturation/lightness −75/0/60, plus six single-axis extrema |
| Levels | 27 | Highlight 0/50/100, midtone −100/0/100, shadow 0/50/100 |
| ColorCurve | 160 | Eight modes × four channel selections × five intensities; exposure/density −255/−64/0/64/255, contrast/highlight/shadow/midtone −100/−25/0/25/100, white/black saturation 0/1/127/254/255 |
| Tint | 35 | Hue −180/−120/−60/0/60/120/180 crossed with amount −100/−50/0/50/100 |

Every case uses the same 32×32, 96-DPI, straight-ARGB source. Flattened indices
are row-major, top-left first:

- 0…255: complete opaque grayscale ramp.
- 256…984: opaque 9³ RGB cube using levels 0, 1, 31, 63, 127, 128, 191, 254, 255;
  red varies slowest and blue fastest.
- 985…1023: RGB (70,140,210), (255,1,128), (1,255,0), each crossed with alpha
  0,1,2,3,7,15,31,63,127,128,191,254,255. RGB varies slowest.

`atlas-requested.rgba` preserves the requested source bytes. `atlas.rgba` and
`atlas.png` preserve the actual native bitmap before any effect. The distinction
matters if native bitmap storage changes fully transparent RGB. The manifests
repeat the index description, not a guessed normalization formula.

`generate` starts GDI+ version 2. Each case first records its own original
`<stem>.emf` through the concrete SDK effect and Graphics.DrawImage effect
overload, with a fixed 32×32 pixel frame, identity placement, SourceCopy and
transparent clear. A separate fresh effect instance then runs Bitmap.ApplyEffect
on the straight source. Successful direct results are `<stem>.rgba/.png`;
available auxiliary data is `<stem>.lut`, retained without assuming its shape or
channel independence. Auxiliary data is capped at 1 MiB per case.

`direct-v1` independently observes ApplyEffect under GDI+ startup version 1 and
writes `direct-v1-<stem>.rgba/.png/.lut`. This does not rewrite original EMFs or
the source atlas. A failed API status remains a failed observation; the tool does
not replace it with an approximate effect.

`replay` (GDI+ v2) and `replay-v1` use the actual pinned Picture constructor path,
`Bitmap(path,FALSE)`, followed by natural-size drawing with default interpolation,
PixelOffsetHalf and WrapTileFlipXY. Both true intrinsic dimensions and intrinsic
GetPixel data are retained. The output canvas uses those actual dimensions;
neither source nor destination is silently stretched into 32×32. `expectedSize`
reports whether the original recording loads as the intended 32×32 image. A
different size is a contract discrepancy for the consumer to reject or inspect,
not a successful 32×32 reference. Unexpected dimensions above 128 are refused.

Direct ApplyEffect and metafile playback are separate observations: the latter
can include native premultiply/unpremultiply conversion before applying the
effect. Alpha and transparent pixels are measured, never inferred from the
effect's name or channel enum. No direct/replay equality is presumed.

The deterministic JSON contract is:

- `generate.json`, `direct-v1.json`, `replay.json`, `replay-v1.json`: platform,
  startupVersion, mode, caseCount, atlas description, and ordered `cases` array.
- Each case has `name`, unprefixed `source` stem, `family`, exact `parameters`,
  and `emf` filename. Parameter names follow SDK fields. ColorCurve uses numeric
  adjustment 0…7 and channel 0…3. Tint's unused naming suffix is zero.
- Generation reports `recordSetParametersStatus`, `recordCreateStatus`,
  `recordStatus`, `recordFrameWidth/Height`, `setParametersStatus`, `applyStatus`,
  and `auxBytes` when those phases were reached. Successful pixels add `width`,
  `height`, `rgba`, `png`; available auxiliary data adds `lut`.
- Replay case names are `replay-<stem>` or `replay-v1-<stem>`. They report
  `bitmapLoadStatus`, `intrinsicWidth/Height`, `expectedSize`, `drawStatus` and
  output pixels. An `intrinsic` object separately references
  `replay[-v1]-<stem>-intrinsic.rgba/.png`, keeping its fields separate from final
  output fields.
- Exceptions append `error`, `recordError`, or `directError`; a recording failure
  does not suppress the independent direct observation. Missing later-phase fields or nonzero statuses are
  not successful pixel evidence. Each case is flushed so partial evidence can
  survive a process failure. Setup/output failures use a nonzero process exit.

The manifests identify the actually loaded GDI+ module. The workflow saves that
module's file version, source revision, compiler information, input hashes, Windows
version and a sorted SHA256/length inventory of every output file. The artifact
is `metafile-pointwise-effects-native-windows`. Automatic runs are restricted to
the new C++ source and this new workflow; manual dispatch is also available.
Source documents and macOS implementation changes do not automatically rerun it.

Primary references: [effect parameters and classes](https://learn.microsoft.com/en-us/windows/win32/api/gdipluseffects/),
[ColorCurve adjustment ranges and linear saturation mappings](https://learn.microsoft.com/en-us/windows/win32/api/gdipluseffects/ne-gdipluseffects-curveadjustments),
[effect auxiliary data](https://learn.microsoft.com/en-us/windows/win32/api/gdipluseffects/nf-gdipluseffects-effect-useauxdata),
[serialized effect identifiers](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/18f3cb09-8793-42e1-9337-b24794d4223c).
The specs do not supply most numeric formulas; this assay obtains the native
observations needed to implement those formulas within a measured byte bound.

## Complete finite Curve lookup and pending-state follow-up

`CurveLookupReference.cpp` includes the earlier original SDK assay only to reuse its native startup, pixel writer and Bitmap(file,FALSE) replay helpers. It does not invoke that assay's 288-case main. Compile this source with the same MSVC/GDI+ flags.

Run `lookup-v1 OUTPUT` and `lookup-v2 OUTPUT` to capture every valid integer intensity for all eight modes: 511 values each for exposure/density,201 each for contrast/highlight/shadow/midtone,255 each for white saturation(1–255) and black saturation(0–254). Each of all2336 parameter pairs yields a256-byte channel table; the binary is598016 bytes. For every pair, all four channel enums are independently exercised using a256-pixel opaque ramp whose R/G/B channels separately cover every input. The assay verifies all1024 B/G/R/A table entries against the captured selected-channel table or identity and compares every actual GetPixel channel exactly. Any unexpected parameter refusal, missing LUT, routing error, pixel error or incomplete domain makes the process fail. No interpolation or guessed numerical formula is included.

The two excluded endpoint intensities are distinct from unknown support: SDK SetParameters returns InvalidParameter, while derived normative-GUID EMFs load/draw successfully as plain images for all four channels (run40502115968). Their entire RGBA buffers match the original identity baseline, under startup versions1 and2. They must use the measured ordinary-image fallback rather than rejection or division by zero.

Reuse the already-downloaded normative-wire artifact, then run the current `make-endpoint-variants.py` once to add the three authored `state-*.emf` witnesses without re-recording any direct examples. `states-v1 OUTPUT` and `states-v2 OUTPUT` discover exactly those three files and record native Bitmap pixels/statuses for validBalance→ignoredCurve→E, ignoredCurve→validBalance→E and ignoredCurve→plainPoints→E. These are observations; prior solo ignored-Curve evidence does not establish interposition behavior. Original source wires/manifests remain preserved by the generator.
