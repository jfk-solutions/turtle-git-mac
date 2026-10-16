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
available DPI, decoded depth and a selected-image counter for multi-image files.
Toolbar artwork is copied byte-for-byte from the pinned TortoiseIDiff resources;
its hashes and source paths are included in the shared icon provenance manifest.
Native colors follow the application appearance.

## Remaining requirements

This is a partial native replacement. Broader animation/frame/provider behavior and
conflict selection acceptance, historical-blob Open prefill,
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

## XOR checkpoint (`38420c1`)

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
bytes remained unchanged. Both unsigned Debug/App Store builds and
bundle audits passed with all 110 original icon resources. See the
[XOR QA record](qa/image-xor-2026-10-10.json). This is hidden native testing;
physical menu/keyboard/drag, VoiceOver and signed acceptance remain open.

## Linked dimensions and stepped zoom

Pinned `FitWidths`/`FitHeights` call `SetZoom`, which matches the other image's
width or height through `SetZoomToWidth`/`SetZoomToHeight`. A single constraint
preserves aspect ratio; both constraints retain both linked extents in
`ShowPicWithBorder`, allowing different proportions to be matched. The native
renderer now carries independent displayed extents through pane layout, alpha
and XOR. The per-picture model retains each zoom and linked dimension through the
source's sequential updates, including disabling one constraint and applying
Original Size to base and then destination. Zero linked extents do not replace
an ordinary extent. Matching is independent of the Link image positions toggle.
Original fitwidths/fitheights artwork is used in the toolbar and View menu.

`FitImageInWindow` caps fitting at 100 percent. Native fitting now also avoids
enlarging small images. `Zoom` quantizes percentages to tens, steps by 10 below
100, by 20 between 100 and 200, and by 10 above 200; Zoom Out bottoms at 10.
The previous multiplicative zoom has been replaced with these source steps.
The disabled Blend alpha menu state is unchecked outside overlay, retaining
the chosen mode for the next overlay. Sizing callbacks capture scalar side identifiers
and weak model references so native panes do not retain their model through
a captured representable.

Core checks cover unequal aspect ratios, each matching combination, absent
reference dimensions, no enlargement and zoom quantization/thresholds. The native
receiver additionally measures actual colored pixel extents for unequal images,
both constraints, stepped zoom and Original size. Native resize/gesture behavior,
Windows integer/border rounding, frame controls and signed acceptance remain open.

The sizing checkpoint (`2d8e313`) passed 19 focused Core/icon/file-comparison tests.
The native receiver passed with system and bundled Git, measuring actual colored
pixel extents for unequal aspect ratios, both matching controls, source stepped
zoom and Original Size; existing pane/alpha/XOR and Git-byte preservation checks
also passed. Both unsigned Debug/App Store builds and bundle audits passed with
all 112 original icon resources. See the [sizing QA record](qa/image-sizing-2026-10-10.json).
These checks do not establish physical input, signed Finder/sandbox acceptance,
all controls or full application parity.

## Alpha input and scoped keyboard commands

Pinned `NiceTrackbar::SetThumb` tracks clicks and drags immediately, rounding
positions in the 0–16 range from the top of a vertical channel. Native alpha
uses an inverted AppKit knob value and reports the actual alpha percentage to
accessibility. `CPicWindow::ToggleAlpha` changes every nonzero value to zero,
then zero to one. Overlay activation resets alpha to half and enables linked
positions. The manual describes movable blend preset markers, but these are
absent from the pinned NiceTrackbar implementation; they are not a missing
control in this source mapping.

`PicWindow::OnMouseWheel` applies Control-Shift-wheel in quarter-alpha steps,
including while XOR is selected. Native coarse wheel events use notch units;
precise trackpad deltas are normalized by 120. AppKit converts Shift-wheel
to the horizontal axis; the handler accepts that mapped axis. Physical device sensitivity still
requires acceptance. MainWindow arrow/Space commands and RC O/F/S/W/H/I,
zoom, vertical arrangement and Escape accelerators use the actual comparison
window. The Windows Control-V accelerator becomes Command-V on macOS.
The bridge is owned by the displayed image view and retires on removal or
window close; text field editing and attached sheets retain their own keys.
No application-wide event monitor is installed.

