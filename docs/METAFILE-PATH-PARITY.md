# EMF+ compressed paths across image comparison

TortoiseGit is pinned at `7338078f8ddd924b8cddee35f512f2286072136d`.
Its image viewer loads Windows metafiles through GDI+. This extension gives the
Mac renderer one path reader for ordinary drawing, regions, custom pen caps and
the existing accepted ellipse-gradient boundary. It adds no window or Git write.

## Binary contract

Microsoft's [EmfPlusPath](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/b539cf16-6232-4705-9f6e-6f914705145f)
uses its R flag for both relative coordinates and type RLE. C is ignored when R
is present; otherwise C selects signed-short coordinates instead of Float32.
Alignment bytes have no painting meaning. The decoder accepts the specified
forms rather than an independent RLE bit inferred by the upstream JS renderer.

[PointR](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/c861a0d4-39f0-4f6c-bad9-e3f7bf63205e)
coordinates carry signed seven- or fifteen-bit components, independently for X
and Y. Deltas accumulate once in path space. The resulting absolute points feed
existing transforms and stroke geometry; playback cannot accumulate them again.

[Type RLE](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/1acc6ffc-ff99-40fe-925e-b90869b7d02c)
associates each run with its point type. Runs must have their marker, consistent
Bezier bit and exact total. Point kinds, cubic groups, starts and closing flags
are checked before tracing. [GDI+ point flags](https://learn.microsoft.com/en-us/windows/win32/api/gdiplusenums/ne-gdiplusenums-pathpointtype)
retain markers and the unused DashMode metadata; they do not create a new dash
pattern. FillPath and path clips use Alternate/even-odd behavior, region paths
retain Alternate, and custom cap filling retains its separate winding rule.
No undefined path flag is treated as a winding-mode switch.

## Shared playback and bounds

`src/turtleGitPaths.js` is reconstructed from the tracked renderer patch and
included by the existing static CommonJS bundler. Its reader serves normal path
objects, RegionNodePath, embedded custom caps and gradient boundary paths.
Each consumer keeps its existing admissible geometry and coordinate limits.
Gradient compression only changes the wire representation of the already
accepted thirteen-point cubic ellipse; arbitrary radial boundaries and optional
gradient features remain outside that subset.

Before arrays are allocated, the reader checks declared count, minimum encoded
storage and the consumer's limit. General paths retain their million-point
limit, a region retains its 262,144-point budget, and a custom-cap path retains
65,536 points and cap-local coordinate bounds. Conversion-wide decoded and traced
path-point limits are each 1,048,576. Repeated object replacement does not reset
decoding work. These explicit limits can refuse large valid Windows inputs.

Incomplete coordinates/types, invalid runs, unknown flags, malformed cubic groups,
arbitrary trailing bytes and budget exhaustion fail the whole conversion.
Optional alignment bytes need not be zero. The existing process deadline,
input/output limits, private request storage and cancellation remain in force.

## Checkpoint and remaining acceptance

The [dated checkpoint](qa/metafile-path-2026-10-20.json) records passing evidence
for 19 distinct relevant Core methods, reconstructed universal runtime conversion,
the Debug app and native consumers with both Git versions. Its 34 accepted and 41
refusal fixtures use original binary records and independent geometry. A retained
invalid padding fixture was repaired without relaxing the decoder or geometry
assertion. Only affected Core checks were repeated; no full local suite ran.
Driver/glyph text, arbitrary gradient boundaries, uncommon classic raster records,
other bitmap formats, Windows font/antialiasing identity, physical image-window
acceptance, current signed deployment and complete upstream parity remain open.
