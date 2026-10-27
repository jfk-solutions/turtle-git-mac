# General RedEye detector discriminator

`RedEyeDetectorReference.cpp` is an original bounded 43-case Windows SDK
observation utility. It records only new source/ROI combinations and preserves
all earlier reference utilities. No correction formula, center, radius, scalar,
expected pixel result or expected native success is supplied by this program.

The parent-approved inventory combines the following related discriminators:

| Group | Count | Purpose |
| --- | ---: | --- |
| square dimension controls | 6 | 16, 24 and 33 pixel sources, with center/edge gray glints |
| ROI scale | 2 | 16-square ROI inside a 32-square source; partially outside ROI |
| surrounding source color | 6 | Redness and RGB channel dependence of circle radius/activation |
| neutral glint intensity | 2 | Black versus white glint, separating darkness from neutral redness |
| selection order | 6 | Single (9,9), far-first/near-center, brightness versus redness minima |
| directional eligibility | 4 | Equal squared distance in different directions |
| glint redness | 4 | Central glint red excess 1, 4, 12 and 32 |
| asymmetric foreground | 6 | Shifted/tight/partial L shapes and unequal two-lobe supports |
| nonsquare source controls | 4 | 16 by 32 and 32 by 16, center and off-axis glints |
| alpha source controls | 3 | Both alpha128; opaque red/transparent glint; alpha128 red/opaque glint |

All exact source values, foreground rectangles, glint coordinates and submitted
ROI lists are immutable aggregate initializers in the C++ source and are written
into every case's JSON `sourceDefinition` and `parameters`. Hole pixels override
foreground rectangles, which override the background. Foreground rectangles and
ROI coordinates are half-open. The default source is RGBA `[240,20,10,255]`, with
neutral glint `[96,96,96,255]`. Color controls use surrounding RGB
`[128,20,10]`, `[240,120,10]`, `[240,20,120]`, `[120,60,60]`, `[255,0,0]` and
`[180,145,120]`. Asymmetric foreground cases instead use neutral background
`[96,96,96,255]` and red foreground `[240,20,10,255]`.

Each original EMF+ clears its exact source-sized frame to opaque sentinel RGBA
`[17,61,173,255]`, then records one identity full-source DrawImage(effect) in
SourceCopy mode. A rejected draw therefore remains distinguishable from
transparent output. The effect's authored ROI may be tight or partially outside;
the recorded image source rectangle remains the complete source image.

Four fresh-process modes independently capture:

- Startup2 recording, direct in-place SDK application and create-output SDK application.
- Startup1 direct in-place and create-output SDK application.
- Startup2 actual `Bitmap(file,FALSE)` intrinsic pixels and final Picture-path drawing.
- Startup1 the same actual file consumer and final drawing.

Both direct startup-version processes save requested and actual GDI+ source
pixels independently. `generate.json` uses `atlas-*` source files;
`direct-v1.json` uses `direct-v1-atlas-*`, so neither overwrites the other.
The requested RGBA path is explicit in each populated atlas record. Every
observation uses fresh input and effect instances. Output captures are full
straight top-left row-major RGBA plus PNG, not sparse expected samples. Dimensions
are bounded at 128 per axis before source creation and before pixel export.

The final Picture path uses SourceCopy, InterpolationModeDefault,
PixelOffsetModeHalf and TileFlipXY. Recording, parameter, direct/create application,
file load and final drawing statuses remain separate. Native status 2 is retained
without rewriting it to success or inferring file behavior. Workflow success means
capture completion only; statuses, requested/actual input differences, v1/v2
comparisons and actual outputs require independent review. Unexpected transport
exceptions are recorded as `error` and make the process fail.

`.github/workflows/metafile-redeye-detector-reference.yml` retains the original
EMFs, full outputs, input/tool/compiler/Windows/GDI+ identities and SHA-256 member
inventories. The parent agent reviews, commits and dispatches it. No application
build/test, earlier corpus recapture or self-dispatch belongs to this utility.
