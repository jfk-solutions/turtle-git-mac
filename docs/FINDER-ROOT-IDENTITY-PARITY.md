# Finder repository-root identity

The pinned source is TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`:
`TGitCache/GITStatusCache.cpp`, `CachedDirectory.cpp`, `TortoiseShell/ContextMenu.cpp`
and `Git/GitIndex.cpp`. Their status cache, path ownership, repository-wide menu
facts and status lookup are adapted to native Finder snapshots and the owned
macOS cache service. This is partial Finder parity, not a new Windows cache engine.

## Repository facts and selection

File statuses already retain exact UTF-8 identities. Repository metadata now uses
the same path map, so canonically equivalent spellings cannot overwrite another
root's merge, Bisect, stash, LFS, SVN or submodule-parent facts. The nearest root,
common selection owner, registered child owner, deletion/rename eligibility and
cross-root transfer gate use exact component boundaries. An exact cached namespace
wins. A unique canonical filesystem alias remains supported; an ambiguous alias
fails closed rather than borrowing another root's metadata. This cache does not
authorize repository access. App-side discovery, grants and operation validation
remain necessary after a Finder command is selected.

Root replacement/removal preserves independent nested checkouts, raw metadata,
index flags and badges for other roots. Folder aggregation and recursive submodule
badges stay within the exact owning tree. Child-scan failure paths and cycle guards,
service directory counts and queued cache removals also retain exact identities.
Finder request relative-path extraction uses byte boundaries instead of grapheme
counts and cannot treat a canonical peer as a selected root or descendant.

## Snapshot and writer migration

The shared snapshot adds lossless `repositoriesV2` records, alongside the existing
lossless file/overlay/index-flag fields. Current readers prefer the new records and
reject malformed/duplicate exact keys. Legacy metadata remains a deterministic
first-byte-sorted projection. Older extensions can read that reduced field while
an app update is being activated; their format cannot represent canonical peers.
Existing legacy snapshots still load, but names already lost in an older writer's
String dictionary cannot be reconstructed from that snapshot.

The private `.writers` file migrates version 1 to version 2 while preserving its
store UUID, monotonic counter and known tickets. Version 2 stores root/sequence and
root/consumed records losslessly. Newer same-root or overlapping subtree reads
supersede old ones; independent canonical peers no longer supersede each other.
Removal consumes that root's pending work without erasing its peer. Invalid
cross-root and non-normalized payloads fail before publication. Locking, atomic
snapshot replacement and cancellation remain in the existing store.

Older app/cache-service writers refuse version 2 instead of overwriting its exact
keys. Update/restart both writers together; do not downgrade by deleting the writer
file while another process is publishing. Installed extension readers still use the
compatible status snapshot. No bookmark/credential format is changed by this batch.

## Validation scope and open work

The batch checkpoint covers lossless/legacy decoding, exact ownership and ambiguous
aliases, root removal/reopen, ticket ordering, format migration, invalid payloads,
badges and selected-path round trips. The native receiver exercises production
Finder menu construction/icons, primitive one-use dispatch, concurrent owned cache
writers and the retained two-foreground-model publication/event family.

The native host volume may alias canonical filenames. The wire fixture intentionally
retains both spellings; it does not prove two physical canonical-peer directories
exist on that volume. Physical multi-volume Finder behavior, migration between
installed signed versions, security-scoped bookmark aliases, minimum OS, all icon
sets/menu masks and full App Store distribution acceptance remain open. No new
screenshot or complete Finder/port certification follows from this batch.

The [18 October checkpoint](qa/finder-root-identity-family-2026-10-18.json)
records 71 distinct relevant Core cases with passing evidence across the initial
unaffected cases and focused repairs. Two Debug builds and both native engine
cases passed; only the affected transfer/creation checks were repeated after
final alias-owner review. Initial compile/legacy-fixture failures are retained.
All four receivers, eight reported exact-root workers and eight retained publication
workers were reaped. The twelve reported PIDs were independently absent. No full
Core, signed deployment, physical Finder or full hosted CI certification is made.

The [query-lifetime continuation](FINDER-QUERY-PARITY.md) reuses the exact namespace
and owner-scoped descendant state within each snapshot value. Mutations detach
query data from retained copies; source masks, wire identities and migration policy
remain as documented above.
