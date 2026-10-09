# Finder command order and separators

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
Implemented Finder entries now follow upstream command-table order and groups.
This is not complete shell command coverage, eligibility or activated appearance.

`MenuInfo.cpp` (`aee7f91ad1111fe03ab85b390855885ca940a27f`) defines ordered command
and separator rows. The [independent pinned fixture](upstream-shell-menu-order.json)
retains every command group through Settings/Help/About, omitting commented-out
entries and the resource-only submenu definitions. The native layout projects
that table onto the 39 implemented root entries, including the two Ignore parents.

Visible order follows Clone/Pull/Fetch/Push, Commit, Diff/comparison mark,
history/Repository Browser/Working Tree/Rebase/stash, Bisect,
Resolve/Rename/Delete/Revert/Clean up,
Switch/Merge/Branch/Tag, Create repository/Ignore, Worktrees/Submodule Update, then
Format Patch. Omitted command groups remain in the fixture for subsequent ports.
The current layout does not add missing commands or change eligibility of the
remaining entries in that order-only follow-up. Repository-wide availability
now also consumes [cached metadata](FINDER-REPOSITORY-METADATA-PARITY.md).

`ContextMenu.cpp` defers separators until a subsequent visible entry. The native
arranger likewise removes preexisting separators and emits one between surviving
groups, with no leading, trailing or doubled separators. An outside folder gets
Clone and Create repository in separate source groups; a lone outside-file
comparison mark has no leading separator. Toolbar commands remain direct entries.
Original icons, enabled states, command packets and nested Ignore menus survive
reordering. Ignore parents carry a separate group key; their child commands retain
actual selection requests.

The source shell exposes Worktrees; New Worktree is reached through the manager's
Add button. The extra default Finder New Worktree item is removed. The app's Git
menu, create dialog, manager Add route and explicit URL action remain available.
This corrects the earlier provisional root entry without removing the workflow.

The actual extension source's Swift 6/macOS 13 standalone receiver compares all
31 root mappings against the pinned fixture's complete independent source groups.
It then checks source projections for six selection cases, nested Ignore position,
sparse toolbar/outside-file separators, absence of a direct New Worktree root item,
icons, enabled states and full command URLs. Existing selection, Control,
creation and cache checks also pass. The receiver displays no windows/popups and
constructs no Finder controller or extension.

Debug and unsigned AppStore builds, bundle audits and site generation are recorded
in [the verification record](qa/finder-menu-layout-2026-10-06.json). Core code is
unchanged, so no new core-suite run is claimed. Actual activated context/toolbar
appearance, manager Add gesture, full shell conditions, root placement/customization,
omitted commands, signed integration and remote verification remain pending.

## Abort Merge command

Abort Merge is now included immediately after Resolve in the source's recovery
group. Its active-merge conditions come from the pinned `MenuInfo.cpp`; conflict
resolution alone does not remove it. The actual builder now projects all 40
implemented command mappings onto the complete pinned groups. It also checks
original Abort artwork, icons on/off, captured paths/URL, real conflicted repository
metadata serialized through the cache, nonmutation during menu construction, and
removal after abort/refresh. See [the QA record](qa/merge-abort-menu-2026-10-08.json).
This remains headless builder evidence; activated Finder and signed handoff remain
pending.


Browse References is now included after Reflog with upstream Repo-browser artwork,
original folder-in-Git/one-selection and bare clauses, request URL and application
standalone-browser route. The actual builder/order/routing receiver and Core
condition/request/metadata tests cover this projection. Signed Finder activation
and complete menu coverage remain pending. See [reference browser](REFERENCE-BROWSER-PARITY.md).
