# Native Blame menu context and panes

The pinned File/Edit/View resource and `MainFrm.cpp` provide shared menu commands,
output/Properties panes, toolbar/status visibility and source option check states.
TurtleGit's macOS menu bar now supplies active Blame Find/Next/Previous/Go To,
encoding, recent files, pane visibility, annotation fields, detection, history and
presentation options. The existing Open command follows focused document ownership.

`BlameMenuContext` resolves the active window at invocation and follows owned Find
panels/sheets. It observes the active model and document replacement, so a background
or retired viewer cannot receive another editor's command. Busy reads and information
sheets gate commands. Detection mode gates complete-log/follow-renames options;
selected revisions gate Next/Previous Change. Standard native Copy remains responder
based. Command-G follows macOS Find Next; Go To uses Command-L.

In the annotation gutter or source text, **Shift-F10** opens the context menu for
the selected line. The accessibility Show Menu action uses that same route.
**Blame previous revision** and **Compare with previous revision** retain the
line's parent and historical filename, including renames. **Show log**, hash/log
copying and source-line copying retain the line on which the menu opened. **Copy**
retains the selected source text, even if the selection later changes.

Annotation and embedded Log menu items dispatch once. Reloading, replacing or
closing the document invalidates their old targets. Source menu icons honor the
owning viewer's context-icon setting. Unified diff and native source-editing
commands remain available alongside the source revision commands.

Toolbar, Log, Properties and status/footer visibility persist in the supplied Blame
defaults. The source remains usable when panes are hidden, and menu-bar controls can
restore a hidden toolbar. Color Age also persists. Source options now consistently
use the supplied store, rather than writing global defaults from private viewers.

Dark Mode installs a Blame-window appearance override, also applied to Find and
native picker/information panels. Follow System Appearance removes the override.
New viewers inherit persisted layout/appearance defaults; existing independent
viewers retain their current layout until changed. Native split panes, utility
panels and tab containers adapt Windows docking. Pane captions and View →
Toolbars and Panes provide all dock edges, Float, Auto Hide, Tab with the other
pane, and Restore Default Pane Layout. Tab selection and floating frames persist.

Drag a caption to a workspace edge to dock, or release it outside the workspace
to float there. Floating titlebars include an original-icon drag handle for
docking back. Double-click a caption to Float/Dock; its accessibility press action
also toggles placement. Escape cancels a caption drag. Group auto-hide applies to
both panes; pinning either restores their tabs. Moving one pane to another edge
or floating it separates the group. Hiding a member preserves the association.

Physical pointer/Escape/multi-screen, full menu/accelerator and VoiceOver
acceptance remain open. These native interactions do not certify every MFC
smart-docking or toolbar/menu-bar gesture.

The native fixture exercises current/Find/unrelated/second/retired window routing,
visible state, busy/detection gates, hide/restore source selection, window/panel
appearance and reset, reopened layout, private preferences and exact repository
state preservation. These are object-linked native checks, not complete displayed
menu-bar or signed App Store acceptance.

The Debug build and ten grouped native menu/File Open/Find/source/wrap cases
passed with both Git engines. The initial detection fixture used within-file mode
for a between-file-only restriction; the corrected fixture retains the source gates.
Retirement explicitly clears callbacks that could retain a view or target old UI.
Core/AppStore checks were not repeated for this native-only batch.

A separate private preview app also verified the actual SwiftUI menu bar: View and
Edit commands were present, menu-bar toolbar hide/restore worked, Find accepted
keyboard input, Command-G reported wrap and Command-L opened Go To Line from the
Find panel. Its unique preferences/repository were isolated and PID was verified
absent after normal Quit. This preview used `--resource-runtimes`; its runtime
layout differs from production and cannot establish production signing acceptance.