The focused Core/icon/file-comparison suite passed 21 tests. The final native
receiver passed with system and bundled Git, including actual slider click,
drag and release, knob direction, accessibility value/increment/decrement,
Control-Shift wheel in Alpha and XOR, actual-window image accelerators and
retirement on close. HEAD, raw index and working bytes remained unchanged.
Native light/dark offscreen pane captures were visually inspected. Physical
gestures, VoiceOver, full accelerator coverage and signed acceptance remain
open. Unsigned Debug/App Store builds and bundle audits passed with all
112 original icons. See the [input QA record](qa/image-input-2026-10-10.json).


Three-pane regular image conflict selection is now implemented with a separate
source selection-mode toolbar and copy-then-resolve confirmation. See
[image conflict parity](IMAGE-CONFLICT-PARITY.md) for its distinct workflow and
verification scope.


Native frame/page navigation and owned playback are now implemented for both
comparison and conflict panes. Manual controls clamp, playback wraps with source
delay limits, linked commands propagate, and overlay/scene/window retirement
stops timers. See [frame/page parity](IMAGE-FRAMES-PARITY.md) for source details,
format differences and verification scope.

## Transparent color and per-window Dark Mode

The View menu now includes native transparency color selection and Dark Mode,
with scoped D keyboard routing. Comparison and conflict panes share the chosen
RGB color per window, including alpha/XOR composition. Switching appearance
resets it to the native theme default, matching upstream SetTheme. See
[color parity](IMAGE-COLORS-PARITY.md) for source behavior and verification limits.

Native Load Images and standalone viewing are now implemented; see
[Open parity](IMAGE-OPEN-PARITY.md) for control mapping and acceptance limits.

## Windows containers and compressed SVG — October 15, 2026

Compared TortoiseIDiff's Load Images filters in `MainWindow.cpp` and the GDI+/
FreeImage/Direct2D loader in `Utils/MiscUI/Picture.cpp` at the pinned source.
The native loader no longer assumes every accepted format has a directly
usable ImageIO container. The adaptation keeps original Git/file bytes intact.

Packed DIB input receives an in-memory BMP header with the correct pixel offset.
Core/Info/V2/V3/V4/V5 header sizes, indexed color tables and external bitfield masks
are accounted for before ImageIO decoding. Header/palette truncation and invalid
counts fail. This delegates actual bitmap compression/color-profile support to
ImageIO; every possible Windows bitmap subtype is not certified.

CUR entries retain directory order and per-representation hotspots. PNG-backed
entries decode individually, including non-square/small representations that the
native ICO decoder rejects. Bitmap-backed entries use single-representation ICO
containers. Variant changes preserve document identity and hotspot metadata;
cursor representations never enable animation. Image Information shows the
hotspot. The original cursor bytes remain available for conflict-side selection.

SVGZ uses system zlib's CRC-checked gzip decoding, including concatenated members,
with a 64 MiB expanded-data limit. Truncated/invalid streams fail. Systems that
do not rasterize SVG through ImageIO use AppKit's vector renderer with an explicit
bitmap at the declared image dimensions, independent of Retina scale. Vector
rendering stays in memory; no temporary previews or converted repository files
are written. Native SVG geometry/color/rendering equivalence for every SVG feature
is not certified. EMF/WMF and any remaining unsupported native codecs stay open.

[Container QA](qa/image-containers-2026-10-15.json) records actual pixel/metadata,
format failure/repair and native window evidence. Full upstream image-format,
physical layout/input and signed sandbox/App Store acceptance remain unfinished.

## Native command surface — October 15, 2026

The connected [native image command family](IMAGE-COMMAND-PARITY.md) replaces
controller-hosted content tool rows with source-ordered AppKit toolbars and
native menu/overflow actions, common keyboard gates, full header tooltips and
stable model ownership across image replacement. See its dated evidence for
validation and remaining acceptance limits.

## Source viewer selection — October 16, 2026

