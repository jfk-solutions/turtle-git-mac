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

Shutdown fences queued callbacks, cancels and awaits active readers, and retains
published status without writing after it returns. The host must explicitly await
shutdown before exiting. Concurrent shutdown also awaits readers already retiring
for a registration replacement.

This is the reusable runtime, not an installed login service. Authenticated IPC,
service target/registration, signed sandbox transfer, additional independent
administration grants and physical Finder acceptance remain open. Unavailable old
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
