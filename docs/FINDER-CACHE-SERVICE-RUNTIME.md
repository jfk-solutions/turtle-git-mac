# Independent cache runtime

The source reference is the pinned TortoiseGit `TGitCache/DirectoryWatcher.cpp`
(`Stop`, `RemovePathAndChildren`, `WorkerThread`): owned stream/thread lifetime,
root removal and event-driven crawling are adapted to FSEvents and Swift tasks.
Windows completion-port recovery and its cache service are not a native deployment
proof.

`FinderCacheServiceRuntime` connects receiver-private persisted permissions to
long-lived FSEvents streams, cancellable recursive repository collection and the
shared publication protocol. It can run without a workspace window or main app
model. The host supplies its Git executable, shared store and notification hook.

Startup restores receiver-owned bookmarks, retains one lease per usable root and
reports unavailable saved entries. Streams are installed before the initial status
read. Working tree, Git administration and linked-worktree common administration
must all lie inside the acquired scope; extra permissions are still required for
shared administration outside that scope. Such roots report failure rather than
silently publishing an incompletely watched result.

Each read acquires a publication ticket before collection. Only successful current
publication triggers notification; superseded reads schedule another collection.
Filesystem events coalesce while a read is running. Submodule failures and monitor
startup errors remain visible to the host.

Replacement validates and persists the entire new authorization set first. Failed
permission installation leaves current streams and registrations intact. Successful
installation retires old callbacks and streams, cancels Git readers and waits for
them before attaching replacements. Removed active roots are tombstoned in the
shared cache. Cleanup failures are separate from read failures and retry on manual
refresh or the next replacement. Multiple moved paths are retained for cleanup.
Grant persistence and shared-cache cleanup are separate transactions.

Shutdown fences queued callbacks, cancels and awaits active readers, then ends
only its own live publication session. Other active publishers remain eligible.
The optional warm archive follows the shared default-true CacheSave policy;
current status is not trusted merely because its file survived a process exit.
The host must explicitly await shutdown before exiting. Concurrent shutdown also
awaits readers already retiring for a registration replacement. See
[cache persistence and publisher lifetime](FINDER-CACHE-PERSISTENCE.md).

The reusable runtime is hosted by the [embedded cache agent](FINDER-SERVICE-DEPLOYMENT.md).
Its signed development checkpoint covers selected installed behavior; denied peers,
all additional administration scopes, minimum-OS execution and distribution
approval retain separate acceptance requirements. Unavailable old
registrations have no resolved path to tombstone; cleanup retries are currently
in-memory and do not survive a process crash. The shared cache is not a substitute
for permission authority.

Validation uses private roots and owned processes. The native receiver checks real
Foundation bookmark persistence, cache updates from an external edit after the
sender releases its lease, settled shutdown and unchanged HEAD/index. Its unsigned
security-scope exemption does not prove signed sandbox access.

The Debug build, seven focused Core checks, two-engine native receiver batch and
website build passed. Owned parent receiver PIDs were independently checked absent;
child workers were waited/reaped by their parent fixture. The initial actor-isolation
and test-closure compilation failures were fixed before the successful run. Detailed
scope and source hashes are in `qa/finder-service-runtime-2026-10-13.json`.

## Optional cache menu and local activity — October 16, 2026

The independent helper now owns [the cache menu](CACHE-MENU.md), with source
counts, bounded activity, cache-mode changes and awaited Exit. Startup collection,
accepted publication and failures feed its local activity ring; watched-path and
cached-folder counts come from current sessions. These private paths are not added
to the authenticated report or shared snapshot. Exit, signals and system Quit
share one shutdown task before process exit. Signed/physical acceptance remains
open; this does not weaken the helper's identity or bookmark requirements.

Twelve focused Core cases, the repaired Debug build, native cache-menu/window
receiver and embedded helper audit pass. The initial native selector-dispatch
failure, owned-process sampling/termination, repair scope and exact boundaries are
recorded in [the batch evidence](qa/cache-tray-2026-10-16.json). Only the affected
native case was repeated; Core was not rerun for that repair. The activity window
captures are published in the guide; no real system menu-bar item or signed user
service was installed by the native check.
