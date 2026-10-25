# Path-gradient painting in image comparison

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
`TortoiseIDiff/MainWindow.cpp` offers WMF/EMF input, and
`Utils/MiscUI/Picture.cpp::Load` uses Windows GDI+ playback. This family extends
the shared macOS metafile renderer used by image comparison and conflict panes.
The original metafile remains the comparison, save and conflict-resolution input.

## Painting contract

The candidate supports simple closed line polygons and the previously recognized
canonical ellipse, separate surrounding colors, off-center brush origins,
transforms, focus scales, blend factors, preset colors and gamma correction.
Fills, pen strokes, text outlines, clipping and SourceCopy use the same captured
brush. Pen coverage remains an independent geometry operation: recorded smoothing
and aliased stroke coverage must not be approximated by changing gradient colors.
This does not establish cross-platform equality of arbitrary fonts or every
antialiased edge.

Windows distinguishes several combinations. Uniform surrounding colors use the
analytic path profile. Focus scales expand its center-color region about the
configured center; scales 0 and 1 follow measured GDI+ endpoint behavior. For
multiple surrounding colors, the measured focus setting has no effect. Those
polygons use device-space Gouraud spans with integer major-axis distance counters
and fractional endpoint carry. The surrounding-color array supplies one color
per vertex; missing serialized colors become white and excess colors are ignored.
This wire behavior differs from the native setter's expansion of a short array.

Preset positions also depend on the profile: uniform-brush stops progress from
the boundary toward the center, while the measured multicolor profile starts at
the center. Blend factors retain their separately measured mapping. Gamma and
alpha interpolation follow independent Windows path and linear controls:
associated-alpha color interpolation and an empirical power-2.2 gamma profile.
Linear gamma interpolates sixteen factor intervals; reflected path tiles filter
the brush texel lattice across the repeated or mirrored neighbors.
The exponent is a compatibility reconstruction from pixels, not a normative
formula asserted by the specification. Linear brushes use their own integer
sample lattice; Windows repeats the measured linear Clamp records. Path Clamp
and reflected path tiles retain their distinct domain and seam behavior.

The point-array brush form is treated as a closed line polygon because native
GDI+ records and replays it identically to the explicit line-path form. The
MS-EMFPLUS description calls the array a cardinal spline, but does not supply a
curve tension that would justify inventing different geometry for these records.
No Wine gradient painting code was copied; the numeric reconstruction and
synthetic reference programs are original.

## Independent Windows evidence and repairs

The original assay, [run 40211592419](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40211592419),
contains 88 cases: 36 authored records, 26 native controls and 26 recorded
replays. The focused [framing repair](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40212332279)
preserves that evidence and measures display headers, explicit pixel page units
and bounds before enrolling corrected samples. It also supplies independent
linear alpha/gamma controls. The Windows glyph draw returned status 9; it is not
an exact cross-platform font-outline oracle.

The pixel assays initially render into an explicit 64 by 64 pixel destination.
A later exact `Picture.cpp` consumer assay uses `Bitmap(filename, FALSE)` and
reads its natural pixels directly. Authored inputs have a 65 by 65 natural
canvas; the two native-recorded linear-alpha inputs have a 64 by 64 canvas. Their
top-left 64 by 64 pixels are byte-identical to the earlier references. The
recorded dimensions and the reference playback extent are separate facts.

Four additional physical-frame controls distinguish the extent formula:
approximately 64.1 and 64.4 pixels produce a 65-pixel natural canvas, while 64.6
and 64.9 produce 66. The candidate therefore uses `round(frame extent at 96 dpi)
+ 1` for EMF, publishing that same extent to the renderer's header bounds. It adds
the inclusive right/bottom pixel without rescaling recorded device geometry.
Without a usable physical frame, the inclusive `rclBounds` supplies the extent.
This inclusive policy belongs to the top-level file-backed Bitmap consumer.
Embedded metafile inspection, live replay and isolated texture rendering retain
their established logical frame extent and captured device DPI. Applying the
file Bitmap extent to an embedded child changed texture periods and broke the
independent raw-bitmap controls; the repaired candidate keeps these profiles
separate. Generic serialized metafile textures remain a native display extension,
as documented in the [embedded-image contract](METAFILE-EMBEDDED-IMAGE-PARITY.md),
rather than an asserted Windows child-dimension rule. WMF sizing remains
unchanged. Existing viewport and work limits apply to both profiles.

The first grouped Core checkpoint actually failed: all five retained methods
passed, the four new positive methods failed, and the new refusal method passed.
Its failures exposed linear wrapping/sample phase, focus and multicolor blend
semantics, native Gouraud quantization, reflected seams and pen coverage. That
result remains evidence. A third, [six-control assay](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40215837603),
varies vertex and center phase and steep/shallow edges without repeating the
prior corpus. The resulting common major-axis model matches ten independent
multicolor reference frames within one channel value in numeric probes.

The final grouped Core checkpoint ran 167 methods: 162 passed, including all
five path-gradient methods and all 100 retained image methods. Five methods in
two suites exposed the embedded texture profile distinction and an export test
that resized the new canvas. After repairing those causes, all 13 methods in
the two affected suites passed; the other 154 methods were not repeated.
The rebuilt Debug app and the new native workflow passed with system and bundled
Git. Both owned receivers were reaped and independently absent. The native
checkpoint covers original-byte comparison/conflict consumers, refusal,
permissions, cancellation and Quit ownership. It does not prove signed installed
behavior or complete visual parity. Exact failures, repairs and scope are in the
[Mac checkpoint](qa/metafile-path-gradient-2026-10-25.json); unchanged Windows
expectations and profile limits are in
[the reference record](qa/metafile-path-gradient-windows-reference-2026-10-25.json).

## Bounds and remaining gaps

Complex cubic boundaries beyond the recognized ellipse, multiple subpaths,
self-intersections and degenerate boundaries are refused. A Gouraud edge whose
major device-axis extent truncates to zero is also refused rather than divided
by zero or assigned guessed subpixel colors. These are whole-image refusals;
earlier painted records are not exposed as a successful partial image.

Each boundary admits at most 4,096 points, with 1,048,576 aggregate decoded path
points and 16,777,216 aggregate boundary comparisons. Rasterization allows at
most 16,777,216 pixels per viewport, 67,108,864 aggregate gradient pixels and
67,108,864 estimated path-gradient work units, including edge and focus costs.
Mask markup has its own bounds. These limits do not promise arbitrary curved
paths, devices, fonts, codecs, minimum-OS behavior, signed sandbox integration or
App Store acceptance.
