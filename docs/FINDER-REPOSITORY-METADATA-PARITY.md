# Finder repository metadata and command availability

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
The app now publishes repository-wide facts used by existing Finder commands.
Full shell path/status clauses, background monitoring and signed handoff remain
pending; cached facts are not permission or fresh Git-state validation.

## Source and collector

`TGitPath.cpp` (`312f765756181b69ef0421d6c681b1aa7ff6ebb2`) sets stash,
bisect, merge and submodule-container bits in GetAdminDirMask. Its operation
markers belong to the particular worktree, while stash belongs to shared refs.
Submodule-container means `.gitmodules` exists, not that indexed gitlinks exist.
`MenuInfo.cpp` applies these bits and bare-repository alternatives to commands.

The containing app's GitRepository actor resolves the absolute Git directory,
removing only Git's final LF so whitespace/Unicode/newlines in paths survive.
BISECT_START and MERGE_HEAD are checked there, including linked-worktree private
Git directories. Git's ref resolver checks refs/stash across loose, packed and
supported current ref storage. This replaces the source's manual loose/packed
scan; malformed refs can report a collector error rather than publish false facts.
Bare identity is reused from the app scan or queried by the collector.
`.gitmodules` presence follows the source and does not parse its content.

Finder does not invoke the collector or run Git. It reads the shared snapshot.

## Snapshot and application wiring

`FinderSnapshot.repositories` is a root-keyed dictionary of bare, bisectActive,
mergeActive, hasStash and hasSubmoduleConfig values. Missing metadata in older
snapshots decodes as an empty dictionary. Older readers continue decoding the
unchanged roots/states/updated fields and ignore the added key. The preferences
file and comparison mark schema are unchanged.

The app restores this dictionary with the other cached data at startup. Each
successful repository refresh collects and replaces that root's metadata while
preserving other roots, then publishes it with statuses through the existing
atomic snapshot write and distributed notification. These are code paths that
compile; actual entitled application-to-extension publication remains unverified.

The consumer selects the deepest cached root containing the whole selection,
respecting path-component boundaries. Legacy/missing metadata retains the earlier
menu behavior until that repository is refreshed; it does not invent facts.
Non-current repositories can retain stale facts because the independent cache
service/FSEvents/background refresh remains unfinished.

## Implemented repository clauses

- Bare metadata admits Fetch, Push, Log, Reflog, Repository Browser and Worktrees
  from the implemented repository-command set. Creation/comparison/Ignore handling
  remains separate and still requires its own path rules.
- Bisect or MERGE_HEAD hides Pull, Merge and Rebase.
- MERGE_HEAD hides Stash save; bisect alone does not, matching the source table.
- Without a stash ref, Stash apply/pop/list are hidden.
- Without `.gitmodules`, Submodule Update is hidden.

Original ordered groups, separators, command snapshots and artwork are retained.
This is repository-wide clause parity, not full command eligibility: single/two
selection, folder/added/versioned status, submodules, git-svn, inaccessible/admin
paths, configuration and other source bit combinations still require porting.
Backend permission and Git-state guards remain necessary after activation.

## Verification

Four new core tests verify old/new-reader snapshot compatibility, root selection
and boundary matching, source repository clause combinations, real ordinary/bare
repositories, actual stash creation/packing/removal and linked-worktree shared
stash/private marker isolation. Operation marker presence is simulated inside real
repositories, following the source's existence checks; real bisect/merge workflows
and signed grants are not claimed by these cases. The focused run passes 16 tests. The full core regression passes 471 tests with
zero failures.

The actual extension source's standalone Swift 6/macOS 13 receiver verifies
absent/present stash and `.gitmodules` menus, merge/bisect exclusions, the six
bare-root commands and preserved source groups. Existing menu order, selection,
icon and cache checks also run. No controller, extension, window or popup is
activated. Broader native/signed and stale-state acceptance remains pending.

Build, regression and bundle evidence is recorded in
[the verification record](qa/finder-repository-metadata-2026-10-06.json).
