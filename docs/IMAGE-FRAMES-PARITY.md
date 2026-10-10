# Image frame/page controls and playback

Reference: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`TortoiseIDiff/PicWindow.cpp` PrevImage/NextImage, LEFT/RIGHT/PLAYBUTTON_ID,
WM_TIMER and overlay transitions in MainWindow.cpp; frame metadata in
`Utils/MiscUI/Picture.cpp`; player resources in TortoiseIDiff.rc.

Each multi-image pane receives original Previous/Next artwork and a one-based
“X of Y” counter. Manual navigation clamps at both ends. Multi-frame images and
TIFF pages offer Play/Stop; ICO variants offer navigation without playback,
matching the source's separate icon-dimension handling. ImageIO zero-based
indexes map to visible image 1 for the first decoded image. Frames are decoded
on demand from retained original bytes. Per-image pixel dimensions and metadata
update without resetting the current zoom or linked width/height extents.

Linked comparison panes receive the same Previous/Next and Play/Stop commands;
individual timers use each image's delay. Turning linking off permits independent
navigation and playback. Entering overlay stops both timers, as in the source.
Conflict selection panes remain independent. Selecting a conflict side still
copies the complete original image file, including every frame/page, rather
than re-encoding the visible frame.

The first playback tick uses the source Windows minimum timer interval of
10 ms. Later ticks advance with wrapping and use the newly displayed frame's
delay, with the source minimum of 100 ms. GIF/APNG delay metadata is read when
available; other multi-image formats use the timer minimum. Play/Stop state
reflects the visible controls in both linked panes. Owned tasks hold weak model
references between ticks, carry generation fences, and cancel on Stop, overlay,
source replacement, scene removal or production-window close. Undecodable
frames display an error and stop that pane's playback.

## Verification and remaining work

The focused Core run passed 42 tests, including frame decoding/index bounds,
GIF delay flooring, TIFF/ICO variants, zoom/extent retention and existing image,
file-comparison and image/text-conflict regressions. The Debug build and bundle
audit passed with all 116 original icons. Native comparison controls and rendered
frame pixels passed with system and bundled Git. Existing native image conflict
selection/confirmation also passed with both engines after the receiver waited
for the actual native Select button to become enabled following published
operation completion; immediate clicks before SwiftUI applied that state had
caused a test timeout. Production target/action and guards remain exercised.

The extended receiver also passed a real Git multi-frame conflict with both
engines: Mine navigation/playback left Base/Theirs unchanged, Select at a later
visible frame copied the complete original three-frame GIF, No preserved the
unmerged index, and closing the conflict window cancelled its owned player.
Both final unsigned Debug and AppStore builds and bundle audits passed with
116 original icons; AppStore includes the required bundled runtime. These
checks do not prove signing, sandbox runtime acceptance or App Review eligibility.
See the [QA record](qa/image-frames-2026-10-10.json). Exact GDI/ImageIO disposal, frame-index/provider,
color-profile and DPI behavior across all image formats remains incomplete.
Physical player/keyboard gestures, screen-reader announcements, retained preferences and signed distribution
acceptance remain open. This is part of the continuing full application port.

Shared transparency backgrounds and per-window Dark Mode are now implemented;
see [color parity](IMAGE-COLORS-PARITY.md).

Native standalone image loading is now implemented; see
[Open parity](IMAGE-OPEN-PARITY.md).
