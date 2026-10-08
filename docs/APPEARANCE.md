# Appearance and color parity

TurtleGit offers Follow System, Light and Dark in Settings and the Appearance menu.
The choice is saved for the app and applied to AppKit and SwiftUI windows through
`NSApp.appearance`. Follow System removes the app override. Finder's appearance is
controlled by macOS; the app's preference does not change Finder or system settings.

Use the [official dialog screenshots](https://tortoisegit.org/docs/) alongside the
pinned source/resource layouts when reviewing every replacement. Native controls
should retain upstream's semantic colors, recognizable artwork, list density and
layout. A single accent color is not a substitute for those distinctions.

The file-status defaults now use the pinned CColors RGB values: modified
(0,50,160), added/copy (100,0,100), deleted (100,0,0), conflict (255,0,0),
renamed (0,0,255) and merged (0,100,0). Native dynamic colors follow the source
HSL lightness inversion for dark appearance, including its 5–90 lightness clamp;
high-contrast dark uses the source's unclamped inversion. Neutral normal,
unversioned and ignored records use native label text. The source's explicit
GRAY action is a separate Log-filter condition and is not inferred from ignored
working files. Merged is retained as a palette role; porcelain working statuses
do not provide a separate merged action.

Commit and Working Tree apply the action color to every text column, including
line counts, metadata and the optional owner column. Combined index/worktree
actions use source priority: conflict, modification/type change, added/copy,
deletion, rename, then neutral. A renamed file with further modifications is
therefore modified blue. Selected rows use native semantic primary text across
all columns. Original icons and status words remain visible. Other FileState
consumers share the exact default roles, but their complete action/selection
behavior still needs individual source review. Graph lanes and branch/tag labels
use multiple colors; the patch view distinguishes additions, removals and hunks.
Remote-specific colors and user-configurable CColors settings remain pending.

[Status color QA](qa/status-colors-2026-10-09.json) compares numeric RGB values
and Aqua/Dark Aqua/high-contrast dark AppKit resolutions against independently
compiled pinned C++ conversion functions. It also checks mixed action priority
and the selected semantic color. These checks do not prove current pixels,
selected-row contrast, accessibility or visual parity in every dialog. Existing
screenshots below predate this palette change and have not been refreshed.

The Rebase port adds five byte-exact original assets for Pick, Skip, Edit, Squash
and branch/upstream reversal, with provenance hashes. The icon suite renders all
all recorded resources through AppKit. Rename adds the original menurename artwork. The upstream license notice remains in the bundle.

Actual light/dark Commit and Rebase captures use disposable repositories. Initial
light/dark rendering and live Settings switching Light → Dark → Light → Follow
System were verified. Comprehensive switching across every open window, selected-row
contrast, accessibility contrast settings, Finder appearance and every other
window's visual comparison remain in the UI parity audit. User-selectable status
palettes and upstream Colors settings are not implemented yet.

Original Log and Help icons are monochrome at every embedded size. They now use
native template tinting alongside cherry-pick; the shared SwiftUI command label
respects template images while preserving all colored artwork. The updated native
submodule dark capture verifies readable Log/Help shapes and green Fast Forward
types. The byte-exact source ICO files remain unchanged.
