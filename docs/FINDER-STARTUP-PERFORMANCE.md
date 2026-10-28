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

## Cold command delivery and foreground startup — October 28, 2026

A Finder click must open its requested dialog even when the app is not running.
The old extension supplied only `--turtlegit-action-only` as launch arguments;
the actual command existed solely in a GetURL event during SwiftUI startup.
Existing warm/direct-delegate checks did not establish that first event's
delivery ordering. The receipt protocol supports the same single-use request through unsandboxed
launch arguments or URL Apple events. The following signed-SDK investigation
separates those paths: sandboxed callers cannot supply launch arguments.

The extension publishes the original validated FinderRequest URL into a separate
private `ActionHandoffs-v1` directory. A bounded envelope carries only a random
receipt ID and action, keeping long selections off argv. Both encodings use that
envelope. Exclusive no-follow claiming permits one consumer, and the application
remembers accepted attempt IDs so an argv/event duplicate cannot repeat a Git
action or show a second error. Different menu clicks retain distinct IDs, even
for the same command and path. Missing or malformed requests use the existing
owned compact error presentation. A tool process forwards the unconsumed request
to an independent application owner using Launch Services URL delivery. Neither transport nor its private payload
grants repository authority.

The payload is bounded to 1 MiB and retains the existing private handoff
primitive's expiry, file validation, exclusive claim, cleanup and directory
limits. Clipboard patch bytes remain a separate capability. A failed extension
launch discards its unpublished action and captured patch receipt; a failed
request preparation still attempts an identifiable error handoff.

Workspace construction previously published cache persistence and two policy
transactions synchronously. Each writer-lock acquisition could wait up to five
seconds before a window was presented. Workspace services now begin after
presentation, with typed captured settings and policy/cache work off the main
actor. Watch restoration waits for accepted cache authority, resolves captured
bookmarks on workers and adopts renewed records only if their source record is
still current. Cache-session creation also runs off the main actor. Closing the
owner cancels startup and drains acquired sessions instead of publishing a late
watcher set.

An ordinary Finder action also used to resolve saved grants in archive order on
the main actor before testing containment. Foreground lookup now prioritizes
the selected path's likely saved record and resolves it off the main actor;
moved-bookmark fallback remains available. This avoids resolving unrelated saved
roots first without treating a recorded path as authority. The separate recent
repository and watched-repository archives retain their different policies.

Saved global Git configuration directory scopes remain required for reads as
well as writes. A shared independent resolver retains those scopes before
signalling a synchronous Core Git execution boundary. Async native dispatch
awaits the same result; a wait does not require a main-actor callback to finish.
Cancellation can stop a waiting Git command before it spawns. The same boundary
covers the selected CLI/libgit2 helper and direct Git daemon. Config-write
choosers retain their existing explicit permission checks.

The [cold-start checkpoint](qa/finder-cold-start-2026-10-28.json) records actual
Core, native and fresh SwiftUI-process results, phase timings, failures and
cleanup. Those private observations must not be presented as a measured speedup
for every repository. The earlier Ladybird Core read profile remains a separate
warm measurement. Commit start hooks, optional provider/network reads and a full
signed physical Finder cold launch have their own observable costs and acceptance
scope; this continuation does not silently skip them.

## Registered commands after publisher exit — October 28, 2026

[Installed build22](qa/signed-consolidation-build22-2026-10-28.json) passed its
structural checks but failed complete cold Finder acceptance. Ladybird's full Git
menu appeared while its publisher was alive and reverted to first-use commands
after the app quit. `readLive` intentionally projects only living owners; menu
discovery therefore shared the badge lifetime and could not start Commit after
publisher exit. The observed large cache also contains roughly 40 MB live data,
40 MB writer state and 60 MB warm data. Samples showed an idle app main thread
and cache decoding on a worker; the extension sample was idle and does not prove
the cause of every omitted menu.

