# Matched RedEye model discriminator

This original Windows SDK source capture isolates the remaining **general**
RedEye questions. It is not an application check or a fitted replacement for
GDI+. Production RedEye application remains disabled. No inferred coefficient,
scored center or observed expected pixel is fed back into this generator.

`RedEyeModelReference.cpp` records 27 planned 32×32 opaque sources plus two
same-job uniform controls. It retains the reviewed Seed/Inverse native transport:
fresh input and Effect for each operation, readable heap storage of
`sizeof(RedEyeCorrectionParams)+sizeof(RECT)`, both the real pointed-to RECT and
inline backing, stable lifetime, and one full-source signed rectangle. The shared
Pointwise reference is included only for native SDK setup, PNG codec and file
helpers. No earlier inventory is rerun. The square24 matched-histogram anchor and
two uniform controls intentionally repeat individual inputs within this new job.

## Questions and complete inventory

| Inputs | Count | Discriminator |
| --- | ---: | --- |
| `model-hist-{square24,permuted,two-rectangles,center-rows,center-gray}` | 5 | Exactly 576 red `(240,20,10,255)` and 448 gray `(96,96,96,255)` pixels in each, with different foreground extent, topology and angular distributions. Source histogram equivalence is asserted before SDK work. A difference rules out an exclusively global RGB-histogram amplitude selector; sameness alone does not establish a formula. |
| `model-gray-hole{2,4,8,16}` | 4 | Center gray holes of increasing size on otherwise uniform red, retaining full red extent32. Separates rare-outlier/glint handling from the 24-sized foreground amplitude. |
| `model-red-square{20,22,26,28,30}` | 5 | Center red extent20/22/26/28/30 on gray. Complements the existing16/24/uniform observations and distinguishes a smooth extent response from histogram-confidence or median boundaries. |
| `model-channel-{g0,b0,gb0,r255}-{uniform,gray-hole}` | 8 | Colors `(240,0,10)`, `(240,20,0)`, `(240,0,0)`, `(255,20,10)`, each uniform and with one gray96 pixel at15,15. Separates a zero green/blue denominator, two zero channels and red255 saturation from the earlier pure-red FILE/direct divergence. No zero-channel branch is presumed. |
| `model-gradient-{red-x,red-y,green-x,blue-x,brightness-x}` | 5 | Continuous distributions. Red-axis permutation has exactly identical RGB histogram; all red levels32..240 stay above green20. Green/blue vary0..96 independently. Brightness ramp has fixed positive7:2:1 chromaticity. Source-only mean extension and variance models must face these full buffers rather than binary-only plateaus. |
| `model-control-{red,gray}` | 2 controls | Same-job opaque uniform red baseline and gray identity, with fresh source/context. |

All29 cases use full ROI `[0,0,32,32]`, alpha255, source-copy recording, native
32×32 frame and no manual pixel scaling. Gray-hole cases may contain a native
glint component; complete buffers retain it rather than masking it away.

## Observations and provenance

The four independent processes are `generate` (GDI+ startup2), `direct-v1`,
`replay` (startup2), and `replay-v1`. Each native replay performs the pinned
`Bitmap(file,FALSE)` load, captures intrinsic GetPixel RGBA, and captures the
actual Picture-style DrawImage with SourceCopy, default interpolation,
PixelOffsetHalf and TileFlipXY. No direct result substitutes for FILE output.

All29 observations are in each manifest’s `cases` array: `caseCount29`,
`plannedCaseCount27`, `controlCount2`; controls share the identical schema.

Both generating startup processes preserve actual input GetPixel RGBA/PNG and
requested raw RGBA (`atlas-…` versus `atlas-direct-v1-…`); a mismatch is explicit
and fails the utility after preserving observations. Each of29 cases retains
8 effect observation buffers: direct/create-output for both startup versions and
intrinsic/final FILE output for both versions. There are232 full observation RGBA
buffers. Successful manifests expose435 expected zero SDK/file statuses. Every
RGBA is straight, top-left row-major and exactly4096bytes. Direct/create/file
outputs are intentionally not asserted equal: differences are evidence.

The scoped `.github/workflows/metafile-redeye-model-reference.yml` builds this
single tool with MSVC on native `windows-2022`, runs all four modes, checks all
29 inventories, statuses, dimensions and source-equality booleans, and retains
artifacts on failure. Tool nonzero status, missing fields, exceptions, dimensions
or source mismatch fail the job. The provenance step records source revision,
compiler/OS/GDI+ versions, hashes of this source, the included Pointwise helper,
workflow and executable, then every output member's bytes/SHA256.

The original SDK-recorded EMFs and raw observed RGBA are the evidence. No Wine,
Mac rendering, screenshot compositing, application build or old-corpus rerun is
part of this source-contract job. A green action is insufficient without reading
all status fields, both startup source observations and full FILE buffers.

## Local Windows invocation

```text
cl /nologo /std:c++17 /EHsc /W4 RedEyeModelReference.cpp /link gdiplus.lib user32.lib gdi32.lib
RedEyeModelReference.exe generate reference-output
RedEyeModelReference.exe direct-v1 reference-output
RedEyeModelReference.exe replay reference-output
RedEyeModelReference.exe replay-v1 reference-output
```

No dispatch or push is performed by authoring these files. Parent review precedes
any native reference execution. Existing598-source/raw-reference inventory and
strict application oracles remain unchanged.
