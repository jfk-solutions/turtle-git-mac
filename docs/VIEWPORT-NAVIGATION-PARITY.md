# Revision Graph and comparison viewport navigation

Source baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This family covers navigation of the existing graph and editor views. It does
not certify the whole application or every physical input device.

## Revision Graph

`RevisionGraphDlgFunc.cpp::DoZoom` rescales both scroll positions by the ratio
between the new and old zoom. The native graph applies that contract to toolbar,
View-menu, percentage-box, fit and modifier-wheel routes. Native scroll bounds
clamp the result after the canvas is resized. This preserves the inspected graph
location where the resulting viewport can contain it; it does not substitute a
pointer-centered zoom policy for the source origin-scaling contract. Invalid
percentages retain the current zoom and viewport.

With the graph canvas focused, arrows move the viewport twenty native points and
Page Up/Down move it by half its height, following
`RevisionGraphDlg.cpp::PreTranslateMessage`. Native field editing and unrelated
modified shortcuts keep their normal AppKit routes. Escape first cancels an
active canvas or overview pan. The graph remains open after this cancellation;
normal close behavior remains available when no gesture is active.

Canvas panning and overview navigation capture the accepted press and its owning
graph/layout state. Orphan drag events and events after reload, zoom, modal
ownership, Quit or closure cannot move the viewport. The overview can still
recenter on an accepted click. Native open/closed hand cursors represent the
source pan cursors; blocked and retired views release their gesture feedback.
The source anchors are `RevisionGraphWnd.cpp::CancelMouseZoom`, mouse handlers
and `OnSetCursor`. No working rectangle-zoom or middle-button feature is inferred
from inactive source remnants.

## Compare and Merge

`TortoiseMerge/MainFrm.cpp::OnViewLineUpDown` and `OnViewLineLeftRight` scroll
all available text views by one displayed line or one character cell. The native
commands apply these operations to the current two-pane, combined or three-pane
presentation without changing source text, caret selection, saved state or Undo
history. Wrapped and folded views use their current displayed geometry. Normal
caret-arrow behavior remains unchanged.

The pinned source has command handlers but no corresponding menu or accelerator
entry in its resource files. Native menu discovery is therefore a macOS
adaptation, rather than a claim of a matching Windows shortcut. Current owned
editor/menu guards reject commands during competing operations, sheets and
retired or replaced documents.

## Verification and remaining work

The [dated grouped checkpoint](qa/viewport-navigation-family-2026-10-23.json)
records the actual app build, native scenarios, failures and focused repairs.
Private repositories, preferences and receiver windows separate these checks
from user-owned sessions. No Core production changes are required for this
native navigation family.

Native points, font-cell and viewport metrics replace Windows device pixels.
Physical keyboard layouts, mouse/trackpad timing, VoiceOver, complete source
layout, installed signed Finder/App Store workflows, minimum-version/Intel and
full hosted integration remain separate acceptance requirements.

## Linked pointer scrolling — October 28, 2026

This connected family covers the native two-pane/combined Compare and
three-pane Merge viewports. Pinned `TortoiseMerge/BaseView.cpp:1049–1110`
broadcasts horizontal scrollbar actions, while `2275–2333` broadcasts wheel
movement. A thumb position and a wheel delta have different contracts: the
former establishes a common text column; the latter advances each pane from its
own offset and clamps at that pane's limit. Native leading ruler/inset offsets
are accounted for independently, rather than treating each clip origin as zero.
`EnsureCaretVisible` also calls
`ScrollAllToChar` at `3725–3727`, so horizontal coupling is not restricted to
mouse-tracking callbacks.

The source exchanges vertical and horizontal wheel directions when Control
**or** Shift is held. Both modifiers together still exchange the axes once.
Horizontal movement is ignored while wrapping; vertical movement remains
available. The native policy retains diagonal components instead of choosing
only the largest delta. Direction is axis-specific: Windows horizontal wheel
messages define positive as right, while native positive horizontal deltas
move the viewport left. For native deltas `(X, Y)`, ordinary origin movement
is `(-X, -Y)`; modified movement is `(-Y, +X)`. A bare swap would reverse the
source's modified horizontal-wheel action. The source handlers and
[Windows horizontal-wheel contract](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousehwheel)
must be considered together, rather than substituting native X for raw Windows
wheel units.

The negative-X/rightward native convention is also visible in a separate
[macOS backend implementation](https://raw.githubusercontent.com/godotengine/godot/master/platform/macos/godot_content_view.mm)
(`scrollWheel`, lines 838–862 at the review date); that code was reviewed as
directional evidence, not copied into the app.

Native precise deltas use points. Coarse deltas use the receiving pane's font
cell and line metrics. AppKit has already applied the user's natural-scroll
direction; it must not be inverted a second time. These units follow the
[NSEvent scrolling delta contract](https://developer.apple.com/documentation/appkit/nsevent/scrollingdeltay)
and the SDK's `NSEvent.h:349–359`, rather than treating Windows wheel units as
Mac pixels. Actual device/driver Shift behavior is a separate physical acceptance
scope, not something established by a synthetic event.

All recipients must belong to the current live editor and presentation.
Hidden, detached, replaced, busy, modal or retired panes cannot initiate or
receive a linked gesture. A relative movement batch suppresses ordinary
position-following callbacks so a peer cannot move twice. Locator, rulers and
line-preview offsets must follow the resulting accepted positions, without
changing document bytes, selected ranges, focus or Undo history.

P4-style source panes contain unaligned text and retain their existing vertical
independence. Horizontal movement links their live visible panes; a vertical
component affects only its receiving pane. This is the native P4-style layout's
policy, not a claim that upstream TortoiseMerge contains that optional layout.

The [pointer-family checkpoint](qa/merge-pointer-scrolling-2026-10-28.json)
records the actual implementation, validation and failures. It must be assessed
separately from the earlier keyboard/menu family above. Full physical mouse,
trackpad/momentum, keyboard-layout, VoiceOver, signed installation and upstream
layout acceptance remain separate requirements.
