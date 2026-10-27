# Finder startup and publication cost

This batch keeps the Finder workflow while removing work unrelated to opening
an individual action window. It follows the saved repository authority, cache
mode, live publication and cancellation contracts documented in
[FINDER-REGISTRATION-PARITY.md](FINDER-REGISTRATION-PARITY.md),
[FINDER-CACHE-PERSISTENCE.md](FINDER-CACHE-PERSISTENCE.md) and
[FINDER-STATUS-POLICY-PARITY.md](FINDER-STATUS-POLICY-PARITY.md).

## Action windows and monitoring

An action router loads its saved repository authority without starting fresh
status collections for every saved root. A completed Git mutation requests a
refresh of its matching watched repository. This route cannot turn an unknown
Finder path into a grant. Exact path matching retains Unicode identities; a
moved repository can be found through its retained bookmark, preserving its
watch identity and replacing the previous owned cache subtree.

Opening the workspace or the watched-repository settings restores the complete
local watch set using the same manager. Background authority transfer remains a
complete replacement: a partial action manager cannot send a subset of grants.
When Add to TurtleGit or a completed Clone needs the enabled background helper,
every saved grant is checked through the existing Git root discovery and scope
containment path. Preparing that authority does not collect unrelated status or
submodules. An unavailable unrelated saved folder keeps the valid target registered
locally and defers helper synchronization with a visible service error; a partial
grant set is never sent. Other available grants are still prepared so recovery of
the unavailable folder can finish the complete transfer. Cancellation must drain
preparation before the existing accepted
publication and paired recent-repository record can finish.

## Publication validation

Within one writer operation or atomic read attempt, canonical path spelling is
checked once per exact UTF-8 path. Root membership is checked independently for
each contribution. Immutable contribution objects are retained for that operation
so an unchanged payload need not be walked again before writing. Changed or
freshly decoded contributions still require validation. No trust cache survives
an operation or replaces validation of another process's files.

Every original field remains covered: roots, states, repository metadata,
overlay entries, index flags and overlay policies. Namespace, counter, cardinality,
lease, ticket, policy and hostile-file checks remain in force. Long walks check
cancellation, including before live publication writes. Public APIs and persisted
wire formats are unchanged.

## Evidence and limits

The [build15 acceptance record](qa/signed-consolidation-build15-2026-10-27.json)
contains the original private-repository startup observation and sample. Its
active worker was validating Finder snapshot paths while the main thread was
idle. This proves expensive concurrent publication work; it does not prove that
Finder publication caused the complete Commit delay.

The [grouped checkpoint](qa/finder-startup-publication-2026-10-27.json) records focused Core checks, the existing native
registration family and a bounded private publication comparison using frozen
old and current Debug Core frameworks. A console publication measurement does
not measure full Commit startup, physical Finder refresh latency or signed helper
behavior. Installed build16 predates these performance changes. Complete hosted,
physical Finder, Intel/minimum-macOS and source acceptance remain separate.

The single 20,000-entry Debug sample produced identical semantic hashes and
verified lease cleanup with each framework. Publication measured 21.62 seconds
before and 21.10 seconds after; fresh reads measured 4.94 and 5.09 seconds. This
does **not** establish a substantial publication speedup. Projection and
serialization cost remains open. The native action-routing assertions establish
that unrelated status scans are avoided, but the complete Commit loading delay
still needs an installed measurement.

## Publication pipeline continuation

The next connected batch removes work repeated by an accepted publication:

- The previous complete projection is built only when a ticket is rejected. That
  return still filters contributions through current live leases.
- A successfully decoded raw snapshot can be reused within one operation while
  its regular-file identity remains unchanged. Replacements, symlinks and files
  changed by a settings callback require another check; no decode cache crosses
  operations.
- Exact V2 records and compatibility maps share one UTF-8 ordering. Both wire
  formats and their existing canonical-collision priorities remain present.
- Exact root ownership uses an immutable component index shared by a snapshot's
  queries. It preserves the nearest nested owner, component boundaries, `/`,
  distinct Unicode spellings and value-copy invalidation. Public noncanonical
  inputs retain their previous ancestor behavior. Hashing exact names uses the
  same raw-byte feed for native and bridged String storage.

The [pipeline checkpoint](qa/finder-publication-pipeline-2026-10-27.json) records
the grouped validation and a new measurement separately from the earlier sample.
Neither a synthetic cache timing nor avoided unrelated scans proves the complete
installed Commit loading time. Signed Finder refresh and first-launch acceptance
remain separate.

The continuation passed 103 focused Core methods and all 14 native Finder
case/engine pairs after two fixture-only compile repairs. A fresh frozen/current
Debug comparison with the same console binary measured publication at 21.54 and
12.86 seconds (about 40% less), with fresh reads at 5.12 and 4.60 seconds. Exact
semantic hashes, snapshot size, lease cleanup and private storage cleanup matched.
This is one sample per framework, with no timing threshold. The remaining
12.86-second synthetic publication cost is still substantial, and the result
does not measure complete Commit loading or installed signed Finder latency.

## Repeated persistence maintenance — October 27, 2026

The installed build18 acceptance exposed one writer-lock timeout during Add. A
clean subsequent Add passed; neither observation identifies the earlier lock
holder. Source review found that background root collection reapplies persistence
settings on each refresh. The existing implementation decodes and rewrites the
whole warm archive for each live contribution even when the policy is unchanged.
The physical archive was approximately 63 MB. Finder itself reads without the
writer lock; this contention concerns application/cache-service writers.

The connected correction retains a maintenance receipt for the exact immutable
contribution revisions and regular archive file identity. An unchanged policy
can skip completed maintenance only while both still match, with no pending reset
or legacy migration. Missing/replaced/corrupt archives and failed maintenance must
still follow repair and warning paths. Full maintenance decodes once, merges the
ordered live roots and publishes once. Live publication remains independent of
optional restart-cache failures. This does not increase the five-second lock
limit or claim that every large publication now finishes within it.

[The grouped checkpoint](qa/finder-warm-maintenance-2026-10-27.json) separates this
source correction from build18's physical launch acceptance. Installed build18
predates the maintenance correction; no physical performance or timeout-elimination
claim follows from its successful launch check.

The checkpoint passes 45 focused Core methods, the final incremental Debug build
and six relevant native cases with bundled Git, including URL registration without
launch arguments, cancellation/error ownership and separate-process cache crash
recovery. All seven attempted receiver processes, including the failed fixture
attempt, and its owned cache worker are independently absent. The initial Swift
throwing-expression compile error, contradictory build diagnostic and fixture
startup-order failure remain recorded. No full Core rerun or new signed bundle
was performed after these focused checks passed.
