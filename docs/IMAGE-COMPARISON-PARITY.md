# Image comparison

Reference: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseIDiff/MainWindow.cpp`, `PicWindow.cpp`, `TortoiseIDiff.rc`, and
[the official image-diff manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-diff.html).

The existing file-comparison routes now decode original comparison bytes with
ImageIO. Two recognized images, or a recognized image paired with an absent
(empty) side, use the native TurtleGitIDiff view. Mixed image/non-image content
retains the existing binary/text comparison. This is independent of filename
extension. Existing revision pinning and sandbox access leases remain in effect;
the image view performs no file writes or external application launches.

The native view has side-by-side panes with path/revision headers, top/bottom
arrangement, linked scroll positions (default on), drag panning, fit-to-window,
original pixel size and zoom. Overlay forces linked positions and disables
vertical arrangement and the link toggle, matching the upstream command gates.
A left-hand vertical slider controls alpha and the original alpha-toggle icon
switches between endpoints. Image information includes byte size, pixel size,
available DPI, decoded depth and a first-frame notice for multiframe images.
Toolbar artwork is copied byte-for-byte from the pinned TortoiseIDiff resources;
its hashes and source paths are included in the shared icon provenance manifest.
Native colors follow the application appearance.

## Remaining requirements

This is a partial native replacement. XOR/white unchanged regions, separate fit
widths/heights modes, configurable transparent color, blend preset markers,
Ctrl+Shift-wheel alpha, toolbar/menu keyboard equivalents, timed animation and
frame/page controls, three-way conflict selection, standalone Load Images,
image title tooltips, retained layout/preferences and full resizing/physical
interaction/VoiceOver/signed sandbox acceptance remain incomplete. No complete
TortoiseIDiff parity or App Store acceptance is claimed.

The focused Core/icon/file-comparison suite passed 14 tests. The final native
receiver passed with `/usr/bin/git` and the bundled Git engine: actual Git
routing without an image extension, pane raster colors, fit/manual zoom,
linked/unlinked scroll, vertical/overlay transitions, and alpha endpoints and
midpoint, with unchanged HEAD/index/file bytes. Endpoints are compared with
native reference renders in the same display color profile. The final Debug
and App Store unsigned builds and bundle audits passed, including all 109 icon
resources. Inventory pinning and local website generation passed; cleanup found
no remaining test processes or fixtures. See the [QA record](qa/image-comparison-2026-10-10.json).

The Core tests ran before the final native overlay-rendering refinement; Core
sources were unchanged afterward. The final native receiver and both builds
cover the current application source. Native light/dark offscreen captures were
visually inspected as diagnostic artifacts. They do not prove physical gestures,
keyboard handling, VoiceOver, signed Finder activation or signed distribution.
