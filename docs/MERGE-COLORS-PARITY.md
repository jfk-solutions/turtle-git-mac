# Merge Colors page

Source baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
`SetColorPage.cpp::SetupColorButtons`, `SaveData`, `OnBnClickedRestore` and
`IDD_SETCOLORPAGE` in `TortoiseMergeENG.rc`.

The native page retains the source Line differences, Inline differences and
Misc groups, Foreground/Background columns, eight line roles, two inline roles,
and the whitespace foreground. It has exactly 17 swatches: Modified/Filtered
and inline roles have no foreground control; Whitespace has no background.

Each swatch is a native AppKit color well with a dropdown containing
**Automatic** and **More colors…**, using the source labels. Automatic shows the
role/channel's default color and restores only that channel in the selected
palette. The checkmark follows whether the selected RGB equals that default.
More colors activates the shared native color panel; alpha is disabled and
chosen colors are converted to sRGB bytes, matching the source RGB-only values.

Light/Dark choose the palette being edited, initially following the current
application appearance. Both drafts are retained when switching palettes.
Restore Default affects only the selected palette. Apply saves both palettes,
refreshes open merge panes/locator/whitespace colors and clears the modified
state; Cancel discards both drafts. Neither palette switching nor individual
color edits persist before Apply. The page participates in the shared Settings
transaction, with errors reported if applying fails.

Color wells release their owned panel on page detachment, removal or owner
window close. Closing an inactive picker does not hide/deactivate another
picker's panel. The previous shared-panel alpha setting is restored on
release. Removed controls reject late menu actions. Native wells and menus have
role/channel accessibility labels, including distinct inline-role labels.

The source's global Use dark mode checkbox is adapted to independent palette
editing; app appearance remains controlled by General on macOS. Whitespace
colors remain independently editable in both palettes. Source theme switching,
physical dropdown/color-panel/VoiceOver acceptance, exact row spacing and
whole-window light/dark screenshot acceptance remain open. The upstream
filtered Automatic setup appears to target the Empty button; the Mac control
uses the intended filtered role default instead.

## Renderer coverage retained from the previous batch

Source orange/yellow/red/green/purple/gray defaults and dark variants remain
unchanged, including Normal dark #202020/#DDDDDD. Missing or invalid persisted
colors fall back to source defaults. Renderers use an immutable palette snapshot;
per-row drawing does not decode preferences. The later
[appearance ownership batch](PATCH-COMPARISON-APPEARANCE-PARITY.md) gives each
comparison model its own preferences-backed snapshot rather than replacing one
process-wide private palette. Apply notifies open panes to read their own store
and does not change file contents or source encodings.

Both viewers consume supported-state foreground/background colors. Normal
colors cover canvas/caret, locator stripes use state backgrounds, inline changes
and missing-character marks use their configured roles, and whitespace paths
use Whitespaces. The dark ending-icon cache invalidates when colors change;
original icon bytes remain unchanged. Modified colors provide the common inline
background. Conflict resolved is stored, but fuller resolved/edited three-pane
presentation and all source state aliases remain incomplete.

The earlier renderer batch recorded 21 Core checks, an unsigned build and
focused native supported-state/whitespace color checks. Its initial calibrated
RGB mismatch was repaired with explicit sRGB construction; the full receiver
was not repeated in that earlier batch. See
[the original renderer record](qa/merge-colors-2026-10-12.json).
The new controls batch has a separate record; it does not replace that evidence.
High contrast/large-file, all editor state aliases, signed/minimum-OS and complete
application parity still require acceptance.


## Current controls evidence

The unsigned Debug build passed after correcting the imported color-well
activation signature. One receiver compilation linked the built app objects;
all twelve Merge families passed in one process, including the native Colors
controls and panel lifecycle. No new Core tests were added or rerun for these
native-only changes. See [the controls record](qa/merge-colors-controls-2026-10-12.json).
All test-owned windows/panels/helpers closed. Full hosted CI and physical
whole-page/source appearance acceptance remain unproven.

Resolved and manual edited result channels are now connected to editing, history,
save/reload, Find and locator presentation in
[Result states parity](MERGE-RESULT-STATES-PARITY.md). Remaining source aliases and
physical/signed acceptance are still open.


Side-specific, identical-change and conflict source/gap aliases now share the
source palette channels and Colors Apply behavior. Pane statistics use these
state categories as well. See [source states and counts](MERGE-RESULT-STATES-PARITY.md).
Whitespace-only/ignored/resolved-empty production and physical whole-window
acceptance remain open; the new aliases do not certify the full state catalogue.

The native swatch and palette controls are now shared with the source status/log,
Blame and Unified Diff color pages. They also honor disabled state, fence detached
or retired callbacks and release an owned panel on disable/owner changes. Existing
Merge identifiers/defaults/channel counts remain stable; the retained native
Merge Colors workflow is part of the connected color-settings validation.

The shared source color-button family passed native Settings draft/panel checks; see [dated evidence](qa/settings-color-choices-2026-10-16.json) for fixture repairs, exact scope and remaining navigation/physical acceptance.

The [navigation/layout batch evidence](qa/settings-navigation-layout-2026-10-16.json) records the initial-size repair, fixture failures, final four-case pass and visual scope. Older color-gallery frames predate the new navigation layout.


[Line-change margins](MERGE-MARGINS-PARITY.md) now complement the state palette
with the original colored status icons. Palette edits retain the original icon
artwork; they do not recolor or rewrite those assets.

## Source palette contexts and footer — October 17, 2026

The source Line differences / Inline differences / Misc groups and 17 channels
remain. Palette to edit and Restore Default now share the bottom row, preserving
the source placement of dark-mode/reset choices. Independent Light/Dark palette
editing remains the macOS adaptation; General controls the app's appearance.

Swatches, palette choice and Restore capture their model, palette and edit
revision. Palette changes, Apply/Cancel, reset, visibility and owner changes
invalidate earlier edits. A hidden cached page keeps its draft and still accepts
authorized shared Settings Apply, but cannot accept old visible-page controls.
Window closure retires delivery. The page owner probe and native controls share
panel/visibility ownership.

Shared native Automatic/More colors items are now captured single-use invocations.
Reopening the menu creates fresh items. A changed context rejects old menu items
even when its RGB values are identical. Context changes close only the owned
panel; continuous RGB edits within that context retain normal panel ownership.
The native palette control checks enabled/attached/retired state and detaches its
target on removal. Source channel identifiers and serialized color data stay stable.

All 35 static source controls now have explicit partial mappings. The Debug build and all three grouped native families pass on their first attempt: source contexts, retained Merge Colors and the six shared Settings color pages. Both raw light/dark page captures were individually reviewed; all 17 swatches, source columns/groups and palette/reset footer fit. All three owned receivers were reaped and independently absent. Core was unchanged and not repeated. See [batch evidence](qa/merge-colors-source-family-2026-10-17.json) for build diagnostics, capture provenance and acceptance limits. Physical color-panel interaction,
VoiceOver, every renderer/state alias, high contrast and signed App Store acceptance
remain open; this is not full Colors certification.
