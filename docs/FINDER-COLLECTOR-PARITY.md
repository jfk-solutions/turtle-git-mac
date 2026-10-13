# Cancellable Finder cache collection

This batch prepares the read engine needed by an independent cache service. It
also corrects a foreground issue: recursive child scans used ordinary Git status,
which can update child indexes and trigger more filesystem notifications.

## Whole-read ownership

`collectFinderRepository` returns one Sendable collection: root/bare/branch,
working status, replay/submodule facts, shell metadata, watch directories, root
and child snapshots, and ordinary child failures. It retains literal Git argument
arrays and existing subtree projection. A caller must retain its access lease
for the whole operation; the authorized-root check is not a security-scope grant.

Cancellation reaches root discovery, bare/status/branch, tracked paths/index
flags, watch-dir discovery, metadata and every recursive child query. Cancellation
in an optional metadata lookup cannot turn into a default, and cancellation in a
child scan cannot become an ordinary partial-error snapshot. Ordinary missing,
unsafe or inaccessible children still report their existing partial failures.
Owned Git process groups terminate and settle before cancellation returns.

Root and child status reads use GIT_OPTIONAL_LOCKS=0. Read-only collection does
not refresh index stat caches. The optional asynchronous watch-ready callback
runs after watch-dir discovery and before status; the app establishes FSEvents
before reading, preserving invalidations during the initial collection.

The workspace consumes the single collection instead of assembling a separate
uncancellable read chain. Its existing snapshot publication, child-failure message
and notification-after-write behavior remain. This does not add an independent
process or change the shared cache format.

## Validation scope

The focused group covers pre-cancelled reads, complete nested-module snapshots,
exact raw index/content/HEAD preservation, and nine live root/child cancellation
phases with owned leader/child reaping. Existing metadata/submodule tests retain
linked/bare facts, unsafe scope rejection, removed-child cache cleanup and nested
independent-root preservation.

The expanded native event receiver drives the shipping app model with private
snapshots and notifications on system and packaged Git. It adds real registered
child edits and exact child-index-byte preservation to working-file edits, busy/
Quit deferral, retirement and linked shared-admin invalidation.

See [actual verification](qa/finder-collector-2026-10-13.json). Independent cache
process/startup, watched-root management, cross-process publication ownership,
physical Finder activation, signed grants and App Store acceptance remain open.
The app still blocks ordinary Close/Quit during foreground work; this API's owned
cancellation checks do not establish a new visible Cancel control.

All 16 focused Core checks passed on the first grouped run. The expanded native
case passed with system and packaged Git; both receivers were reaped and
independently verified absent. Debug and unsigned App Store builds and the website
build passed. No full runtime audit or signed/physical acceptance was repeated.

The later [publication batch](FINDER-PUBLICATION-PARITY.md) routes production
app updates through root-scoped tickets and atomic cross-process merge ownership.
The independent service remains unimplemented.