The preview investigation exposed a required distribution fix: mixed runtime data
and reconstruction kits currently live under `Contents/Helpers`. Apple expects code
in that location; data/scripts need appropriate resource placement, and dotted Perl
library directories were rejected as bundles. See
[Apple's signing guidance](https://developer.apple.com/library/archive/technotes/tn2206/).
The initial preview-only resource relocation preserved helper lookups with relative
aliases and passed ad-hoc verification. Production runtime placement and auxiliary
library signing were subsequently implemented and checked; see
[DISTRIBUTION.md](DISTRIBUTION.md). Actual signed distribution remains open. [Evidence](qa/blame-menus-2026-10-13.json) records both successes and this gap.

## Source Encode catalog

Both the macOS menu bar and the Blame window's Edit menu share the pinned Encode
catalog: UTF-8/UTF-16 LE/UTF-16 BE, then all sixteen language groups in resource
order, with all 48 legacy entries and original captions. Selection is checked by
code page rather than localized codec name. Automatic and Additional macOS
Encodings follow the source choices, retaining native detection and platform
codecs without changing the source categories.

Foundation supplies 49 of the 51 source codecs. OEM 720 and OEM 858 now use embedded
single-byte mappings, including Arabic and the Euro replacement in OEM 858.
Historical annotation, whole-file decoding and the native editor's trailing line
handling use the same decoder. NUL/binary guards remain enforced. These choices
require no process execution or additional sandbox entitlement.

Focused Core coverage resolves every source choice and preserves additional codec
access, checks Arabic/Euro mappings and binary rejection, and annotates historical
OEM files while preserving HEAD, index and the working copy. The native menu
receiver covers encoding selection, reset, busy and retired-window gates alongside
the existing ownership/presentation checks. Full physical category-menu clicks,
VoiceOver, all non-ASCII platform-codec behavior and signed execution remain open.

The Debug build, 22 unique focused Core tests (initial UTF-16 mapping failure
fixed and the three affected tests rerun), four grouped native receivers across
system/bundled Git, and two site documentation checks passed within those scopes.
All four owned native receivers were reaped. [Evidence](qa/blame-encoding-2026-10-13.json).

[Pane grouping and drag evidence](qa/blame-pane-tabs-2026-10-15.json) records
the native interaction scope and remaining physical/signed checks.

## Search, line navigation and pane focus

Use **F3 / Shift-F3** or **Command-G / Shift-Command-G** to repeat the last
applied search forward/backward. **Command-F** (also source **Control-F**) opens
the modeless Find panel, prefilling the selected source text. Opening Find again
reuses the panel and its draft.

**Command-L** or source **Control-G** opens **Go To Line**. Enter a decimal from
0 through 40,000,000. Zero closes without moving; a line beyond the file ends at
its last line. Invalid input stays in the sheet. **Cancel** preserves selection;
**OK** returns focus to the source. Other viewer commands and modeless Find
searches wait until this sheet closes. Closing its viewer also closes the sheet.

**F6 / Shift-F6**, also **Edit → Next/Previous Pane**, move between source text
and the revision Log. A floating Log keeps its own native window; a tabbed Log
becomes selected. Hidden/auto-hidden Log panes stay hidden. Native field editors
retain their Escape behavior; Escape in the viewer closes its active window
through the normal operation/child-window guards.

These are native adaptations of the source keyboard commands. Full physical
keyboard, accessibility and signed acceptance remain in progress.


## Author image and revision property values

The embedded Log reserves an 80-point author image area when the shared
**Enable Gravatar** preference is enabled. The viewer uses its originating
preferences for the URL/hash options. Newly selected rows update the image even
with multiple revisions selected; Properties shows a single revision only.
Disabling the feature or closing/replacing the viewer cancels its request.

Properties has collapsible **Basic information** and **Parents** groups. Select a
field to read its full value in the resizable description area. **Copy** or
Command-C copies the complete value, including multiline Body text. Shift-F10 or
the accessibility Show Menu action opens the selected property's menu. Parent
values are their subjects; the description also shows the full hash and parent
number. Group headings offer no Copy action. See the
[author/details source comparison](BLAME-AUTHOR-DETAILS-PARITY.md) for scope and
remaining acceptance. Earlier pane screenshots predate this grid.


## Properties keyboard, divider and focused Copy

Focus the Properties grid and use Left to select a value's group, then Left
again to collapse it. Right expands a group or selects its first value. Space
and Return toggle a selected group; Home/End select the first/last visible row.
The description remains read-only. Drag the divider between property names and
values to resize the name column. Its width persists across floating, docking
and reopening in the viewer's preferences.

Command-C and Edit → Copy follow the focused native control. Source copies its
selected text, Log copies complete revision details including changed paths,
and Properties copies the selected nonempty value. A property's context-menu
Copy also supports an empty value. Group headings have no Copy command. Parent
labels use eight hash characters; their descriptions retain full hashes. The
Log SHA-1 cells contain full hashes, clipped by the column width. Changing focus
while Log details are being read prevents a late clipboard replacement.


## Customize toolbars

The standard Blame toolbar starts with **Open**, **Previous Change**,
**Next Change**, **Copy** and **About TurtleGitBlame**. Use the native toolbar
customization palette to rearrange its commands and spacing or change icon/text
display. View's toolbar controls remain available when the toolbar is hidden.

Toolbar management lets you create several named command bars, choose their
commands and order, rename or delete them, and show or hide each independently.
Commands that do not fit move into that bar's overflow menu. **Reset All
Toolbars** restores the standard commands and removes custom bars. Layouts are
saved for later viewers. Other open viewers adopt saved changes while their
toolbar editor and native customization palette are closed.
See [the source comparison](BLAME-TOOLBAR-PARITY.md) for scope and remaining
physical acceptance.


## Dock or float toolbars

Drag a toolbar's dotted handle toward the top, bottom, left or right edge of the
Blame window to dock it there. Release away from an edge to float it. The
placement preview is temporary; **Escape** cancels without saving a new layout.
Double-click the handle to float a docked bar or return a floating bar to its
previous dock position.

The handle's context menu offers placement choices, **Customize Toolbar…**,
**Manage Toolbars…**, **Reset All Toolbars** and **Hide Toolbar**. The handle's
accessibility action opens the same menu. Toolbar management also offers
placement choices. Closing a floating bar hides it; show it again through the
View menu. The standard toolbar and named bars retain their positions and
floating frames for later viewers.

Hold **Option** while dragging a command to reorder it or move it to another
visible toolbar belonging to the same document. Escape or an invalid/outside
drop preserves the original composition. Use toolbar management to remove a
command. Transfers into another document's toolbar are rejected.

Floating bars retain their document's menu, Copy and Find targets. Closing or
replacing the Blame document also retires its floating toolbars. See
[the placement comparison](BLAME-TOOLBAR-PLACEMENT-PARITY.md) for the exact source
scope and acceptance limits.
