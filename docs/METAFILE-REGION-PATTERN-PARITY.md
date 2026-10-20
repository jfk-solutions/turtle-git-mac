# EMF+ region and pattern painting

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
`TortoiseIDiff/MainWindow.cpp:1255` includes Windows metafiles in its file filter;
`Utils/MiscUI/Picture.cpp::Load` uses GDI+ decoding. This extends the bundled
[metafile decoder](IMAGE-METAFILE-PARITY.md) so existing Compare and image-conflict
panes can open more of those files. Captured repository bytes remain authoritative;
rendering creates only private display data.

## Region geometry and clipping

The format contracts are Microsoft's [region object](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/3f8c4a6a-a0af-4ba2-8bb2-0d2f4569c493),
[region nodes](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/b2c1433b-1c80-4992-a861-bcc0e491c8da),
[FillRegion](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/25183a76-a71f-46a1-9670-77dae28e0027)
and [SetClipRegion](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/a9d596a3-08cb-4232-8ea6-4b58717c4c04).
Region trees carry rectangle, path, empty and infinite leaves and Boolean
AND/OR/XOR/Exclude/Complement operations. RegionNodeCount describes child nodes;
the root is additional. A malformed tree cannot silently become a rectangle.

Region fills resolve the record's brush ID or inline ARGB flag. Region clips
combine with the existing clip in device coordinates so later world transforms
do not move an already captured clip. Indexed Save/Restore and graphics containers
retain that captured state. Each object is limited to 4,095 nodes, depth 64 and 262,144 path points. Each
conversion reserves region work before painting, capped at 65,536 node visits and
1,048,576 path-point visits. Referenced masks avoid recursively copying child
markup; mask construction is capped at 65,536 definitions and 64 MiB of body
markup. Unsupported encodings continue to fail explicitly.

## Hatch cells and texture brushes

Microsoft's [hatch brush](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/ffb875ee-9713-4356-a869-5e4dc4ea4afa)
and [HatchStyle enumeration](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/ac72d44f-1ec9-401b-82d6-f16c8e84134d)
define independent foreground/background colors and 53 styles. Their eight-pixel
cells come from Wine's pinned `HatchBrushes` table, isolated in
`src/turtleGitHatch.js`. They are not average-color substitutes or newly invented
patterns. Foreground/background alpha and device phase remain separate from the
filled geometry.

[Texture brush fields](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/d59b926e-f79c-4a88-af18-77c2e58d53d7),
[optional matrix and image](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/65bf0dda-baf3-4ee0-a6c4-f37a2f73c026)
and [brush flags](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/1ab04f60-1c58-410f-a29e-d725f5eb9b0f)
provide the texture contract. Bitmap bytes use the existing bounded native
raw/compressed-image adapters. Brush matrices, world transforms, wrap/reflection
and DoNotTransform are handled independently; an already gamma-corrected texture
is not corrected a second time. Native CoreSVG's bitmap pattern limitations
require explicit display painting with bounded raster/tile work. Clamp paints
the original texture extent rather than repeating it. Repeated texture cells
retain negative-index phase and independent X/Y reflection.

