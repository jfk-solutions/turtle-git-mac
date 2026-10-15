# Finder selection context and ownership

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseShell/ContextMenu.cpp::Initialize` and its `statfetched` handling.

Finder uses one normalized, ordered selection for command eligibility and the
immutable request dispatched to the app. Duplicate paths count once. The first
effective item supplies status and repository facts; subsequent items contribute
selection count and patch-file presence. This prevents a later conflict or added
file from supplying unrelated flags to the first item's menu.

This is an explicit native adaptation: upstream can skip an unknown leading
item before fetching a later item's status, and its folder handling has separate
branches. TurtleGit consistently uses the first effective item. Cross-repository
Git commands are disabled with an explanation; two-file Diff remains available
across repositories, provided both items are files. Application utilities and
standalone mail/patch review retain their independent eligibility.

The nearest cached repository owns each path. A containing parent never absorbs
a nested checkout merely because the entire selection is beneath its directory.
Registered submodule roots remain parent-repository entries for Rename/Delete;
files inside them belong to the submodule. LFS metadata and other repository
facts require one common owner.

Explicit cached entries override ignored ancestors, preserving tracked files
inside ignored folders. Ignore inheritance stops at the nearest checkout root.
Modern aggregated directory badges are not ignore rules; only explicit entries
propagate. Legacy snapshots without explicit entries retain their state fallback.
Creation commands, ordinary menus and transfer destinations share the same lookup.
Revert permits a mixed selection containing changes; its dialog reviews the
selection and initially checks eligible changes rather than requiring every item
to be changed.

Finder performs no live Git commands while building the menu. The containing app
must still renew access and revalidate before mutation. Root and submenu automatic
enabling are disabled so AppKit does not revive a deliberately disabled command.

The focused receiver is `scripts/test-finder-selection-context.py`. It compiles
the actual extension menu source, exercises target dispatch and menu updates, and
uses private files without activating a Finder controller. Physical Finder
selection ordering, installed extension activation, signed sandbox permissions,
case aliases and full upstream menu parity remain separate acceptance work.

Validation: 44 selected Core cases, Debug build and both actual-menu receivers
passed after the recorded compile/fixture repairs. See the [verification record](qa/finder-selection-context-2026-10-15.json). No full hosted CI pass is claimed.
