# Metafile device bounds and natural canvas

This rendering correction follows the pinned Picture load consumer in TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. Its file-backed GDI+ Bitmap and the
metafile's recorded device bounds are distinct extents. Microsoft's
[ENHMETAHEADER definition](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-enhmetaheader)
states that the device bounds include their right and bottom edges. Those device
units must not be replaced with rounded physical-frame dimensions.

## Regression and correction

Hosted [run 40830336479](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40830336479),
source `c366f2b3`, executed 3,234 Core methods with two skips and 326 failed assertions
in two methods. Two failures came from the existing empty/degenerate gradient
canvas assertions. The other 324 were 81 image-effect border samples times four
channels. No unexpected exception or unrelated Core failure was recorded.

The earlier DIB continuation correctly separated extra Bitmap allocation pixels
from logical initialization for its Windows witnesses, but chose the preinclusive
physical-frame size as that logical extent. That fails when the recorded bounds
already include the final device pixel. It also treated recorded EMF+ comment
streams as classic EMF when their outer parser label was `emf`.

The renderer now captures the original inclusive device-bound extent before
replacing parser bounds with the independently sized natural canvas. Only classic
file-backed EMF receives this bounded logical-DC initialization, clamped to its
validated allocation. Recorded Plus Header presence distinguishes EMF+ containers;
the existing EMF+ background policy remains separate. Embedded transparent
surfaces and WMF behavior retain their established paths. The output is not
cropped, and no final pixel wipe or profile-specific edge rewrite is added.

The table retains the dated bounds-repair policy; the Plus row is superseded by
the initial-alpha continuation below.

| Existing input family | Natural canvas | Recorded inclusive device extent | Initialization policy |
| --- | --- | --- | --- |
| Original Windows DIB profile witnesses |17×9|16×8|Extra allocation remains transparent unless painted |
| Empty/degenerate classic gradient controls |65×65|65×65|Full logical DC remains white |
| Recorded EMF+ image-effect stream |256×64|Separate Plus stream|Historical white compatibility initialization (superseded) |

The entire existing assertions, source wires, reference JSON, raw Windows RGBA
files and tolerances remain unchanged. The DIB family checks complete original
Windows RGBA; the gradient family checks its explicit white-control canvas. These
are different contracts and are not made equal by changing an expected image.

## Historical EMF+ compatibility boundary

The image-effect reference generator explicitly retains both raw `windowsRGBA`
and the established local `rgba` expectations. Its 81 uncovered border samples
are transparent in the native Windows captures and white in the local compatibility
profile. That distinction predates this bounds repair. The subsequent
[initial-alpha continuation](METAFILE-INITIAL-ALPHA-PARITY.md) removes the implicit
Plus matte and adopts the already captured raw samples. The canvas-bounds results
above retain their dated scope. See [image effects](METAFILE-IMAGE-EFFECTS-PARITY.md). It must not be described as raw
Windows alpha equality. Painted transparent pixels keep their original native
assertions; this correction neither widens tolerances nor substitutes backdrop
colors inside recorded paint coverage.

## Checkpoint scope

[The dated checkpoint](qa/metafile-canvas-bounds-2026-10-29.json) records the
successful universal runtime reconstruction, 62 focused Core methods with zero
failures, successful native build and four image-effect/DIB-profile case/engine
pairs passing with system and bundled Git. All four receivers were reaped and
independently confirmed absent; no owned helper survived completion. No local
validation attempt failed in this repair. The original hosted failure remains
separate evidence. A local focused pass is not a complete hosted workflow,
physical image-window acceptance, signed-parent execution, all coordinate origins
or complete metafile support. Installed build31 includes the earlier regression
and predates this correction.
