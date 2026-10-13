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

Toolbar, Log, Properties and status/footer visibility persist in the supplied Blame
defaults. The source remains usable when panes are hidden, and menu-bar controls can
restore a hidden toolbar. Color Age also persists. Source options now consistently
use the supplied store, rather than writing global defaults from private viewers.

Dark Mode installs a Blame-window appearance override, also applied to Find and
native picker/information panels. Follow System Appearance removes the override.
New viewers inherit persisted layout/appearance defaults; existing independent
viewers retain their current layout until changed. Native split panes replace
Windows docking. Floating/docking layout persistence, full encoding-category/menu
order, physical menu click/accelerator and VoiceOver acceptance remain open.

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
The preview-only resource relocation preserves helper lookups with relative aliases,
uses explicit inside-out signing and passes ad-hoc verification. Production layout,
load paths and actual signed distribution still require their own implementation
batch. [Evidence](qa/blame-menus-2026-10-13.json) records both successes and this gap.
