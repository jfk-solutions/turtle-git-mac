# Finder submodule cache tree

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
The native foreground refresh now discovers initialized registered submodules
recursively and publishes their statuses and source menu metadata together with
the parent. A child no longer has to be opened separately first.

`finderSubmoduleSnapshots` enumerates `.gitmodules` path values using separate
NUL-delimited name/value queries with includes disabled. It checks relative
locations and canonical containment in the authorized tree before running Git
in a child. Missing/uninitialized directories are skipped; discovering the
parent's root from an empty submodule directory does not make it a child root.
An initialized child must discover its own root and match its immediate parent's
registration. Bare targets are skipped. Nested scans use canonical ancestor
tracking. Unsafe paths and failed scans return per-path diagnostics rather than
preventing publication of valid parent/sibling data. These are app operations;
the extension continues to run no Git processes.

The app collects parent status through its existing refresh and supplies its
active lease's location as the scan boundary. It constructs one replacement
snapshot and uses the existing atomic App Group write and notification. No
bookmarks or grants are added to shared metadata. Publication and entitled
permission enforcement remain subject to signed acceptance.

`replaceSubtree` drops previously registered child roots, statuses and metadata
when they disappear or become uninitialized. Other opened repositories survive,
including independently opened nested repositories without a registered parent.
Those independent cached trees remain stale until their own refresh. A parent
modified/conflicted gitlink contributes to the registered child's root badge,
so a clean child checkout does not erase the parent's changed-gitlink state.
Child file statuses and per-repository stash/merge/submodule facts stay separate;
deepest-root lookup supplies the appropriate menus. Existing cache/mark/menu
preference schemas are unchanged.

## Verification and limits

Five new core cases create real nested Unicode/newline submodules, modify an
inner working file, create an outer stash, and verify both levels are collected
with their own status/metadata. Parent HEAD and index entries, and child index
entries, are unchanged by collection. Real deinitialization removes cached
children; subtree replacement retains sibling roots, independent nested roots
and parent gitlink badge severity. Unsafe configured traversal, a symlink to an
outside repository, a non-directory target and an insufficient scan boundary
are rejected/reported; missing targets are skipped. The final full regression
passes 486 core tests with zero failures. Debug and unsigned AppStore builds,
both bundle audits and site generation pass.

The actual extension-source receiver creates a real parent and unopened child,
collects and serializes the cache, and uses the restored snapshot to construct
enabled captured Rename/Remove entries. It verifies parent selection routing.
It displays no menus/windows and activates no Finder controller/extension.
App publication is compiled/source-audited, not an entitled handoff or native
Finder click. Broader visual, menu, picker and signed acceptance remains pending.

Foreground collection is not the complete TGitCache/background-monitor port.
FSEvents, independent/background repository refresh, cancellation and scalable
scan scheduling remain unfinished. Scan failures can leave a child's entries
unavailable until a successful refresh; diagnostics are shown in Finder cache
status. Legacy child roots with no ownership metadata are preserved as independent
until their registration can be refreshed. Old/missing-cache parent permission
fallback, conflict/uninitialized action acceptance and full shell classification
still require work.

Evidence is recorded in
[the verification record](qa/finder-submodule-tree-2026-10-06.json).
