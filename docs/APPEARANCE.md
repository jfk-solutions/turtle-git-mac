# Appearance and color parity

TurtleGit offers Follow System, Light and Dark in Settings and the Appearance menu.
The choice is saved for the app and applied to AppKit and SwiftUI windows through
`NSApp.appearance`. Follow System removes the app override. Finder's appearance is
controlled by macOS; the app's preference does not change Finder or system settings.

Use the [official dialog screenshots](https://tortoisegit.org/docs/) alongside the
pinned source/resource layouts when reviewing every replacement. Native controls
should retain upstream's semantic colors, recognizable artwork, list density and
layout. A single accent color is not a substitute for those distinctions.

The initial file-status palette follows the [upstream status roles](https://tortoisegit.org/docs/tortoisegit/tgit-dug-wcstatus.html):
modified blue, added purple, deleted dark red (brighter red in dark mode), conflicts
red, unchanged/unversioned normal label text, and ignored secondary text. Commit
paths, Working Tree paths/status and workspace status labels use these roles. Icons and status words remain
visible, so color is not the only signal. Remote-status-specific colors remain
pending along with remote checks. Graph lanes and branch/tag labels already use
multiple colors; the patch view distinguishes additions, removals and hunk headers.

The Rebase port adds five byte-exact original assets for Pick, Skip, Edit, Squash
and branch/upstream reversal, with provenance hashes. The icon suite renders all
all recorded resources through AppKit. Rename adds the original menurename artwork. The upstream license notice remains in the bundle.

Actual light/dark Commit and Rebase captures use disposable repositories. Initial
light/dark rendering and live Settings switching Light → Dark → Light → Follow
System were verified. Comprehensive switching across every open window, selected-row
contrast, accessibility contrast settings, Finder appearance and every other
window's visual comparison remain in the UI parity audit. User-selectable status
palettes and upstream Colors settings are not implemented yet.
