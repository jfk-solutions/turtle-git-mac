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