Two-file dispatch now selects the viewer by the pinned source tool/extension
policy before decoding. Default image extensions use IDiff; Shift uses Merge.
Explicit enabled or disabled associations preserve their own alternate-tool
inversion. Invalid image sides remain in IDiff; recognizable image bytes do not
switch a selected Merge view into IDiff. Explicit Load Images remains independent
of external tool settings. See [the connected routing family](DIFF-TOOLS-PARITY.md#connected-imagetool-dispatch--october-16-2026).

The retained native image fixtures now use source-recognized image extensions
for automatic dispatch. Arbitrary-extension image loading remains covered through
explicit Load Images. This corrects earlier fixtures that relied on content-only
routing; it does not weaken their frame, pixel, toolbar or repository assertions.


## Image pointer navigation — October 16, 2026

`CPicWindow::OnMouseWheel`, `SetZoom` and mouse-drag handling provide the source
for this connected native batch. Ctrl-wheel now applies the existing quantized
zoom steps to the addressed image, preserving the pixel under the pointer where
scroll bounds allow. Linked positions copy the bounded origin; linked dimensions
and overlay still determine the peer's scale through the existing sizing engine.
Zero wheel deltas do not zoom. Shift-wheel and ordinary trackpad/momentum scrolling
retain AppKit's horizontal/vertical behavior; Ctrl-Shift-wheel in overlay keeps
alpha priority. A precise wheel event advances one source zoom step by direction,
as upstream does per wheel message.

Ordinary drag pans both linked positions. Shift-drag pans the addressed picture
without moving its linked peer. Unlinked pictures snap each axis to the peer's
scroll origin when within the source ten-point threshold, adapted from pixels.
Overlay Ctrl-drag pans only the second image; Shift-drag pans only the first.
The independent translations are bounded by that picture's scrollable extent,
used by alpha and tiled XOR rendering, scaled during wheel zoom, and cleared when
leaving/re-entering overlay or replacing the input images. Ordinary overlay drag
retains those relative translations while moving the shared viewport.

The image canvas receives keyboard focus on a permitted click and exposes a
native open-hand cursor. Drag captures frame identities, scale, overlay and
viewport geometry; a replacement frame/scale/layout cannot continue its old drag.
Native teardown clears callbacks and pending drag. Comparison and conflict panes
reject wheel/drag while their owner has a child sheet, reload/selection operation
or retired lifetime. Conflict panes now share the actual conflict-owner gate;
previously their default predicate remained enabled during selection work.

See [pointer batch evidence](qa/image-pointer-2026-10-16.json) for native scope,
retained frame/toolbar/conflict checks and validation outcomes. No complete
physical trackpad/mouse/VoiceOver, Windows cursor geometry, minimum-OS or signed
Finder/App Store acceptance is established by constructed receiver events.


## Dropped image inputs and information — October 16, 2026

`PicWindow.cpp::WM_DROPFILES` takes only the first dropped file, calls SetPic on
the addressed pane and fits it. Native image canvases now accept ordered file-URL
pasteboard drops using that rule. They accept arbitrary extensions and an
undecodable regular file as a blank preview with its original byte count; a file
read/permission error retains the previous preview and shows the diagnostic.
The other comparison pane remains unchanged. Images, frame controls, metadata,
path tooltip and original frame decoder follow the replacement. An ordinary
SwiftUI reconstruction keeps the preview; explicit Reload or a new Open input
restores the underlying original comparison inputs. That Reload behavior is a
native adaptation; the pinned image tool has no matching Reload command.

Drop preparation acquires its file lease before a detached read. App Store
configuration requires an active scoped permission for that exact input; a
missing permission reports the existing select-again error. No filesystem read
is performed while merely hovering. The owning model serializes reads, disables
competing commands/frame input, stops playback and fences publication by request
identity/cancellation/owner state. Close retires the request. Quit accounting and
the captured file lease remain until the actual reader returns, including a
non-cooperative reader after Close. A loaded preview retains its permission until
replacement, Reload or owner retirement. No file is written by a preview drop.

For conflict selection, MainWindow's SELECTBUTTON_ID copies its original
selectionPaths entry; PicWindow's SetPic does not rewrite that map. The native
conflict drop therefore changes only the preview, with a visible explanation
that Select still uses the original conflict revision. Busy preview reads block
Select and other panes' competing reads. The existing captured working-file/index
validation, original bytes and owned mark-resolved confirmation remain in use.
This also distinguishes an empty original Base from a subsequently dropped preview.

BuildInfoString's size, dimensions, resolution, depth and zoom are shared by
native information panels/tooltips. Overlay shows both inputs' metadata; conflict
panes now include available DPI, zoom, frame and cursor-hotspot information too.
Original caption/tooltips use the dropped path while the underlying comparison
and conflict document remain immutable.

[Drop/information evidence](qa/image-drops-2026-10-16.json) records grouped native
first-file/permission/lifetime/Reload/conflict selection checks and retained
pointer/frame/Open behavior. Actual Finder drag gestures and sandbox-issued drop
grants, native error/panel/VoiceOver layout, all provider formats and signed
App Store acceptance remain open. No full image tool/application parity is claimed.
