# Blame toolbar customization

The pinned TortoiseGit source (`7338078f8ddd924b8cddee35f512f2286072136d`)
creates a customizable Blame toolbar and enables user-defined toolbars in
`src/TortoiseGitBlame/MainFrm.cpp:94–110,277–299`. The normal and 256-color
resources in `src/Resources/TortoiseGitBlameENG.rc:100–122` give its initial
order: Open, separator, Previous, Next, separator, Copy, separator, About.
The Customize dialog scans the main menus rather than just these five buttons.

TurtleGit adapts this to an AppKit toolbar with the same initial actions and
source icons, using the TurtleGit icon for About. The native customization
palette supports command composition, spacing, display mode and overflow.
**View → Toolbars and Panes → Customize Toolbar…** opens that palette;
**Manage Toolbars…** opens toolbar management.
The standard toolbar can be hidden and restored from the menu bar.

Toolbar management adds, renames, deletes and reorders named custom bars. More
than one custom bar can be visible above the document. Each has its own ordered
command list, icon/text display mode and overflow. The standard bar can also be
edited there. **Reset All Toolbars** restores the source default and removes
custom bars. The later [placement family](BLAME-TOOLBAR-PLACEMENT-PARITY.md)
adds four dock edges, floating panels, drag handles and quick command relocation.
It supersedes the first checkpoint’s fixed-top limitation; exact Windows
customization gestures are not certified.

The available commands include the existing Blame navigation, Find, settings,
panes, annotation fields, history, appearance, detection and encoding actions.
Unavailable commands retain their existing gates. Recent file contents remain
dynamic in the File menu; filenames are not saved as executable toolbar entries.
The source disables Help Topics, so it is not presented as a working palette
command. Output-pane context commands are separate from the scanned main menu.

Layouts use stable command IDs and the originating viewer's preference store.
A new viewer restores saved composition, visibility and display modes. Other
open viewers adopt saved changes when neither their toolbar editor nor native
customization palette is active; command targets remain local to each window. Unknown or duplicate commands,
stale bar IDs, invalid names and oversized preferences are sanitized. Repeated
spacers and intentionally empty compositions remain valid. Existing toolbar
visibility preferences migrate when no new configuration has been saved.

Each document owns its native toolbar, custom strips, command targets and
customization panel. Opening a replacement document or closing its viewer retires
the old chrome. Overflow actions must still belong to a visible bar and the
current owner. Busy reads, blocking sheets and retired documents reject ordinary
commands. Copy follows the owning native responder; Find retains its existing
owned panel. About opens the Blame About variant without opening a workspace.

The ordinary macOS File, Edit and View commands remain available with the toolbar
hidden. Toolbar customization does not replace menu or keyboard access.

## Validation and remaining acceptance

The grouped checkpoint is recorded in
[the dated QA record](qa/blame-toolbar-customization-2026-10-26.json).
Implementation checks are scoped to this family. Physical palette dragging,
keyboard and VoiceOver behavior, small-screen overflow, multiple displays,
signed execution, complete Blame parity and full hosted integration remain
separate acceptance work. The installed build12 predates this source batch.
