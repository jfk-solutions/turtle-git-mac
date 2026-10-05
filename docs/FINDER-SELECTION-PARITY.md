# Finder menu selection dispatch

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This ports retained menu selection for existing commands; full shell menu
classification, native activation and signed handoff remain pending.

`ContextMenu.cpp` (`0b31f963e73ff71cd9cdb0861972a671236ae20f`) invokes commands
with retained paths/folder. Commit, Revert and Ignore use those path lists rather
than a new live Explorer selection. DiffLater reads Control at invocation to
clear the comparison mark, while retaining the command's selected paths.

Every custom actionable Finder item now holds a `FinderMenuCommand` with an
immutable `FinderRequest`: creation, ordinary repository commands, nested Ignore
name/extension and marked comparison. Activation resolves that packet directly;
it does not ask the Finder controller for a new selection or target.
Menu items use the same paths for availability and dispatch. Container menus
retain the targeted folder even when child files are selected. Item menus retain
the selected files; targetless toolbar Clone/Create packets retain no paths and
continue to use the native default/picker workflow.

Control still changes only DiffLater into Clear comparison mark at activation.
The core request codec preserves selection order, deduplicates literal paths and
encodes Unicode, newline and URL punctuation without delimiter guessing. No
bookmark/security scope is captured: the containing app must still renew access,
revalidate paths and check Git state before a mutation. A stale menu is not proof
that its files or repository still exist.

The actual extension source's standalone Swift 6/macOS 13 receiver checks:

- Ordinary multi-file packets retain their paths after the test selection changes.
- Container packets retain the folder rather than its selected child.
- Nested Ignore packets retain the selected file and their distinct action.
- Comparison packets retain the file; Control clears only its mark command.
- A literal Unicode/newline/ampersand/question-mark filename and duplicate paths
  round-trip through the actual packet and core codec in order.
- Icon-on/off menu signatures now include the complete request URL, so those
  checks compare command and path routing as well as titles and enabled states.
- Existing folder/toolbar creation, six-case icon and cache checks still pass.

No Finder controller/extension/window is instantiated, no menu gesture is driven,
and no URL is opened. Actual NSWorkspace activation, native dialogs, signed scope
renewal, stale-file recovery and live Finder selection acceptance remain pending.
Core code is unchanged in this follow-up; the prior 12-test request/creation/settings
run passed before this change. Debug and unsigned AppStore builds, bundle audits
and site generation are in [the verification record](qa/finder-selection-2026-10-06.json).
