# Patch and comparison appearance ownership

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.

## Source behavior and macOS adaptation

TortoiseUDiff `MainWindow.cpp` `SetTheme`/`SetSciStyles` reapplies editor,
caret, selection and diff styles together with the configured UDiff font.
`UDiffColors.h` retains separate light and dark palettes: the normal dark
background is `#202020`, added dark is `#104010` and removed dark is `#402020`.
TortoiseMerge `BaseView.cpp` selects state colors from `DiffColors`, including
the source's high-contrast-dark path. These are independent semantic colors.

The embedded Commit patch inherits its containing window's current appearance.
Standalone Unified Diff follows the application appearance until its own Dark
Mode command explicitly chooses a window override. General's Follow System,
Light and Dark choices therefore reach windows that have no local override.
Native selection uses AppKit semantic selection colors. Unified Diff's existing
Increase Contrast adaptation uses semantic foreground/background colors; it is
not a claim of identical Windows high-contrast policy.

The text view, its scroll view and clip view share the same canvas color,
including an empty patch and the area beyond the last line. Palette/font changes
restyle the displayed text without replacing its content, clearing Undo or
resetting selection, Find or scroll position. Source addition/removal/hunk roles
and configured font/tab width remain independent of appearance choice.

## Comparison palette ownership

Each comparison or merge model owns an immutable palette loaded from its own
preferences. Settings Apply tells open models to read their own store. A private
settings window cannot install its palette into another window's renderer.
The shared standard-domain facade remains available to consumers without a
window owner.

The owned palette reaches normal and combined comparison rows, editable merge
results, whitespace and ending marks, inline changes, locator bars, line counts
and the line-difference preview. Text, scroll and clip surfaces use Normal's
background. Live appearance changes invalidate display without replacing the
document. Long documents use the existing TextKit layout path; there is no
separate virtualized comparison renderer to claim as an independently tested UI.

## Verification boundary

The [grouped checkpoint](qa/editor-appearance-2026-10-25.json) records a repaired
Debug build and all three native families passing with both system and bundled
Git. Actual embedded and standalone patch views, comparison panes and editable
merge results retain content, selection, Undo, Find and scroll across appearance
changes. Real Stage/Unstage and Settings Apply are exercised with independent
repository witnesses and private preference suites. All six receivers were
reaped and independently absent. Core code was unchanged and was not retested.

The first build caught a redundant invalid window reference; its affected rebuild
passed. The native fixture initially attempted to write SwiftUI's read-only
contrast environment. That unsupported injection was removed without changing
production or executable workflow assertions; Increase Contrast remains open.
Offscreen public view bitmaps show editor canvases but omit some compositor,
material and button content. They are diagnostic captures, not complete dialog
screenshots. The earlier signed Finder acceptance exposed the white embedded
patch; its installed application predates this repair.

Physical Increase Contrast, VoiceOver, every source state, minimum supported
macOS, Intel hardware and signed App Store acceptance remain open. This bounded
family does not certify visual parity of every upstream dialog.
