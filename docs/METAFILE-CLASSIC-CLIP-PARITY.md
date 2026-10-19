# Classic EMF clipping

This extension ports the connected classic GDI clipping lifecycle used when
TortoiseIDiff opens EMF images through Windows GDI+. It uses the existing captured
bytes, private helper and native image panes. It does not modify repository files
or turn an unsupported image into a successful partial drawing.

## Source and adaptation

The independent decoder reference is
[BaseHmiTypes MetafileToSvgRenderer](https://github.com/jfk-solutions/BaseHmiTypes/blob/f491a9514f935d64b54bc62ec70606db19f9105a/typescript/base-hmi-types/src/images/converters/metafile-to-svg-renderer.ts),
revision `f491a9514f935d64b54bc62ec70606db19f9105a`, copyright 2026 JFK
Solutions, MIT. Region-combine masks and independent metaregion/selected-clip
lifecycle inform this adaptation. Its license accompanies the runtime as
`LICENSE-BaseHmiTypes`; source and license hashes are pinned in
`Configuration/MetafileRuntime.json`. TurtleGit retains its existing renderer,
record framing checks, explicit refusals, budgets, affine painting and native
text/bitmap bridges. No BaseHmiTypes runtime package is installed or required.

Primary behavior references:

- [ExtSelectClipRgn](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-extselectcliprgn):
  COPY, AND, OR, XOR and DIFF; a null region is legal only with COPY.
- [SelectClipPath](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-selectclippath):
  selects a completed path, using its recorded fill rule, then consumes that path.
- [SetMetaRgn](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setmetargn):
  intersects selection with the current metaregion and clears selection.
- [OffsetClipRgn](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-offsetcliprgn):
  offsets selection using a logical vector without moving the metaregion.
- [RestoreDC](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-restoredc):
  negative levels are relative; positive levels identify saved states.
- [RegionDataHeader](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/5ca68a15-1811-45b6-a51b-5e40d1055ccc):
  fixed header, rectangle count, buffer size and bounds.

The MS-EMF EXTSELECTCLIPRGN record description calls RgnData logical units,
whereas the API explicitly specifies device units. The playback distinction is
visible in Wine's `dlls/gdi32/enhmetafile.c`: its EMR_EXTSELECTCLIPRGN branch
creates the region with the initial playback transform and calls ExtSelectClipRgn;
it does not apply the current world/window transform to the recorded rectangles.
TurtleGit follows that device-space interpretation, retaining the initial frame
origin mapping. Rectangle and path clip commands capture their logical geometry
through the transform active when the command is recorded. Later transforms
cannot move a captured clip. Offset commands transform the displacement as a
vector, so translation is not added a second time.

## Implementation scope

`src/turtleGitGdiClip.js` in `patches/metafile-renderer.patch` handles the classic
EMF clipping records as one family. It keeps selected clipping and metaregions
independent, retains null versus genuinely empty regions and snapshots both with
DC state. The default visible surface still bounds final painting. Serialized
mask domains expand for offset chains, including chains reached after restoring
saved DCs, so a region outside the image can subsequently move into view.
Classic path brackets defer primitive painting and preserve earlier figures until
a paint or clip command consumes the path. Boolean masks capture geometry rather than replacing XOR or subtraction with
intersection. Completed classic paint is constrained by selection and metaregion.

Framing and construction limits reject malformed region headers, invalid combine
modes, truncated rectangles and invalid saved states. Construction is bounded by
1,048,576 aggregate region rectangles, 4,096 saved DC states, 65,536 mask
definitions and 64 MiB of mask markup. Offset expansion is limited to 1,000,000
units per axis; the final expanded mask domain must also fit 32,768 units per
dimension and 67,108,864 pixels. Very distant offsets are explicitly refused
rather than asking the native SVG backend for an unbounded mask surface. An empty region remains empty; resetting
the selected clip does not reset a metaregion.

## Verification and remaining work

The batch evidence is recorded in
[the classic clipping checkpoint](qa/metafile-classic-clip-2026-10-19.json).
Synthetic fixtures use independent Boolean membership predicates on actual native
pixels, with separate state, transform, off-canvas and malformed-record cases.
The checkpoint identifies the actual executed Core/native scopes and failures;
source existence and serialized SVG alone are insufficient evidence of painting.

This does not finish EMF, WMF or EMF+ compatibility. EMF framed regions,
unsupported raster operations, driver/glyph text, every
font substitution and a Windows pixel oracle remain open. Transformed/compound
EMF+ strokes have a separate [pen extension](METAFILE-PEN-PARITY.md). This family
does not extend classic WMF region APIs. EMF+ custom caps have their own
[connected extension](METAFILE-CUSTOM-CAP-PARITY.md). Every curved classic primitive and
Windows edge-antialiasing rule has not been pixel-certified. Physical Finder acceptance, signed App
Store distribution and whole-dialog visual parity remain separate requirements.
