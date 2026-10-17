# Finder snapshot query lifetime and directory menus

This continues the pinned TortoiseGit status-cache and context-menu adaptation at
`7338078f8ddd924b8cddee35f512f2286072136d`. Native Finder consumes the already
published snapshot; building menus or looking up a badge never runs Git. Source
menu order, command masks, artwork, grants and Git operations are unchanged.

## Reusing one snapshot generation

Each snapshot lazily retains its exact path namespace and watched-root set. The
namespace preserves exact UTF-8 components and the existing unique canonical-alias
fallback; ambiguous aliases still refuse lookup. Repeated menu eligibility and
root queries reuse that namespace. Root lookup walks the selected path's ancestors
in an exact set instead of scanning all watched roots. Badge projection uses the
same exact root set, independently of filesystem alias matching.

Directory commands use a cached set of descendant states grouped by the real
entry owner. Independent nested repositories cannot make a parent-only folder
Resolve/Revert/Delete action eligible. A registered submodule's parent gitlink is
separate from that child's internal changes. Direct tracked entries still beat
ignored ancestry. Legacy snapshots retain their original aggregate-entry behavior;
modern snapshots use their direct entries. Original menu predicates keep their
specific state sets and selection rules.

The cache belongs to a snapshot value. A retained value may share immutable query
data with its copies. Mutating roots, states, direct entries or repository facts
replaces only the changed copy's query generation; an older captured value keeps
its own results. Construction/publication is protected for concurrent readers.
Timestamps and index-flag presentation do not change path/owner eligibility. Query
data is never encoded into the shared snapshot or writer-state protocol.

## Scope and remaining acceptance

The batch exercises value copies and each relevant mutation, direct versus legacy
entries, nested and registered-child ownership, canonical peers, concurrent reads,
wire encoding and repeated queries over a 5,000-entry/201-root cache. The native
receiver constructs actual Finder menus, checks original icons and eligibility,
changes snapshots after warming them, and retains the existing exact-root and
foreground/event/cross-process publication checks with owned cleanup.

Timing samples describe this host and fixture, without a flaky performance gate or
an estimate for all repositories. The first query still builds a namespace or
ancestor-state index from its snapshot. Memory use is proportional to cached paths
and ancestors. Finder snapshot reading/JSON decoding and overall badge refresh
remain synchronous; this batch does not claim asynchronous Finder reloads or bounded
latency on very large repositories. Physical Finder, huge/sparse/remote-volume
loads, accessibility, minimum OS and installed signed/App Store acceptance remain
open. No new screenshots or whole-application certification follow from the query
implementation.

The [18 October checkpoint](qa/finder-query-family-2026-10-18.json) passed on its
first validation attempt: 48 scoped Core cases, the Debug build and both native
engine cases. The local 5,000-entry/201-root Core sample recorded a 117 ms cold
query and 33 ms for 1,500 warm folder/root queries. Production native menu samples
recorded about 0.8 seconds cold (including initial artwork/menu construction) and
0.23 seconds for 20 warm menus. These are host-specific measurements without a
before/after speedup claim. All owned receivers and workers were reaped; the six
reported PIDs were independently absent. No broader test set was repeated.