The initial local implementation assumed CoreSVG would supply a 2× raster and
used bilinear footprint sampling to reduce it to intrinsic size. Hosted macOS
15.5 demonstrated that this was not a portable contract: hatch colors/phase and
wrapped-gradient stops failed their unchanged pixel assertions. The
[explicit raster continuation](#explicit-native-raster-continuation--october-19-2026)
replaces that assumption with a controlled intrinsic-size render.
Hatch coverage blends premultiplied colors before unpremultiplication so a
transparent colored foreground cannot contaminate background RGB. The original
vector geometry still clips the brush paint; this does not provide unlimited
resolution pattern rerendering on zoom.

## Source and licensing

The base renderer remains MIT-licensed WmfEmfViewer at
`4e0d6d6807349ebfc8f8c681009c14f9e57621ff`. The hatch table is adapted from
[Wine brush.c at 7298a818](https://github.com/wine-mirror/wine/blob/7298a818b79446bae153b8d5aa27235ab3703bf9/dlls/gdiplus/brush.c),
under LGPL-2.1-or-later. Its copyright and source revision accompany the adapted
module; `Licenses/Wine-LGPL-2.1.txt`, NOTICE and exact patch sources accompany the
packaged runtime. Configuration/MetafileRuntime.json records the full source hash.
No Wine executable or library is linked or required. Reconstruction and hosted
cache inputs include the added license and notices.

## Validation and remaining work

The [dated evidence](qa/metafile-region-pattern-2026-10-19.json) records the
universal runtime/source/license reconstruction, Debug app build, 26 distinct
passing metafile Core methods, six runtime-cache checks and four native
case/engine pairs. The initial Core failures, sampling diagnostic and focused
rechecks remain recorded. Twenty-five methods passed after the production
sampling repair; only the remaining fixture's corrected texture-center method
needed another run. No full application Core suite was repeated.

The 44 new original records cover region Boolean truth tables, all six clip
combine modes, float/int16 path geometry and holes, infinite/empty leaves, captured
transforms/restores, all 53 hatch styles, origin/device phase, unequal alpha,
texture wraps/matrices/DoNotTransform/gamma flags and malformed/resource refusals.
The native receiver loads representative new images through actual two-side
Compare and a real three-stage region/hatch/texture conflict, reloads them and
retains original bytes, HEAD, index and working files. Both Git engines also pass
the retained native color/alpha/theme/ownership checks. All four owned receivers
were reaped and their PID/process-group absence checked afterward. These checks
ran on the local arm64 host; universal slices are not full Intel rendering proof.

Full Windows pixel identity, physical zoom/font/antialiasing acceptance, current
signed-parent execution and complete hosted integration remain separate gates.
Relative/RLE region paths, negative rectangle extents, singular/ill-conditioned
region fill transforms and nested-metafile textures remain explicit refusals.
Classic WMF region/flood filling, uncommon raster operations, advanced pens,
complex glyph/StringFormat layouts and other documented format gaps remain open.
This batch does not certify every Windows metafile or the complete application.


## Explicit native raster continuation — October 19, 2026

The full hosted bfa1fafe run compiled the app and extension successfully, then
ran 2,089 Core methods with two skips and 86 failed assertions in three metafile
methods. The failure is broader than the earlier local pattern checkpoint:
checker cells lose both pure colors, eight-pixel phase comparisons drift, and a
wrapped-gradient sample is blurred. Earlier ARM-only passes do not certify this
hosted raster path. [Dated evidence](qa/metafile-raster-compatibility-2026-10-19.json)
retains the failed run and subsequent scoped implementation/checks.

The compatibility family controls the SVG bitmap dimensions and named sRGB
color space instead of relying on an unspecified cached NSImage representation
and a guessed 2× reconstruction. Embedded painting samples follow device-pixel
centers, while vector clipping/antialiasing and captured hatch alpha/origin/world
state retain their existing contracts. Input and aggregate painting limits remain
bounded. Original pixel assertions remain part of acceptance; no wider tolerance
or successful blank/average-color substitute is introduced.

Current hosted revalidation, physical Intel/minimum macOS, arbitrary source
painting and the later signed distribution candidate still require separate
acceptance. This family does not certify all metafile formats or the whole port.


A new diagnostic initially compared a plain native SVG vector gradient with a
literal channel-interpolation formula; the local native backend returned other
channel values. That observation remains a separate plain-SVG color-interpolation
acceptance gap. [SVG specifies sRGB as the initial interpolation space](https://www.w3.org/TR/SVG2/painting.html#ColorInterpolation),
so this observation does not invalidate the original formula or establish native
SVG conformance. The strict reconstruction regression instead embeds an
independent named-sRGB pixel ramp, matching the metafile helper's actual paint
contract, and compares every channel at its expected device-pixel center. The
existing hatch/gradient predicates are retained. The raw helper pixels and final
native raster are checked separately so another resampling stage cannot hide a
painting or phase error.


The explicit-raster checkpoint passed 33 distinct current Core methods
cumulatively (32 initial and the one corrected embedded-ramp case). Debug passed;
four native consumer/color case/engine pairs passed cumulatively. The first
bundled native attempt inherited the live desktop Shift key and intentionally
selected Merge before decoding. Pinning the test-owned task-local default choice
repaired that fixture without changing production routing or relaxing its image
assertion. Only failed/unrun native pairs were repeated. All five receivers,
including the failed attempt, were reaped and independently absent by PID/group.
No full local Core suite or current signed/hosted acceptance is claimed.

The [compressed-path continuation](METAFILE-PATH-PARITY.md) supersedes the earlier
relative/RLE region-path refusal. Region tree, coordinate and mask budgets remain
independent of the shared path decoding/tracing budgets.
