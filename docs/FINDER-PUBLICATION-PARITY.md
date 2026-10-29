# Shared Finder snapshot publication

This batch supplies the publication layer required for app and cache-service
writers to coexist. It adapts TGitCache's centralized cache ownership to the
native JSON snapshot. It does not create the independent service.

## Protocol

FinderSnapshotStore serializes read/merge/write with a persistent POSIX lock.
Lock waits are cancellable and bounded by a monotonic five-second deadline. The
lock file is retained rather than unlinked while other processes may use it.

A writer obtains a ticket before collecting Git state. The private sidecar records
its store identity and issued sequence. Newer requests for the same or overlapping
root supersede older collections. Unrelated roots can commit in either order.
Tickets publish once; failed publication requires a new ticket/read rather than
replaying an old result. Removal advances the sequence before deleting the owned
subtree, so late same-root or overlapping writes cannot revive it. Independently
opened nested roots retain the existing subtree-preservation behavior.

Publication reads the latest snapshot under the lock and replaces only the
requested repository subtree. Other repositories, metadata, overlay leaves and
index flags remain. Out-of-subtree payloads are refused. Invalid existing JSON
or non-regular store files fail instead of being silently replaced. Snapshot
writes remain atomic; the extension continues reading the same status.json
schema. Sidecar/lock files contain ordering state, not bookmarks or credentials.

The app's production path issues the ticket before its cancellable collector,
publishes the collected subtree through the store, then updates its cached union
from the committed result. Superseded writes have a distinct status and send no
notification. Notifications still follow successful atomic publication. Private
writer/store injection remains available for native checks.

## Evidence and limits

Core checks cover independent-root merges, duplicate/superseded and overlapping
reads, removal/late replies, nested preservation, foreign tickets, corrupt JSON,
escaping payloads and cancellation while a lock is held. Existing subtree tests
retain child cleanup and independent-root behavior.

The grouped native receiver opens two real app models with a private store,
changes both working files, and verifies both root updates survive. It also starts
two separate owned worker processes against that store and verifies their roots
merge without dropping app roots. These workers exercise the shipping store with
simulated status payloads; they are test receivers, not the deployed cache service.
Notifications are checked after readable writes. The existing event/collector
case remains in the same pass, using both Git engines.

See [actual results](qa/finder-publication-2026-10-13.json). Readers remain lock-free
because the snapshot file is replaced atomically. Ordering is not an atomic Git
filesystem snapshot. Data-write failure may consume a ticket while retaining the
previous snapshot; callers obtain a new ticket to retry. Legacy full-snapshot
writers are outside this protocol and should not be used by the future service.

Independent service packaging/startup, watched-root management, bookmark renewal,
physical Finder activation, signed App Group/security scopes and App Store
acceptance remain open. No complete Finder integration is certified.

## Live ownership and restart continuation — October 19, 2026

[Cache persistence and publisher lifetime](FINDER-CACHE-PERSISTENCE.md) now separate
the optional warm archive from current Finder publication. Version-three control
records retain exact-root contributions per live session. Retirement and crash
filtering preserve other active publishers, while root removal fences owned
subtree claims. Readers cache projection work and probe kernel leases without
waiting for writer locks. Earlier file-survival evidence does not establish live
ownership; updated native workers remain alive during concurrent-root checks and
are then released/reaped before stale-root assertions.

## Large live-cache claim and publication work — October 29, 2026

Installed build35 exposed a live-writer contention error while opening a private
10,001-file repository. Read-only samples showed multiple descriptors in the same
app competing for the store, with full snapshot/control encoding under the lock.
The sampled writer files were about 74 MB. The error did not establish an abandoned
lock, and the lock file must not be removed to work around it.

Current source sequences writers for the same physical store within the process
before starting the existing cross-process lock deadline. Waiting remains
cancellable. Immutable contribution bodies and exact-file-identity decode results
are reused without changing the version-four wire format. A claim-only operation
still persists its ordering fence, but does not rewrite an unchanged live snapshot.
Policy and live-owner changes continue to rebuild the authoritative projection.
The first cold decode remains real work; this is not a promise of zero-cost startup.

Settings dismissal now waits for watch actions accepted by that Settings page,
rather than unrelated workspace registration. Actual Add/Renew/Remove, permission
and background-service actions retain their page ownership until their work drains.
This source correction is separate from the computer-control tool's observed
Settings timeout, which did not prove a blocked application main thread.

The [grouped checkpoint](qa/finder-large-cache-2026-10-29.json) passes 68 distinct
Core methods and native persistence, separate-process lease/removal, Settings close
and retained watch-action cases. Two initial warm-warning regressions were repaired
without removing assertions; only those affected methods were repeated. A private
10,001-file cold claim took about three seconds, while five retained claims took
about nine milliseconds together and repeated no payload work. Those observations
are not an installed startup benchmark. The installed app remains build35, and
physical Finder/Settings acceptance after the control-tool failure is still open.