The following source repair introduces a small registered-root catalog containing
watch UUID, lexical repository root and confirmed working-tree/bare kind. It has
no bookmarks, status, index flags or badge authority. Registration publishes it
before its heavy initial status publication; renewal, movement and removal update
the same watch identity. It remains after the publisher exits. Finder uses it for
single registered folder command discovery, preserving command artwork, source
ordering and menu preferences. Unknown repository kinds expose only general
history/remote utilities until confirmed. File-specific commands and commands selected by conflict, stash, bisect, LFS
or submodule facts continue to require live metadata; hints do not manufacture
those states. Dispatch reacquires actual saved authority
and discovers the current repository.

The catalog projects the current private watch archive under a separate keyed
writer lock, with bounded reads and source identity checks before and after
publication. Stale manager snapshots cannot restore removed catalog roots or
erase a peer's added root. Kind observations match both watch UUID and root.
Production watcher managers share their in-process archive store; arbitrary
cross-process writes to the private policy archive remain a separate persistence
boundary. The catalog itself carries no bookmark data.

Finder callbacks use a nonblocking current-cache check that verifies atomic file
identities and living owner leases without decoding or projection. Changed data
is decoded and prepared on a coalesced worker. An invalid cache loses its status
authority immediately; a late worker result must still match current identities
before installation. Badge invalidations are bounded per main-loop turn, with
on-demand lookup using the current accepted state. This separates command
availability from expensive cache work without reviving dead-owner badges.

The [registered-context checkpoint](qa/finder-registered-context-2026-10-28.json)
records the affected checks, failed attempts and cleanup. It remains distinct
from a complete signed physical cold launch and a general large-repository
performance guarantee.

The installed SDK's `NSWorkspace.OpenConfiguration.arguments` contract states
that arguments are ignored when the caller is sandboxed. Finder is such a
caller. Private argv receivers establish only the unsandboxed protocol, not
Finder's actual launch behavior. Build23 attempted an explicit first GetURL
event; the physical signed extension received launch error256 and no main app
started. The exact OS error cause was not established. This failed configuration
is recorded separately from the successful post-exit menu persistence check.

The following repair uses ordinary `open(urls:withApplicationAt:configuration:)`
URL delivery, preserving the same private receipt envelope and startup ownership.
The tool relay also retains ordinary URL delivery for a single Finder receipt.
Unsandboxed launch arguments remain supplementary and deduplicated against URL
events. The native sender seam asserts the URL, activation and instance policy,
and absence of the rejected custom event. Signed physical acceptance remains
required; descriptor construction alone does not prove sandbox launch behavior.

## Dialog-first loading instead of duplicate workspace scans — October 28, 2026

Build24's physical Finder click reached the app in about half a second and
subsequently opened Commit, but the owner still observed an excessive delay.
Source inspection found `openSession` awaited a complete workspace/Finder reload
before constructing the Commit controller. That work started a publisher session,
collected tracked/status/index/submodule metadata, merged the cache and wrote live
and warm data. Commit then performed its own independent display read. Earlier
private Commit-read timings did not include that first full publication.

The following native repair retains folder and metadata permissions, exact
selection/root validation and a fresh bare check, then presents standalone
self-loading dialogs directly. The explicit family covers Commit, Status, Log,
RefLog, stash list, revision graph, reference/repository browsers, Fetch, Pull,
Push, branch/tag creation, Switch, Reset and Merge. Workspace adoption and
Services actions requiring source eligibility retain their full preflight;
entry-consuming operations use the existing route.

Selected-root Finder publication waits for the chosen dialog's first read to
settle. It has its own adoption token, dialog-close cancellation and termination
drain, without setting routing busy. Post-await state and monitor updates check
the captured root/adoption so a previous refresh cannot overwrite a newer root.
Commit's hooks, provider/template handling, staged state and mutation readiness
remain in its own load. No optional read is silently skipped.

Local `DialogStartup` OS log phases record preflight, repository readiness,
window presentation and Commit identity/change/message/row readiness, using only
timing and row counts. They contain no paths, messages or configuration values.
The [dialog-first checkpoint](qa/dialog-first-read-2026-10-28.json) requires real
Commit, Log and Status windows and data while a private Finder writer lock remains
held. That ordering proof is distinct from the next signed Ladybird timing check.
