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

This is a partial native replacement. Separate fit
widths/heights modes, configurable transparent color, blend preset markers,
Ctrl+Shift-wheel alpha, toolbar/menu keyboard equivalents, timed animation and
frame/page controls, three-way conflict selection, standalone Load Images,
image title tooltips, retained layout/preferences and full resizing/physical
interaction/VoiceOver/signed sandbox acceptance remain incomplete. No complete
TortoiseIDiff parity or App Store acceptance is claimed.

## Initial pane checkpoint (`e6d3a90`)

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
sources were unchanged afterward. The native receiver and both builds
covered that initial pane checkpoint. Native light/dark offscreen captures were
visually inspected as diagnostic artifacts. They do not prove physical gestures,
keyboard handling, VoiceOver, signed Finder activation or signed distribution.

## XOR overlay

The source `MainWindow.cpp` Blend alpha command toggles Alpha/Xor and is
enabled only in overlay mode. `PicWindow.cpp` applies `SRCINVERT` followed by
`InvertRect` to the rendered panes. The native toolbar and View menu now offer
the original Blend alpha label/artwork; XOR hides the alpha controls and retains
the selected alpha when switching back. The vertical toolbar state is unchecked
while overlay disables it.

The native renderer rasterizes the visible tile at backing resolution, applying
zoom and position before opaque background composition and bytewise RGB XOR
and complement. Identical image/background pixels are white. It avoids an
allocation proportional to the full zoomed canvas. Source Windows/device color
management, border pixels, all image formats and physical appearance remain
subject to the broader parity work. Empty sides compare as background.

Focused Core checks cover exact known RGB XOR values (which distinguish this
from an absolute-difference blend), white identical pixels, scaling/translation,
missing sides, transparency and invalid dimensions. The focused suite passed 17 tests. The current native receiver passed with
system and bundled Git: colored XOR output for changed images, white output
for identical images, removal of the alpha slider in XOR mode and restoration
of alpha-rendered pixels after switching back. HEAD, raw index and working
bytes remained unchanged. Both current unsigned Debug/App Store builds and
bundle audits passed with all 110 original icon resources. See the
[XOR QA record](qa/image-xor-2026-10-10.json). This is hidden native testing;
physical menu/keyboard/drag, VoiceOver and signed acceptance remain open.
