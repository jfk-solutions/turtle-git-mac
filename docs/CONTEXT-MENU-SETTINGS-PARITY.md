# Context Menu settings — implementation in progress

Source: SetLookAndFeelPage.cpp (CSetLookAndFeelPage/CSetExtMenu), its two
resource dialogs, ShellCache.h defaults, ShellCache.cpp context-path filters,
Globals.h menu IDs and MenuInfo.cpp at
7338078f8ddd924b8cddee35f512f2286072136d.

General now has native Context Menu and Context Menu 2 pages. Both retain source
group order, explanatory text, a scrolling checkbox/icon list, three-state
Select/deselect all and Restore Default. Context Menu includes Hide menus for
unversioned paths and the exclusion editor. Finder Sync has no Explorer drag-menu
surface; that control is disabled with a native explanation. All 55 source list
entries retain labels, original icons and 64-bit IDs. Unimplemented Finder routes
remain disabled; this is not complete context-menu or dialog certification.
The source catalog and default masks are recorded in
`upstream-context-menu-settings.json`.

The two pages share one retained draft and one property-sheet Apply/Cancel
participant. Restore Default resets only the current page's command mask, as in
upstream; it leaves the other page, exclusions and Hide preference unchanged.
An individual edit and Select/deselect all preserve mask bits outside the source
catalog. Apply publishes the shared App Group JSON atomically, saves local
preferences and posts the existing status notification. An unsigned build saves
local preferences and reports unavailable signed group access. Publication
failure retains the modified draft. Advanced owns ShowContextMenuIcons: Apply
reads its current value instead of publishing the value from an older page draft.
Advanced publication also retains saved context-menu policy. Old icon-only JSON
receives the source placement and Shift-only defaults without losing its choice.

Finder's actual menu builder applies exclusions before classifying the selection
or creating command metadata. Excluded items are removed from mixed selections;
an entirely excluded selection produces no menu. Shift never bypasses exclusions.
A bare path excludes exactly itself; a terminal slash excludes that directory and
children; a terminal star excludes a spelling prefix, including a similarly
prefixed sibling, matching ShellCache's distinct grammar. ~/ and $HOME replace
Windows environment expansion. Existing volume metadata determines case matching,
with the known root/parent as fallback for a missing leaf. Unknown metadata uses
case-sensitive matching. Relative and NUL rules cannot be saved. Symlink aliases,
nested mounts and multi-level missing-path case identity need native acceptance.

Hide for unversioned paths uses source repository-membership flags, rather than
hiding an untracked file inside a repository. Shift restores outside-repository
menus. Cached inaccessible repository folders preserve their membership exception.
The source default Shift-only mask includes Stash Apply and Submodule Sync
(and the unavailable SVN Ignore route). Shift reveals these commands only when
their existing status/metadata clauses permit them; it does not bypass command
eligibility or enabled-state checks.

The source default first-level mask includes Commit, Clone, Create Repository
and the unavailable Sync route. Checked implemented commands move from the
TurtleGit submenu to Finder's main context menu, keeping their icon, enabled
state, target, selector and captured paths. First-level labels receive the source
Git prefix. Nested Ignore choices move with their parent; shared Bisect and
Merge/Abort Merge IDs obey a single preference each. Each resulting level retains
source command order and clean separator groups. Empty TurtleGit submenus are
omitted. The Finder toolbar remains flat while applying visibility/path policy.
Menus inside the application continue using their own placement; these source
settings target the shell integration.

Grouped validation: the final incremental Debug arm64 native build exited 0;
23 focused Core tests passed, zero failures, in 0.484 seconds. The actual Finder
menu-builder receiver and actual Settings model/transaction receiver both exited
0. All 55 source row images decode to AppKit pixels. A Windows RC/tracked filename
case mismatch for Tag.ico was fixed during this pass. Empty-menu test assumptions
were updated to source omission behavior, and intrinsic checkbox sizing was
corrected after visual inspection. Both pages were rendered offscreen in light
and dark, all four previews inspected, and the receiver processes exited. No
installed app or Finder extension was launched; no full suite was rerun.
See `qa/context-menu-settings-batch-2026-10-12.json`. Offscreen page
previews exercise the real SwiftUI views but do not establish physical keyboard,
mouse, Settings-navigation geometry, installed Finder Shift gestures, signed
App Group propagation or sandbox acceptance. The 16 unavailable Finder routes,
full context-menu command parity and the complete application port remain open.
