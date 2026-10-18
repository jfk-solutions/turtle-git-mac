# Log revision context consumer policies

This connected partial review follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`:

- `GitLogListBase.cpp` constructor, `hideFromContextMenu` and `OnContextMenu`
  (source insertion order, command masks and extended-menu exceptions).
- `TortoiseGitBlame/LogListBlameAction.cpp::hideUnimplementedCommands`
  (exclusive Blame history consumer).
- `TortoiseProc/RebaseDlg.cpp:327` (rebase consumer exclusions).
- `TortoiseProc/LogDlg.cpp` (normal Log and selection consumers retain the
  shared-list constructor policy; selection mode does not invent restrictions).

`HistoryContextCommand` preserves source command identities independently of
translated captions and native selectors. `HistoryContextMenuPolicy.log`
retains the constructor defaults; `.blame` and `.rebase` express the source
consumer sets. Exclusive-show intersects the current set, matching the source;
it cannot silently enable a previously disabled command. These are consumer
capabilities, not user preferences and not persisted global settings.

The native revision menu applies the policy to existing repository, comparison,
reference, working-tree, stash, transport, bisect, patch, notes, clipboard,
Find and rollup commands. Parent comparison/revert/reference items and their
children retain the original captured canonical targets and source icons.
Removing an entire submenu removes its empty parent. Filtering preserves the
existing source insertion order, collapses repeated separators and removes
leading/trailing separators. Masked Combine does not start its asynchronous
ancestry validation. A mask never enables an operation excluded by working-tree,
HEAD, stash, merge, selection, callback or other existing operation guards.

`ID_LOG` follows the explicit source exception: the consumer bit **or** a named
non-stash revision **or** captured Shift permits Show log. Thus a restricted
mask can still show that command on a named revision or with Shift. The three
two-revision range-log entries have no source mask check and remain available
under their existing selection rules. The normal Log and picker policies do not
force Show log for an unnamed revision. A consumer such as Blame can set the bit.

The Compare with previous revision menu item, and the first parent choice for a
merge, receive native bold default-action emphasis when
`DiffByDoubleClickInLog` is enabled. Masked items receive no emphasis. The existing
Return/double-click behavior remains owned by its original implementation.
Reference accessibility captures Shift when preparing its pointed popup; pointer
and keyboard entries retain their existing captured Shift state.

Every native menu receipt also captures its consumer policy. Changing that policy
retires a captured item even if the selection and refs remain unchanged. Existing
one-shot, history generation, projection, selection, canonical-ref, busy, child,
Find and ordering checks remain, with explicit Quit refusal added to the receipt.
The ordinary Show Log window initializer defaults to `.log`; callers may supply
`contextMenuPolicy:` for an actual shared-list consumer.

## Grouped validation and remaining scope

`HistoryContextMenuPolicyTests` covers the constructor and source consumer sets,
exclusive intersection, source Show log exception and stable repeated-parent
order. `docs/qa/log-context-menu-policy-native-2026-10-18.swift` exercises the
production menu against private real history: masks across multiple families,
empty submenu/separator cleanup, Show log exceptions, unmasked range entries,
default emphasis, unchanged input/index/HEAD and policy/Quit/one-shot retirement.
Fixture existence does not prove a pass; the parent records the grouped outcome.

This does not certify the full Windows menu or every shared-list consumer.
The connected [Rebase revision menu family](REBASE-REVISION-MENU-PARITY.md)
now applies the choosing-phase action/current/done gates and existing command
consumer mappings to the embedded native list. [Durable paused-session editing](REBASE-PENDING-ACTIONS-PARITY.md) now handles
reproducible native sessions; the rest of the shared Log commands remain open. Remaining work also includes historical Blame
parent-path actions outside normal Log, every source command's exact enabled/
omitted matrix across all branch/merge/submodule/reflog states, all source
separators under asynchronous Combine visibility, Windows default-item versus
AppKit visual emphasis, and physical pointer/VoiceOver discovery. Consumer
presets do not imply those missing UI handlers have been implemented. There is
no invented global picker restriction and no whole-port completion claim.

Actual grouped build/check outcomes: [history action batch evidence](qa/history-actions-2026-10-18.json).

The [connected consumer continuation](HISTORY-REFERENCE-WORKFLOWS.md) implements
additional Rebase reference menus and Blame parent/file behavior. Its source and
verification scope supersede those specific older gaps without certifying every
shared-list state or full visual parity.
